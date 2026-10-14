package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
)

// recordedRequest is a request that the fake Public API received.
type recordedRequest struct {
	method string
	path   string
	query  map[string]string
	header http.Header
	body   map[string]any
}

// fakeRoute is the status and JSON body that the fake Public API returns for one route.
type fakeRoute struct {
	status int
	body   string
}

// newFakeAPI starts a Public API stub that answers each "METHOD /path" key of routes, and records every request it receives.
func newFakeAPI(t *testing.T, routes map[string]fakeRoute) (srv *httptest.Server, recorded *[]recordedRequest) {
	t.Helper()
	recorded = &[]recordedRequest{}
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := recordedRequest{
			method: r.Method,
			path:   r.URL.Path,
			query:  map[string]string{},
			header: r.Header.Clone(),
		}
		for key := range r.URL.Query() {
			rec.query[key] = r.URL.Query().Get(key)
		}
		reqBody, err := io.ReadAll(r.Body)
		if err != nil {
			t.Errorf("read request body: %v", err)
		}
		if len(reqBody) > 0 {
			if err := json.Unmarshal(reqBody, &rec.body); err != nil {
				t.Errorf("request body is not JSON: %v", err)
			}
		}
		*recorded = append(*recorded, rec)

		route, ok := routes[r.Method+" "+r.URL.Path]
		if !ok {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(route.status)
		_, _ = io.WriteString(w, route.body)
	}))
	t.Cleanup(srv.Close)
	return srv, recorded
}

// chdirWorkspace makes a temporary directory the working directory, as the runner does with the workspace, and writes go.sum there.
func chdirWorkspace(t *testing.T) {
	t.Helper()
	t.Chdir(t.TempDir())
	if err := os.WriteFile("go.sum", []byte("content"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestResolvePath(t *testing.T) {
	tests := []struct {
		name         string
		lockfilePath string
		repoName     string
		want         string
	}{
		{name: "without repo name cleans path", lockfilePath: "./go.sum", want: "go.sum"},
		{name: "without repo name keeps directories", lockfilePath: "./web/../web/yarn.lock", want: "web/yarn.lock"},
		{name: "repo name prefix", lockfilePath: "./web/yarn.lock", repoName: "owner/repo", want: "owner/repo/web/yarn.lock"},
		{name: "absolute path loses leading slash", lockfilePath: "/github/workspace/go.sum", want: "github/workspace/go.sum"},
		{name: "absolute path with repo name", lockfilePath: "/github/workspace/go.sum", repoName: "owner/repo", want: "owner/repo/github/workspace/go.sum"},
		{name: "repo name with leading slash", lockfilePath: "go.sum", repoName: "/owner/repo", want: "owner/repo/go.sum"},
		{name: "url prefix", lockfilePath: "go.sum", repoName: "https://github.com/owner/repo", want: "https://github.com/owner/repo/go.sum"},
		{name: "url prefix with trailing slash", lockfilePath: "./go.sum", repoName: "https://github.com/owner/repo/", want: "https://github.com/owner/repo/go.sum"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := resolvePath(tt.lockfilePath, tt.repoName); got != tt.want {
				t.Errorf("resolvePath(%q, %q) = %q, want %q", tt.lockfilePath, tt.repoName, got, tt.want)
			}
		})
	}
}

func TestUpload(t *testing.T) {
	tests := []struct {
		name       string
		routes     map[string]fakeRoute
		want       uploadResult
		wantMethod string
		wantBody   map[string]any
	}{
		{
			name: "creates lockfile when none is registered",
			routes: map[string]fakeRoute{
				"GET /v1/server/uuid/uuid-1": {status: http.StatusOK, body: `{"id":10}`},
				"GET /v1/lockfiles":          {status: http.StatusOK, body: `{"paging":{}}`},
				"POST /v1/lockfile":          {status: http.StatusOK, body: `{"id":99}`},
			},
			want:       uploadResult{isCreated: true, lockfileID: 99},
			wantMethod: http.MethodPost,
			wantBody:   map[string]any{"serverID": float64(10), "path": "owner/repo/go.sum", "fileContent": "content"},
		},
		{
			name: "updates registered lockfile",
			routes: map[string]fakeRoute{
				"GET /v1/server/uuid/uuid-1": {status: http.StatusOK, body: `{"id":10}`},
				"GET /v1/lockfiles":          {status: http.StatusOK, body: `{"lockfiles":[{"id":7}]}`},
				"PUT /v1/lockfile/7":         {status: http.StatusOK, body: `{"id":7}`},
			},
			want:       uploadResult{isCreated: false, lockfileID: 7},
			wantMethod: http.MethodPut,
			wantBody:   map[string]any{"path": "owner/repo/go.sum", "fileContent": "content"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv, recorded := newFakeAPI(t, tt.routes)
			apiClient := newClient(srv.URL, "secret-token")

			got, err := upload(context.Background(), apiClient, "uuid-1", "owner/repo/go.sum", "content")
			if err != nil {
				t.Fatalf("upload() error = %v", err)
			}
			if got != tt.want {
				t.Errorf("upload() = %+v, want %+v", got, tt.want)
			}

			if len(*recorded) != 3 {
				t.Fatalf("recorded %d requests, want 3", len(*recorded))
			}
			list := (*recorded)[1]
			if list.query["filterServerID"] != "10" || list.query["filterPath"] != "owner/repo/go.sum" {
				t.Errorf("lockfile list query = %v, want filterServerID=10 filterPath=owner/repo/go.sum", list.query)
			}
			last := (*recorded)[2]
			if last.method != tt.wantMethod {
				t.Errorf("last request method = %s, want %s", last.method, tt.wantMethod)
			}
			if !reflect.DeepEqual(last.body, tt.wantBody) {
				t.Errorf("last request body = %v, want %v", last.body, tt.wantBody)
			}
		})
	}
}

func TestUploadReturnsError(t *testing.T) {
	tests := []struct {
		name      string
		routes    map[string]fakeRoute
		wantErr   string
		wantErrIs error
	}{
		{
			name: "server response without id",
			routes: map[string]fakeRoute{
				"GET /v1/server/uuid/uuid-1": {status: http.StatusOK, body: `{}`},
			},
			wantErr:   "get server: response has no id",
			wantErrIs: errNoID,
		},
		{
			name: "server response that cannot be decoded",
			routes: map[string]fakeRoute{
				"GET /v1/server/uuid/uuid-1": {status: http.StatusOK, body: `{"id":99999999999999999999999}`},
			},
			wantErr:   "get server: decode response: unexpected response format",
			wantErrIs: errUnexpectedResponse,
		},
		{
			name: "list fails",
			routes: map[string]fakeRoute{
				"GET /v1/server/uuid/uuid-1": {status: http.StatusOK, body: `{"id":10}`},
				"GET /v1/lockfiles":          {status: http.StatusInternalServerError, body: `{"message":"internal"}`},
			},
			wantErr: "list lockfiles: HTTP 500: internal",
		},
		{
			name: "list item without id",
			routes: map[string]fakeRoute{
				"GET /v1/server/uuid/uuid-1": {status: http.StatusOK, body: `{"id":10}`},
				"GET /v1/lockfiles":          {status: http.StatusOK, body: `{"lockfiles":[{}]}`},
			},
			wantErr:   "list lockfiles: response has no id",
			wantErrIs: errNoID,
		},
		{
			name: "update fails",
			routes: map[string]fakeRoute{
				"GET /v1/server/uuid/uuid-1": {status: http.StatusOK, body: `{"id":10}`},
				"GET /v1/lockfiles":          {status: http.StatusOK, body: `{"lockfiles":[{"id":7}]}`},
				"PUT /v1/lockfile/7":         {status: http.StatusBadRequest, body: `{"message":"invalid lockfile"}`},
			},
			wantErr: "update lockfile 7: HTTP 400: invalid lockfile",
		},
		{
			name: "update response without id",
			routes: map[string]fakeRoute{
				"GET /v1/server/uuid/uuid-1": {status: http.StatusOK, body: `{"id":10}`},
				"GET /v1/lockfiles":          {status: http.StatusOK, body: `{"lockfiles":[{"id":7}]}`},
				"PUT /v1/lockfile/7":         {status: http.StatusOK, body: `{"message":"unexpected"}`},
			},
			wantErr:   "update lockfile 7: response has no id",
			wantErrIs: errNoID,
		},
		{
			name: "create fails",
			routes: map[string]fakeRoute{
				"GET /v1/server/uuid/uuid-1": {status: http.StatusOK, body: `{"id":10}`},
				"GET /v1/lockfiles":          {status: http.StatusOK, body: `{}`},
				"POST /v1/lockfile":          {status: http.StatusBadRequest, body: `{"message":"invalid lockfile"}`},
			},
			wantErr: "create lockfile: HTTP 400: invalid lockfile",
		},
		{
			name: "create response without id",
			routes: map[string]fakeRoute{
				"GET /v1/server/uuid/uuid-1": {status: http.StatusOK, body: `{"id":10}`},
				"GET /v1/lockfiles":          {status: http.StatusOK, body: `{}`},
				"POST /v1/lockfile":          {status: http.StatusOK, body: `{}`},
			},
			wantErr:   "create lockfile: response has no id",
			wantErrIs: errNoID,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv, _ := newFakeAPI(t, tt.routes)
			apiClient := newClient(srv.URL, "secret-token")

			_, err := upload(context.Background(), apiClient, "uuid-1", "go.sum", "content")
			if err == nil || err.Error() != tt.wantErr {
				t.Errorf("upload() error = %v, want %q", err, tt.wantErr)
			}
			if tt.wantErrIs != nil && !errors.Is(err, tt.wantErrIs) {
				t.Errorf("upload() error = %v, want errors.Is %v", err, tt.wantErrIs)
			}
		})
	}
}

func TestClientSendsToken(t *testing.T) {
	srv, recorded := newFakeAPI(t, map[string]fakeRoute{
		"GET /v1/server/uuid/uuid-1": {status: http.StatusOK, body: `{"id":10}`},
	})
	apiClient := newClient(srv.URL, "secret-token")

	if err := apiClient.do(context.Background(), http.MethodGet, "v1/server/uuid/uuid-1", nil, nil, nil); err != nil {
		t.Fatalf("do() error = %v", err)
	}
	if got := (*recorded)[0].header.Get("Authorization"); got != "secret-token" {
		t.Errorf("Authorization header = %q, want %q", got, "secret-token")
	}
}

func TestClientReturnsErrorOnFailureStatus(t *testing.T) {
	tests := []struct {
		name    string
		route   fakeRoute
		wantErr string
	}{
		{
			name:    "includes API error message",
			route:   fakeRoute{status: http.StatusNotFound, body: `{"message":"not found"}`},
			wantErr: "HTTP 404: not found",
		},
		{
			name:    "omits body that is not an API error",
			route:   fakeRoute{status: http.StatusBadGateway, body: `<html>upstream detail</html>`},
			wantErr: "HTTP 502",
		},
		{
			name:    "truncates long API error message",
			route:   fakeRoute{status: http.StatusBadRequest, body: `{"message":"` + strings.Repeat("あ", maxErrorMessageLen+1) + `"}`},
			wantErr: "HTTP 400: " + strings.Repeat("あ", maxErrorMessageLen) + "...",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv, _ := newFakeAPI(t, map[string]fakeRoute{"GET /v1/server/uuid/uuid-1": tt.route})
			apiClient := newClient(srv.URL, "secret-token")

			err := apiClient.do(context.Background(), http.MethodGet, "v1/server/uuid/uuid-1", nil, nil, nil)
			if err == nil || err.Error() != tt.wantErr {
				t.Errorf("do() error = %v, want %q", err, tt.wantErr)
			}
		})
	}
}

func TestClientTransportErrorOmitsURL(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	srv.Close()
	apiClient := newClient(srv.URL, "secret-token")

	err := apiClient.do(context.Background(), http.MethodGet, "v1/server/uuid/uuid-1", nil, nil, nil)
	if err == nil {
		t.Fatal("do() error = nil, want a transport error")
	}
	if strings.Contains(err.Error(), "uuid-1") || strings.Contains(err.Error(), srv.URL) {
		t.Errorf("do() error = %q, want it without the request URL", err.Error())
	}
}

func TestClientDoesNotFollowRedirect(t *testing.T) {
	var isRedirected bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/elsewhere" {
			isRedirected = true
			return
		}
		http.Redirect(w, r, "/elsewhere", http.StatusFound)
	}))
	t.Cleanup(srv.Close)
	apiClient := newClient(srv.URL, "secret-token")

	err := apiClient.do(context.Background(), http.MethodGet, "v1/server/uuid/uuid-1", nil, nil, nil)
	if err == nil || !strings.Contains(err.Error(), "HTTP 302") {
		t.Errorf("do() error = %v, want error containing %q", err, "HTTP 302")
	}
	if isRedirected {
		t.Error("client followed the redirect and resent the token")
	}
}

func TestIsSecureBaseURL(t *testing.T) {
	tests := []struct {
		name    string
		baseURL string
		want    bool
	}{
		{name: "https", baseURL: "https://rest.vuls.biz", want: true},
		{name: "http to localhost", baseURL: "http://localhost:8080", want: true},
		{name: "http to ipv4 loopback", baseURL: "http://127.0.0.1:8080", want: true},
		{name: "http to ipv6 loopback", baseURL: "http://[::1]:8080", want: true},
		{name: "http to remote host", baseURL: "http://rest.vuls.biz", want: false},
		{name: "http to host named like localhost", baseURL: "http://localhost.example.com", want: false},
		{name: "http to host named like loopback ip", baseURL: "http://127.0.0.1.example.com", want: false},
		{name: "unsupported scheme", baseURL: "ftp://localhost", want: false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isSecureBaseURL(tt.baseURL); got != tt.want {
				t.Errorf("isSecureBaseURL(%q) = %v, want %v", tt.baseURL, got, tt.want)
			}
		})
	}
}

func TestIsSafeRepoName(t *testing.T) {
	tests := []struct {
		name     string
		repoName string
		want     bool
	}{
		{name: "empty", repoName: "", want: true},
		{name: "owner and repo", repoName: "owner/repo", want: true},
		{name: "url", repoName: "https://github.com/owner/repo", want: true},
		{name: "url with trailing slash", repoName: "https://github.com/owner/repo/", want: true},
		{name: "url with credentials", repoName: "https://user:pass@github.com/owner/repo", want: false},
		{name: "url with user only", repoName: "HTTPS://user@github.com/owner/repo", want: false},
		{name: "url with query", repoName: "https://github.com/owner/repo?q=1", want: false},
		{name: "url with empty query", repoName: "https://github.com/owner/repo?", want: false},
		{name: "url with fragment", repoName: "https://github.com/owner/repo#frag", want: false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isSafeRepoName(tt.repoName); got != tt.want {
				t.Errorf("isSafeRepoName(%q) = %v, want %v", tt.repoName, got, tt.want)
			}
		})
	}
}

func TestRun(t *testing.T) {
	createRoutes := map[string]fakeRoute{
		"GET /v1/server/uuid/uuid-1": {status: http.StatusOK, body: `{"id":10}`},
		"GET /v1/lockfiles":          {status: http.StatusOK, body: `{}`},
		"POST /v1/lockfile":          {status: http.StatusOK, body: `{"id":99}`},
	}
	updateRoutes := map[string]fakeRoute{
		"GET /v1/server/uuid/uuid-1": {status: http.StatusOK, body: `{"id":10}`},
		"GET /v1/lockfiles":          {status: http.StatusOK, body: `{"lockfiles":[{"id":7}]}`},
		"PUT /v1/lockfile/7":         {status: http.StatusOK, body: `{"id":7}`},
	}

	tests := []struct {
		name       string
		routes     map[string]fakeRoute
		env        map[string]string
		unset      string
		wantCode   int
		wantOut    string
		wantMethod string
		wantPath   string
	}{
		{
			name:       "creates lockfile with repo name",
			routes:     createRoutes,
			env:        map[string]string{"INPUT_REPONAME": "owner/repo"},
			wantCode:   0,
			wantOut:    "Created lockfile: 99 (owner/repo/go.sum)",
			wantMethod: http.MethodPost,
			wantPath:   "owner/repo/go.sum",
		},
		{
			name:       "updates lockfile without repo name",
			routes:     updateRoutes,
			env:        map[string]string{"INPUT_REPONAME": ""},
			wantCode:   0,
			wantOut:    "Updated lockfile: 7 (go.sum)",
			wantMethod: http.MethodPut,
			wantPath:   "go.sum",
		},
		{name: "requires token", routes: createRoutes, unset: "FVULS_TOKEN", wantCode: 1, wantOut: "::error::FVULS_TOKEN is required"},
		{name: "requires server uuid", routes: createRoutes, unset: "FVULS_SERVER_UUID", wantCode: 1, wantOut: "::error::FVULS_SERVER_UUID is required"},
		{name: "requires path", routes: createRoutes, unset: "INPUT_PATH", wantCode: 1, wantOut: "::error::input path is required"},
		{
			name:     "rejects plain http base url",
			routes:   createRoutes,
			env:      map[string]string{"FVULS_BASE_URL": "http://rest.example.com"},
			wantCode: 1,
			wantOut:  "::error::FVULS_BASE_URL must use https",
		},
		{
			name:     "escapes registered path in success output",
			routes:   createRoutes,
			env:      map[string]string{"INPUT_REPONAME": "owner/repo\n::warning::injected"},
			wantCode: 0,
			wantOut:  "Created lockfile: 99 (owner/repo%0A::warning::injected/go.sum)",
		},
		{
			name:     "rejects repo name url with credentials",
			routes:   createRoutes,
			env:      map[string]string{"INPUT_REPONAME": "https://user:repo-secret@github.com/owner/repo"},
			wantCode: 1,
			wantOut:  "::error::repoName must not contain credentials, a query or a fragment",
		},
		{
			name:     "rejects repo name url with query",
			routes:   createRoutes,
			env:      map[string]string{"INPUT_REPONAME": "https://github.com/owner/repo?token=repo-secret"},
			wantCode: 1,
			wantOut:  "::error::repoName must not contain credentials, a query or a fragment",
		},
		{
			name:     "reports unreadable lockfile",
			routes:   createRoutes,
			env:      map[string]string{"INPUT_PATH": "./missing.lock"},
			wantCode: 1,
			wantOut:  "::error::read lockfile: open ./missing.lock:",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			chdirWorkspace(t)
			srv, recorded := newFakeAPI(t, tt.routes)
			env := map[string]string{
				"FVULS_BASE_URL":    srv.URL,
				"FVULS_TOKEN":       "secret-token",
				"FVULS_SERVER_UUID": "uuid-1",
				"INPUT_PATH":        "./go.sum",
			}
			for key, value := range tt.env {
				env[key] = value
			}
			delete(env, tt.unset)
			var out bytes.Buffer

			code := run(context.Background(), func(key string) string { return env[key] }, &out)

			if code != tt.wantCode {
				t.Errorf("run() = %d, want %d (output: %s)", code, tt.wantCode, out.String())
			}
			if !strings.Contains(out.String(), tt.wantOut) {
				t.Errorf("run() output = %q, want it to contain %q", out.String(), tt.wantOut)
			}
			if strings.Contains(out.String(), "secret-token") || strings.Contains(out.String(), "repo-secret") {
				t.Errorf("run() output leaks a secret: %q", out.String())
			}
			if tt.wantPath == "" {
				return
			}
			if len(*recorded) != 3 {
				t.Fatalf("recorded %d requests, want 3", len(*recorded))
			}
			if got := (*recorded)[1].query["filterPath"]; got != tt.wantPath {
				t.Errorf("filterPath = %q, want %q", got, tt.wantPath)
			}
			last := (*recorded)[2]
			if last.method != tt.wantMethod || last.body["path"] != tt.wantPath {
				t.Errorf("last request = %s path %v, want %s path %q", last.method, last.body["path"], tt.wantMethod, tt.wantPath)
			}
		})
	}
}

func TestRunEscapesErrorAnnotation(t *testing.T) {
	chdirWorkspace(t)
	srv, _ := newFakeAPI(t, map[string]fakeRoute{
		"GET /v1/server/uuid/uuid-1": {status: http.StatusBadRequest, body: `{"message":"bad\n::warning::injected 100%"}`},
	})
	env := map[string]string{
		"FVULS_BASE_URL":    srv.URL,
		"FVULS_TOKEN":       "secret-token",
		"FVULS_SERVER_UUID": "uuid-1",
		"INPUT_PATH":        "./go.sum",
	}
	var out bytes.Buffer

	code := run(context.Background(), func(key string) string { return env[key] }, &out)

	if code != 1 {
		t.Errorf("run() = %d, want 1", code)
	}
	want := "::error::upload go.sum: get server: HTTP 400: bad%0A::warning::injected 100%25\n"
	if out.String() != want {
		t.Errorf("run() output = %q, want %q", out.String(), want)
	}
}

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"
	"time"
)

const (
	requestTimeout = 30 * time.Second
	// maxErrorMessageLen caps the API error message, in characters, that is written to the workflow log.
	maxErrorMessageLen = 200
)

var (
	// errNoID reports a successful Public API response that does not carry the ID of the resource.
	errNoID = errors.New("response has no id")
	// errUnexpectedResponse reports a successful Public API response that cannot be decoded.
	// It replaces the encoding/json error, which quotes values from the response body.
	errUnexpectedResponse = errors.New("unexpected response format")
)

// client calls the FutureVuls Public API.
type client struct {
	baseURL    string
	token      string
	httpClient *http.Client
}

// newClient returns a client that sends token to the Public API at baseURL.
func newClient(baseURL, token string) *client {
	return &client{
		baseURL: strings.TrimSuffix(baseURL, "/"),
		token:   token,
		httpClient: &http.Client{
			Timeout: requestTimeout,
			// net/http keeps the Authorization header on redirects to the same host over plain HTTP and to subdomains.
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
	}
}

// do sends a request to endpoint and decodes the JSON response into out when out is non-nil.
// Its errors leave out the endpoint, which can contain the server UUID; callers wrap them with the operation name.
func (c *client) do(ctx context.Context, method, endpoint string, query url.Values, body, out any) error {
	var reqBody io.Reader
	if body != nil {
		reqJSON, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("encode request body: %w", err)
		}
		reqBody = bytes.NewReader(reqJSON)
	}

	requestURL := c.baseURL + "/" + endpoint
	if len(query) > 0 {
		requestURL += "?" + query.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, method, requestURL, reqBody)
	if err != nil {
		return fmt.Errorf("build request: %w", stripURL(err))
	}
	req.Header.Set("Authorization", c.token)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	res, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("send request: %w", stripURL(err))
	}
	defer func() { _ = res.Body.Close() }()

	resBody, err := io.ReadAll(res.Body)
	if err != nil {
		return fmt.Errorf("read response: %w", err)
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		if msg := getAPIErrorMessage(resBody); msg != "" {
			return fmt.Errorf("HTTP %d: %s", res.StatusCode, msg)
		}
		return fmt.Errorf("HTTP %d", res.StatusCode)
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(resBody, out); err != nil {
		return fmt.Errorf("decode response: %w", errUnexpectedResponse)
	}
	return nil
}

// stripURL returns the cause of a *url.Error without the request URL, which contains the server UUID.
func stripURL(err error) error {
	var urlErr *url.Error
	if errors.As(err, &urlErr) {
		return urlErr.Err
	}
	return err
}

// getAPIErrorMessage returns the "message" field of a Public API error response, truncated to maxErrorMessageLen characters.
// It returns "" for any other body so that unexpected content is not written to the workflow log.
func getAPIErrorMessage(body []byte) string {
	var res struct {
		Message string `json:"message"`
	}
	if err := json.Unmarshal(body, &res); err != nil {
		return ""
	}
	msg := []rune(res.Message)
	if len(msg) > maxErrorMessageLen {
		return string(msg[:maxErrorMessageLen]) + "..."
	}
	return string(msg)
}

// resolvePath returns the lockfile path registered in FutureVuls, prefixed with repoName when it is given.
// The path is cleaned and has no leading "/", because FutureVuls stores it that way and filterPath is an exact match.
func resolvePath(lockfilePath, repoName string) string {
	if isURL(repoName) {
		return strings.TrimSuffix(repoName, "/") + "/" + strings.TrimPrefix(path.Clean(lockfilePath), "/")
	}
	return strings.TrimPrefix(path.Join(repoName, lockfilePath), "/")
}

// isURL reports whether rawURL is an absolute http or https URL.
func isURL(rawURL string) bool {
	parsed, err := url.Parse(rawURL)
	return err == nil && (parsed.Scheme == "http" || parsed.Scheme == "https") && parsed.Host != ""
}

// uploadResult is the lockfile that upload created or updated.
type uploadResult struct {
	isCreated  bool
	lockfileID int64
}

// idResponse is a Public API response that carries the ID of a resource.
type idResponse struct {
	ID int64 `json:"id"`
}

// upload registers content as the lockfile at registeredPath on the server identified by serverUUID.
// It updates the lockfile when one with the same path is already registered, and creates one otherwise.
func upload(ctx context.Context, apiClient *client, serverUUID, registeredPath, content string) (result uploadResult, err error) {
	var server idResponse
	if err := apiClient.do(ctx, http.MethodGet, "v1/server/uuid/"+url.PathEscape(serverUUID), nil, nil, &server); err != nil {
		return uploadResult{}, fmt.Errorf("get server: %w", err)
	}
	if server.ID == 0 {
		return uploadResult{}, fmt.Errorf("get server: %w", errNoID)
	}

	query := url.Values{
		"page":           {"1"},
		"limit":          {"1"},
		"filterServerID": {strconv.FormatInt(server.ID, 10)},
		"filterPath":     {registeredPath},
	}
	var list struct {
		Lockfiles []idResponse `json:"lockfiles"`
	}
	if err := apiClient.do(ctx, http.MethodGet, "v1/lockfiles", query, nil, &list); err != nil {
		return uploadResult{}, fmt.Errorf("list lockfiles: %w", err)
	}

	if len(list.Lockfiles) > 0 {
		lockfileID := list.Lockfiles[0].ID
		if lockfileID == 0 {
			return uploadResult{}, fmt.Errorf("list lockfiles: %w", errNoID)
		}
		body := map[string]any{"path": registeredPath, "fileContent": content}
		var updated idResponse
		if err := apiClient.do(ctx, http.MethodPut, "v1/lockfile/"+strconv.FormatInt(lockfileID, 10), nil, body, &updated); err != nil {
			return uploadResult{}, fmt.Errorf("update lockfile %d: %w", lockfileID, err)
		}
		if updated.ID == 0 {
			return uploadResult{}, fmt.Errorf("update lockfile %d: %w", lockfileID, errNoID)
		}
		return uploadResult{isCreated: false, lockfileID: lockfileID}, nil
	}

	body := map[string]any{"serverID": server.ID, "path": registeredPath, "fileContent": content}
	var created idResponse
	if err := apiClient.do(ctx, http.MethodPost, "v1/lockfile", nil, body, &created); err != nil {
		return uploadResult{}, fmt.Errorf("create lockfile: %w", err)
	}
	if created.ID == 0 {
		return uploadResult{}, fmt.Errorf("create lockfile: %w", errNoID)
	}
	return uploadResult{isCreated: true, lockfileID: created.ID}, nil
}

// Command fvuls-lockfile-uploader uploads a lockfile to FutureVuls through the Public API.
// It runs as a GitHub Action and reads its inputs from environment variables.
package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"strings"
)

const (
	defaultBaseURL = "https://rest.vuls.biz"
	exitSuccess    = 0
	exitFailure    = 1
)

// annotationEscaper escapes workflow command data so that a newline in the output cannot start another workflow command.
var annotationEscaper = strings.NewReplacer("%", "%25", "\r", "%0D", "\n", "%0A")

func main() {
	os.Exit(run(context.Background(), os.Getenv, os.Stdout))
}

// run uploads the lockfile and returns the process exit code.
// Errors are written as GitHub Actions error annotations so that they show up in the workflow summary.
func run(ctx context.Context, getenv func(string) string, stdout io.Writer) int {
	printf := func(format string, args ...any) {
		_, _ = fmt.Fprintf(stdout, format, args...)
	}
	errorf := func(format string, args ...any) {
		printf("::error::%s\n", annotationEscaper.Replace(fmt.Sprintf(format, args...)))
	}

	token := getenv("FVULS_TOKEN")
	serverUUID := getenv("FVULS_SERVER_UUID")
	lockfilePath := getenv("INPUT_PATH")
	for _, required := range []struct{ name, value string }{
		{name: "FVULS_TOKEN", value: token},
		{name: "FVULS_SERVER_UUID", value: serverUUID},
		{name: "input path", value: lockfilePath},
	} {
		if required.value == "" {
			errorf("%s is required", required.name)
			return exitFailure
		}
	}

	baseURL := getenv("FVULS_BASE_URL")
	if baseURL == "" {
		baseURL = defaultBaseURL
	}
	if !isSecureBaseURL(baseURL) {
		errorf("FVULS_BASE_URL must use https")
		return exitFailure
	}
	repoName := getenv("INPUT_REPONAME")
	if !isSafeRepoName(repoName) {
		errorf("repoName must not contain credentials, a query or a fragment")
		return exitFailure
	}

	content, err := os.ReadFile(lockfilePath)
	if err != nil {
		errorf("read lockfile: %v", err)
		return exitFailure
	}

	registeredPath := resolvePath(lockfilePath, repoName)
	res, err := upload(ctx, newClient(baseURL, token), serverUUID, registeredPath, string(content))
	if err != nil {
		errorf("upload %s: %v", registeredPath, err)
		return exitFailure
	}

	escapedPath := annotationEscaper.Replace(registeredPath)
	if res.isCreated {
		printf("Created lockfile: %d (%s)\n", res.lockfileID, escapedPath)
	} else {
		printf("Updated lockfile: %d (%s)\n", res.lockfileID, escapedPath)
	}
	return exitSuccess
}

// isSecureBaseURL reports whether baseURL uses https, or plain http to a loopback host for local testing.
func isSecureBaseURL(baseURL string) bool {
	parsed, err := url.Parse(baseURL)
	if err != nil {
		return false
	}
	if parsed.Scheme == "https" {
		return true
	}
	host := parsed.Hostname()
	return parsed.Scheme == "http" && (host == "localhost" || net.ParseIP(host).IsLoopback())
}

// isSafeRepoName reports whether repoName, when it is a URL, has no userinfo, query or fragment.
// Those parts can carry credentials, and repoName is written to the workflow log and stored in FutureVuls.
func isSafeRepoName(repoName string) bool {
	if !isURL(repoName) {
		return true
	}
	parsed, err := url.Parse(repoName)
	return err == nil && parsed.User == nil && parsed.RawQuery == "" && !parsed.ForceQuery && parsed.Fragment == ""
}

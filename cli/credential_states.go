package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/KogenAI/kogen-coordinator/project"
	"github.com/KogenAI/kogen-loop/sys"
)

// The three credential states, with the labels docs/providers.md defines and Kogen.dev uses.
// Every line the CLI prints about them takes its label from these constants.
const (
	labelKeySaved        = "key saved"
	labelConnectionTried = "connection tested"
	labelRoleVerified    = "role verified"
)

// testableProvider is the only provider `kogen provider test` can test: it has a configured
// endpoint (the base_url of a role) to call from the CLI.
const testableProvider = "openai-compatible"

// Failure classes of a connection test.
const (
	classAuth      = "auth"
	classEndpoint  = "endpoint"
	classTimeout   = "timeout"
	classMalformed = "malformed reply"
)

// connectionWatchdog bounds one connection test: no complete reply by then is the timeout class.
// It is a variable only so tests can shorten it.
var connectionWatchdog = 20 * time.Second

const (
	// connectionPrompt is the one short user prompt; the output ceiling is a few tokens.
	connectionPrompt    = "Reply with the single word: ok"
	connectionMaxTokens = 8
	// connectionReplyLimit bounds how much of a reply is read; nothing of it is ever printed.
	connectionReplyLimit = 1 << 20
)

// connectionRecord is the recorded result of the latest connection test of one provider. It holds
// the time, the outcome, the class of a failure and the endpoint origin; never a key or a reply.
type connectionRecord struct {
	Time   string `json:"time"`
	Result string `json:"result"` // "ok" or "failed"
	Status int    `json:"status,omitempty"`
	Class  string `json:"class,omitempty"`
	Origin string `json:"origin"`
}

func connectionRecordPath(home, name string) string {
	return filepath.Join(home, ".kogen", "credentials", name+".connection.json")
}

// readConnectionRecord returns the latest record, or false when there is none or it is unreadable.
func readConnectionRecord(home, name string) (connectionRecord, bool) {
	data, err := os.ReadFile(connectionRecordPath(home, name))
	if err != nil {
		return connectionRecord{}, false
	}
	var r connectionRecord
	if json.Unmarshal(data, &r) != nil || r.Time == "" || (r.Result != "ok" && r.Result != "failed") {
		return connectionRecord{}, false
	}
	return r, true
}

// writeConnectionRecord replaces the record atomically in the private credentials directory.
func writeConnectionRecord(home, name string, r connectionRecord) error {
	path := connectionRecordPath(home, name)
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	data, err := json.Marshal(r)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, "."+name+"-connection-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// connectionResult is the outcome of one connection test that reached the endpoint.
type connectionResult struct {
	At     time.Time
	OK     bool
	Status int    // HTTP status; 0 when no answer arrived
	Class  string // failure class
	Detail string // what follows the class; never a key or any part of the reply
}

// formatTime is UTC RFC 3339 with whole seconds, e.g. 2026-11-28T10:00:00Z.
func formatTime(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05Z") }

// line is the one line `kogen provider test` prints for the result.
func (r connectionResult) line(name string) string {
	if r.OK {
		return fmt.Sprintf("%s: %s %s (HTTP %d)", name, labelConnectionTried, formatTime(r.At), r.Status)
	}
	return fmt.Sprintf("%s: connection test failed, class: %s (%s)", name, r.Class, r.Detail)
}

// connectionTester runs one connection test of a role; the guided login replaces it in tests.
var connectionTester = testConnection

// normalizeOrigin is the origin of an http(s) URL: lower-case scheme and host, the port unless it
// is the scheme's default; path, query, fragment and user info are dropped.
func normalizeOrigin(raw string) (string, bool) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return "", false
	}
	scheme, host := strings.ToLower(u.Scheme), strings.ToLower(u.Hostname())
	if (scheme != "https" && scheme != "http") || host == "" {
		return "", false
	}
	port := u.Port()
	if port != "" {
		n, err := strconv.ParseUint(port, 10, 16)
		if err != nil {
			return "", false
		}
		port = strconv.FormatUint(n, 10)
	}
	if port == "" || (scheme == "https" && port == "443") || (scheme == "http" && port == "80") {
		if strings.Contains(host, ":") {
			host = "[" + host + "]"
		}
		return scheme + "://" + host, true
	}
	return scheme + "://" + net.JoinHostPort(host, port), true
}

// plainLoopback reports whether an origin is plain http to localhost or a literal loopback IP.
func plainLoopback(origin string) bool {
	u, err := url.Parse(origin)
	if err != nil || u.Scheme != "http" {
		return false
	}
	if u.Hostname() == "localhost" {
		return true
	}
	ip := net.ParseIP(u.Hostname())
	return ip != nil && ip.IsLoopback()
}

// savedKey reads the saved openai-compatible key and the origin it is bound to.
func savedKey(home string) (key, origin string, err error) {
	login := "no usable OpenAI-compatible key; run kogen provider login openai-compatible"
	data, rerr := os.ReadFile(filepath.Join(home, ".kogen", "credentials", testableProvider+".json"))
	if rerr != nil {
		return "", "", sys.Fail("provider", "login", login, 4)
	}
	var c map[string]any
	if json.Unmarshal(data, &c) != nil || c["provider"] != testableProvider {
		return "", "", sys.Fail("provider", "login", login, 4)
	}
	key, _ = c["api_key"].(string)
	if key == "" || !utf8.ValidString(key) || strings.IndexFunc(key, unicode.IsControl) >= 0 {
		return "", "", sys.Fail("provider", "login", login, 4)
	}
	saved, _ := c["origin"].(string)
	if saved == "" {
		return "", "", sys.Fail("provider", "login", "the saved OpenAI-compatible key is not bound to an origin; log in again with the base URL it is for (run kogen provider login openai-compatible)", 4)
	}
	origin, ok := normalizeOrigin(saved)
	if !ok {
		return "", "", sys.Fail("provider", "login", "the saved OpenAI-compatible origin is invalid; log in again with an HTTPS base URL", 4)
	}
	return key, origin, nil
}

// testConnection makes one minimal streaming request to the role's endpoint and classifies the
// answer. A refusal (no key, a key bound to another origin, plain http off loopback) is returned
// as an error before anything is sent. The result is recorded here, so a failure replaces an
// earlier success; a refusal records nothing.
func testConnection(ctx context.Context, home string, role project.Role) (connectionResult, error) {
	dest, ok := normalizeOrigin(role.BaseURL)
	if !ok {
		return connectionResult{}, sys.Fail("provider", "refused", "base_url is not an http(s) URL with a host", 4)
	}
	if strings.HasPrefix(dest, "http://") && !plainLoopback(dest) {
		return connectionResult{}, sys.Fail("provider", "refused", "plaintext HTTP to "+dest+" is refused: HTTP is allowed only for localhost or a loopback IP address; use HTTPS", 4)
	}
	key, saved, err := savedKey(home)
	if err != nil {
		return connectionResult{}, err
	}
	if saved != dest {
		return connectionResult{}, sys.Fail("provider", "refused", "the saved OpenAI-compatible key belongs to "+saved+" but the test goes to "+dest+"; no key was sent", 4)
	}
	res := sendConnectionRequest(ctx, strings.TrimRight(role.BaseURL, "/")+"/chat/completions", key, role.Model)
	if ctx.Err() != nil && !errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return connectionResult{}, ctx.Err() // interrupted by the caller: nothing is recorded
	}
	rec := connectionRecord{Time: formatTime(res.At), Result: "failed", Class: res.Class, Origin: dest}
	if res.OK {
		rec = connectionRecord{Time: formatTime(res.At), Result: "ok", Status: res.Status, Origin: dest}
	}
	if err := writeConnectionRecord(home, testableProvider, rec); err != nil {
		return res, sys.Fail("environment", "record_unwritable", "cannot record the result: "+err.Error(), 3)
	}
	return res, nil
}

// sendConnectionRequest sends the one request and classifies the outcome.
func sendConnectionRequest(parent context.Context, endpoint, key, model string) connectionResult {
	res := connectionResult{At: time.Now().UTC()}
	fail := func(class, detail string) connectionResult {
		res.Class, res.Detail = class, detail
		return res
	}
	ctx, cancel := context.WithTimeout(parent, connectionWatchdog)
	defer cancel()
	timeout := func() connectionResult {
		return fail(classTimeout, "no complete reply within "+connectionWatchdog.String())
	}
	body, _ := json.Marshal(map[string]any{
		"model":      model,
		"messages":   []any{map[string]any{"role": "user", "content": connectionPrompt}},
		"stream":     true,
		"max_tokens": connectionMaxTokens,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(string(body)))
	if err != nil {
		return fail(classEndpoint, "no connection")
	}
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "text/event-stream")
	client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return timeout()
		}
		return fail(classEndpoint, "no connection")
	}
	defer resp.Body.Close()
	res.Status = resp.StatusCode
	switch {
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return fail(classAuth, "HTTP "+strconv.Itoa(resp.StatusCode))
	case resp.StatusCode < 200 || resp.StatusCode > 299:
		return fail(classEndpoint, "HTTP "+strconv.Itoa(resp.StatusCode))
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, connectionReplyLimit))
	if err != nil {
		if ctx.Err() != nil {
			return timeout()
		}
		return fail(classEndpoint, "connection lost before the reply ended")
	}
	if !wellFormedReply(data) {
		return fail(classMalformed, "HTTP "+strconv.Itoa(resp.StatusCode)+", not a Chat Completions reply")
	}
	res.OK = true
	return res
}

// wellFormedReply reports whether a reply body is a Chat Completions reply: a server-sent event
// stream with a data line holding a JSON object with a choices array, or one such JSON object.
func wellFormedReply(data []byte) bool {
	hasChoices := func(raw []byte) bool {
		var obj map[string]json.RawMessage
		if json.Unmarshal(raw, &obj) != nil {
			return false
		}
		c, ok := obj["choices"]
		return ok && len(c) > 0 && c[0] == '['
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if rest, ok := strings.CutPrefix(line, "data:"); ok && hasChoices([]byte(strings.TrimSpace(rest))) {
			return true
		}
	}
	return hasChoices([]byte(strings.TrimSpace(string(data))))
}

// providerTest is `kogen provider test <provider>`.
func providerTest(inv *invocation) int {
	home, err := os.UserHomeDir()
	if err != nil {
		return exitFor(sys.Fail("environment", "home_unavailable", "cannot find the home directory", 3))
	}
	cwd, err := os.Getwd()
	if err != nil {
		return exitFor(sys.Fail("environment", "cwd_unavailable", err.Error(), 3))
	}
	cfg, err := project.LoadConfig(cwd)
	if err != nil {
		return exitFor(err)
	}
	role, ok := endpointRole(cfg)
	if !ok {
		return exitFor(sys.Fail("environment", "no_endpoint", "no role in .kogen/models.yaml uses "+testableProvider+"; set provider: "+testableProvider+" and a base_url on a role", 3))
	}
	s := sys.New()
	stop := s.WatchSignals()
	defer stop()
	res, err := connectionTester(s.Context(), home, role)
	if err != nil {
		if ie := s.Err(); ie != nil {
			return exitFor(ie)
		}
		return exitFor(err)
	}
	fmt.Println(res.line(testableProvider))
	if res.OK {
		return 0
	}
	return 4
}

// endpointRole is the first role (shape, build, review) whose provider is openai-compatible.
func endpointRole(cfg *project.Config) (project.Role, bool) {
	for _, name := range project.ModelRoles {
		if r := cfg.Models[name]; r.Provider == testableProvider && !r.External() {
			return r, true
		}
	}
	return project.Role{}, false
}

// keySavedStatus reports whether a `kogen provider list` status line shows a stored usable login.
func keySavedStatus(state string) bool {
	for _, p := range []string{"key saved", "signed in", "token saved", "managed access snapshot fresh"} {
		if strings.HasPrefix(state, p) {
			return true
		}
	}
	return false
}

// joinStates is the held labels joined by "; ", or none.
func joinStates(held []string) string {
	if len(held) == 0 {
		return "none"
	}
	return strings.Join(held, "; ")
}

// connectionHeld is the `connection tested <time>` state when the provider's latest record is a
// success and, when origin is not empty, it was recorded for that origin.
func connectionHeld(home, name, origin string) (string, bool) {
	if name != testableProvider {
		return "", false
	}
	r, ok := readConnectionRecord(home, name)
	if !ok || r.Result != "ok" {
		return "", false
	}
	if origin != "" && r.Origin != origin {
		return "", false
	}
	return labelConnectionTried + " " + r.Time, true
}

// roleVerifiedIn reports whether the provider's row of the qualification table in the docs text
// has `<Role>: verified (` for the role.
func roleVerifiedIn(docs, name, role string) bool {
	if role == "" {
		return false
	}
	want := strings.ToUpper(role[:1]) + role[1:] + ": verified ("
	for _, line := range strings.Split(docs, "\n") {
		if strings.HasPrefix(line, "| `"+name+"` |") {
			for _, cell := range strings.Split(line, "|") {
				if strings.Contains(cell, want) {
					return true
				}
			}
		}
	}
	return false
}

// shippedDocs is the docs/providers.md shipped with the binary, empty when it is missing.
func shippedDocs(root string) string {
	data, err := os.ReadFile(filepath.Join(root, "docs", "providers.md"))
	if err != nil {
		return ""
	}
	return string(data)
}

// providerStates is the `states <provider>` lines for the status lines of `kogen provider list`.
func providerStates(home string, status []string) []string {
	var out []string
	for _, l := range status {
		name, state, ok := strings.Cut(l, ": ")
		if !ok {
			continue
		}
		var held []string
		if keySavedStatus(state) {
			held = append(held, labelKeySaved)
		}
		if c, ok := connectionHeld(home, name, ""); ok {
			held = append(held, c)
		}
		out = append(out, "states "+name+": "+joinStates(held))
	}
	return out
}

// roleStatesLine is `states role <role> (<provider>, <model>): <held labels>`.
func roleStatesLine(home, docs, name string, r project.Role, keySaved bool) string {
	var held []string
	if keySaved {
		held = append(held, labelKeySaved)
	}
	if r.BaseURL != "" {
		if origin, ok := normalizeOrigin(r.BaseURL); ok {
			if c, ok := connectionHeld(home, r.Provider, origin); ok {
				held = append(held, c)
			}
		}
	}
	if roleVerifiedIn(docs, r.Provider, name) {
		held = append(held, labelRoleVerified)
	}
	return "states role " + name + " (" + r.Provider + ", " + r.Model + "): " + joinStates(held)
}

// loginSaved reports whether the provider has a stored usable login.
func loginSaved(status []string, name string) bool {
	for _, l := range status {
		if n, state, ok := strings.Cut(l, ": "); ok && n == name {
			return keySavedStatus(state)
		}
	}
	return false
}

// stateLines are the lines `kogen provider list` prints after its existing ones: one per
// provider, then one per role of the lineup when it loads.
func stateLines(home, root string, status []string, cfg *project.Config) []string {
	lines := providerStates(home, status)
	if cfg == nil {
		return lines
	}
	docs := shippedDocs(root)
	for _, name := range project.ModelRoles {
		r := cfg.Models[name]
		lines = append(lines, roleStatesLine(home, docs, name, r, loginSaved(status, r.Provider)))
	}
	return lines
}

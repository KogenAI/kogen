package build

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
	gitpkg "kogen/git"
	"kogen/project"
	"kogen/verify"
)

const (
	testSlug    = "fixture"
	testFeature = "Feature: Integration fixture\n  Scenario: First\n    Given the fixture is available\n    Then the acceptance check passes\n  Scenario: Second\n    Then the acceptance check passes\n"
	stepsFile   = "features/steps/integration_steps.js"
)

// ---- the scripted provider ----

type handler func(w http.ResponseWriter, r *http.Request)

// fakeProvider answers /v1/responses from a script, one handler per request, and keeps the
// requests. Past the end of the script it answers 400.
type fakeProvider struct {
	t      *testing.T
	srv    *httptest.Server
	mu     sync.Mutex
	reqs   []map[string]any
	script []handler
	next   int
	ids    atomic.Int64
}

func newFakeProvider(t *testing.T) *fakeProvider {
	f := &fakeProvider{t: t}
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeProvider) serve(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	if r.URL.Path != "/v1/responses" {
		http.NotFound(w, r)
		return
	}
	var req map[string]any
	json.Unmarshal(body, &req)
	f.mu.Lock()
	f.reqs = append(f.reqs, req)
	var h handler
	if f.next < len(f.script) {
		h = f.script[f.next]
	}
	f.next++
	f.mu.Unlock()
	if h == nil {
		h = refused()
	}
	h(w, r)
}

// then appends handlers to the script.
func (f *fakeProvider) then(h ...handler) *fakeProvider {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.script = append(f.script, h...)
	return f
}

// replace drops the handlers not yet played and appends h.
func (f *fakeProvider) replace(h ...handler) *fakeProvider {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.script = append(f.script[:min(f.next, len(f.script)):min(f.next, len(f.script))], h...)
	return f
}

func (f *fakeProvider) requests() []map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]map[string]any(nil), f.reqs...)
}

func (f *fakeProvider) count() int { return len(f.requests()) }

func (f *fakeProvider) call(name string, args any) map[string]any {
	b, _ := json.Marshal(args)
	id := f.ids.Add(1)
	return map[string]any{
		"type": "function_call", "id": fmt.Sprintf("function-%d", id), "call_id": fmt.Sprintf("call-%d", id),
		"name": name, "arguments": string(b),
	}
}

// calls answers with one function call per (name, args) pair.
func (f *fakeProvider) calls(pairs ...any) handler {
	var items []map[string]any
	for i := 0; i < len(pairs); i += 2 {
		items = append(items, f.call(pairs[i].(string), pairs[i+1]))
	}
	return sse(items...)
}

func sse(items ...map[string]any) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("X-Request-Id", "req-fixture")
		for i, it := range items {
			io.WriteString(w, "data: "+jsonText(map[string]any{"type": "response.output_item.done", "output_index": i, "item": it})+"\n\n")
		}
		io.WriteString(w, "data: "+jsonText(map[string]any{"type": "response.completed", "response": map[string]any{"usage": map[string]any{
			"input_tokens": 1, "input_tokens_details": map[string]any{"cached_tokens": 0},
			"output_tokens": 1, "output_tokens_details": map[string]any{"reasoning_tokens": 0}}}})+"\n\n")
	}
}

// hang opens the stream and keeps it open until the client goes away; opened is closed
// when the request arrived.
func hang(opened chan struct{}) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, ": waiting\n\n")
		w.(http.Flusher).Flush()
		close(opened)
		select {
		case <-r.Context().Done():
		case <-time.After(20 * time.Second):
		}
	}
}

func refused() handler {
	return failure(400, "invalid_request_error", "scripted provider refusal")
}

func failure(status int, code, message string) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Request-Id", "req-fixture")
		w.WriteHeader(status)
		io.WriteString(w, jsonText(map[string]any{"error": map[string]any{"code": code, "message": message, "type": "invalid_request_error"}}))
	}
}

func jsonText(v any) string {
	b, err := encodeJSON(v)
	if err != nil {
		panic(err)
	}
	return string(b)
}

// ---- the project ----

// project is a repository with an approved Intent, ready to build.
type env struct {
	t     *testing.T
	root  string
	home  string
	aux   string // outside the repository: reports, scripts
	git   []string
	prov  *fakeProvider
	hooks string
}

func isolatedEnv(extra ...string) []string {
	var out []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "GIT_") {
			out = append(out, kv)
		}
	}
	return append(out, append([]string{"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1", "GIT_TERMINAL_PROMPT=0"}, extra...)...)
}

// physical resolves symbolic links so that paths agree with Git's own.
func physical(t *testing.T, dir string) string {
	t.Helper()
	p, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// newEnv makes the repository: one commit with README.md, app.txt, .gitignore and the
// project configuration; the Intent `fixture` (not applicable model, two scenarios, one step
// file) written but not committed, and approved.
func newEnv(t *testing.T, mutate ...func(*project.Config)) *env {
	t.Helper()
	e := &env{t: t, root: physical(t, t.TempDir()), home: physical(t, t.TempDir()), aux: physical(t, t.TempDir()), prov: newFakeProvider(t)}
	e.hooks = t.TempDir()
	e.git = isolatedEnv()
	e.run("git", "init", "-q", "--initial-branch=main")
	for k, v := range map[string]string{"user.name": "Kogen Integration", "user.email": "kogen-integration@example.invalid",
		"commit.gpgsign": "false", "core.hooksPath": e.hooks} {
		e.run("git", "config", k, v)
	}
	writeFile(t, filepath.Join(e.root, "README.md"), "# Fixture project\n", 0o644)
	writeFile(t, filepath.Join(e.root, "app.txt"), "baseline\n", 0o644)
	writeFile(t, filepath.Join(e.root, ".gitignore"), ".kogen/local/\n", 0o644)

	green := filepath.Join(e.aux, "green.ndjson")
	red := filepath.Join(e.aux, "red.ndjson")
	feature := project.FeaturePath(testSlug)
	writeFile(t, green, reportFor(t, feature, testFeature, "PASSED"), 0o644)
	writeFile(t, red, reportFor(t, feature, testFeature, "FAILED"), 0o644)
	accept := filepath.Join(e.aux, "accept.sh")
	writeFile(t, accept, "#!/bin/sh\nif grep -qx red app.txt; then cp '"+red+"' \"$KOGEN_ACCEPTANCE_REPORT\"; echo actual-case-red; exit 1; fi\ncp '"+green+"' \"$KOGEN_ACCEPTANCE_REPORT\"\n", 0o755)
	cfg := &project.Config{Acceptance: &project.Acceptance{Run: accept, StepsDir: "features/steps"}}
	for _, m := range mutate {
		m(cfg)
	}
	e.writeConfig(cfg)
	e.run("git", "add", "README.md", "app.txt", ".gitignore", ".kogen/project.yaml")
	e.run("git", "commit", "-qm", "fixture baseline")

	writeFile(t, filepath.Join(e.root, project.IntentMDPath(testSlug)), `# Preserve the fixture

Slug: fixture
Model: not applicable — no model for this fixture

Acceptance:
- .kogen/intents/fixture/acceptance.feature
- `+stepsFile+`

## Tests
- the fixture stays as it is: the acceptance scenario (existing)

## Source comparison
- addressed: preserve app.txt fixture behavior; source request; contract Tests and acceptance.feature.

## Feasibility
- none
`, 0o644)
	writeFile(t, filepath.Join(e.root, feature), testFeature, 0o644)
	writeFile(t, filepath.Join(e.root, stepsFile), "// steps\n", 0o644)
	e.approve()
	return e
}

func (e *env) writeConfig(cfg *project.Config) {
	writeFile(e.t, filepath.Join(e.root, ".kogen/project.yaml"), project.RenderConfig(cfg), 0o644)
}

// approve (re)writes the approval of the Intent as it is now.
func (e *env) approve() {
	e.t.Helper()
	cfg, err := project.LoadConfig(e.root)
	if err != nil {
		e.t.Fatal(err)
	}
	baseline, err := project.Baseline(e.root, testSlug, cfg)
	if err != nil {
		e.t.Fatal(err)
	}
	err = project.WriteApproval(e.root, project.Approval{
		Slug: testSlug, SHA256: project.Hash(e.root, baseline), Approver: "Kogen Integration <kogen-integration@example.invalid>",
		ApprovedAt: "2026-10-22T00:00:00Z",
	})
	if err != nil {
		e.t.Fatal(err)
	}
}

func (e *env) run(name string, args ...string) string {
	e.t.Helper()
	cmd := exec.Command(name, args...)
	cmd.Dir = e.root
	cmd.Env = e.git
	out, err := cmd.CombinedOutput()
	if err != nil {
		e.t.Fatalf("%s %s: %v\n%s", name, strings.Join(args, " "), err, out)
	}
	return string(out)
}

func (e *env) gitOut(args ...string) string { return strings.TrimSpace(e.run("git", args...)) }

func (e *env) head() string { return e.gitOut("rev-parse", "HEAD") }

func (e *env) write(rel, content string) { writeFile(e.t, filepath.Join(e.root, rel), content, 0o644) }

func (e *env) read(rel string) string {
	b, err := os.ReadFile(filepath.Join(e.root, rel))
	if err != nil {
		e.t.Fatal(err)
	}
	return string(b)
}

func (e *env) hook(name, script string) {
	e.t.Helper()
	writeFile(e.t, filepath.Join(e.hooks, name), "#!/bin/sh\n"+script, 0o755)
}

// credentials seeds a usable ChatGPT login.
func (e *env) credentials() {
	e.t.Helper()
	dir := filepath.Join(e.home, ".kogen", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		e.t.Fatal(err)
	}
	os.Chmod(filepath.Join(e.home, ".kogen"), 0o700)
	b, _ := json.Marshal(map[string]any{
		"client_id": "oaiapp_fake", "access_token": "fake-access-token", "refresh_token": "fake-refresh-token",
		"expires_at": time.Now().Unix() + 86400, "scope": "openid", "email": "integration@example.invalid",
	})
	if err := os.WriteFile(filepath.Join(dir, "chatgpt.json"), b, 0o600); err != nil {
		e.t.Fatal(err)
	}
}

// attempt is one command's run.
type attempt struct {
	s      *sys.Session
	out    *strings.Builder
	errs   *strings.Builder
	exit   int
	err    error
	deps   Deps
	e      *env
	cancel context.CancelFunc
}

func (e *env) session() (*sys.Session, *strings.Builder, *strings.Builder) {
	env := isolatedEnv("HOME="+e.home, "KOGEN_PROVIDER_URL="+e.prov.srv.URL, "KOGEN_AUTH_URL="+e.prov.srv.URL)
	s := sys.NewWith(env, e.root)
	out, errs := &strings.Builder{}, &strings.Builder{}
	s.Stdout, s.Stderr = out, errs
	return s, out, errs
}

func (e *env) deps() Deps {
	return Deps{Client: &provider.Client{Cache: provider.NewCache(nil), Version: "kogen dev+12345678 (test)"}, Tools: verify.Tools{},
		// The core tests build without the independent review; review_test.go uses the real one.
		Reviewer: approveWithoutReview{}}
}

// build runs `kogen intent build fixture` to its end.
func (e *env) build(mutate ...func(*Input)) *attempt {
	e.t.Helper()
	e.credentials()
	s, out, errs := e.session()
	in := Input{Deps: e.deps(), Project: e.root, Slug: testSlug}
	for _, m := range mutate {
		m(&in)
	}
	a := &attempt{s: s, out: out, errs: errs, e: e}
	a.exit, a.err = Build(context.Background(), s, in)
	return a
}

// start runs a build in the background; the session is returned to interrupt it.
func (e *env) start(mutate ...func(*Input)) (*attempt, <-chan struct{}) {
	e.t.Helper()
	e.credentials()
	s, out, errs := e.session()
	in := Input{Deps: e.deps(), Project: e.root, Slug: testSlug}
	for _, m := range mutate {
		m(&in)
	}
	a := &attempt{s: s, out: out, errs: errs, e: e}
	done := make(chan struct{})
	go func() {
		defer close(done)
		a.exit, a.err = Build(context.Background(), s, in)
	}()
	return a, done
}

func (e *env) resume(id string, mutate ...func(*ResumeInput)) *attempt {
	e.t.Helper()
	e.credentials()
	s, out, errs := e.session()
	in := ResumeInput{Deps: e.deps(), Project: e.root, ID: id}
	for _, m := range mutate {
		m(&in)
	}
	a := &attempt{s: s, out: out, errs: errs, e: e}
	a.exit, a.err = Resume(context.Background(), s, in)
	return a
}

// shown is what the user sees on stdout, with a refusal's own text when it has one.
func (a *attempt) shown() string {
	text := a.out.String()
	if e, ok := sys.AsError(a.err); ok {
		text += e.Render()
	}
	return text
}

func (e *env) runIDs() []string {
	entries, err := os.ReadDir(filepath.Join(e.root, ".kogen/local/runs"))
	if err != nil {
		return nil
	}
	var ids []string
	for _, en := range entries {
		ids = append(ids, en.Name())
	}
	return ids
}

func (e *env) onlyRun() string {
	e.t.Helper()
	ids := e.runIDs()
	if len(ids) != 1 {
		e.t.Fatalf("runs %v, want one", ids)
	}
	return ids[0]
}

func (e *env) runPath(id, name string) string {
	return filepath.Join(e.root, ".kogen/local/runs", id, name)
}

func (e *env) result(id string) map[string]any {
	e.t.Helper()
	return e.jsonFile(e.runPath(id, "result.json"))
}

func (e *env) jsonFile(path string) map[string]any {
	e.t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		e.t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		e.t.Fatalf("%s: %v", path, err)
	}
	return m
}

func (e *env) events(id string) []map[string]any {
	e.t.Helper()
	b, err := os.ReadFile(e.runPath(id, "log.jsonl"))
	if err != nil {
		e.t.Fatal(err)
	}
	var out []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			e.t.Fatalf("log line %q: %v", line, err)
		}
		out = append(out, m)
	}
	return out
}

func eventsNamed(events []map[string]any, name string) []map[string]any {
	var out []map[string]any
	for _, ev := range events {
		if ev["event"] == name {
			out = append(out, ev)
		}
	}
	return out
}

// toolOutputs are the function_call_output texts the provider received, in order.
func (f *fakeProvider) toolOutputs() []string {
	var out []string
	for _, req := range f.requests() {
		items, _ := req["input"].([]any)
		for _, it := range items {
			m, _ := it.(map[string]any)
			if m["type"] == "function_call_output" {
				out = append(out, fmt.Sprint(m["output"]))
			}
		}
	}
	return out
}

func contains(t *testing.T, name, text, part string) {
	t.Helper()
	if !strings.Contains(text, part) {
		t.Fatalf("%s lacks %q:\n%s", name, part, text)
	}
}

func lacks(t *testing.T, name, text, part string) {
	t.Helper()
	if strings.Contains(text, part) {
		t.Fatalf("%s has %q:\n%s", name, part, text)
	}
}

func eq[T any](t *testing.T, name string, got, want T) {
	t.Helper()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%s = %#v, want %#v", name, got, want)
	}
}

// readState reads the state of a run's checkpoint.
func (e *env) checkpoint(id string) (map[string]any, map[string]any) {
	e.t.Helper()
	doc := e.jsonFile(e.runPath(id, "checkpoint.json"))
	state, _ := doc["state"].(map[string]any)
	return doc, state
}

func (e *env) writeCheckpoint(id string, doc map[string]any) {
	e.t.Helper()
	b, _ := json.Marshal(doc)
	if err := os.WriteFile(e.runPath(id, "checkpoint.json"), append(b, '\n'), 0o600); err != nil {
		e.t.Fatal(err)
	}
}

func execGit(e *env, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = e.root
	cmd.Env = e.git
	out, err := cmd.Output()
	return string(out), err
}

func (e *env) gitRepo() *gitpkg.Repo { return gitpkg.New(e.root, e.git) }

func sessionOf(e *env) *sys.Session {
	s, _, _ := e.session()
	return s
}

func defaultRole() project.Role { return project.Role{Model: "gpt-6.1-sol", Effort: "medium"} }

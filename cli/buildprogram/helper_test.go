package buildprogram

import (
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

	gitpkg "github.com/KogenAI/kogen-coordinator/git"
	"github.com/KogenAI/kogen-coordinator/project"
)

const (
	testSlug    = "fixture"
	testFeature = "Feature: Integration fixture\n  Scenario: First\n    Given the fixture is available\n    Then the acceptance check passes\n  Scenario: Second\n    Then the acceptance check passes\n"
	stepsFile   = "features/steps/integration_steps.js"
)

type handler func(w http.ResponseWriter, r *http.Request)

// fakeProvider answers /v1/responses from a script, one handler per request, and keeps the
// requests. Past the end of the script it answers 400.
type fakeProvider struct {
	t      *testing.T
	srv    *httptest.Server
	mu     sync.Mutex
	reqs   []map[string]any
	bodies [][]byte // the raw bytes of each request, as received
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
	if r.URL.Path != "/v1/responses" && r.URL.Path != "/v1/messages" && r.URL.Path != "/inference/go/openai/v1/chat/completions" {
		http.NotFound(w, r)
		return
	}
	var req map[string]any
	json.Unmarshal(body, &req)
	f.mu.Lock()
	f.reqs = append(f.reqs, req)
	f.bodies = append(f.bodies, body)
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

func (f *fakeProvider) requests() []map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]map[string]any(nil), f.reqs...)
}

// rawRequests are the request bodies exactly as the provider received them.
func (f *fakeProvider) rawRequests() [][]byte {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([][]byte(nil), f.bodies...)
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

// project is a repository with an approved Intent, ready to build.
type env struct {
	t        *testing.T
	root     string
	home     string
	aux      string // outside the repository: reports, scripts
	git      []string
	prov     *fakeProvider
	hooks    string
	extraEnv []string
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
	return newEnvIn(t, physical(t, t.TempDir()), physical(t, t.TempDir()), physical(t, t.TempDir()), nil, mutate...)
}

// newEnvIn is newEnv in the given repository, home and auxiliary folders, with extra Git
// environment (such as fixed commit dates).
func newEnvIn(t *testing.T, root, home, aux string, gitEnv []string, mutate ...func(*project.Config)) *env {
	t.Helper()
	e := &env{t: t, root: root, home: home, aux: aux, prov: newFakeProvider(t)}
	e.hooks = t.TempDir()
	e.git = isolatedEnv(gitEnv...)
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
		Slug: testSlug, SHA256: project.Hash(e.root, baseline), Base: e.head(), Approver: "Kogen Integration <kogen-integration@example.invalid>",
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

// eventsNamed are the events with that name, without the timestamp every logged event carries.
func eventsNamed(events []map[string]any, name string) []map[string]any {
	var out []map[string]any
	for _, ev := range events {
		if ev["event"] == name {
			bare := make(map[string]any, len(ev))
			for k, v := range ev {
				if k != "at" {
					bare[k] = v
				}
			}
			out = append(out, bare)
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

func execGit(e *env, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = e.root
	cmd.Env = e.git
	out, err := cmd.Output()
	return string(out), err
}

func (e *env) gitRepo() *gitpkg.Repo { return gitpkg.New(e.root, e.git) }

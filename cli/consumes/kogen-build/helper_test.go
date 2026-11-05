package consumes

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/KogenAI/kogen-build/build"
	"github.com/KogenAI/kogen-coordinator/project"
	"github.com/KogenAI/kogen-verification/verify"
	"kogen-loop/provider"
	"kogen-loop/sys"
)

const (
	testSlug    = "fixture"
	testFeature = "Feature: Integration fixture\n  Scenario: First\n    Given the fixture is available\n    Then the acceptance check passes\n  Scenario: Second\n    Then the acceptance check passes\n"
	stepsFile   = "features/steps/integration_steps.js"
)

// ---- the scripted loopback provider ----

type handler func(w http.ResponseWriter, r *http.Request)

// fakeProvider answers /v1/responses on a free loopback port from a script, one handler per
// request, and keeps the request bodies. Past the end of the script it answers 400.
type fakeProvider struct {
	srv    *httptest.Server
	mu     sync.Mutex
	bodies []string
	script []handler
	next   int
	ids    atomic.Int64
}

func newFakeProvider(t *testing.T) *fakeProvider {
	f := &fakeProvider{}
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
	f.mu.Lock()
	f.bodies = append(f.bodies, string(body))
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
func (f *fakeProvider) then(h ...handler) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.script = append(f.script, h...)
}

// replace drops the handlers not yet played and appends h.
func (f *fakeProvider) replace(h ...handler) {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := min(f.next, len(f.script))
	f.script = append(f.script[:n:n], h...)
}

// requests are the bodies of the requests the provider received, in order.
func (f *fakeProvider) requests() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.bodies)
}

// calls answers with one function call per (name, args) pair.
func (f *fakeProvider) calls(pairs ...any) handler {
	var items []map[string]any
	for i := 0; i < len(pairs); i += 2 {
		b, _ := json.Marshal(pairs[i+1])
		id := f.ids.Add(1)
		items = append(items, map[string]any{
			"type": "function_call", "id": fmt.Sprintf("function-%d", id), "call_id": fmt.Sprintf("call-%d", id),
			"name": pairs[i].(string), "arguments": string(b),
		})
	}
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("X-Request-Id", "req-fixture")
		for i, it := range items {
			io.WriteString(w, frame(map[string]any{"type": "response.output_item.done", "output_index": i, "item": it}))
		}
		io.WriteString(w, frame(map[string]any{"type": "response.completed", "response": map[string]any{"usage": map[string]any{
			"input_tokens": 1, "input_tokens_details": map[string]any{"cached_tokens": 0},
			"output_tokens": 1, "output_tokens_details": map[string]any{"reasoning_tokens": 0}}}}))
	}
}

func frame(v any) string {
	b, _ := json.Marshal(v)
	return "data: " + string(b) + "\n\n"
}

// hang opens the stream and keeps it open until the client goes away; opened is closed when the
// request arrived.
func hang(opened chan struct{}) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, ": waiting\n\n")
		w.(http.Flusher).Flush()
		close(opened)
		<-r.Context().Done()
	}
}

func refused() handler {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(400)
		b, _ := json.Marshal(map[string]any{"error": map[string]any{"code": "invalid_request_error", "message": "scripted provider refusal", "type": "invalid_request_error"}})
		w.Write(b)
	}
}

// submitReview answers the independent reviewer with a verdict without findings.
func (f *fakeProvider) submitReview(verdict string) handler {
	return f.calls("submit_review", map[string]any{"verdict": verdict, "findings": []any{}})
}

// ---- the project ----

// env is a repository with an approved Intent, ready to build, a HOME of its own signed in to a
// fake ChatGPT, and the loopback provider.
type env struct {
	t    *testing.T
	root string
	home string
	aux  string // outside the repository: reports, scripts
	git  []string
	prov *fakeProvider
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

func writeFile(t *testing.T, path, content string, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
}

// newEnv makes the repository: one commit with README.md, app.txt, .gitignore and the project
// configuration (acceptance by a script that reports every scenario passed); the Intent
// `fixture` (not applicable model, two scenarios, one step file) written but not committed, and
// approved. Each mutator is applied, in order, to the project configuration before it is rendered
// and committed. Nothing is shared with another test and nothing leaves the temporary folders.
func newEnv(t *testing.T, mutate ...func(*project.Config)) *env {
	t.Helper()
	t.Parallel()
	e := &env{t: t, root: physical(t, t.TempDir()), home: physical(t, t.TempDir()), aux: physical(t, t.TempDir()), prov: newFakeProvider(t)}
	hooks := physical(t, t.TempDir())
	e.git = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1", "GIT_TERMINAL_PROMPT=0")
	e.run("git", "init", "-q", "--initial-branch=main")
	for k, v := range map[string]string{"user.name": "Kogen Consumer", "user.email": "kogen-consumer@example.invalid",
		"commit.gpgsign": "false", "core.hooksPath": hooks} {
		e.run("git", "config", k, v)
	}
	writeFile(t, filepath.Join(e.root, "README.md"), "# Fixture project\n", 0o644)
	writeFile(t, filepath.Join(e.root, "app.txt"), "baseline\n", 0o644)
	writeFile(t, filepath.Join(e.root, ".gitignore"), ".kogen/local/\n", 0o644)

	feature := project.FeaturePath(testSlug)
	green := filepath.Join(e.aux, "green.ndjson")
	writeFile(t, green, reportFor(t, feature, testFeature), 0o644)
	accept := filepath.Join(e.aux, "accept.sh")
	writeFile(t, accept, "#!/bin/sh\nprintf '%s' \"$KOGEN_NODE\" > '"+filepath.Join(e.aux, "node-seen")+"'\ncp '"+green+"' \"$KOGEN_ACCEPTANCE_REPORT\"\n", 0o755)
	cfg := &project.Config{Acceptance: &project.Acceptance{Run: accept, StepsDir: "features/steps"}}
	for _, m := range mutate {
		m(cfg)
	}
	writeFile(t, filepath.Join(e.root, ".kogen/project.yaml"), project.RenderConfig(cfg), 0o644)
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
	e.credentials()
	return e
}

// reportFor is the Cucumber Messages report of a runner that passed every step of every scenario
// of the feature text.
func reportFor(t *testing.T, feature, text string) string {
	t.Helper()
	scenarios, err := project.ParseGherkin(text)
	if err != nil {
		t.Fatal(err)
	}
	var children []any
	for i, s := range scenarios {
		var steps []any
		for j, st := range s.Steps {
			steps = append(steps, map[string]any{"id": fmt.Sprintf("ast-step-%d-%d", i+1, j+1), "location": map[string]any{"line": st.Line}, "keyword": st.Keyword})
		}
		children = append(children, map[string]any{"scenario": map[string]any{
			"id": fmt.Sprintf("ast-scenario-%d", i+1), "location": map[string]any{"line": s.Line}, "steps": steps, "examples": []any{},
		}})
	}
	events := []map[string]any{{"gherkinDocument": map[string]any{"uri": feature, "feature": map[string]any{"children": children}}}}
	for i, s := range scenarios {
		prefix := fmt.Sprintf("case-%d", i+1)
		var pickleSteps, testSteps []any
		for j, st := range s.Steps {
			id := fmt.Sprintf("%s-pickle-step-%d", prefix, j+1)
			pickleSteps = append(pickleSteps, map[string]any{"id": id, "astNodeIds": []any{fmt.Sprintf("ast-step-%d-%d", i+1, j+1)}, "text": st.Text})
			testSteps = append(testSteps, map[string]any{"id": fmt.Sprintf("%s-test-step-%d", prefix, j+1), "pickleStepId": id})
		}
		events = append(events,
			map[string]any{"pickle": map[string]any{"id": prefix + "-pickle", "uri": feature, "name": s.Name, "astNodeIds": []any{fmt.Sprintf("ast-scenario-%d", i+1)}, "steps": pickleSteps}},
			map[string]any{"testCase": map[string]any{"id": prefix + "-case", "pickleId": prefix + "-pickle", "testSteps": testSteps}},
			map[string]any{"testCaseStarted": map[string]any{"id": prefix + "-started", "testCaseId": prefix + "-case"}})
		for _, ts := range testSteps {
			events = append(events, map[string]any{"testStepFinished": map[string]any{
				"testCaseStartedId": prefix + "-started", "testStepId": ts.(map[string]any)["id"], "testStepResult": map[string]any{"status": "PASSED"},
			}})
		}
		events = append(events, map[string]any{"testCaseFinished": map[string]any{"testCaseStartedId": prefix + "-started", "willBeRetried": false}})
	}
	lines := make([]string, len(events))
	for i, ev := range events {
		b, err := json.Marshal(ev)
		if err != nil {
			t.Fatal(err)
		}
		lines[i] = string(b)
	}
	return strings.Join(lines, "\n") + "\n"
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
		Slug: testSlug, SHA256: project.Hash(e.root, baseline), Base: e.head(), Approver: "Kogen Consumer <kogen-consumer@example.invalid>",
		ApprovedAt: "2026-10-22T00:00:00Z",
	})
	if err != nil {
		e.t.Fatal(err)
	}
}

// credentials seeds a usable ChatGPT login under the fixture's HOME.
func (e *env) credentials() {
	e.t.Helper()
	dir := filepath.Join(e.home, ".kogen", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		e.t.Fatal(err)
	}
	b, _ := json.Marshal(map[string]any{
		"client_id": "oaiapp_fake", "access_token": "fake-access-token", "refresh_token": "fake-refresh-token",
		"expires_at": time.Now().Unix() + 86400, "scope": "openid", "email": "consumer@example.invalid",
	})
	if err := os.WriteFile(filepath.Join(dir, "chatgpt.json"), b, 0o600); err != nil {
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
	e.t.Helper()
	b, err := os.ReadFile(filepath.Join(e.root, rel))
	if err != nil {
		e.t.Fatal(err)
	}
	return string(b)
}

// session is a session in the repository the way kogen makes one, with the fixture's HOME and
// the loopback provider as the model and sign-in seams.
func (e *env) session() (*sys.Session, *strings.Builder) {
	env := append(slices.Clone(e.git), "HOME="+e.home, "KOGEN_PROVIDER_URL="+e.prov.srv.URL, "KOGEN_AUTH_URL="+e.prov.srv.URL)
	s := sys.NewWith(env, e.root)
	out := &strings.Builder{}
	s.Stdout, s.Stderr = out, io.Discard
	return s, out
}

// deps are the dependencies kogen passes: a client and the tools, no external executor.
func (e *env) deps() build.Deps {
	return build.Deps{Client: provider.NewClient("kogen dev+12345678 (test)"), Tools: verify.Tools{Node: filepath.Join(e.aux, "node")}}
}

// attempt is one command's end.
type attempt struct {
	s    *sys.Session
	out  *strings.Builder
	exit int
	err  error
}

// shown is what the user sees: stdout and a refusal's own rendering.
func (a *attempt) shown() string {
	text := a.out.String()
	if e, ok := sys.AsError(a.err); ok {
		text += e.Render()
	}
	return text
}

// build runs `kogen intent build fixture` to its end.
func (e *env) build(mutate ...func(*build.Input)) *attempt {
	e.t.Helper()
	s, out := e.session()
	in := build.Input{Deps: e.deps(), Project: e.root, Slug: testSlug}
	for _, m := range mutate {
		m(&in)
	}
	a := &attempt{s: s, out: out}
	a.exit, a.err = build.Build(context.Background(), s, in)
	return a
}

// start runs a build in the background; the session is returned to interrupt it.
func (e *env) start() (*attempt, <-chan struct{}) {
	e.t.Helper()
	s, out := e.session()
	in := build.Input{Deps: e.deps(), Project: e.root, Slug: testSlug}
	a := &attempt{s: s, out: out}
	done := make(chan struct{})
	go func() {
		defer close(done)
		a.exit, a.err = build.Build(context.Background(), s, in)
	}()
	return a, done
}

// resume runs `kogen intent resume <id>` to its end.
func (e *env) resume(id string) *attempt {
	e.t.Helper()
	s, out := e.session()
	a := &attempt{s: s, out: out}
	a.exit, a.err = build.Resume(context.Background(), s, build.ResumeInput{Deps: e.deps(), Project: e.root, ID: id})
	return a
}

// recoverBuild runs `kogen intent recover <id> --output <output>` to its end.
func (e *env) recoverBuild(id, output string) *attempt {
	e.t.Helper()
	s, out := e.session()
	a := &attempt{s: s, out: out}
	a.exit, a.err = build.Recover(context.Background(), s, build.RecoverInput{Project: e.root, ID: id, Output: output})
	return a
}

var buildIDLine = regexp.MustCompile(`\(Build ([0-9a-f]{8})\)`)

// buildID is the id of the run a command's stdout names, as the user reads it.
func buildID(t *testing.T, out string) string {
	t.Helper()
	m := buildIDLine.FindStringSubmatch(out)
	if m == nil {
		t.Fatalf("stdout names no Build id:\n%s", out)
	}
	return m[1]
}

// runIDs are the run folders the checkout holds.
func (e *env) runIDs() []string {
	entries, _ := os.ReadDir(filepath.Join(e.root, ".kogen/local/runs"))
	var ids []string
	for _, en := range entries {
		ids = append(ids, en.Name())
	}
	return ids
}

func contains(t *testing.T, name, text, part string) {
	t.Helper()
	if !strings.Contains(text, part) {
		t.Fatalf("%s %q does not contain %q", name, text, part)
	}
}

func equal[T comparable](t *testing.T, name string, got, want T) {
	t.Helper()
	if got != want {
		t.Fatalf("%s = %v, want %v", name, got, want)
	}
}

// asRefusal is the *sys.Error err is, or fails the test.
func asRefusal(t *testing.T, err error) *sys.Error {
	t.Helper()
	e, ok := sys.AsError(err)
	if !ok {
		t.Fatalf("error %v (%T), want a *sys.Error", err, err)
	}
	return e
}

func sha256Hex(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

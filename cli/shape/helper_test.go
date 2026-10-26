package shape

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
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen/git"
	"kogen/project"
)

// ---- a scripted provider ----

// shpStep is one answer of the scripted provider: the items of a completed response, an HTTP
// failure, or a custom handler.
type shpStep struct {
	items   []map[string]any
	status  int // HTTP failure when not 0
	code    string
	resets  int64
	handler func(w http.ResponseWriter, r *http.Request)
}

type shpProvider struct {
	t    *testing.T
	srv  *httptest.Server
	mu   sync.Mutex
	reqs []map[string]any
	seq  []shpStep
	next int
	// route, when set, chooses the answer by what the request says; nil falls back to the
	// sequence.
	route func(req map[string]any) *shpStep
}

func newShpProvider(t *testing.T, steps ...shpStep) *shpProvider {
	p := &shpProvider{t: t, seq: steps}
	p.srv = httptest.NewServer(http.HandlerFunc(p.serve))
	t.Cleanup(p.srv.Close)
	return p
}

func (p *shpProvider) serve(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	var req map[string]any
	json.Unmarshal(body, &req)
	p.mu.Lock()
	p.reqs = append(p.reqs, req)
	n := len(p.reqs) - 1
	var step shpStep
	route := p.route
	routed := false
	if route != nil {
		p.mu.Unlock()
		if st := route(req); st != nil {
			step, routed = *st, true
		}
		p.mu.Lock()
	}
	if !routed {
		if n := p.takeLocked(); n < len(p.seq) {
			step = p.seq[n]
		} else {
			step = shpStep{status: 400, code: "invalid_request_error"}
		}
	}
	p.mu.Unlock()
	switch {
	case step.handler != nil:
		step.handler(w, r)
	case step.status != 0:
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(step.status)
		errBody := map[string]any{"code": step.code, "message": "scripted failure", "type": "invalid_request_error"}
		if step.resets != 0 {
			errBody["resets_at"] = step.resets
		}
		json.NewEncoder(w).Encode(map[string]any{"error": errBody})
	default:
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("X-Request-Id", "req-fixture")
		for i, it := range step.items {
			shpFrame(w, map[string]any{"type": "response.output_item.done", "output_index": i, "item": it})
		}
		shpFrame(w, map[string]any{"type": "response.completed", "response": map[string]any{
			"id": fmt.Sprintf("resp-%d", n+1), "model": "gpt-6.1-sol", "reasoning": map[string]any{"effort": "high"},
			"usage": map[string]any{
				"input_tokens": 100 + n, "input_tokens_details": map[string]any{"cached_tokens": 40, "cache_write_tokens": 0, "cache_write_tokens_details": map[string]any{"ttl_30m_tokens": 0, "ttl_12h_tokens": 0}},
				"output_tokens": 30, "output_tokens_details": map[string]any{"reasoning_tokens": 10},
			},
		}})
	}
}

// takeLocked is the index of the next scripted step.
func (p *shpProvider) takeLocked() int {
	n := p.next
	p.next++
	return n
}

func shpFrame(w io.Writer, ev any) {
	b, _ := json.Marshal(ev)
	fmt.Fprintf(w, "data: %s\n\n", b)
}

func (p *shpProvider) requests() []map[string]any {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]map[string]any(nil), p.reqs...)
}

// shpCall is a function call item.
func shpCall(id, name string, args any) map[string]any {
	b, _ := json.Marshal(args)
	return map[string]any{"type": "function_call", "call_id": id, "name": name, "arguments": string(b)}
}

func shpAnswer(items ...map[string]any) shpStep { return shpStep{items: items} }

// shpSubmit is one answer that submits. A files submission follows a read of the README: a
// Shape that inspected nothing cannot publish (shape/uninspected).
func shpSubmit(id string, args any) shpStep {
	if m, ok := args.(map[string]any); ok {
		if _, files := m["files"]; files {
			return shpAnswer(shpCall(id+"-inspect", "read_file", map[string]any{"path": "README.md"}), shpCall(id, "submit", args))
		}
	}
	return shpAnswer(shpCall(id, "submit", args))
}

// shpAck is the smallest submission that acknowledges accounted red: one owned file, whole.
func shpAck(id string) shpStep {
	return shpSubmit(id, map[string]any{"files": []any{
		map[string]any{"path": ".kogen/intents/is-even/acceptance.feature", "content": shpFeature},
	}})
}

// shpBody is the text of everything a request carries, decoded: the policy, the messages
// (every content block), the model's replayed items and the tool outputs.
func shpBody(req map[string]any) string {
	var b strings.Builder
	var walk func(v any)
	walk = func(v any) {
		switch x := v.(type) {
		case string:
			b.WriteString(x + "\n")
		case []any:
			for _, e := range x {
				walk(e)
			}
		case map[string]any:
			for _, k := range sortedKeys(x) {
				if k == "type" || k == "role" {
					continue
				}
				walk(x[k])
			}
		}
	}
	walk(req["instructions"])
	walk(req["input"])
	return b.String()
}

// shpOutputs are the function_call_output texts of a request by call id.
func shpOutputs(req map[string]any) map[string]string {
	out := map[string]string{}
	input, _ := req["input"].([]any)
	for _, it := range input {
		m, _ := it.(map[string]any)
		if m["type"] == "function_call_output" {
			s, _ := m["output"].(string)
			out[fmt.Sprint(m["call_id"])] = s
		}
	}
	return out
}

func shpToolNames(req map[string]any) []string {
	var names []string
	tools, _ := req["tools"].([]any)
	for _, t := range tools {
		m, _ := t.(map[string]any)
		names = append(names, fmt.Sprint(m["name"]))
	}
	return names
}

// ---- the project ----

const shpSlug = "is-even"

const shpFeature = "Feature: Is even\n  Scenario: Even numbers\n    Given the number 4\n    Then it is even\n  Scenario: Odd numbers\n    Given the number 3\n    Then it is not even\n"

const shpSteps = "// steps\nGiven('the number {int}', function () {});\n"

const shpIntentMD = "# Add an is-even check\n\nSlug: is-even\nModel: not applicable — a pure function without state\nAcceptance:\n- .kogen/intents/is-even/acceptance.feature\n- features/steps/is_even_steps.js\n\ncalc.is_even(n) returns True for even integers.\n\n## Decisions\n- Non-integers raise TypeError. (source: request)\n\n## Source comparison\n- The request asks for is_even; the feature covers it.\n\n## Tests\n- is_even returns True for even integers: add test_is_even in tests/test_calc.py (unit)\n\n## Feasibility\n- none\n"

// shpFiles is a valid submission of the whole package.
func shpFiles() map[string]any {
	return map[string]any{"files": []any{
		map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": shpIntentMD},
		map[string]any{"path": ".kogen/intents/is-even/acceptance.feature", "content": shpFeature},
		map[string]any{"path": "features/steps/is_even_steps.js", "content": shpSteps},
	}}
}

func shpEnv(extra ...string) []string {
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "GIT_") {
			env = append(env, kv)
		}
	}
	env = append(env, "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1", "GIT_TERMINAL_PROMPT=0")
	return append(env, extra...)
}

type shpFx struct {
	t      *testing.T
	Root   string
	Home   string
	Aux    string
	Env    []string
	Repo   *git.Repo
	Prov   *shpProvider
	Stdout *strings.Builder
	Stderr *strings.Builder
	S      *sys.Session
	Tmp    string
	Client *provider.Client
}

// newShpFx is a committed project whose acceptance runner replays a prepared report (red by
// default), a signed-in home and a provider that plays steps.
func newShpFx(t *testing.T, steps ...shpStep) *shpFx {
	t.Helper()
	tmp := t.TempDir()
	t.Setenv("TMPDIR", tmp)
	f := &shpFx{t: t, Root: t.TempDir(), Home: t.TempDir(), Aux: t.TempDir(), Tmp: tmp}
	f.Prov = newShpProvider(t, steps...)
	f.Env = shpEnv("HOME="+f.Home, "KOGEN_PROVIDER_URL="+f.Prov.srv.URL)
	f.Repo = git.New(f.Root, f.Env)
	f.git("init", "-q")
	f.git("config", "user.name", "Fixture")
	f.git("config", "user.email", "fixture@example.invalid")
	f.git("config", "core.hooksPath", t.TempDir())
	f.git("config", "commit.gpgsign", "false")
	f.write(".gitignore", ".kogen/local/\n")
	f.write("README.md", "# Calc\n\nA tiny calculator.\n")
	f.write("app.txt", "red\n")
	f.write("calc.js", "function add(a, b) { return a + b }\n")
	f.write("features/steps/calc_steps.js", "Given('a calculator', function () {});\n")
	f.write(".kogen/project.yaml", "version: 1\ncommands:\n  checks: [{name: unit, run: 'true'}]\n  acceptance: {run: ./accept.sh, steps_dir: features/steps}\n")
	script := fmt.Sprintf(`#!/bin/sh
echo run >> '%[1]s/trace'
case "$KOGEN_ACCEPTANCE_FEATURES" in */check.feature) : > "$KOGEN_ACCEPTANCE_REPORT"; exit 0;; esac
if [ -f '%[1]s/exit' ]; then code=$(cat '%[1]s/exit'); else code=1; fi
cp '%[1]s/report' "$KOGEN_ACCEPTANCE_REPORT"
echo "$KOGEN_ACCEPTANCE_FEATURES" > '%[1]s/feature-path'
exit $code
`, f.Aux)
	f.write("accept.sh", script)
	if err := os.Chmod(filepath.Join(f.Root, "accept.sh"), 0o755); err != nil {
		t.Fatal(err)
	}
	f.setReport("FAILED", 1)
	f.git("add", "-A")
	f.git("commit", "-qm", "fixture project")
	f.signIn()
	f.newSession()
	f.Client = &provider.Client{Cache: provider.NewCache(nil), Sleep: func(ctx context.Context, d time.Duration) error { return nil }}
	return f
}

func (f *shpFx) newSession() {
	f.Stdout, f.Stderr = &strings.Builder{}, &strings.Builder{}
	f.S = sys.NewWith(f.Env, f.Root)
	f.S.Stdout, f.S.Stderr = f.Stdout, f.Stderr
}

// setReport prepares the report the acceptance runner replays: every step with status, and
// the exit code.
func (f *shpFx) setReport(status string, code int) {
	f.t.Helper()
	scenarios, err := project.ParseGherkin(shpFeature)
	if err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.Aux, "report"), []byte(shpMessages(f.t, scenarios, status)), 0o644); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.Aux, "exit"), []byte(fmt.Sprint(code)), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

func (f *shpFx) signIn() {
	dir := filepath.Join(f.Home, ".kogen", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		f.t.Fatal(err)
	}
	creds, _ := json.Marshal(map[string]any{
		"access_token": "access", "refresh_token": "refresh", "client_id": "oaiapp_fixture",
		"expires_at": time.Now().Add(24 * time.Hour).Unix(),
	})
	if err := os.WriteFile(filepath.Join(dir, "chatgpt.json"), creds, 0o600); err != nil {
		f.t.Fatal(err)
	}
}

func shpMessages(t *testing.T, scenarios []project.Scenario, status string) string {
	t.Helper()
	feature := project.FeaturePath(shpSlug)
	type msg = map[string]any
	var children []any
	for i, sc := range scenarios {
		n := i + 1
		var astSteps []any
		for j, st := range sc.Steps {
			astSteps = append(astSteps, msg{"id": fmt.Sprintf("ast-step-%d-%d", n, j+1), "location": msg{"line": st.Line}, "keyword": st.Keyword})
		}
		children = append(children, msg{"scenario": msg{"id": fmt.Sprintf("ast-sc-%d", n), "location": msg{"line": sc.Line}, "steps": astSteps, "examples": []any{}}})
	}
	events := []msg{{"gherkinDocument": msg{"uri": feature, "feature": msg{"children": children}}}}
	for i, sc := range scenarios {
		n := i + 1
		var pickleSteps, testSteps, finished []any
		for j, st := range sc.Steps {
			pid, tid := fmt.Sprintf("p-%d-%d", n, j+1), fmt.Sprintf("t-%d-%d", n, j+1)
			pickleSteps = append(pickleSteps, msg{"id": pid, "astNodeIds": []any{fmt.Sprintf("ast-step-%d-%d", n, j+1)}, "text": st.Text})
			testSteps = append(testSteps, msg{"id": tid, "pickleStepId": pid})
			result := msg{"status": status}
			if status == "FAILED" && j > 0 {
				result["status"] = "SKIPPED"
			}
			if status == "FAILED" {
				result["message"] = "assertion failed in scenario " + sc.Name
			}
			finished = append(finished, msg{"testStepFinished": msg{"testCaseStartedId": fmt.Sprintf("s-%d", n), "testStepId": tid, "testStepResult": result}})
		}
		events = append(events,
			msg{"pickle": msg{"id": fmt.Sprintf("pk-%d", n), "uri": feature, "name": sc.Name, "astNodeIds": []any{fmt.Sprintf("ast-sc-%d", n)}, "steps": pickleSteps}},
			msg{"testCase": msg{"id": fmt.Sprintf("c-%d", n), "pickleId": fmt.Sprintf("pk-%d", n), "testSteps": testSteps}},
			msg{"testCaseStarted": msg{"id": fmt.Sprintf("s-%d", n), "testCaseId": fmt.Sprintf("c-%d", n)}})
		for _, fin := range finished {
			events = append(events, fin.(msg))
		}
		events = append(events, msg{"testCaseFinished": msg{"testCaseStartedId": fmt.Sprintf("s-%d", n), "willBeRetried": false}})
	}
	var b strings.Builder
	for _, e := range events {
		line, err := json.Marshal(e)
		if err != nil {
			t.Fatal(err)
		}
		b.Write(line)
		b.WriteByte('\n')
	}
	return b.String()
}

func (f *shpFx) git(args ...string) string {
	f.t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = f.Root
	cmd.Env = f.Env
	out, err := cmd.CombinedOutput()
	if err != nil {
		f.t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return string(out)
}

func (f *shpFx) write(rel, content string) {
	f.t.Helper()
	path := filepath.Join(f.Root, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

func (f *shpFx) read(rel string) string {
	f.t.Helper()
	b, err := os.ReadFile(filepath.Join(f.Root, rel))
	if err != nil {
		f.t.Fatal(err)
	}
	return string(b)
}

func (f *shpFx) exists(rel string) bool {
	_, err := os.Lstat(filepath.Join(f.Root, rel))
	return err == nil
}

func (f *shpFx) head() string { return strings.TrimSpace(f.git("rev-parse", "HEAD")) }

func (f *shpFx) runs() int {
	b, _ := os.ReadFile(filepath.Join(f.Aux, "trace"))
	return strings.Count(string(b), "run\n")
}

// shape runs `kogen intent shape` with a fresh session's output buffers.
func (f *shpFx) shape(request string) (int, error) {
	return f.shapeFrom(request, "")
}

func (f *shpFx) shapeFrom(request, path string) (int, error) {
	f.t.Helper()
	f.newSession()
	return Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: request, RequestPath: path, Client: f.Client})
}

func shpWantError(t *testing.T, err error, class, reason, detail string, exit int) *sys.Error {
	t.Helper()
	e, ok := sys.AsError(err)
	if !ok {
		t.Fatalf("err = %v, want %s/%s", err, class, reason)
	}
	if e.Class != class || e.Reason != reason || (detail != "" && !strings.Contains(e.Detail, detail)) || e.Exit != exit {
		t.Fatalf("err = %s (exit %d), want %s/%s: %s (exit %d)", e.Error(), e.Exit, class, reason, detail, exit)
	}
	return e
}

func shpContains(t *testing.T, what, text, want string) {
	t.Helper()
	if !strings.Contains(text, want) {
		shown := text
		if len(shown) > 1500 {
			shown = shown[:300] + "\n[... " + fmt.Sprint(len(text)) + " bytes in all ...]\n" + shown[len(shown)-1000:]
		}
		t.Fatalf("%s does not contain %q:\n%s", what, want, shown)
	}
}

func shpEq[T comparable](t *testing.T, what string, got, want T) {
	t.Helper()
	if got != want {
		t.Fatalf("%s = %v, want %v", what, got, want)
	}
}

func shpMatch(t *testing.T, what, text, pattern string) {
	t.Helper()
	if !regexp.MustCompile(pattern).MatchString(text) {
		t.Fatalf("%s does not match %q:\n%s", what, pattern, text)
	}
}

// shpEvents are the events of the run's evidence file.
func (f *shpFx) events() []map[string]any {
	f.t.Helper()
	b, err := os.ReadFile(filepath.Join(f.Root, ".kogen/local/shaping", shpSlug, "events.ndjson"))
	if err != nil {
		f.t.Fatal(err)
	}
	var out []map[string]any
	for _, line := range strings.Split(string(b), "\n") {
		if line == "" {
			continue
		}
		var ev map[string]any
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			f.t.Fatalf("event %q: %v", line, err)
		}
		out = append(out, ev)
	}
	return out
}

func shpNamed(events []map[string]any, name string) []map[string]any {
	var out []map[string]any
	for _, e := range events {
		if e["event"] == name {
			out = append(out, e)
		}
	}
	return out
}

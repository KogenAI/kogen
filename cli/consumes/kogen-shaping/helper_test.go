package consumes

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/KogenAI/kogen-verification/verify"
	"kogen-loop/provider"
	"kogen-loop/sys"
)

const slug = "fixture"

// acceptanceConfig is the project configuration: acceptance is one script that replays a
// prepared report.
const acceptanceConfig = "version: 1\ncommands:\n  acceptance: {run: sh accept.sh, steps_dir: features/steps}\n"

const feature = "Feature: Fixture\n  Scenario: First\n    Then the candidate succeeds\n"

const intentMD = "# Fixture intent\n\nSlug: fixture\nModel: not applicable — nothing to model\nAcceptance:\n" +
	"- .kogen/intents/fixture/acceptance.feature\n- features/steps/fixture_steps.js\n\nThe fixture.\n\n" +
	"## Decisions\n- Fixture decision. (source: request)\n\n## Tests\n- none: fixture\n\n## Feasibility\n- none\n"

// reply writes one scripted streamed response of the loopback provider.
type reply func(w http.ResponseWriter, r *http.Request)

// fx is a temporary Git repository with its own identity, no signing and an empty hooks folder,
// a HOME of its own (signed in to ChatGPT when asked), fake node and Cucumber paths, a committed
// project whose acceptance command replays a prepared report and a loopback provider on a free
// port that plays a script. Nothing reaches the network.
type fx struct {
	t      *testing.T
	base   string
	home   string
	aux    string // outside the repository: reports and traces
	bin    string
	root   string
	hooks  string
	srv    *httptest.Server
	mu     sync.Mutex
	script []reply
	n      int
	env    []string
	tools  verify.Tools
}

func newFx(t *testing.T, signedIn bool, script ...reply) *fx {
	t.Helper()
	t.Parallel()
	base, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	f := &fx{t: t, base: base, home: filepath.Join(base, "home"), aux: filepath.Join(base, "aux"), bin: filepath.Join(base, "bin"),
		root: filepath.Join(base, "repo"), hooks: filepath.Join(base, "hooks"), script: script}
	for _, d := range []string{f.home, f.aux, f.bin, f.root, f.hooks, filepath.Join(base, "cucumber")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	f.env = envWith(os.Environ(), "HOME="+f.home, "KOGEN_PROVIDER_URL="+f.srv.URL)
	f.tools = verify.Tools{Node: filepath.Join(f.bin, "node"), Cucumber: filepath.Join(base, "cucumber")}
	if signedIn {
		dir := filepath.Join(f.home, ".kogen", "credentials")
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		creds := fmt.Sprintf(`{"client_id":"oaiapp_fixture","access_token":"fake-access","refresh_token":"fake-refresh","expires_at":%d}`, time.Now().Unix()+3600)
		if err := os.WriteFile(filepath.Join(dir, "chatgpt.json"), []byte(creds), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	f.git("init", "-q")
	f.git("config", "user.name", "Fixture")
	f.git("config", "user.email", "fixture@example.invalid")
	f.git("config", "core.hooksPath", f.hooks)
	f.git("config", "commit.gpgsign", "false")
	f.write(".gitignore", ".kogen/local/\n")
	f.write("README.md", "# Fixture\n")
	f.configure(acceptanceConfig)
	f.write("features/steps/calc_steps.js", "// steps\n")
	f.write("accept.sh", fmt.Sprintf(`#!/bin/sh
echo run >> '%[1]s/trace'
printf '%%s\n%%s\n' "$KOGEN_NODE" "$KOGEN_CUCUMBER" > '%[1]s/tools'
case "$KOGEN_ACCEPTANCE_FEATURES" in */check.feature) : > "$KOGEN_ACCEPTANCE_REPORT"; exit 0;; esac
cp '%[1]s/red.ndjson' "$KOGEN_ACCEPTANCE_REPORT"
exit 1
`, f.aux))
	if err := os.WriteFile(filepath.Join(f.aux, "red.ndjson"), []byte(report("FAILED")), 0o644); err != nil {
		t.Fatal(err)
	}
	f.commitAll("fixture project")
	return f
}

// configure replaces the project configuration without committing it.
func (f *fx) configure(yaml string) { f.write(".kogen/project.yaml", yaml) }

// addIntent writes the Intent `fixture` (acceptance red) and commits it.
func (f *fx) addIntent() {
	f.t.Helper()
	f.write(".kogen/intents/fixture/intent.md", intentMD)
	f.write(".kogen/intents/fixture/acceptance.feature", feature)
	f.write("features/steps/fixture_steps.js", "// steps\n")
	f.commitAll("fixture intent")
}

// report is the Cucumber Messages report of the one-scenario feature with every step at status.
func report(status string) string {
	events := []map[string]any{
		{"gherkinDocument": map[string]any{"uri": ".kogen/intents/fixture/acceptance.feature", "feature": map[string]any{"children": []any{
			map[string]any{"scenario": map[string]any{"id": "ast-sc-1", "location": map[string]any{"line": 2},
				"steps": []any{map[string]any{"id": "ast-step-1-1", "location": map[string]any{"line": 3}, "keyword": "Then "}}, "examples": []any{}}}}}}},
		{"pickle": map[string]any{"id": "pk-1", "uri": ".kogen/intents/fixture/acceptance.feature", "name": "First", "astNodeIds": []any{"ast-sc-1"},
			"steps": []any{map[string]any{"id": "p-1-1", "astNodeIds": []any{"ast-step-1-1"}, "text": "the candidate succeeds"}}}},
		{"testCase": map[string]any{"id": "c-1", "pickleId": "pk-1", "testSteps": []any{map[string]any{"id": "t-1-1", "pickleStepId": "p-1-1"}}}},
		{"testCaseStarted": map[string]any{"id": "s-1", "testCaseId": "c-1"}},
		{"testStepFinished": map[string]any{"testCaseStartedId": "s-1", "testStepId": "t-1-1", "testStepResult": map[string]any{"status": status}}},
		{"testCaseFinished": map[string]any{"testCaseStartedId": "s-1", "willBeRetried": false}},
	}
	var b strings.Builder
	for _, e := range events {
		line, _ := json.Marshal(e)
		b.Write(line)
		b.WriteByte('\n')
	}
	return b.String()
}

// envWith is env with each KEY=value of set replacing the variable of the same name.
func envWith(env []string, set ...string) []string {
	out := slices.Clone(env)
	for _, kv := range set {
		k, _, _ := strings.Cut(kv, "=")
		out = slices.DeleteFunc(out, func(e string) bool { return strings.HasPrefix(e, k+"=") })
		out = append(out, kv)
	}
	return out
}

// serve plays the next scripted reply; a request beyond the script is refused.
func (f *fx) serve(w http.ResponseWriter, r *http.Request) {
	io.Copy(io.Discard, r.Body)
	f.mu.Lock()
	f.n++
	var rep reply
	if f.n <= len(f.script) {
		rep = f.script[f.n-1]
	}
	f.mu.Unlock()
	if rep == nil {
		w.WriteHeader(400)
		io.WriteString(w, `{"error":{"message":"no scripted reply","code":"invalid_request_error"}}`)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	rep(w, r)
}

// requests is the number of requests the loopback provider received.
func (f *fx) requests() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.n
}

// git runs a command in the fixture directly and fails the test unless it succeeds.
func (f *fx) git(args ...string) string {
	f.t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = f.root
	cmd.Env = f.env
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		f.t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, stderr.String())
	}
	return string(out)
}

func (f *fx) write(rel, content string) {
	f.t.Helper()
	path := filepath.Join(f.root, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

func (f *fx) read(rel string) string {
	f.t.Helper()
	b, err := os.ReadFile(filepath.Join(f.root, rel))
	if err != nil {
		f.t.Fatal(err)
	}
	return string(b)
}

func (f *fx) exists(rel string) bool {
	_, err := os.Lstat(filepath.Join(f.root, rel))
	return err == nil
}

func (f *fx) commitAll(message string) {
	f.t.Helper()
	f.git("add", "-A")
	f.git("commit", "-qm", message)
}

// readAux reads a file the acceptance script left outside the repository.
func (f *fx) readAux(name string) string {
	f.t.Helper()
	b, err := os.ReadFile(filepath.Join(f.aux, name))
	if err != nil {
		f.t.Fatal(err)
	}
	return string(b)
}

// head is HEAD's commit.
func (f *fx) head() string { return strings.TrimSpace(f.git("rev-parse", "HEAD")) }

// session is a session in the repository, as kogen's runEngine makes one: its output goes to
// the returned builder.
func (f *fx) session() (*sys.Session, *strings.Builder) {
	s := sys.NewWith(f.env, f.root)
	out := &strings.Builder{}
	s.Stdout, s.Stderr = out, io.Discard
	return s, out
}

// client is the provider client kogen makes, pointed at the loopback provider by the session's
// environment.
func (f *fx) client() *provider.Client { return provider.NewClient("dev+12345678") }

func frame(v any) string {
	b, _ := json.Marshal(v)
	return "data: " + string(b) + "\n\n"
}

// call answers with one function call.
func call(name string, args any) reply {
	b, _ := json.Marshal(args)
	item := map[string]any{"type": "function_call", "id": "fc_1", "call_id": "call_1", "name": name, "arguments": string(b), "status": "completed"}
	return func(w http.ResponseWriter, _ *http.Request) {
		io.WriteString(w, frame(map[string]any{"type": "response.output_item.done", "output_index": 0, "item": item}))
		io.WriteString(w, frame(map[string]any{"type": "response.completed", "response": map[string]any{"usage": map[string]any{
			"input_tokens": 100, "input_tokens_details": map[string]any{"cached_tokens": 0},
			"output_tokens": 20, "output_tokens_details": map[string]any{"reasoning_tokens": 5}}}}))
	}
}

// wantError checks that err is a *sys.Error with the class, reason and exit status, and that
// exit is that status, as kogen's exitFor prints and returns it.
func wantError(t *testing.T, exit int, err error, class, reason string, want int) *sys.Error {
	t.Helper()
	e, ok := sys.AsError(err)
	if !ok {
		t.Fatalf("exit %d, error %v (%T); want *sys.Error %s/%s", exit, err, err, class, reason)
	}
	if e.Class != class || e.Reason != reason || e.Exit != want || exit != want {
		t.Fatalf("exit %d, error %s (exit %d); want %s/%s (exit %d)", exit, e.Error(), e.Exit, class, reason, want)
	}
	if !strings.HasPrefix(e.Render(), class+"/"+reason+": ") {
		t.Fatalf("Render = %q", e.Render())
	}
	return e
}

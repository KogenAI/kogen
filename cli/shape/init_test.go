package shape

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"kogen/agent"
	"kogen/project"
	"kogen/provider"
	"kogen/sys"
	"kogen/verify"
)

// ---- Validate and Merge (ExUnit rows `shape:` of docs/evidence/go-core-migration/ledger.md) ----

func initArgs(m map[string]any) map[string]any { return m }

func initCheckList(pairs ...string) []any {
	var out []any
	for i := 0; i+1 < len(pairs); i += 2 {
		out = append(out, map[string]any{"name": pairs[i], "run": pairs[i+1]})
	}
	return out
}

func TestInitValidateRefusesOneTimeMachineBootstrap(t *testing.T) {
	_, problems := Validate(initArgs(map[string]any{"setup": []any{"mix local.hex --force"}}), InitContext{})
	if len(problems) != 1 || !strings.Contains(problems[0], "one-time machine prerequisite") {
		t.Fatalf("problems = %q", problems)
	}
	for _, command := range []string{"mix local.rebar --force", "cd x && mix local.hex", "a; mix  local.rebar", "a&mix local.hex"} {
		if _, p := Validate(map[string]any{"setup": []any{command}}, InitContext{}); len(p) != 1 {
			t.Errorf("%q: problems %q", command, p)
		}
	}
	for _, command := range []string{"mix deps.get", "echo mix local.hex", "mix local.hexagon"} {
		if _, p := Validate(map[string]any{"setup": []any{command}}, InitContext{}); len(p) != 0 {
			t.Errorf("%q: problems %q", command, p)
		}
	}
}

func TestInitMergeDeduplicatesExactCommands(t *testing.T) {
	detected := project.Detected{Checks: []project.Check{{Name: "test", Run: "mix test"}}}
	proposed := InitProposal{Checks: []project.Check{
		{Name: "duplicate", Run: "mix test"},
		{Name: "unit", Run: "mix test test/kogen"},
		{Name: "integration", Run: "mix test test/integration"},
		{Name: "tagged", Run: "mix test test/integration --include external"},
	}}
	want := []project.Check{
		{Name: "test", Run: "mix test"},
		{Name: "unit", Run: "mix test test/kogen"},
		{Name: "integration", Run: "mix test test/integration"},
		{Name: "tagged", Run: "mix test test/integration --include external"},
	}
	if got := Merge(detected, proposed).Checks; !reflect.DeepEqual(got, want) {
		t.Fatalf("checks = %v", got)
	}
}

func TestInitMergeProposedCheckReplacesDetectedOthersFollow(t *testing.T) {
	detected := project.Detected{
		Setup:   []string{"mix deps.get"},
		Checks:  []project.Check{{Name: "test", Run: "mix test"}, {Name: "compile", Run: "mix compile"}},
		Protect: []string{".formatter.exs"},
	}
	proposed := InitProposal{
		Setup: []string{"mix deps.get", "mix ecto.create"},
		Fix:   []string{"mix format"},
		Checks: []project.Check{
			{Name: "sobelow", Run: "mix sobelow"},
			{Name: "test", Run: "mix test --warnings-as-errors"},
		},
		Protect: []string{".credo.exs", ".formatter.exs"},
	}
	want := InitProposal{
		Setup: []string{"mix deps.get", "mix ecto.create"},
		Fix:   []string{"mix format"},
		Checks: []project.Check{
			{Name: "test", Run: "mix test --warnings-as-errors"},
			{Name: "compile", Run: "mix compile"},
			{Name: "sobelow", Run: "mix sobelow"},
		},
		Protect: []string{".formatter.exs", ".credo.exs"},
	}
	if got := Merge(detected, proposed); !reflect.DeepEqual(got, want) {
		t.Fatalf("merge = %+v", got)
	}
}

func TestInitValidateDependencyOnlyManifestsAreNotEligible(t *testing.T) {
	cases := []struct {
		path, content string
		checks        []any
		eligible      bool
	}{
		{"mix.exs", "defmodule App.MixProject do\n  def project, do: [app: :app, deps: deps()]\n  defp deps, do: [{:ecto, \"~> 3.0\"}]\nend\n", nil, false},
		{"cli/go.mod", "module example.invalid/cli\n\ngo 1.27\n\nrequire example.invalid/lib v1.0.0\n", nil, false},
		{"cli/go.sum", "example.invalid/lib v1.0.0 h1:abc\n", nil, false},
		{"mix.lock", "%{\"ecto\" => {:hex, :ecto, \"3.0\", \"checksum\"}}\n", nil, false},
		{"package-lock.json", "{\"lockfileVersion\": 3, \"packages\": {}}\n", nil, false},
		{"package.json", `{"scripts":{"lint":"eslint ."}}`, initCheckList("lint", "npm run lint"), true},
		{"package.json", `{"eslintConfig":{"rules":{"eqeqeq":"error"}}}`, initCheckList("lint", "npx eslint ."), true},
		{"mix.exs", "def project, do: [aliases: [check: [\"format --check-formatted\", \"test\"]]]\n", initCheckList("check", "mix check"), true},
		{"mix.exs", "def project, do: [aliases: aliases()]\ndefp aliases, do: [check: [\"test\"]]\n", initCheckList("check", "mix check"), true},
		{"mix.exs", "def project, do: [elixirc_options: [warnings_as_errors: true]]\n", initCheckList("compile", "mix compile"), true},
		{"mix.exs", "# aliases: [check: [\"test\"]]\ndef project, do: [deps: []]\n", initCheckList("check", "mix check"), false},
		{".formatter.exs", "[inputs: [\"{lib,test}/**/*.{ex,exs}\"]]\n", nil, true},
	}
	for _, c := range cases {
		args := map[string]any{"setup": []any{}, "fix": []any{}, "checks": c.checks, "protect": []any{c.path}}
		if c.checks == nil {
			args["checks"] = []any{}
		}
		got, problems := Validate(args, InitContext{Tracked: []string{c.path}, Contents: map[string]string{c.path: c.content}})
		if c.eligible {
			if len(problems) != 0 || !reflect.DeepEqual(got.Protect, []string{c.path}) {
				t.Errorf("%s: got %+v %q", c.path, got, problems)
			}
			continue
		}
		if len(problems) != 1 || !strings.HasPrefix(problems[0], "protect path "+c.path+" is not eligible:") {
			t.Errorf("%s: problems %q", c.path, problems)
		}
	}
}

func TestInitValidateProtectionIncludesDetectedChecks(t *testing.T) {
	args := map[string]any{"checks": []any{}, "protect": []any{"package.json"}}
	ctx := InitContext{
		Tracked:        []string{"package.json"},
		Contents:       map[string]string{"package.json": `{"scripts":{"test":"node --test"}}`},
		DetectedChecks: []project.Check{{Name: "test", Run: "npm run test"}},
	}
	got, problems := Validate(args, ctx)
	if len(problems) != 0 || !reflect.DeepEqual(got.Protect, []string{"package.json"}) {
		t.Fatalf("got %+v %q", got, problems)
	}
	// The model's own check of the same name replaces the detected one.
	args["checks"] = initCheckList("test", "echo ok")
	if _, problems := Validate(args, ctx); len(problems) != 1 {
		t.Fatalf("problems %q", problems)
	}
	// npm's placeholder script is not a definition.
	ctx.Contents["package.json"] = `{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}`
	args["checks"] = []any{}
	if _, problems := Validate(args, ctx); len(problems) != 1 {
		t.Fatalf("placeholder: problems %q", problems)
	}
	// Without the manifest's text there is nothing to validate against.
	_, problems = Validate(args, InitContext{Tracked: []string{"package.json"}})
	if len(problems) != 1 || !strings.Contains(problems[0], "dependency manifest content is unavailable") {
		t.Fatalf("no content: problems %q", problems)
	}
}

func TestInitValidateMixTestDiscoveryAndCoverageAreVerificationConfiguration(t *testing.T) {
	for _, key := range []string{"test_paths", "test_pattern", "test_load_filters", "test_ignore_filters", "test_coverage"} {
		ctx := InitContext{Tracked: []string{"mix.exs"}, Contents: map[string]string{"mix.exs": "def project, do: [" + key + ": []]"}}
		got, problems := Validate(map[string]any{"protect": []any{"mix.exs"}}, ctx)
		if len(problems) != 0 || !reflect.DeepEqual(got.Protect, []string{"mix.exs"}) {
			t.Errorf("%s: %+v %q", key, got, problems)
		}
	}
}

func TestInitValidateCommittedMixTestSelectionIsProtectedConfiguration(t *testing.T) {
	// The mix.exs of this repository's Elixir Kogen, which sets test_load_filters and
	// test_ignore_filters inside a multi-line project list full of captures.
	manifest, err := os.ReadFile("testdata/init/kogen-mix.exs")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(manifest), "test_load_filters:") || !strings.Contains(string(manifest), "test_ignore_filters:") {
		t.Fatal("fixture lost its test selection settings")
	}
	ctx := InitContext{
		Tracked: []string{"mix.exs"}, Contents: map[string]string{"mix.exs": string(manifest)},
		DetectedChecks: []project.Check{{Name: "test", Run: "mix test"}},
	}
	got, problems := Validate(map[string]any{"checks": []any{}, "protect": []any{"mix.exs"}}, ctx)
	if len(problems) != 0 || !reflect.DeepEqual(got.Protect, []string{"mix.exs"}) {
		t.Fatalf("%+v %q", got, problems)
	}
}

func TestInitValidateNamesDuplicatesReservedAndUntrackedAreProblems(t *testing.T) {
	args := map[string]any{
		"setup": []any{""},
		"checks": []any{
			map[string]any{"name": "Docs Check", "run": "x"},
			map[string]any{"name": "acceptance", "run": "x"},
			map[string]any{"name": "a", "run": "x"},
			map[string]any{"name": "a", "run": "y"},
		},
		"protect": []any{"missing.cfg"},
	}
	_, problems := Validate(args, InitContext{Tracked: []string{"README.md"}})
	want := []string{
		"setup must be a list of non-empty commands",
		"protect path missing.cfg is not a tracked file",
		"check name Docs Check must be lowercase letters, digits and dashes",
		"check name acceptance is reserved",
		"check name a is used twice",
	}
	if !reflect.DeepEqual(problems, want) {
		t.Fatalf("problems = %q", problems)
	}
	got, problems := Validate(map[string]any{"checks": initCheckList("docs", "node docs-check.js")}, InitContext{})
	if len(problems) != 0 || !reflect.DeepEqual(got.Checks, []project.Check{{Name: "docs", Run: "node docs-check.js"}}) {
		t.Fatalf("got %+v %q", got, problems)
	}
}

func TestInitValidateShapes(t *testing.T) {
	cases := []struct {
		name string
		args map[string]any
		want []string
	}{
		{"setup not a list", map[string]any{"setup": "mix deps.get"}, []string{"setup must be a list"}},
		{"null fix", map[string]any{"fix": nil}, []string{"fix must be a list"}},
		{"blank command", map[string]any{"protect": []any{"  "}}, []string{"protect must be a list of non-empty commands"}},
		{"number command", map[string]any{"fix": []any{1}}, []string{"fix must be a list of non-empty commands"}},
		{"checks not a list", map[string]any{"checks": "x"}, []string{"checks must be a list"}},
		{"check without run", map[string]any{"checks": []any{map[string]any{"name": "a"}, "text"}},
			[]string{"each check needs a name and a run command", "each check needs a name and a run command"}},
		{"model is reserved", map[string]any{"checks": initCheckList("model", "x")}, []string{"check name model is reserved"}},
		{"empty command", map[string]any{"checks": initCheckList("a", "  ")}, []string{"check a has no command"}},
		{"dash edges", map[string]any{"checks": initCheckList("-a", "x", "a-", "x", "a--b", "x", "a-b", "x")},
			[]string{"check name -a must be lowercase letters, digits and dashes", "check name a- must be lowercase letters, digits and dashes", "check name a--b must be lowercase letters, digits and dashes"}},
		{"invalid arguments", map[string]any{"__invalid__": true}, nil},
	}
	for _, c := range cases {
		if _, got := Validate(c.args, InitContext{}); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: problems %q, want %q", c.name, got, c.want)
		}
	}
}

func TestInitMixVerificationMatchesElixir(t *testing.T) {
	data, err := os.ReadFile("testdata/init/mix-golden.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Text     string
		Checks   []project.Check
		Eligible bool
	}
	// Check keeps its field names in the golden file as lowercase keys.
	var raw []struct {
		Text   string `json:"text"`
		Checks []struct {
			Name string `json:"name"`
			Run  string `json:"run"`
		} `json:"checks"`
		Eligible bool `json:"eligible"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatal(err)
	}
	for _, r := range raw {
		var checks []project.Check
		for _, c := range r.Checks {
			checks = append(checks, project.Check{Name: c.Name, Run: c.Run})
		}
		cases = append(cases, struct {
			Text     string
			Checks   []project.Check
			Eligible bool
		}{r.Text, checks, r.Eligible})
	}
	if len(cases) < 250 {
		t.Fatalf("only %d cases", len(cases))
	}
	for i, c := range cases {
		if got := initMixVerification(c.Text, c.Checks); got != c.Eligible {
			t.Errorf("case %d: got %v, Elixir says %v\nchecks %v\n%s", i, got, c.Eligible, c.Checks, c.Text)
		}
	}
}

func TestInitDetectedJSONKeyOrderAndEscapes(t *testing.T) {
	d := project.Detected{Setup: []string{"a \"q\"\n"}, Checks: []project.Check{{Name: "t", Run: "x\ty"}}}
	want := `{"setup":["a \"q\"\n"],"protect":[],"fix":[],"checks":[{"name":"t","run":"x\ty"}]}`
	if got := initDetectedJSON(d); got != want {
		t.Fatalf("got %s", got)
	}
}

// ---- the command ----

// initSSE is one scripted provider answer.
type initSSE func(w http.ResponseWriter)

// initInput is the conversation of a recorded request, the developer message first.
func initInput(body map[string]any) []map[string]any {
	var out []map[string]any
	// The request carries its policy as the frozen `instructions`; the tests read it as the
	// leading developer message of the conversation.
	if policy, ok := body["instructions"].(string); ok {
		out = append(out, map[string]any{"role": "developer", "content": policy})
	}
	for _, it := range body["input"].([]any) {
		out = append(out, it.(map[string]any))
	}
	return out
}

// initText is the text of an item: a string content or the joined text blocks.
func initText(item map[string]any) string {
	switch c := item["content"].(type) {
	case string:
		return c
	case []any:
		var parts []string
		for _, b := range c {
			parts = append(parts, b.(map[string]any)["text"].(string))
		}
		return strings.Join(parts, "")
	}
	return ""
}

func initFrame(v any) string {
	b, _ := json.Marshal(v)
	return "data: " + string(b) + "\n\n"
}

func initUsage() map[string]any {
	return map[string]any{"usage": map[string]any{
		"input_tokens": 100, "input_tokens_details": map[string]any{"cached_tokens": 0},
		"output_tokens": 20, "output_tokens_details": map[string]any{"reasoning_tokens": 5}}}
}

// initSubmit answers with one submit_configuration call.
func initSubmit(args map[string]any) initSSE {
	b, _ := json.Marshal(args)
	call := map[string]any{"type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "submit_configuration", "arguments": string(b), "status": "completed"}
	return func(w http.ResponseWriter) {
		io.WriteString(w, initFrame(map[string]any{"type": "response.output_item.done", "output_index": 0, "item": call}))
		io.WriteString(w, initFrame(map[string]any{"type": "response.completed", "response": initUsage()}))
	}
}

// initNothing is the reply `init-proposes-nothing`.
func initNothing() initSSE {
	return initSubmit(map[string]any{"setup": []any{}, "fix": []any{}, "checks": []any{}, "protect": []any{}})
}

func initAnswerText(text string) initSSE {
	msg := map[string]any{"type": "message", "id": "msg_1", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": text, "annotations": []any{}}}}
	return func(w http.ResponseWriter) {
		io.WriteString(w, initFrame(map[string]any{"type": "response.output_item.done", "output_index": 0, "item": msg}))
		io.WriteString(w, initFrame(map[string]any{"type": "response.completed", "response": initUsage()}))
	}
}

type initFx struct {
	t        *testing.T
	home     string
	bin      string
	repo     string
	srv      *httptest.Server
	mu       sync.Mutex
	script   []initSSE
	bodies   []map[string]any
	env      []string
	tools    verify.Tools
	out, err *strings.Builder
}

func initTestRun(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %v\n%s", args, err, out)
	}
	return string(out)
}

// initNewFx makes a temp HOME with a saved ChatGPT login (when signedIn), fake mix, npm and
// node programs, a scripted provider and an empty repository.
func initNewFx(t *testing.T, signedIn bool, script ...initSSE) *initFx {
	t.Helper()
	base, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	f := &initFx{t: t, home: filepath.Join(base, "home"), bin: filepath.Join(base, "bin"), repo: filepath.Join(base, "repo"), script: script,
		out: &strings.Builder{}, err: &strings.Builder{}}
	for _, d := range []string{f.home, f.bin, f.repo, filepath.Join(base, "cucumber")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	f.program("mix", `case "$*" in
  "deps.get") exit 0;;
  "format --check-formatted") exit 0;;
  "compile --warnings-as-errors") echo "warning: unused variable" >&2; exit 1;;
  "test") exit 0;;
esac
exit 3`)
	f.program("npm", `case "$*" in
  "ci --no-audit --no-fund") exit 0;;
  "run test") exit 0;;
  "run lint") exit 2;;
esac
exit 3`)
	f.program("node", `[ -n "$FAKE_NODE_STATUS" ] && exit "$FAKE_NODE_STATUS"
[ -n "$KOGEN_ACCEPTANCE_REPORT" ] && echo '{}' > "$KOGEN_ACCEPTANCE_REPORT"
exit 0`)
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	f.env = []string{"HOME=" + f.home, "PATH=" + f.bin + ":" + os.Getenv("PATH"), "KOGEN_PROVIDER_URL=" + f.srv.URL,
		"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1"}
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
	initTestRun(t, f.repo, "git", "init", "-q")
	hooks := filepath.Join(base, "hooks")
	os.MkdirAll(hooks, 0o755)
	f.git("config", "core.hooksPath", hooks)
	f.git("config", "user.name", "Test User")
	f.git("config", "user.email", "test@example.invalid")
	f.git("config", "commit.gpgsign", "false")
	return f
}

func (f *initFx) program(name, body string) {
	f.t.Helper()
	if err := os.WriteFile(filepath.Join(f.bin, name), []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
		f.t.Fatal(err)
	}
}

func (f *initFx) serve(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	var doc map[string]any
	json.Unmarshal(body, &doc)
	f.mu.Lock()
	f.bodies = append(f.bodies, doc)
	n := len(f.bodies)
	var reply initSSE
	if n <= len(f.script) {
		reply = f.script[n-1]
	}
	f.mu.Unlock()
	if reply == nil {
		w.WriteHeader(400)
		io.WriteString(w, `{"error":{"message":"no scripted reply","code":"invalid_request_error"}}`)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	reply(w)
}

func (f *initFx) git(args ...string) string {
	f.t.Helper()
	return initTestRun(f.t, f.repo, append([]string{"git"}, args...)...)
}

func (f *initFx) write(path, content string) {
	f.t.Helper()
	full := filepath.Join(f.repo, path)
	os.MkdirAll(filepath.Dir(full), 0o755)
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

func (f *initFx) read(path string) string {
	b, err := os.ReadFile(filepath.Join(f.repo, path))
	if err != nil {
		f.t.Fatal(err)
	}
	return string(b)
}

func (f *initFx) exists(path string) bool {
	_, err := os.Lstat(filepath.Join(f.repo, path))
	return err == nil
}

// commitAll commits every file written so far.
func (f *initFx) commitAll(message string) {
	f.git("add", "-A")
	f.git("commit", "-qm", message)
}

func (f *initFx) head() string { return strings.TrimSpace(f.git("rev-parse", "HEAD")) }

func (f *initFx) requests() []map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]map[string]any(nil), f.bodies...)
}

// run runs Init in dir (the repository root when "") and returns what it printed.
func (f *initFx) run(dir string) (exit int, stdout, stderr string, err error) {
	f.t.Helper()
	if dir == "" {
		dir = f.repo
	}
	f.out.Reset()
	f.err.Reset()
	s := sys.NewWith(f.env, dir)
	s.Stdout, s.Stderr = f.out, f.err
	exit, err = Init(context.Background(), s, InitInput{Client: provider.NewClient("dev+12345678"), Tools: f.tools, Home: f.home})
	return exit, f.out.String(), f.err.String(), err
}

func (f *initFx) mustRun() (stdout, stderr string) {
	f.t.Helper()
	exit, out, errs, err := f.run("")
	if err != nil || exit != 0 {
		f.t.Fatalf("exit %d, err %v\nstdout %s\nstderr %s", exit, err, out, errs)
	}
	return out, errs
}

func (f *initFx) wantError(class, reason string, exit int) *sys.Error {
	f.t.Helper()
	got, out, errs, err := f.run("")
	e, ok := sys.AsError(err)
	if !ok || e.Class != class || e.Reason != reason || e.Exit != exit || got != exit {
		f.t.Fatalf("got exit %d, err %v; want %s/%s (%d)\nstdout %s\nstderr %s", got, err, class, reason, exit, out, errs)
	}
	return e
}

// shaPattern replaces the commit id of a `Commit:` line so the output can be compared.
func initScrub(out string) string {
	lines := strings.Split(out, "\n")
	for i, l := range lines {
		if rest, ok := strings.CutPrefix(l, "Commit: "); ok && len(rest) > 8 {
			lines[i] = "Commit: {sha8}" + rest[8:]
		}
	}
	return strings.Join(lines, "\n")
}

func initWantLines(t *testing.T, got string, want ...string) {
	t.Helper()
	if g, w := initScrub(got), strings.Join(want, "\n")+"\n"; g != w {
		t.Fatalf("stdout:\n%s\nwant:\n%s", g, w)
	}
}

func (f *initFx) commitFiles() []string {
	files := strings.Fields(f.git("show", "--name-only", "--format=", "HEAD"))
	slices.Sort(files)
	return files
}

func (f *initFx) subject() string { return strings.TrimSpace(f.git("log", "-1", "--format=%s")) }

func (f *initFx) dirtyPaths() string { return f.git("status", "--porcelain") }

func (f *initFx) config() *project.Config {
	f.t.Helper()
	cfg, err := project.LoadConfig(f.repo)
	if err != nil {
		f.t.Fatal(err)
	}
	return cfg
}

func TestInitEmptyRepositoryMakesTheFirstCommit(t *testing.T) {
	f := initNewFx(t, false)
	out, errs := f.mustRun()
	initWantLines(t, out,
		"Initialized Kogen in "+f.repo,
		"Commit: {sha8} Initial commit (the first commit of this repository)",
		initNextAcceptance, initNextChecks)
	if errs != "" || len(f.requests()) != 0 {
		t.Fatalf("stderr %q, %d requests", errs, len(f.requests()))
	}
	if f.subject() != "Initial commit" || !reflect.DeepEqual(f.commitFiles(), []string{".gitignore", ".kogen/project.yaml"}) {
		t.Fatalf("commit %q %v", f.subject(), f.commitFiles())
	}
	if f.read(".kogen/project.yaml") != project.Template() || f.read(".gitignore") != ".kogen/local/\n" {
		t.Fatalf("files: %q %q", f.read(".kogen/project.yaml"), f.read(".gitignore"))
	}
	if st := f.dirtyPaths(); st != "" {
		t.Fatalf("status %q", st)
	}
	// The commit hash printed is the new HEAD.
	if !strings.Contains(out, f.head()[:8]) {
		t.Fatalf("%s does not name %s", out, f.head()[:8])
	}
}

func TestInitEmptyRepositoryKeepsAnExistingGitignore(t *testing.T) {
	f := initNewFx(t, false)
	f.write(".gitignore", "node_modules")
	f.mustRun()
	if got := f.read(".gitignore"); got != "node_modules\n.kogen/local/\n" {
		t.Fatalf(".gitignore = %q", got)
	}
}

func TestInitRefusesFilesNotCommittedYet(t *testing.T) {
	f := initNewFx(t, false)
	f.write("app.txt", "x")
	e := f.wantError("environment", "no_commits", 3)
	if e.Detail != `1 file(s) are not committed yet; commit them first (git add -A && git commit -m "Initial commit"), then run kogen init` {
		t.Fatal(e.Detail)
	}
	if f.exists(".kogen") {
		t.Fatal("wrote .kogen")
	}
	// .gitignore alone is not an uncommitted file.
	os.Remove(filepath.Join(f.repo, "app.txt"))
	f.write(".gitignore", "x\n")
	f.mustRun()
}

func TestInitNotAGitRepository(t *testing.T) {
	f := initNewFx(t, false)
	plain := filepath.Join(filepath.Dir(f.repo), "plain")
	os.MkdirAll(plain, 0o755)
	exit, out, _, err := f.run(plain)
	e, ok := sys.AsError(err)
	if !ok || e.Reason != "not_a_git_repo" || exit != 3 || out != "" || !strings.HasSuffix(e.Detail, "; run git init first") {
		t.Fatalf("exit %d, %v, out %q", exit, err, out)
	}
	if _, err := os.Stat(filepath.Join(plain, ".kogen")); err == nil {
		t.Fatal("wrote .kogen")
	}
}

func TestInitWithoutGitIdentityWritesNothing(t *testing.T) {
	f := initNewFx(t, true, initNothing())
	f.git("config", "--unset", "user.name")
	e := f.wantError("environment", "git_identity_missing", 3)
	if e.Detail != "configure git user.name and user.email" || f.exists(".kogen") || len(f.requests()) != 0 {
		t.Fatalf("%v", e)
	}
}

func TestInitWithoutLoginWritesNothing(t *testing.T) {
	f := initNewFx(t, false)
	f.write("notes.txt", "x")
	f.commitAll("first")
	e := f.wantError("provider", "login", 4)
	if e.Detail != "not signed in; run kogen provider login chatgpt" || f.exists(".kogen") || len(f.requests()) != 0 {
		t.Fatalf("%v", e)
	}
	if st := f.dirtyPaths(); st != "" {
		t.Fatalf("status %q", st)
	}
}

func TestInitConfiguresAProjectWithoutChecksAndAddsTheBridge(t *testing.T) {
	f := initNewFx(t, true, initNothing())
	f.write("README.md", "# notes\n")
	f.write("notes.txt", "one\n")
	f.write("docs/guide.md", "guide\n")
	f.write("CLAUDE.md", "be nice\n")
	f.write(".cursor/rules/a.mdc", "rule\n")
	f.commitAll("notes")
	f.write("notes.txt", "changed outside Kogen\n")
	f.write("untracked.txt", "u\n")

	exit, out, errs, err := f.run(filepath.Join(f.repo, "docs"))
	if err != nil || exit != 0 {
		t.Fatalf("exit %d: %v\n%s\n%s", exit, err, out, errs)
	}
	initWantLines(t, out,
		"Initialized Kogen in "+f.repo,
		"Setup: none",
		"Checks: none found",
		"Acceptance: Cucumber bridge added in features/steps",
		"Note: Kogen gives its models README.md only; it does not read CLAUDE.md, .cursor/rules",
		"Commit: {sha8} Add Kogen configuration",
		initNextChecks)
	for _, line := range []string{
		"kogen: detecting the project's commands",
		"kogen: asking gpt-6.1-sol/high about the project's commands",
		"kogen: checking the acceptance runner",
	} {
		if !strings.Contains(errs, line+"\n") {
			t.Errorf("stderr lacks %q:\n%s", line, errs)
		}
	}
	if !strings.Contains(errs, "kogen: init gpt-6.1-sol/high input=100 cached=0 output=20 reasoning=5 wall_ms=") {
		t.Errorf("stderr lacks the usage line:\n%s", errs)
	}
	if got := f.commitFiles(); !reflect.DeepEqual(got, []string{".gitignore", ".kogen/project.yaml", "features/steps/README.md"}) {
		t.Fatalf("commit files %v", got)
	}
	if f.subject() != "Add Kogen configuration" {
		t.Fatal(f.subject())
	}
	cfg := f.config()
	if cfg.Acceptance == nil || cfg.Acceptance.StepsDir != "features/steps" || !strings.Contains(cfg.Acceptance.Run, "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js") {
		t.Fatalf("acceptance %+v", cfg.Acceptance)
	}
	if f.read("features/steps/README.md") != "Cucumber step definitions for Kogen acceptance scenarios.\n" || !strings.Contains(f.read(".gitignore"), ".kogen/local/") {
		t.Fatal("bridge files")
	}
	if st := f.dirtyPaths(); st != " M notes.txt\n?? untracked.txt\n" {
		t.Fatalf("working tree: %q", st)
	}
	req := f.requests()
	if len(req) != 1 || req[0]["model"] != "gpt-6.1-sol" || req[0]["reasoning"].(map[string]any)["effort"] != "high" {
		t.Fatalf("requests %v", req)
	}
	body, _ := json.Marshal(req[0])
	if !strings.Contains(string(body), `README.md`) || !strings.Contains(string(body), "# notes") || strings.Contains(string(body), "be nice") {
		t.Fatalf("request body: %s", body)
	}
	tools := req[0]["tools"].([]any)
	if len(tools) != 1 || tools[0].(map[string]any)["name"] != "submit_configuration" {
		t.Fatalf("tools %v", tools)
	}
	// The shaping prompt leads the conversation as the developer message.
	if text := initText(initInput(req[0])[0]); !strings.HasPrefix(text, "You configure Kogen for an existing software project.") || text != agent.Prompt(agent.Init) {
		t.Fatalf("policy %q", text)
	}
}

func TestInitLeavesOutAFailingCheckOnTheCommittedTree(t *testing.T) {
	f := initNewFx(t, true, initNothing())
	f.write("mix.exs", "defmodule ExApp.MixProject do\n  def project, do: [app: :ex_app]\nend\n")
	f.write(".formatter.exs", "[inputs: [\"lib/*.ex\"]]\n")
	f.write("lib/ex_app.ex", "defmodule ExApp do\nend\n")
	f.commitAll("ex app")
	f.write("lib/ex_app.ex", "defmodule ExApp do\n  # changed outside Kogen\nend\n")

	out, errs := f.mustRun()
	initWantLines(t, out,
		"Initialized Kogen in "+f.repo,
		"Setup: mix deps.get",
		"Checks: format, test",
		"Left out: compile (mix compile --warnings-as-errors) failed with status 1",
		"Acceptance: Cucumber bridge added in features/steps",
		"Commit: {sha8} Add Kogen configuration")
	for _, line := range []string{
		"kogen: running setup-1: mix deps.get",
		"kogen: running setup-1 again: mix deps.get",
		"kogen: checking format: mix format --check-formatted",
		"kogen: checking compile: mix compile --warnings-as-errors",
		"kogen: checking test: mix test",
	} {
		if !strings.Contains(errs, line+"\n") {
			t.Errorf("stderr lacks %q:\n%s", line, errs)
		}
	}
	yaml := f.read(".kogen/project.yaml")
	for _, want := range []string{"    - name: format\n", "      run: 'mix format --check-formatted'\n", "    - 'mix format'\n", "  - '.formatter.exs'\n"} {
		if !strings.Contains(yaml, want) {
			t.Errorf("project.yaml lacks %q:\n%s", want, yaml)
		}
	}
	if st := f.dirtyPaths(); st != " M lib/ex_app.ex\n" {
		t.Fatalf("working tree %q", st)
	}
	body, _ := json.Marshal(f.requests()[0])
	if !strings.Contains(string(body), "## File mix.exs") || !strings.Contains(string(body), "defmodule ExApp.MixProject") {
		t.Fatalf("request lacks mix.exs: %s", body)
	}
	// The detection result is part of the request, keys in the Elixir order.
	if !strings.Contains(string(body), `# Detected\n\n{\"setup\":[\"mix deps.get\"],\"protect\":[\".formatter.exs\"],\"fix\":[\"mix format\"],\"checks\":[{\"name\":\"format\"`) {
		t.Fatalf("request lacks the detection result: %s", body)
	}
	if got := f.read(".kogen/project.yaml"); strings.Contains(got, "compile") {
		t.Fatalf("compile kept:\n%s", got)
	}
	if exit, _, _, err := f.run(""); exit != 0 || err != nil {
		t.Fatalf("second run: %d %v", exit, err)
	}
}

func TestInitRunsEveryProjectCommandOnACopyOfTheCommittedTree(t *testing.T) {
	f := initNewFx(t, true, initNothing())
	f.write("mix.exs", "defmodule A.MixProject do\nend\n")
	f.write(".gitignore", "deps/\n")
	f.write("lib/a.ex", "tracked\n")
	f.commitAll("a")
	f.write("lib/a.ex", "changed\n")
	f.write("untracked.txt", "u\n")
	f.write("deps/dep.txt", "ignored\n")
	// Records what the checks see on the copy.
	f.program("mix", `case "$*" in
  "deps.get") exit 0;;
  "compile --warnings-as-errors") { cat lib/a.ex; [ -e untracked.txt ] && echo untracked; [ -e deps/dep.txt ] && echo deps; [ -e .git ] && echo git; pwd; } > "$MIXLOG"; exit 0;;
  "test") exit 0;;
esac
exit 3`)
	log := filepath.Join(filepath.Dir(f.repo), "mix.log")
	f.env = append(f.env, "MIXLOG="+log)
	f.mustRun()
	got, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(got)), "\n")
	if len(lines) != 3 || lines[0] != "tracked" || lines[1] != "deps" || strings.HasPrefix(lines[2], f.repo) {
		t.Fatalf("copy saw %q", lines)
	}
	if _, err := os.Stat(lines[2]); err == nil {
		t.Fatalf("copy %s was not removed", lines[2])
	}
}

func TestInitLeavesOutSetupThatCannotRunTwiceOnTheSameTree(t *testing.T) {
	f := initNewFx(t, true, initSubmit(map[string]any{
		"setup": []any{"mkdir seeded", "echo run >> runs.txt", "true"}, "fix": []any{}, "checks": []any{}, "protect": []any{}}))
	f.write("README.md", "x\n")
	f.write(".gitignore", "build/\n")
	f.commitAll("notes")
	out, _ := f.mustRun()
	initWantLines(t, out,
		"Initialized Kogen in "+f.repo,
		"Setup: true",
		"Checks: none passed", // quirk kept: left-out setup entries count
		"Left out: setup-1 (mkdir seeded) is not repeatable: its second run failed with status 1; setup-2 (echo run >> runs.txt) is not repeatable: its second run changed runs.txt",
		"Acceptance: Cucumber bridge added in features/steps",
		"Commit: {sha8} Add Kogen configuration",
		initNextChecks)
	if f.exists("seeded") || f.exists("runs.txt") {
		t.Fatal("setup ran in the working tree")
	}
}

func TestInitSetupThatFailsIsLeftOut(t *testing.T) {
	f := initNewFx(t, true, initSubmit(map[string]any{
		"setup": []any{"exit 4"}, "fix": []any{"echo fixer"}, "checks": []any{map[string]any{"name": "fails", "run": "exit 7"}}, "protect": []any{"README.md"}}))
	f.write("README.md", "x\n")
	f.commitAll("notes")
	out, _ := f.mustRun()
	initWantLines(t, out,
		"Initialized Kogen in "+f.repo,
		"Setup: none",
		"Checks: none passed",
		"Left out: setup-1 (exit 4) failed with status 4; fails (exit 7) failed with status 7",
		"Acceptance: Cucumber bridge added in features/steps",
		"Commit: {sha8} Add Kogen configuration",
		initNextChecks)
	cfg := f.config()
	// Without a passing check nothing is protected; fixers are kept untested.
	if len(cfg.Protect) != 0 || !reflect.DeepEqual(cfg.Fix, []string{"echo fixer"}) {
		t.Fatalf("config %+v", cfg)
	}
}

func TestInitUsesTheProjectsOwnCucumberRunner(t *testing.T) {
	f := initNewFx(t, true, initSubmit(map[string]any{
		"setup": []any{}, "fix": []any{}, "checks": []any{map[string]any{"name": "docs", "run": "node docs-check.js"}}, "protect": []any{}}))
	f.write("README.md", "# node app\n")
	f.write("package.json", `{"scripts":{"test":"node --test","lint":"eslint ."},"devDependencies":{"@cucumber/cucumber":"13.3.0"}}`)
	f.write("package-lock.json", "{}")
	f.write("features/step_definitions/app_steps.js", "// steps\n")
	f.write("docs-check.js", "// check\n")
	f.commitAll("node app")
	out, _ := f.mustRun()
	initWantLines(t, out,
		"Initialized Kogen in "+f.repo,
		"Setup: npm ci --no-audit --no-fund",
		"Checks: test, docs",
		"Left out: lint (npm run lint) failed with status 2",
		"Acceptance: existing Cucumber runner, steps in features/step_definitions",
		"Commit: {sha8} Add Kogen configuration")
	if got := f.commitFiles(); !reflect.DeepEqual(got, []string{".gitignore", ".kogen/project.yaml"}) {
		t.Fatalf("commit files %v", got)
	}
	yaml := f.read(".kogen/project.yaml")
	if !strings.Contains(yaml, "    - name: docs\n      run: 'node docs-check.js'\n") || !strings.Contains(yaml, `node_modules/@cucumber/cucumber/bin/cucumber.js`) {
		t.Fatalf("project.yaml:\n%s", yaml)
	}
	if cfg := f.config(); cfg.Acceptance.StepsDir != "features/step_definitions" {
		t.Fatalf("%+v", cfg.Acceptance)
	}
}

func TestInitReportsAnExistingRunnerThatDoesNotStart(t *testing.T) {
	f := initNewFx(t, true, initNothing())
	f.write("README.md", "x\n")
	f.write("package.json", `{"devDependencies":{"@cucumber/cucumber":"13.3.0"}}`)
	f.write("features/steps/a.js", "this is not JavaScript\n")
	f.commitAll("node app")
	f.env = append(f.env, "FAKE_NODE_STATUS=1")
	out, _ := f.mustRun()
	initWantLines(t, out,
		"Initialized Kogen in "+f.repo,
		"Setup: none",
		"Checks: none found",
		"Acceptance: not configured: the runner check failed with status 1",
		"Commit: {sha8} Add Kogen configuration",
		initNextAcceptance, initNextChecks)
	if f.exists("features/steps/README.md") {
		t.Fatal("added the bridge next to an existing runner")
	}
}

func TestInitBridgeThatWritesNoReportIsNotAdded(t *testing.T) {
	f := initNewFx(t, true, initNothing())
	f.write("README.md", "x\n")
	f.commitAll("notes")
	f.program("node", "exit 0")
	out, _ := f.mustRun()
	initWantLines(t, out,
		"Initialized Kogen in "+f.repo,
		"Setup: none",
		"Checks: none found",
		"Acceptance: not configured: the runner check wrote no report",
		"Commit: {sha8} Add Kogen configuration",
		initNextAcceptance, initNextChecks)
	if f.exists("features/steps/README.md") || !reflect.DeepEqual(f.commitFiles(), []string{".gitignore", ".kogen/project.yaml"}) {
		t.Fatalf("files %v", f.commitFiles())
	}
}

func TestInitAsksOnceToRemoveDependencyOnlyProtection(t *testing.T) {
	f := initNewFx(t, true,
		initSubmit(map[string]any{"setup": []any{}, "fix": []any{}, "checks": []any{}, "protect": []any{"mix.exs", ".formatter.exs"}}),
		initSubmit(map[string]any{"setup": []any{}, "fix": []any{}, "checks": []any{}, "protect": []any{".formatter.exs"}}))
	f.write("mix.exs", "defmodule A.MixProject do\n  def project, do: [app: :a, deps: []]\nend\n")
	f.write(".formatter.exs", "[]\n")
	f.commitAll("a")
	f.mustRun()
	req := f.requests()
	if len(req) != 2 {
		t.Fatalf("%d requests", len(req))
	}
	second, _ := json.Marshal(req[1])
	if !strings.Contains(string(second), "invalid: protect path mix.exs is not eligible") {
		t.Fatalf("request 2: %s", second)
	}
	yaml := f.read(".kogen/project.yaml")
	if !strings.Contains(yaml, "  - '.formatter.exs'\n") || strings.Contains(yaml, "mix.exs") {
		t.Fatalf("project.yaml:\n%s", yaml)
	}
}

func TestInitRepliesToACallWithItsOutputAndReplaysTheAnswer(t *testing.T) {
	f := initNewFx(t, true,
		initSubmit(map[string]any{"setup": []any{"mix local.hex --force"}, "fix": []any{}, "checks": []any{}, "protect": []any{}}),
		initNothing())
	f.write("README.md", "x\n")
	f.commitAll("a")
	f.mustRun()
	req := f.requests()
	if len(req) != 2 {
		t.Fatalf("%d requests", len(req))
	}
	first, second := initInput(req[0]), initInput(req[1])
	if len(first) != 2 || len(second) != 4 || !reflect.DeepEqual(second[:2], first) {
		t.Fatalf("inputs %v / %v", first, second)
	}
	call, output := second[2], second[3]
	if call["type"] != "function_call" || call["call_id"] != "call_1" || output["type"] != "function_call_output" || output["call_id"] != "call_1" {
		t.Fatalf("conversation %v", second)
	}
	text := output["output"].(string)
	if !strings.HasPrefix(text, "invalid: setup command mix local.hex --force is a one-time machine prerequisite") {
		t.Fatalf("output %q", text)
	}
	if got := f.read(".kogen/project.yaml"); strings.Contains(got, "local.hex") {
		t.Fatal("kept the prerequisite")
	}
}

func TestInitAnAnswerWithoutTheCallIsAskedForAgain(t *testing.T) {
	f := initNewFx(t, true, initAnswerText("I think the project is fine."), initNothing())
	f.write("README.md", "x\n")
	f.commitAll("a")
	f.mustRun()
	second := initInput(f.requests()[1])
	if len(second) != 4 {
		t.Fatalf("input %v", second)
	}
	last := second[3]
	if last["role"] != "user" || initText(last) != "Answer by calling submit_configuration." || second[2]["type"] != "message" {
		t.Fatalf("input %v", second)
	}
}

func TestInitTwoInvalidAnswersEndWithNothingWritten(t *testing.T) {
	bad := initSubmit(map[string]any{"setup": "no", "fix": []any{}, "checks": []any{}, "protect": []any{}})
	for name, script := range map[string][]initSSE{
		"invalid twice":      {bad, bad},
		"no call twice":      {initAnswerText("a"), initAnswerText("b")},
		"no call then bad":   {initAnswerText("a"), bad},
		"invalid then no it": {bad, initAnswerText("a")},
	} {
		t.Run(name, func(t *testing.T) {
			f := initNewFx(t, true, script...)
			f.write("notes.txt", "x\n")
			f.commitAll("a")
			head := f.head()
			e := f.wantError("provider", "init_invalid", 4)
			if e.Detail != "the model did not return a valid configuration; nothing was written" || f.exists(".kogen") || f.head() != head || f.dirtyPaths() != "" {
				t.Fatalf("%v %q", e, f.dirtyPaths())
			}
			if len(f.requests()) != 2 {
				t.Fatalf("%d requests", len(f.requests()))
			}
			if f.out.String() != "" {
				t.Fatalf("stdout %q", f.out.String())
			}
		})
	}
}

func TestInitProviderFailureEndsInitWithoutWriting(t *testing.T) {
	f := initNewFx(t, true)
	f.write("notes.txt", "x\n")
	f.commitAll("a")
	_, _, _, err := f.run("")
	e, ok := sys.AsError(err)
	if !ok || e.Class != "provider" || f.exists(".kogen") {
		t.Fatalf("err %v", err)
	}
}

func TestInitAlreadyInitializedChangesNothing(t *testing.T) {
	f := initNewFx(t, true, initNothing())
	f.write("README.md", "x\n")
	f.commitAll("a")
	f.mustRun()
	head := f.head()
	f.out.Reset()
	out, errs := f.mustRun()
	initWantLines(t, out, "Kogen is already initialized in "+f.repo, initNextChecks)
	if errs != "" || f.head() != head || len(f.requests()) != 1 || f.dirtyPaths() != "" {
		t.Fatalf("stderr %q head %s requests %d", errs, f.head(), len(f.requests()))
	}
}

func TestInitAlreadyInitializedPrintsWhatIsMissing(t *testing.T) {
	f := initNewFx(t, false)
	f.write(".kogen/project.yaml", project.Template())
	f.commitAll("configured")
	out, _ := f.mustRun()
	initWantLines(t, out, "Kogen is already initialized in "+f.repo, initNextAcceptance, initNextChecks)
}

func TestInitCommitsTheConfigurationAFailedInitLeftBehind(t *testing.T) {
	f := initNewFx(t, false)
	f.write("README.md", "x\n")
	f.commitAll("a")
	f.write(".kogen/project.yaml", "version: 1\ncommands:\n  setup: []\n  fix: []\n  checks:\n    - name: test\n      run: 'true'\n  acceptance:\n    run: 'x'\n    steps_dir: features/steps\nprotect: []\n")
	f.write("features/steps/README.md", "x\n")
	f.write("other.txt", "stays out\n")
	f.write(".gitignore", "build")
	out, _ := f.mustRun()
	initWantLines(t, out, "Initialized Kogen in "+f.repo, "Commit: {sha8} Add Kogen configuration")
	if got := f.commitFiles(); !reflect.DeepEqual(got, []string{".gitignore", ".kogen/project.yaml", "features/steps/README.md"}) {
		t.Fatalf("commit files %v", got)
	}
	if got := f.read(".gitignore"); got != "build\n.kogen/local/\n" {
		t.Fatalf(".gitignore %q", got)
	}
	if st := f.dirtyPaths(); st != "?? other.txt\n" || len(f.requests()) != 0 {
		t.Fatalf("status %q", st)
	}
}

func TestInitLeftoverConfigurationMustBeValid(t *testing.T) {
	f := initNewFx(t, true)
	f.write("README.md", "x\n")
	f.commitAll("a")
	f.write(".kogen/project.yaml", "version: 1\nlimits: 3\n")
	e := f.wantError("environment", "project_config_invalid", 3)
	if len(e.Lines) != 1 || !strings.HasPrefix(e.Lines[0], "line 2: ") {
		t.Fatalf("%+v", e)
	}
}

func TestInitRefusesUncommittedChangesToTheFilesItWrites(t *testing.T) {
	for _, path := range []string{".gitignore", "features/steps/README.md"} {
		t.Run(path, func(t *testing.T) {
			f := initNewFx(t, true, initNothing())
			f.write("README.md", "x\n")
			f.commitAll("a")
			f.write(path, "changed\n")
			e := f.wantError("environment", "dirty_tree", 5)
			if e.Detail != path+" has uncommitted changes; commit, stash or discard them first" || f.exists(".kogen") || len(f.requests()) != 0 {
				t.Fatalf("%v", e)
			}
		})
	}
}

func TestInitRefusesAnEarlierKogensConfigurationBeforeLoginOrWrites(t *testing.T) {
	// SET-4: a legacy file the repository ignores is still refused, signed in or not.
	for _, signedIn := range []bool{false, true} {
		f := initNewFx(t, signedIn, initNothing())
		f.write("README.md", "x\n")
		f.write(".gitignore", ".kogen/\n")
		f.commitAll("ignore local configuration")
		legacy := "# Keep this legacy configuration\ncommands: {}\n"
		f.write(".kogen/project.yaml", legacy)
		head := f.head()
		e := f.wantError("environment", "old_kogen_config", 3)
		if e.Detail != ".kogen/ is from an earlier Kogen; move it aside (git mv .kogen .kogen-old), commit, and run kogen init" ||
			f.read(".kogen/project.yaml") != legacy || f.head() != head || len(f.requests()) != 0 {
			t.Fatalf("signedIn=%v: %v", signedIn, e)
		}
	}
}

func TestInitCommitFailureLeavesTheFilesUncommitted(t *testing.T) {
	f := initNewFx(t, true, initNothing())
	f.write("README.md", "x\n")
	f.commitAll("a")
	hooks := strings.TrimSpace(f.git("config", "core.hooksPath"))
	if err := os.WriteFile(filepath.Join(hooks, "pre-commit"), []byte("#!/bin/sh\necho 'hook says no'\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	head := f.head()
	exit, out, _, err := f.run("")
	e, ok := sys.AsError(err)
	if !ok || e.Reason != "commit_failed" || exit != 3 || e.Detail != "git commit failed (status 1); the configuration is left uncommitted" ||
		!reflect.DeepEqual(e.Lines, []string{"hook says no"}) {
		t.Fatalf("exit %d err %+v", exit, err)
	}
	// The lines before the commit were printed; the files stay, unstaged.
	if !strings.HasPrefix(out, "Initialized Kogen in "+f.repo+"\n") || strings.Contains(out, "Commit:") {
		t.Fatalf("stdout %q", out)
	}
	if f.head() != head || !f.exists(".kogen/project.yaml") {
		t.Fatal("state after the failed commit")
	}
	if st := f.dirtyPaths(); st != "?? .gitignore\n?? .kogen/\n?? features/\n" {
		t.Fatalf("status %q", st)
	}
	// The next init commits what was left (SET-3).
	os.Remove(filepath.Join(hooks, "pre-commit"))
	initWantAfter, _ := f.mustRun()
	initWantLines(t, initWantAfter, "Initialized Kogen in "+f.repo, "Commit: {sha8} Add Kogen configuration", initNextChecks)
}

func TestInitFirstCommitFailureLeavesNothingStaged(t *testing.T) {
	f := initNewFx(t, false)
	hooks := strings.TrimSpace(f.git("config", "core.hooksPath"))
	os.WriteFile(filepath.Join(hooks, "pre-commit"), []byte("#!/bin/sh\nexit 1\n"), 0o755)
	e := f.wantError("environment", "commit_failed", 3)
	_ = e
	if got := f.git("status", "--porcelain"); got != "?? .gitignore\n?? .kogen/\n" {
		t.Fatalf("status %q", got)
	}
}

func TestInitInterruptedBeforeAnyCommandStartsNothing(t *testing.T) {
	f := initNewFx(t, true, initNothing())
	f.write("mix.exs", "x\n")
	f.commitAll("a")
	s := sys.NewWith(f.env, f.repo)
	s.Stdout, s.Stderr = f.out, f.err
	s.Interrupt("SIGINT")
	exit, err := Init(context.Background(), s, InitInput{Client: provider.NewClient("dev+12345678"), Tools: f.tools, Home: f.home})
	var in *sys.Interrupted
	if !errors.As(err, &in) || exit != 130 {
		t.Fatalf("exit %d err %v", exit, err)
	}
	if f.exists(".kogen") {
		t.Fatal("wrote .kogen")
	}
}

func TestInitHomeDefaultsToTheSessionsHome(t *testing.T) {
	f := initNewFx(t, true, initNothing())
	f.write("README.md", "x\n")
	f.commitAll("a")
	s := sys.NewWith(f.env, f.repo)
	s.Stdout, s.Stderr = f.out, f.err
	exit, err := Init(context.Background(), s, InitInput{Client: provider.NewClient("dev+12345678"), Tools: f.tools})
	if exit != 0 || err != nil {
		t.Fatalf("exit %d err %v", exit, err)
	}
}

func TestInitCommitSubjectsFollowTheRepositoryState(t *testing.T) {
	// SET-3 quirk kept from the Elixir Kogen: a leftover configuration committed in a
	// repository without commits uses the first commit's subject but reports the usual line.
	f := initNewFx(t, false)
	f.write(".kogen/project.yaml", project.Template())
	out, _ := f.mustRun()
	initWantLines(t, out, "Initialized Kogen in "+f.repo, "Commit: {sha8} Add Kogen configuration", initNextAcceptance, initNextChecks)
	if f.subject() != "Initial commit" {
		t.Fatal(f.subject())
	}
}

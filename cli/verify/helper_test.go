package verify

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"

	"kogen-loop/sys"
	"kogen/git"
)

// testEnv is the process environment without Git's own variables, isolated from the
// machine's global and system Git configuration.
func testEnv(extra ...string) []string {
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "GIT_") {
			env = append(env, kv)
		}
	}
	env = append(env, "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1", "GIT_TERMINAL_PROMPT=0")
	return append(env, extra...)
}

// fixture is a temporary repository with one commit, a test identity, no signing and an
// empty hooks directory of its own.
type fixture struct {
	t    *testing.T
	Root string
	Env  []string
	Repo *git.Repo
}

func newFixture(t *testing.T, extraEnv ...string) *fixture { return newFixtureIn(t, "", extraEnv...) }

// newFixtureIn is newFixture in a folder of the given name (which may hold spaces).
func newFixtureIn(t *testing.T, name string, extraEnv ...string) *fixture {
	t.Helper()
	root := t.TempDir()
	if name != "" {
		root = filepath.Join(root, name)
		if err := os.MkdirAll(root, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	env := testEnv(extraEnv...)
	f := &fixture{t: t, Root: root, Env: env, Repo: git.New(root, env)}
	f.git("init", "-q")
	f.git("config", "user.name", "Fixture")
	f.git("config", "user.email", "fixture@example.invalid")
	f.git("config", "core.hooksPath", t.TempDir())
	f.git("config", "commit.gpgsign", "false")
	f.write(".gitignore", ".kogen/local/\nbuild/\n")
	f.write("README.md", "readme\n")
	f.git("add", ".")
	f.git("commit", "-qm", "baseline")
	return f
}

func (f *fixture) git(args ...string) string {
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

func (f *fixture) write(rel, content string) {
	f.t.Helper()
	path := filepath.Join(f.Root, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

func (f *fixture) read(rel string) string {
	f.t.Helper()
	b, err := os.ReadFile(filepath.Join(f.Root, rel))
	if err != nil {
		f.t.Fatal(err)
	}
	return string(b)
}

func (f *fixture) commit(msg string) {
	f.t.Helper()
	f.git("add", "-A")
	f.git("commit", "-qm", msg)
}

func (f *fixture) head() string { return strings.TrimSpace(f.git("rev-parse", "HEAD")) }

// session is a sys.Session over the fixture's environment, with stderr captured.
func (f *fixture) session() (*sys.Session, *strings.Builder) {
	s := sys.NewWith(f.Env, f.Root)
	stderr := &strings.Builder{}
	s.Stderr = stderr
	return s, stderr
}

// memLog is a Logger that keeps events.
type memLog struct {
	mu     sync.Mutex
	events []map[string]any
}

func (l *memLog) Log(event map[string]any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.events = append(l.events, event)
}

func (l *memLog) named(event string) []map[string]any {
	var out []map[string]any
	for _, e := range l.events {
		if e["event"] == event {
			out = append(out, e)
		}
	}
	return out
}

// memEvidence is an Evidence that keeps what it was told.
type memEvidence struct {
	counts   map[string]int
	timedFor []string
	probes   int
	events   []map[string]any
}

func newEvidence() *memEvidence { return &memEvidence{counts: map[string]int{}} }

func (e *memEvidence) Count(kind string) { e.counts[kind]++ }
func (e *memEvidence) Timed(phase string, fn func() error) error {
	e.timedFor = append(e.timedFor, phase)
	return fn()
}
func (e *memEvidence) Probe(fn func() (ProbeResult, error)) (ProbeResult, error) {
	e.probes++
	return fn()
}
func (e *memEvidence) Record(event map[string]any) { e.events = append(e.events, event) }

func eq[T comparable](t *testing.T, name string, got, want T) {
	t.Helper()
	if got != want {
		t.Fatalf("%s = %#v, want %#v", name, got, want)
	}
}

func eqSlice(t *testing.T, name string, got, want []string) {
	t.Helper()
	if !slices.Equal(got, want) {
		t.Fatalf("%s = %q, want %q", name, got, want)
	}
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

// isolateTmp points the temporary folder at a fresh directory so a test can see what Kogen
// leaves behind in it.
func isolateTmp(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("TMPDIR", dir)
	return dir
}

func leftovers(t *testing.T, dir, prefix string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), prefix) {
			out = append(out, e.Name())
		}
	}
	return out
}

// ---- the real tools ----

// moduleRoot is the repository root that holds cli/ (the Elixir tree and its node_modules).
func moduleRoot(t *testing.T) string {
	t.Helper()
	_, file, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(file), "..", "..")
}

var nodeOnce struct {
	sync.Once
	path string
}

func findNode(t *testing.T) string {
	t.Helper()
	nodeOnce.Do(func() {
		if p, err := exec.LookPath("node"); err == nil {
			nodeOnce.path = p
			return
		}
		cmd := exec.Command("mise", "which", "node")
		cmd.Dir = filepath.Join(moduleRoot(t))
		if out, err := cmd.Output(); err == nil {
			nodeOnce.path = strings.TrimSpace(string(out))
		}
	})
	if nodeOnce.path == "" {
		t.Skip("node is not available")
	}
	return nodeOnce.path
}

// realTools are the Node, Quint and Cucumber of the repository's own node_modules
// (test/acceptance and spec; `npm ci` there installs them).
func realTools(t *testing.T) Tools {
	t.Helper()
	node := findNode(t)
	root := moduleRoot(t)
	tools := Tools{
		Node:     node,
		Quint:    filepath.Join(root, "spec/node_modules/@informalsystems/quint/dist/src/cli.js"),
		Cucumber: filepath.Join(root, "test/acceptance/node_modules"),
	}
	if !isRegular(tools.Quint) || !isRegular(filepath.Join(tools.Cucumber, "@cucumber/cucumber/bin/cucumber.js")) {
		t.Skip("run npm ci in test/acceptance and spec for the real Cucumber and Quint")
	}
	return tools
}

// cucumberRun is the acceptance command Kogen's init writes for its own Cucumber.
func cucumberRun(stepsDir string) string {
	return `NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" ` +
		`--strict --require '` + stepsDir + `/*.js' --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"`
}

// ---- reference data from the Elixir implementation ----

// readGolden decodes testdata/golden/<name> (written by testdata/gen/*.exs) into v.
func readGolden(t *testing.T, name string, v any) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "golden", name))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, v); err != nil {
		t.Fatalf("%s: %v", name, err)
	}
}

// sameJSON fails unless got and want (raw JSON) are equal by value.
func sameJSON(t *testing.T, name string, got any, want json.RawMessage) {
	t.Helper()
	var w any
	d := json.NewDecoder(strings.NewReader(string(want)))
	d.UseNumber()
	if err := d.Decode(&w); err != nil {
		t.Fatal(err)
	}
	if g, x := encode(generic(got)), encode(w); g != x {
		t.Fatalf("%s differs\n got: %s\nwant: %s", name, g, x)
	}
}

func sha(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

// sessionFor is a session over the isolated Git environment in dir.
func sessionFor(dir string) *sys.Session { return sys.NewWith(testEnv(), dir) }

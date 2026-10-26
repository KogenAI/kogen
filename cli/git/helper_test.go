package git

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"kogen-loop/sys"
)

// testEnv is the process environment without Git's own variables, isolated from the
// machine's global and system Git configuration, plus extra.
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
	*Repo
	Hooks string
	Env   []string
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	root := t.TempDir()
	hooks := t.TempDir()
	env := testEnv()
	f := &fixture{Repo: New(root, env), Hooks: hooks, Env: env}
	run(t, root, env, "init", "-q")
	f.configure(t, "user.name", "Fixture")
	f.configure(t, "user.email", "fixture@example.invalid")
	f.configure(t, "core.hooksPath", hooks)
	f.configure(t, "commit.gpgsign", "false")
	f.write(t, "README.md", "readme\n")
	run(t, root, env, "add", ".")
	run(t, root, env, "commit", "-qm", "baseline")
	return f
}

func (f *fixture) configure(t *testing.T, key, value string) {
	t.Helper()
	run(t, f.Dir, f.Env, "config", key, value)
}

func (f *fixture) git(t *testing.T, args ...string) string {
	t.Helper()
	return run(t, f.Dir, f.Env, args...)
}

func (f *fixture) write(t *testing.T, rel, content string) {
	t.Helper()
	path := filepath.Join(f.Dir, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func (f *fixture) hook(t *testing.T, name, script string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(f.Hooks, name), []byte("#!/bin/sh\n"+script), 0o755); err != nil {
		t.Fatal(err)
	}
}

func (f *fixture) session() (*sys.Session, *strings.Builder) {
	s := sys.NewWith(f.Env, f.Dir)
	var stderr strings.Builder
	s.Stderr = &stderr
	return s, &stderr
}

// run runs git and fails the test unless it succeeds; it returns stdout.
func run(t *testing.T, dir string, env []string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = env
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, stderr.String())
	}
	return string(out)
}

// must returns v, or panics (failing the test) on err.
func must[T any](v T, err error) T {
	if err != nil {
		panic(err)
	}
	return v
}

func equal[T comparable](t *testing.T, name string, got, want T) {
	t.Helper()
	if got != want {
		t.Fatalf("%s = %v, want %v", name, got, want)
	}
}

func sameSet(t *testing.T, name string, got, want []string) {
	t.Helper()
	g, w := append([]string{}, got...), append([]string{}, want...)
	slices.Sort(g)
	slices.Sort(w)
	if strings.Join(g, "\x00") != strings.Join(w, "\x00") {
		t.Fatalf("%s = %q, want %q", name, got, want)
	}
}

func wantSysError(t *testing.T, err error, class, reason string, exit int) *sys.Error {
	t.Helper()
	e, ok := sys.AsError(err)
	if !ok {
		t.Fatalf("error = %v, want *sys.Error %s/%s", err, class, reason)
	}
	if e.Class != class || e.Reason != reason || e.Exit != exit {
		t.Fatalf("error = %s (exit %d), want %s/%s (exit %d)", e.Error(), e.Exit, class, reason, exit)
	}
	return e
}

// gitCmd is a git command in the fixture that the caller runs and inspects itself.
func (f *fixture) gitCmd(args ...string) *exec.Cmd {
	cmd := exec.Command("git", args...)
	cmd.Dir = f.Dir
	cmd.Env = f.Env
	return cmd
}

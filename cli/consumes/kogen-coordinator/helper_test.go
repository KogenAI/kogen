package consumes

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// repoFx is a temporary Git repository with its own identity, no signing and an empty hooks
// folder. Nothing outside the test's temporary directory is read or written.
type repoFx struct {
	t    *testing.T
	base string // the temporary directory, symbolic links resolved
	dir  string // the work tree root
	env  []string
}

func newRepoFx(t *testing.T) *repoFx {
	t.Helper()
	base, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	f := &repoFx{t: t, base: base, dir: filepath.Join(base, "repo"),
		env: append(os.Environ(), "GIT_CEILING_DIRECTORIES="+base)}
	if err := os.MkdirAll(filepath.Join(f.dir, "sub", "dir"), 0o755); err != nil {
		t.Fatal(err)
	}
	f.git("init", "-q")
	f.git("config", "user.name", "Fixture")
	f.git("config", "user.email", "fixture@example.invalid")
	f.git("config", "core.hooksPath", filepath.Join(base, "hooks"))
	f.git("config", "commit.gpgsign", "false")
	return f
}

// git runs a command in the fixture directly and fails the test unless it succeeds.
func (f *repoFx) git(args ...string) string {
	f.t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = f.dir
	cmd.Env = f.env
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		f.t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, stderr.String())
	}
	return string(out)
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

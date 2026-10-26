package tools

// Provenance: this file is a port of the parts of Kogen's Git runner that list_files,
// search_text and the view_image candidate use. Sources, at Kogen commit
// 56eecd572a6e07184863939254a90d9a2dc44e96:
//
//   - cli/git/git.go: Repo.exec (git binary lookup on the PATH of the base environment,
//     CleanEnv, exit mapping with signalled = 128+signal, Status -1 and "git: <err>" for a
//     command that did not run), Repo.Head, CleanEnv and locationVars, okResult.
//   - cli/git/snapshot.go: Repo.Tree (a private temporary index seeded by read-tree, add -A
//     with literal excludes, write-tree).
//
// Not ported, because the three tools never need them: the forbidden-subcommand guard, the
// ReadOnly mode (core.fsmonitor=false, GIT_OPTIONAL_LOCKS=0), RunEnv, At/Observing and the
// rest of Kogen's Git window. Kogen passes its own *git.Repo through Tools.Repo (wrapped in
// an adapter of the Git interface), so its behavior stays exactly Kogen's.

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"

	"kogen-loop/sys"
)

// GitResult is a finished Git command; stdout and stderr stay separate.
type GitResult struct {
	Stdout, Stderr string
	Status         int
}

// Git runs the Git commands of the tools. Run's error is for a Git that did not run (a
// missing binary); a command that ran and failed is in GitResult.Status. Head is the commit
// HEAD names, "" when there is none. Tree is the id of the candidate tree (every tracked
// file and every untracked file that is not ignored, except the excluded paths), built from
// the tree of start without touching the repository's own index.
type Git interface {
	Run(args ...string) (GitResult, error)
	Head() string
	Tree(start string, excluded []string) (string, error)
}

// runner is the default Git: git in dir with the base environment env (nil: this process's
// environment) minus the variables that locate a repository.
type runner struct {
	dir string
	env []string
}

func newRunner(dir string, env []string) *runner { return &runner{dir: dir, env: env} }

// locationVars tell Git where a repository is. A child never inherits them.
var locationVars = map[string]bool{
	"GIT_DIR": true, "GIT_WORK_TREE": true, "GIT_INDEX_FILE": true, "GIT_OBJECT_DIRECTORY": true,
	"GIT_ALTERNATE_OBJECT_DIRECTORIES": true, "GIT_COMMON_DIR": true, "GIT_NAMESPACE": true,
	"GIT_PREFIX": true, "GIT_QUARANTINE_PATH": true, "GIT_IMPLICIT_WORK_TREE": true,
	"GIT_GRAFT_FILE": true, "GIT_SHALLOW_FILE": true,
}

// cleanEnv returns base without the variables that locate a repository.
func cleanEnv(base []string) []string {
	out := make([]string, 0, len(base))
	for _, kv := range base {
		if k, _, _ := strings.Cut(kv, "="); !locationVars[k] {
			out = append(out, kv)
		}
	}
	return out
}

func (r *runner) base() []string {
	if r.env == nil {
		return os.Environ()
	}
	return r.env
}

// gitBinary finds git on the PATH of the base environment.
func (r *runner) gitBinary() string {
	path := ""
	for _, kv := range r.base() {
		if v, ok := strings.CutPrefix(kv, "PATH="); ok {
			path = v
		}
	}
	for _, d := range filepath.SplitList(path) {
		if d == "" {
			d = "."
		}
		p := filepath.Join(d, "git")
		if st, err := os.Stat(p); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
			return p
		}
	}
	if p, err := exec.LookPath("git"); err == nil {
		return p
	}
	return "git"
}

func (r *runner) exec(extra []string, args ...string) (GitResult, error) {
	cmd := exec.Command(r.gitBinary(), args...)
	cmd.Dir = r.dir
	cmd.Env = append(cleanEnv(r.base()), extra...)
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	err := cmd.Run()
	res := GitResult{Stdout: out.String(), Stderr: errb.String()}
	if err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			res.Status = -1
			return res, fmt.Errorf("git: %w", err)
		}
		res.Status = ee.ExitCode()
		if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			res.Status = 128 + int(ws.Signal())
		}
	}
	return res, nil
}

// Run runs git with args in the runner's directory.
func (r *runner) Run(args ...string) (GitResult, error) { return r.exec(nil, args...) }

// ok runs a command that must succeed and returns its stdout.
func (r *runner) ok(extra []string, args ...string) (string, error) {
	res, err := r.exec(extra, args...)
	if err != nil {
		return "", err
	}
	if res.Status != 0 {
		out := strings.TrimSpace(res.Stderr)
		if out == "" {
			out = strings.TrimSpace(res.Stdout)
		}
		return "", fmt.Errorf("git %s failed (status %d): %s", strings.Join(args, " "), res.Status, out)
	}
	return res.Stdout, nil
}

// Head is the commit HEAD names, or "" in a repository without commits (or outside one).
func (r *runner) Head() string {
	res, err := r.exec(nil, "rev-parse", "--verify", "-q", "HEAD")
	if err != nil || res.Status != 0 {
		return ""
	}
	return strings.TrimSpace(res.Stdout)
}

// Tree returns the id of the candidate tree. It is built in a private index seeded from
// start's tree, so the user's index is untouched and nothing staged slips in. An empty
// start (no HEAD) or any failing command is an error, which view_image reports as an
// UNKNOWN candidate.
func (r *runner) Tree(start string, excluded []string) (string, error) {
	if start == "" || strings.HasPrefix(start, "-") || strings.ContainsRune(start, 0) {
		return "", fmt.Errorf("invalid revision: %q", start)
	}
	// "kogen-index" is the prefix Kogen's own snapshot used (cli/git/snapshot.go).
	index := sys.TmpPath("kogen-index")
	defer os.Remove(index)
	env := []string{"GIT_INDEX_FILE=" + index}
	if _, err := r.ok(env, "read-tree", start); err != nil {
		return "", err
	}
	add := []string{"add", "-A", "--", "."}
	for _, p := range excluded {
		add = append(add, ":(exclude,literal)"+p)
	}
	if _, err := r.ok(env, add...); err != nil {
		return "", err
	}
	out, err := r.ok(env, "write-tree")
	return strings.TrimSpace(out), err
}

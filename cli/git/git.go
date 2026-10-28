// Package git is Kogen's window on Git: repository discovery, HEAD, identity, changed and
// tracked paths, the clean candidate snapshot (a tree built in a private index, changed
// paths between trees, cold materialization), the user's index custody, the Build's commit
// and the Build lock.
//
// Every command runs through one runner that removes the variables Git itself sets to
// locate a repository (GIT_DIR, GIT_INDEX_FILE, ...) from the inherited environment, keeps
// stderr apart from the output it parses, and refuses revisions that look like options.
// The runner also refuses the Git commands Kogen never uses: nothing here pushes, fetches,
// rebases, merges, amends, stashes or switches branches (GIT-7). The only operations that
// move HEAD are Repo.Commit and its undo.
package git

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"syscall"

	"kogen-loop/sys"
)

// Repo is a place to run Git commands: a work tree root (or any directory), the base
// environment, and whether observation must leave the repository as it is.
type Repo struct {
	// Dir is where commands run; for a repository it is the work tree root.
	Dir string
	// Env is the base environment, KEY=VALUE. nil means this process's environment.
	Env []string
	// ReadOnly makes commands observe without side effects on the repository: optional
	// locks (index refresh) are off and no fsmonitor hook runs (preflight).
	ReadOnly bool
}

// New returns a Repo for dir without checking that it is a repository.
func New(dir string, env []string) *Repo { return &Repo{Dir: dir, Env: env} }

// At returns a Repo for another directory with the same environment and mode.
func (r *Repo) At(dir string) *Repo { c := *r; c.Dir = dir; return &c }

// Observing returns a read-only view of r.
func (r *Repo) Observing() *Repo { c := *r; c.ReadOnly = true; return &c }

// Open returns the Repo for the repository containing dir, or the environment/not_a_git_repo
// error (SET-1).
func Open(dir string, env []string) (*Repo, error) {
	return open(&Repo{Dir: dir, Env: env}, dir)
}

// OpenReadOnly is Open for a read-only observation.
func OpenReadOnly(dir string, env []string) (*Repo, error) {
	return open(&Repo{Dir: dir, Env: env, ReadOnly: true}, dir)
}

func open(probe *Repo, dir string) (*Repo, error) {
	root, ok := probe.root(dir)
	if !ok {
		return nil, sys.Fail("environment", "not_a_git_repo", dir+"; run git init first", 3)
	}
	c := *probe
	c.Dir = root
	return &c, nil
}

// Root is the repository root containing dir, expressed through the caller's own path when
// that is a symlinked form of the real one; false outside a work tree.
func Root(dir string, env []string) (string, bool) { return (&Repo{Env: env}).root(dir) }

func (r *Repo) root(dir string) (string, bool) {
	res, err := r.exec(dir, nil, nil, nil, "rev-parse", "--show-toplevel")
	if err != nil || res.Status != 0 {
		return "", false
	}
	abs, err := filepath.Abs(dir)
	if err != nil {
		return "", false
	}
	return logicalRoot(abs, strings.TrimSpace(res.Stdout)), true
}

func logicalRoot(dir, top string) string {
	for {
		switch {
		case physical(dir) == physical(top):
			return dir
		case dir == "/" || dir == filepath.Dir(dir):
			return top
		}
		dir = filepath.Dir(dir)
	}
}

func physical(path string) string {
	if p, err := filepath.EvalSymlinks(path); err == nil {
		return p
	}
	return path
}

// ---- runner ----

// Result is a finished Git command; stdout and stderr stay separate.
type Result struct {
	Stdout, Stderr string
	Status         int
}

// CommandError is a Git command that had to succeed and did not.
type CommandError struct {
	Args   []string
	Status int
	Output string
}

func (e *CommandError) Error() string {
	return fmt.Sprintf("git %s failed (status %d): %s", strings.Join(e.Args, " "), e.Status, e.Output)
}

// ErrForbidden is wrapped by the error for a Git command Kogen never runs.
var ErrForbidden = errors.New("git command not allowed")

// ErrBadRevision is wrapped by the error for a revision that is empty or looks like an option.
var ErrBadRevision = errors.New("invalid revision")

// forbidden are the subcommands that rewrite or share history, switch the checkout or move
// HEAD. Commits and the undo of Kogen's own commit have their own methods.
var forbidden = map[string]bool{
	"push": true, "fetch": true, "pull": true, "rebase": true, "merge": true,
	"cherry-pick": true, "revert": true, "am": true, "stash": true, "switch": true,
	"checkout": true, "reset": true, "commit": true, "update-ref": true,
	"filter-branch": true, "replace": true,
}

func subcommand(args []string) string {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "-c" || a == "-C" || a == "--git-dir" || a == "--work-tree" || a == "--namespace":
			i++
		case strings.HasPrefix(a, "-"):
		default:
			return a
		}
	}
	return ""
}

func checkRev(rev string) error {
	if rev == "" || strings.HasPrefix(rev, "-") || strings.ContainsRune(rev, 0) {
		return fmt.Errorf("%w: %q", ErrBadRevision, rev)
	}
	return nil
}

// Run runs git with args in r.Dir. The error is for a Git that did not run (missing binary,
// forbidden command); a command that ran and failed is in Result.Status.
func (r *Repo) Run(args ...string) (Result, error) { return r.RunEnv(nil, args...) }

// RunEnv is Run with extra KEY=VALUE variables, which win over the base environment.
func (r *Repo) RunEnv(extra []string, args ...string) (Result, error) {
	if sub := subcommand(args); forbidden[sub] {
		return Result{Status: -1}, fmt.Errorf("%w: git %s", ErrForbidden, sub)
	}
	return r.exec(r.Dir, extra, nil, nil, args...)
}

// OK runs a command that must succeed and returns its stdout.
func (r *Repo) OK(args ...string) (string, error) { return r.OKEnv(nil, args...) }

// OKEnv is OK with extra KEY=VALUE variables.
func (r *Repo) OKEnv(extra []string, args ...string) (string, error) {
	res, err := r.RunEnv(extra, args...)
	return okResult(res, err, args)
}

// ok is OK without the guard, for the operations this package owns.
func (r *Repo) ok(extra []string, args ...string) (string, error) {
	res, err := r.exec(r.Dir, extra, nil, nil, args...)
	return okResult(res, err, args)
}

func okResult(res Result, err error, args []string) (string, error) {
	if err != nil {
		return "", err
	}
	if res.Status != 0 {
		out := strings.TrimSpace(res.Stderr)
		if out == "" {
			out = strings.TrimSpace(res.Stdout)
		}
		return "", &CommandError{Args: args, Status: res.Status, Output: out}
	}
	return res.Stdout, nil
}

// okTrim is ok with the output trimmed.
func (r *Repo) okTrim(extra []string, args ...string) (string, error) {
	out, err := r.ok(extra, args...)
	return strings.TrimSpace(out), err
}

// locationVars tell Git where a repository is. A child never inherits them: Kogen may be
// started from a hook that Git gave them, and they would redirect every command.
var locationVars = map[string]bool{
	"GIT_DIR": true, "GIT_WORK_TREE": true, "GIT_INDEX_FILE": true, "GIT_OBJECT_DIRECTORY": true,
	"GIT_ALTERNATE_OBJECT_DIRECTORIES": true, "GIT_COMMON_DIR": true, "GIT_NAMESPACE": true,
	"GIT_PREFIX": true, "GIT_QUARANTINE_PATH": true, "GIT_IMPLICIT_WORK_TREE": true,
	"GIT_GRAFT_FILE": true, "GIT_SHALLOW_FILE": true,
}

// CleanEnv returns base without the variables that locate a repository.
func CleanEnv(base []string) []string {
	out := make([]string, 0, len(base))
	for _, kv := range base {
		if k, _, _ := strings.Cut(kv, "="); !locationVars[k] {
			out = append(out, kv)
		}
	}
	return out
}

// UnsetPrefix is a shell prefix that removes the location variables inside a
// `/bin/sh -c` command that inherits the caller's environment.
func UnsetPrefix() string {
	names := make([]string, 0, len(locationVars))
	for k := range locationVars {
		names = append(names, k)
	}
	slices.Sort(names)
	return "unset " + strings.Join(names, " ") + "; "
}

func (r *Repo) environ(extra []string) []string {
	base := r.Env
	if base == nil {
		base = os.Environ()
	}
	env := CleanEnv(base)
	if r.ReadOnly {
		env = append(env, "GIT_OPTIONAL_LOCKS=0")
	}
	return append(env, extra...)
}

// gitBinary finds git on the PATH of the base environment.
func (r *Repo) gitBinary() string {
	base := r.Env
	if base == nil {
		base = os.Environ()
	}
	path := ""
	for _, kv := range base {
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

func (r *Repo) exec(dir string, extra []string, stdin io.Reader, stdout io.Writer, args ...string) (Result, error) {
	if r.ReadOnly {
		args = append([]string{"-c", "core.fsmonitor=false"}, args...)
	}
	cmd := exec.Command(r.gitBinary(), args...)
	cmd.Dir = dir
	cmd.Env = r.environ(extra)
	cmd.Stdin = stdin
	var out, errb bytes.Buffer
	if stdout != nil {
		cmd.Stdout = stdout
	} else {
		cmd.Stdout = &out
	}
	cmd.Stderr = &errb
	err := cmd.Run()
	res := Result{Stdout: out.String(), Stderr: errb.String()}
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

// ---- observations ----

// Head is the commit HEAD names, or "" in a repository without commits.
func (r *Repo) Head() string {
	res, err := r.exec(r.Dir, nil, nil, nil, "rev-parse", "--verify", "-q", "HEAD")
	if err != nil || res.Status != 0 {
		return ""
	}
	return strings.TrimSpace(res.Stdout)
}

// Resolve is `git rev-parse <rev>` for a revision expression such as `<commit>^{tree}`.
func (r *Repo) Resolve(rev string) (string, error) {
	if err := checkRev(rev); err != nil {
		return "", err
	}
	return r.okTrim(nil, "rev-parse", "--verify", "-q", rev)
}

// GitDir is the absolute path of the repository's Git directory.
func (r *Repo) GitDir() (string, error) { return r.okTrim(nil, "rev-parse", "--absolute-git-dir") }

var identRE = regexp.MustCompile(`^(.*>) \d+ [+-]\d{4}$`)

// Identity is `Name <email>` as Git would author a commit, or "" when the user's
// configuration sets no user.name or no user.email.
func (r *Repo) Identity() string {
	for _, key := range []string{"user.name", "user.email"} {
		res, err := r.exec(r.Dir, nil, nil, nil, "config", "--get", key)
		if err != nil || res.Status != 0 || res.Stdout == "\n" {
			return ""
		}
	}
	res, err := r.exec(r.Dir, nil, nil, nil, "var", "GIT_AUTHOR_IDENT")
	if err != nil || res.Status != 0 {
		return ""
	}
	m := identRE.FindStringSubmatch(strings.TrimSpace(res.Stdout))
	if m == nil {
		return ""
	}
	return m[1]
}

// CanCommit is true when Git produces both an author and a committer identity from
// config or the environment, never by guessing from the host.
func (r *Repo) CanCommit() bool {
	for _, v := range []string{"GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT"} {
		res, err := r.exec(r.Dir, nil, nil, nil, "-c", "user.useConfigOnly=true", "var", v)
		if err != nil || res.Status != 0 {
			return false
		}
	}
	return true
}

// RequireIdentity is Identity, or environment/git_identity_missing (exit 3).
func (r *Repo) RequireIdentity() (string, error) {
	if who := r.Identity(); who != "" {
		return who, nil
	}
	return "", sys.Fail("environment", "git_identity_missing", "configure git user.name and user.email", 3)
}

// ChangedPaths lists the paths with uncommitted changes (staged, unstaged, or untracked and
// not ignored), relative to the root, optionally limited to pathspecs. A rename reports
// the new path then the old one; a copy leaves its source out.
func (r *Repo) ChangedPaths(pathspec ...string) ([]string, error) {
	args := append([]string{"status", "--porcelain=v1", "-z", "--untracked-files=all", "--"}, pathspec...)
	out, err := r.ok(nil, args...)
	if err != nil {
		return nil, err
	}
	return parseStatus(splitNUL(out))
}

func parseStatus(tokens []string) ([]string, error) {
	var paths []string
	for i := 0; i < len(tokens); i++ {
		t := tokens[i]
		if len(t) < 4 || t[2] != ' ' {
			return nil, fmt.Errorf("git status: unexpected entry %q", t)
		}
		x, y, path := t[0], t[1], t[3:]
		switch {
		case x == 'R' || y == 'R':
			if i+1 >= len(tokens) {
				return nil, fmt.Errorf("git status: rename of %q without its source", path)
			}
			paths = append(paths, path, tokens[i+1])
			i++
		case x == 'C' || y == 'C':
			if i+1 >= len(tokens) {
				return nil, fmt.Errorf("git status: copy of %q without its source", path)
			}
			paths = append(paths, path)
			i++
		default:
			paths = append(paths, path)
		}
	}
	return paths, nil
}

// splitNUL splits NUL-terminated output, dropping empty items.
func splitNUL(s string) []string {
	var out []string
	for _, p := range strings.Split(s, "\x00") {
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

// Tracked lists the files in the index.
func (r *Repo) Tracked() ([]string, error) {
	out, err := r.ok(nil, "ls-files", "-z", "--cached")
	return splitNUL(out), err
}

// Unignored lists tracked files and untracked files that are not ignored (VER-10).
func (r *Repo) Unignored() ([]string, error) {
	out, err := r.ok(nil, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
	return splitNUL(out), err
}

// Ignored returns those of paths that Git ignores, by the ignore rules alone (also for
// tracked files).
func (r *Repo) Ignored(paths ...string) []string {
	if len(paths) == 0 {
		return nil
	}
	res, err := r.exec(r.Dir, nil, nil, nil, append([]string{"check-ignore", "--no-index", "--"}, paths...)...)
	if err != nil || res.Status != 0 {
		return nil
	}
	var out []string
	for _, l := range strings.Split(res.Stdout, "\n") {
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}

// Show is the content of path in rev; false when there is none.
func (r *Repo) Show(rev, path string) (string, bool) {
	if checkRev(rev) != nil {
		return "", false
	}
	res, err := r.exec(r.Dir, nil, nil, nil, "show", rev+":"+path)
	if err != nil || res.Status != 0 {
		return "", false
	}
	return res.Stdout, true
}

// OperationInProgress is "merge", "rebase", "cherry-pick" or "revert" while one is
// unfinished, else "" (AUT-5).
func (r *Repo) OperationInProgress() (string, error) {
	dir, err := r.GitDir()
	if err != nil {
		return "", err
	}
	for _, c := range []struct{ file, op string }{
		{"MERGE_HEAD", "merge"}, {"rebase-merge", "rebase"}, {"rebase-apply", "rebase"},
		{"CHERRY_PICK_HEAD", "cherry-pick"}, {"REVERT_HEAD", "revert"},
	} {
		if _, err := os.Stat(filepath.Join(dir, c.file)); err == nil {
			return c.op, nil
		}
	}
	return "", nil
}

// shellQuote quotes s for /bin/sh.
func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

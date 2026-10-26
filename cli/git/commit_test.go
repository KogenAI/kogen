package git

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"kogen-loop/sys"
)

// candidate is a fixture with an edit and a new file, and the spec of its commit.
func candidate(t *testing.T) (*fixture, CommitSpec) {
	f := newFixture(t)
	start := f.Head()
	f.write(t, "app.txt", "verified edit\n")
	f.write(t, "README.md", "readme\nchanged\n")
	spec := CommitSpec{
		Tree: must(f.Tree(start, nil)), Start: start,
		Title: "Add the app", Slug: "add-app",
		MessageFile: filepath.Join(t.TempDir(), "commit-message.txt"),
	}
	return f, spec
}

func (f *fixture) log(t *testing.T, format string) string {
	t.Helper()
	return f.git(t, "log", "-1", "--format="+format)
}

func TestCommitMessageFormat(t *testing.T) {
	equal(t, "message", CommitMessage("Add the app", "add-app"), "Add the app\n\nKogen-Intent: add-app\n")
}

func TestCommitLandsTheReviewedTree(t *testing.T) {
	f, spec := candidate(t)
	s, _ := f.session()
	indexBefore := must(f.IndexBytes())
	f.write(t, "ignored-later.txt", "not in the reviewed tree\n") // appears after the snapshot
	head, err := f.Commit(s, spec)
	if err != nil {
		t.Fatal(err)
	}
	equal(t, "returned", head, f.Head())
	equal(t, "message", f.log(t, "%B"), "Add the app\n\nKogen-Intent: add-app\n\n")
	equal(t, "trailers", strings.TrimSpace(f.log(t, "%(trailers:key=Kogen-Intent,valueonly)")), "add-app")
	equal(t, "parent", strings.TrimSpace(f.log(t, "%P")), spec.Start)
	equal(t, "tree", strings.TrimSpace(f.log(t, "%T")), spec.Tree)
	equal(t, "author", strings.TrimSpace(f.log(t, "%an <%ae> / %cn <%ce>")), "Fixture <fixture@example.invalid> / Fixture <fixture@example.invalid>")
	equal(t, "message file", string(must(os.ReadFile(spec.MessageFile))), "Add the app\n\nKogen-Intent: add-app\n")
	equal(t, "one commit", strings.TrimSpace(f.git(t, "rev-list", "--count", spec.Start+"..HEAD")), "1")
	equal(t, "index", bytes.Equal(must(f.IndexBytes()), indexBefore), false)
	// The file added after the snapshot is not in the commit and stays in the work tree.
	equal(t, "status", f.git(t, "status", "--porcelain"), "?? ignored-later.txt\n")
}

func TestCommitRunsTheUsersHooks(t *testing.T) {
	f, spec := candidate(t)
	marker := filepath.Join(t.TempDir(), "hooks")
	for _, h := range []string{"pre-commit", "commit-msg", "post-commit"} {
		f.hook(t, h, fmt.Sprintf("echo %s >> '%s'\n", h, marker))
	}
	s, _ := f.session()
	must(f.Commit(s, spec))
	equal(t, "hooks", string(must(os.ReadFile(marker))), "pre-commit\ncommit-msg\npost-commit\n")
}

func TestCommitHonoursSigning(t *testing.T) {
	f, spec := candidate(t)
	gpg := filepath.Join(t.TempDir(), "fake-gpg")
	os.WriteFile(gpg, []byte("#!/bin/sh\ncat >/dev/null\necho '[GNUPG:] SIG_CREATED ' >&2\nprintf -- '-----BEGIN PGP SIGNATURE-----\\n\\nZmFrZQ==\\n-----END PGP SIGNATURE-----\\n'\n"), 0o755)
	f.configure(t, "gpg.program", gpg)
	f.configure(t, "user.signingkey", "TESTKEY")
	f.configure(t, "commit.gpgsign", "true")
	s, _ := f.session()
	head := must(f.Commit(s, spec))
	if !gpgsigRE.MatchString(f.git(t, "cat-file", "commit", head)) {
		t.Fatal("the commit is not signed although commit.gpgsign=true")
	}
}

func TestCommitDoesNotSignWhenTheUserDoesNot(t *testing.T) {
	f, spec := candidate(t)
	s, _ := f.session()
	head := must(f.Commit(s, spec))
	if gpgsigRE.MatchString(f.git(t, "cat-file", "commit", head)) {
		t.Fatal("Kogen signed a commit the user's configuration does not sign")
	}
}

func TestCommitIgnoresInheritedRepositoryLocation(t *testing.T) {
	f, spec := candidate(t)
	other := t.TempDir()
	run(t, other, f.Env, "init", "-q")
	env := append(append([]string{}, f.Env...), "GIT_DIR="+filepath.Join(other, ".git"),
		"GIT_INDEX_FILE="+filepath.Join(other, "no-such-index"), "GIT_WORK_TREE="+other)
	f.Repo.Env = env
	s := sys.NewWith(env, f.Dir)
	must(f.Commit(s, spec))
	equal(t, "committed here", strings.TrimSpace(f.log(t, "%T")), spec.Tree)
	equal(t, "other untouched", strings.TrimSpace(run(t, other, f.Env, "rev-list", "--all", "--count")), "0")
}

func TestCommitFailureReportsGitOutputAndLeavesTheCommitUndone(t *testing.T) {
	f, spec := candidate(t)
	f.hook(t, "pre-commit", "echo 'lint failed: first'\necho 'lint failed: second' >&2\nexit 7\n")
	s, _ := f.session()
	_, err := f.Commit(s, spec)
	e := wantSysError(t, err, "environment", "commit_failed", 3)
	equal(t, "detail", e.Detail, "git commit failed (status 1); the verified changes are left uncommitted")
	sameSet(t, "lines", e.Lines, []string{"lint failed: first", "lint failed: second"})
	equal(t, "head", f.Head(), spec.Start)
}

func TestCommitRefusesAReadOnlyRepository(t *testing.T) {
	f, spec := candidate(t)
	s, _ := f.session()
	if _, err := f.Observing().Commit(s, spec); err == nil {
		t.Fatal("committed through a read-only repository")
	}
	if _, err := f.Observing().CommitPaths(s, "x", []string{"README.md"}, true); err == nil {
		t.Fatal("committed paths through a read-only repository")
	}
	equal(t, "head", f.Head(), spec.Start)
}

func TestCommitUndoesACommitWhoseHookChangedTheTree(t *testing.T) {
	f, spec := candidate(t)
	f.hook(t, "pre-commit", "printf 'hook edit\\n' > hook-made.txt\nprintf 'hook edit\\n' > app.txt\ngit add hook-made.txt app.txt\n")
	s, _ := f.session()
	_, err := f.Commit(s, spec)
	e := wantSysError(t, err, "candidate", "hook_changed_commit", 1)
	equal(t, "detail", e.Detail, "a commit hook changed app.txt, hook-made.txt; the commit was undone and the changes are left in place")
	equal(t, "head back at start", f.Head(), spec.Start)
	equal(t, "hook edit stays", string(must(os.ReadFile(filepath.Join(f.Dir, "hook-made.txt")))), "hook edit\n")
	// The commit stays in the reflog with Kogen's reason.
	reflog := f.git(t, "reflog", "-3", "--format=%gs")
	if !strings.Contains(reflog, "kogen: undo the unverified commit") {
		t.Fatalf("reflog lacks the undo entry:\n%s", reflog)
	}
}

func TestCommitUndoesACommitThatIsNotSignedWhenTheUserSigns(t *testing.T) {
	f, spec := candidate(t)
	// A hook cannot sign, but a wrapper that drops --gpg-sign would: simulate by letting
	// git commit without signing while the configuration is read as signing afterwards.
	f.hook(t, "post-commit", "git config commit.gpgsign true\n")
	s, _ := f.session()
	_, err := f.Commit(s, spec)
	e := wantSysError(t, err, "candidate", "hook_changed_commit", 1)
	equal(t, "detail", e.Detail, "a commit hook changed the commit itself; the commit was undone and the changes are left in place")
	equal(t, "head", f.Head(), spec.Start)
}

func TestCommitUndoesACommitWithAnotherParent(t *testing.T) {
	f, spec := candidate(t)
	// A post-commit hook that adds a commit on top: same tree, but not the start HEAD as parent.
	marker := filepath.Join(t.TempDir(), "done")
	f.hook(t, "post-commit", fmt.Sprintf("[ -f '%[1]s' ] && exit 0\ntouch '%[1]s'\ngit commit -q --allow-empty -m sneaky\n", marker))
	s, _ := f.session()
	_, err := f.Commit(s, spec)
	e := wantSysError(t, err, "candidate", "hook_changed_commit", 1)
	equal(t, "detail", e.Detail, "a commit hook changed the commit itself; the commit was undone and the changes are left in place")
	equal(t, "head", f.Head(), spec.Start)
}

func TestCheckCommitMsgHook(t *testing.T) {
	f := newFixture(t)
	s, _ := f.session()
	if err := f.CheckCommitMsg(s, "A title", "slug"); err != nil {
		t.Fatalf("no hook: %v", err)
	}
	seen := filepath.Join(t.TempDir(), "message")
	f.hook(t, "commit-msg", fmt.Sprintf("cp \"$1\" '%s'\nexit 0\n", seen))
	if err := f.CheckCommitMsg(s, "A title", "slug"); err != nil {
		t.Fatalf("accepting hook: %v", err)
	}
	equal(t, "message seen by the hook", string(must(os.ReadFile(seen))), "A title\n\nKogen-Intent: slug\n")

	var lines []string
	for i := 1; i <= 30; i++ {
		lines = append(lines, fmt.Sprintf("echo 'line %d'", i))
	}
	f.hook(t, "commit-msg", strings.Join(lines, "\n")+"\nexit 12\n")
	err := f.CheckCommitMsg(s, "A title", "slug")
	e := wantSysError(t, err, "environment", "commit_rejected", 3)
	equal(t, "detail", e.Detail, "the commit-msg hook rejects this Intent's commit message (status=12); change the Intent's title or the hook, then approve again")
	equal(t, "lines", len(e.Lines), 20)
	equal(t, "first", e.Lines[0], "line 11")
	equal(t, "last", e.Lines[19], "line 30")
	equal(t, "head", f.log(t, "%s"), "baseline\n")
}

func TestCheckCommitMsgRejectionWithoutOutputHasOneEmptyLine(t *testing.T) {
	f := newFixture(t)
	f.hook(t, "commit-msg", "exit 3\n")
	s, _ := f.session()
	e := wantSysError(t, f.CheckCommitMsg(s, "T", "s"), "environment", "commit_rejected", 3)
	if len(e.Lines) != 1 || e.Lines[0] != "" {
		t.Fatalf("lines = %q", e.Lines)
	}
}

func TestTailLines(t *testing.T) {
	equal(t, "short", tailLines("a\nb\n\n", 20), "a\nb")
	equal(t, "cut", tailLines("1\n2\n3\n4", 2), "3\n4")
	equal(t, "empty", tailLines("", 20), "")
	equal(t, "spaces", tailLines("a  \n b \t\n", 20), "a  \n b")
}

func TestCommitPathsCommitsOnlyThosePaths(t *testing.T) {
	f := newFixture(t)
	f.write(t, ".kogen/project.yaml", "version: 1\n")
	f.write(t, "other.txt", "staged elsewhere\n")
	f.git(t, "add", "other.txt")
	f.write(t, "unstaged.txt", "x\n")
	s, _ := f.session()
	sha, err := f.CommitPaths(s, "Add Kogen configuration", []string{".kogen/project.yaml"}, true)
	if err != nil {
		t.Fatal(err)
	}
	equal(t, "sha", sha, f.Head()[:8])
	equal(t, "message", f.log(t, "%B"), "Add Kogen configuration\n\n")
	equal(t, "files", f.git(t, "show", "--name-only", "--format=", "HEAD"), ".kogen/project.yaml\n")
	equal(t, "staged elsewhere stays", f.git(t, "diff", "--cached", "--name-only"), "other.txt\n")
}

func TestCommitPathsInAnEmptyRepository(t *testing.T) {
	dir := t.TempDir()
	env := testEnv()
	run(t, dir, env, "init", "-q")
	r := New(dir, env)
	for k, v := range map[string]string{"user.name": "Fixture", "user.email": "fixture@example.invalid", "commit.gpgsign": "false", "core.hooksPath": t.TempDir()} {
		run(t, dir, env, "config", k, v)
	}
	os.WriteFile(filepath.Join(dir, ".gitignore"), []byte(".kogen/local/\n"), 0o644)
	s := sys.NewWith(env, dir)
	sha, err := r.CommitPaths(s, "Initial commit", []string{".gitignore"}, false)
	if err != nil || len(sha) != 8 {
		t.Fatalf("CommitPaths = %q, %v", sha, err)
	}
	equal(t, "head", r.Head()[:8], sha)
}

func TestCommitPathsFailureUnstagesAndReportsOutput(t *testing.T) {
	for _, hadHead := range []bool{true, false} {
		t.Run(fmt.Sprint("hadHead=", hadHead), func(t *testing.T) {
			dir := t.TempDir()
			hooks := t.TempDir()
			env := testEnv()
			run(t, dir, env, "init", "-q")
			for k, v := range map[string]string{"user.name": "Fixture", "user.email": "fixture@example.invalid", "commit.gpgsign": "false", "core.hooksPath": hooks} {
				run(t, dir, env, "config", k, v)
			}
			r := New(dir, env)
			if hadHead {
				os.WriteFile(filepath.Join(dir, "base.txt"), []byte("x\n"), 0o644)
				run(t, dir, env, "add", ".")
				run(t, dir, env, "commit", "-qm", "base")
			}
			os.WriteFile(filepath.Join(hooks, "pre-commit"), []byte("#!/bin/sh\necho 'no commits today'\nexit 1\n"), 0o755)
			os.WriteFile(filepath.Join(dir, "cfg.yaml"), []byte("x\n"), 0o644)
			_, err := r.CommitPaths(sys.NewWith(env, dir), "Add Kogen configuration", []string{"cfg.yaml"}, hadHead)
			e := wantSysError(t, err, "environment", "commit_failed", 3)
			equal(t, "detail", e.Detail, "git commit failed (status 1); the configuration is left uncommitted")
			equal(t, "lines", strings.Join(e.Lines, "|"), "no commits today")
			equal(t, "unstaged", run(t, dir, env, "diff", "--cached", "--name-only"), "")
			equal(t, "file stays", string(must(os.ReadFile(filepath.Join(dir, "cfg.yaml")))), "x\n")
		})
	}
}

// ---- interrupts (CLI-7) ----

// blockingHook is a hook that ignores termination and waits for a release file, the
// way a slow user hook would.
func blockingHook(dir string) string {
	return fmt.Sprintf("trap '' TERM HUP INT\ntouch '%[1]s/started'\nwhile [ ! -f '%[1]s/release' ]; do sleep 0.02; done\n", dir)
}

func waitFile(t *testing.T, path string) {
	t.Helper()
	for i := 0; i < 500; i++ {
		if _, err := os.Stat(path); err == nil {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", path)
}

type commitResult struct {
	head string
	err  error
}

func TestInterruptDuringCommitWaitsForGitAndUndoesALandedCommit(t *testing.T) {
	f, spec := candidate(t)
	dir := t.TempDir()
	f.hook(t, "post-commit", blockingHook(dir)) // runs after the commit is created
	s, _ := f.session()
	done := make(chan commitResult, 1)
	go func() { head, err := f.Commit(s, spec); done <- commitResult{head, err} }()

	waitFile(t, filepath.Join(dir, "started"))
	if f.Head() == spec.Start {
		t.Fatal("fixture: the commit had not landed when the hook ran")
	}
	s.Interrupt("SIGINT")
	select {
	case r := <-done:
		t.Fatalf("Commit returned %+v while git commit was still running", r)
	case <-time.After(300 * time.Millisecond):
	}
	os.WriteFile(filepath.Join(dir, "release"), nil, 0o644)
	r := <-done
	if _, ok := r.err.(*sys.Interrupted); !ok {
		t.Fatalf("error = %v, want *sys.Interrupted", r.err)
	}
	equal(t, "head undone", f.Head(), spec.Start)
	equal(t, "edit stays", string(must(os.ReadFile(filepath.Join(f.Dir, "app.txt")))), "verified edit\n")
}

func TestInterruptBeforeCommitStartsEffectsNothing(t *testing.T) {
	f, spec := candidate(t)
	s, _ := f.session()
	s.Interrupt("SIGINT")
	_, err := f.Commit(s, spec)
	if _, ok := err.(*sys.Interrupted); !ok {
		t.Fatalf("error = %v", err)
	}
	equal(t, "head", f.Head(), spec.Start)
}

func TestInterruptDuringPostCommitValidationUndoesTheCommit(t *testing.T) {
	f, spec := candidate(t)
	bin := t.TempDir()
	dir := t.TempDir()
	realGit := must(exec.LookPath("git"))
	// Widen the real post-commit query window without changing Git's output or behaviour.
	os.WriteFile(filepath.Join(bin, "git"), []byte(fmt.Sprintf(`#!/bin/sh
if [ "$1" = cat-file ] && [ "$2" = commit ]; then
  touch '%[1]s/waiting'
  while [ ! -f '%[1]s/release' ]; do sleep 0.02; done
fi
exec '%[2]s' "$@"
`, dir, realGit)), 0o755)
	env := append(append([]string{}, f.Env...), "PATH="+bin+":"+os.Getenv("PATH"))
	f.Repo.Env = env
	s := sys.NewWith(env, f.Dir)
	done := make(chan commitResult, 1)
	go func() { head, err := f.Commit(s, spec); done <- commitResult{head, err} }()

	waitFile(t, filepath.Join(dir, "waiting"))
	s.Interrupt("SIGINT")
	time.Sleep(100 * time.Millisecond)
	os.WriteFile(filepath.Join(dir, "release"), nil, 0o644)
	r := <-done
	if _, ok := r.err.(*sys.Interrupted); !ok {
		t.Fatalf("error = %v, want *sys.Interrupted", r.err)
	}
	equal(t, "head undone", f.Head(), spec.Start)
	equal(t, "edit stays", string(must(os.ReadFile(filepath.Join(f.Dir, "app.txt")))), "verified edit\n")
}

func TestCommitMsgHookThatStagesIsUndoneByIndexRestore(t *testing.T) {
	for _, exit := range []int{0, 12} {
		t.Run(fmt.Sprint("exit=", exit), func(t *testing.T) {
			f := newFixture(t)
			f.write(t, "app.txt", "original\n")
			f.git(t, "add", "app.txt")
			f.git(t, "commit", "-qm", "app")
			backup := filepath.Join(t.TempDir(), "index-at-start")
			must(0, f.SaveIndex(backup))
			before := must(f.IndexBytes())
			f.hook(t, "commit-msg", fmt.Sprintf("printf 'hook edit\\n' > app.txt\ngit add app.txt\nexit %d\n", exit))
			s, _ := f.session()
			err := f.CheckCommitMsg(s, "T", "s")
			if exit == 0 && err != nil {
				t.Fatal(err)
			}
			if exit != 0 {
				wantSysError(t, err, "environment", "commit_rejected", 3)
			}
			equal(t, "hook staged its edit", f.git(t, "diff", "--cached", "--name-only"), "app.txt\n")
			must(0, f.RestoreIndex(backup))
			if !bytes.Equal(must(f.IndexBytes()), before) {
				t.Fatal("the index is not what it was")
			}
			equal(t, "edit stays in the work tree", string(must(os.ReadFile(filepath.Join(f.Dir, "app.txt")))), "hook edit\n")
		})
	}
}

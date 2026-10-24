package git

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestChangedPathsStagedRenameWithSpaces(t *testing.T) {
	f := newFixture(t)
	f.write(t, "original name.txt", strings.Repeat("a substantial fixture line\n", 30))
	f.git(t, "add", ".")
	f.git(t, "commit", "-qm", "named")
	f.git(t, "mv", "original name.txt", "new name.txt")
	got := must(f.ChangedPaths())
	sameSet(t, "paths", got, []string{"new name.txt", "original name.txt"})
	equal(t, "first", got[0], "new name.txt") // the new path, then the old one
}

func TestChangedPathsCopyKeepsSourceOutOfRenames(t *testing.T) {
	f := newFixture(t)
	f.configure(t, "status.renames", "copies")
	body := strings.Repeat("a substantial fixture line\n", 30)
	f.write(t, "original name.txt", body)
	f.git(t, "add", ".")
	f.git(t, "commit", "-qm", "named")
	f.write(t, "copied name.txt", body)
	f.write(t, "original name.txt", body+"a later source edit\n")
	f.git(t, "add", ".")
	if status := f.git(t, "status", "--porcelain=v1", "-z"); !strings.Contains(status, "C  copied name.txt\x00original name.txt\x00") {
		t.Fatalf("fixture is not a detected copy: %q", status)
	}
	sameSet(t, "paths", must(f.ChangedPaths()), []string{"copied name.txt", "original name.txt"})
}

func TestChangedPathsNULSafeAndFiltered(t *testing.T) {
	f := newFixture(t)
	odd := []string{"new\nline.txt", "quo\"te.txt", "ünï cödé.txt", "dir with space/a b.txt", "-dash.txt"}
	for _, p := range odd {
		f.write(t, p, "x\n")
	}
	f.write(t, ".gitignore", "ignored.txt\n")
	f.write(t, "ignored.txt", "x\n")
	f.write(t, "README.md", "changed\n")
	got := must(f.ChangedPaths())
	sameSet(t, "all", got, append([]string{"README.md", ".gitignore"}, odd...))
	sameSet(t, "filtered", must(f.ChangedPaths(":(literal)README.md")), []string{"README.md"})
	sameSet(t, "dir", must(f.ChangedPaths("dir with space")), []string{"dir with space/a b.txt"})
	f.git(t, "add", "-A")
	f.git(t, "commit", "-qm", "all")
	if got := must(f.ChangedPaths()); len(got) != 0 {
		t.Fatalf("clean tree reports %q", got)
	}
}

func TestRootDiscovery(t *testing.T) {
	f := newFixture(t)
	f.write(t, "a/b/c.txt", "x\n")
	sub := filepath.Join(f.Dir, "a", "b")
	root, ok := Root(sub, f.Env)
	if !ok || root != f.Dir {
		t.Fatalf("Root(%s) = %q, %v; want %s", sub, root, ok, f.Dir)
	}
	r, err := Open(sub, f.Env)
	if err != nil || r.Dir != f.Dir {
		t.Fatalf("Open = %v, %v", r, err)
	}
	// Through a symlink the answer is the caller's own spelling.
	link := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(f.Dir, link); err != nil {
		t.Fatal(err)
	}
	root, ok = Root(filepath.Join(link, "a"), f.Env)
	if !ok || root != link {
		t.Fatalf("Root through symlink = %q, %v; want %s", root, ok, link)
	}
}

func TestOpenOutsideRepositoryIsNotAGitRepo(t *testing.T) {
	dir := t.TempDir()
	env := testEnv("GIT_CEILING_DIRECTORIES=" + filepath.Dir(dir))
	_, err := Open(dir, env)
	e := wantSysError(t, err, "environment", "not_a_git_repo", 3)
	equal(t, "detail", e.Detail, dir+"; run git init first")
	if _, ok := Root(filepath.Join(dir, "missing"), env); ok {
		t.Fatal("Root of a missing directory")
	}
	if _, err := OpenReadOnly(dir, env); err == nil {
		t.Fatal("OpenReadOnly outside a repository succeeded")
	}
}

func TestHead(t *testing.T) {
	dir := t.TempDir()
	env := testEnv()
	run(t, dir, env, "init", "-q")
	r := New(dir, env)
	equal(t, "empty repository", r.Head(), "")
	f := newFixture(t)
	want := strings.TrimSpace(f.git(t, "rev-parse", "HEAD"))
	equal(t, "head", f.Head(), want)
	if len(want) != 40 && len(want) != 64 {
		t.Fatalf("head %q", want)
	}
}

func TestIdentity(t *testing.T) {
	f := newFixture(t)
	equal(t, "identity", f.Identity(), "Fixture <fixture@example.invalid>")
	equal(t, "required", must(f.RequireIdentity()), "Fixture <fixture@example.invalid>")
	f.git(t, "config", "--unset", "user.email")
	equal(t, "no email", f.Identity(), "")
	_, err := f.RequireIdentity()
	e := wantSysError(t, err, "environment", "git_identity_missing", 3)
	equal(t, "detail", e.Detail, "configure git user.name and user.email")
	f.git(t, "config", "user.email", "x@example.invalid")
	f.git(t, "config", "user.name", "")
	equal(t, "empty name", f.Identity(), "")
}

func TestShowTrackedAndMissing(t *testing.T) {
	f := newFixture(t)
	got, ok := f.Show("HEAD", "README.md")
	if !ok || got != "readme\n" {
		t.Fatalf("Show = %q, %v", got, ok)
	}
	if _, ok := f.Show("HEAD", "missing.txt"); ok {
		t.Fatal("Show of a missing path")
	}
	if _, ok := f.Show("--no-such", "README.md"); ok {
		t.Fatal("Show accepted an option-like revision")
	}
}

func TestOperationInProgress(t *testing.T) {
	f := newFixture(t)
	if op := must(f.OperationInProgress()); op != "" {
		t.Fatalf("operation %q in a quiet repository", op)
	}
	f.git(t, "checkout", "-qb", "side")
	f.write(t, "README.md", "side\n")
	f.git(t, "commit", "-qam", "side")
	f.git(t, "checkout", "-q", "-")
	f.write(t, "README.md", "main\n")
	f.git(t, "commit", "-qam", "main")
	cmd := f.gitCmd("merge", "side")
	if cmd.Run() == nil {
		t.Fatal("merge did not conflict")
	}
	equal(t, "merge", must(f.OperationInProgress()), "merge")
	f.git(t, "merge", "--abort")
	for file, op := range map[string]string{"CHERRY_PICK_HEAD": "cherry-pick", "REVERT_HEAD": "revert", "rebase-merge": "rebase", "rebase-apply": "rebase"} {
		dir := strings.TrimSpace(f.git(t, "rev-parse", "--absolute-git-dir"))
		if err := os.Mkdir(filepath.Join(dir, file), 0o755); err != nil {
			t.Fatal(err)
		}
		equal(t, file, must(f.OperationInProgress()), op)
		os.Remove(filepath.Join(dir, file))
	}
}

func TestTrackedUnignoredIgnored(t *testing.T) {
	f := newFixture(t)
	f.write(t, ".gitignore", "build/\n")
	f.write(t, "build/out.txt", "x\n")
	f.write(t, "new file.txt", "x\n")
	f.write(t, "tracked ignored.txt", "x\n")
	f.git(t, "add", "README.md")
	f.git(t, "add", "-f", "build/out.txt")
	sameSet(t, "tracked", must(f.Tracked()), []string{"README.md", "build/out.txt"})
	sameSet(t, "unignored", must(f.Unignored()), []string{"README.md", "build/out.txt", ".gitignore", "new file.txt", "tracked ignored.txt"})
	sameSet(t, "ignored", f.Ignored("build/out.txt", "new file.txt", "build/other.txt"), []string{"build/out.txt", "build/other.txt"})
	if got := f.Ignored(); got != nil {
		t.Fatalf("Ignored() = %q", got)
	}
}

func TestResolveRefusesOptionLikeRevisions(t *testing.T) {
	f := newFixture(t)
	head := f.Head()
	equal(t, "tree", len(must(f.Resolve("HEAD^{tree}"))) >= 40, true)
	equal(t, "head", must(f.Resolve("HEAD")), head)
	for _, rev := range []string{"", "--output=/tmp/x", "-1", "HEAD\x00"} {
		if _, err := f.Resolve(rev); !errors.Is(err, ErrBadRevision) {
			t.Errorf("Resolve(%q) error = %v", rev, err)
		}
		if _, err := f.Tree(rev, nil); !errors.Is(err, ErrBadRevision) {
			t.Errorf("Tree(%q) error = %v", rev, err)
		}
		if _, err := f.Changed(rev, head); !errors.Is(err, ErrBadRevision) {
			t.Errorf("Changed(%q) error = %v", rev, err)
		}
		if _, err := f.DiffAll(head, rev); !errors.Is(err, ErrBadRevision) {
			t.Errorf("DiffAll(%q) error = %v", rev, err)
		}
		if _, err := f.Materialize(rev, t.TempDir()); !errors.Is(err, ErrBadRevision) {
			t.Errorf("Materialize(%q) error = %v", rev, err)
		}
		if _, err := f.TreeEntries(rev); !errors.Is(err, ErrBadRevision) {
			t.Errorf("TreeEntries(%q) error = %v", rev, err)
		}
		if err := f.ReadTree(rev); !errors.Is(err, ErrBadRevision) {
			t.Errorf("ReadTree(%q) error = %v", rev, err)
		}
	}
}

func TestRunnerRefusesRewritingAndSharingCommands(t *testing.T) {
	f := newFixture(t)
	head := f.Head()
	for _, args := range [][]string{
		{"push"}, {"fetch"}, {"pull"}, {"rebase", "HEAD"}, {"merge", "HEAD"}, {"cherry-pick", "HEAD"},
		{"revert", "HEAD"}, {"am"}, {"stash"}, {"switch", "-c", "x"}, {"checkout", "-b", "x"},
		{"reset", "--hard"}, {"commit", "--amend", "-m", "x"}, {"update-ref", "HEAD", "HEAD"},
		{"-c", "user.name=x", "commit", "--allow-empty", "-m", "x"}, {"-C", ".", "push"},
	} {
		if _, err := f.Run(args...); !errors.Is(err, ErrForbidden) {
			t.Errorf("git %v: error = %v", args, err)
		}
		if _, err := f.OK(args...); !errors.Is(err, ErrForbidden) {
			t.Errorf("OK git %v: error = %v", args, err)
		}
	}
	equal(t, "head unchanged", f.Head(), head)
	if _, err := f.OK("log", "-1", "--format=%s"); err != nil {
		t.Fatal(err)
	}
}

func TestRunnerKeepsStderrOutOfParsedOutput(t *testing.T) {
	f := newFixture(t)
	res, err := f.Run("rev-parse", "--verify", "-q", "no-such-ref")
	if err != nil || res.Status == 0 {
		t.Fatalf("Run = %+v, %v", res, err)
	}
	res = must(f.Run("cat-file", "-p", "HEAD:no-such-file"))
	if res.Status == 0 || res.Stdout != "" || res.Stderr == "" {
		t.Fatalf("stdout %q stderr %q status %d", res.Stdout, res.Stderr, res.Status)
	}
	_, err = f.OK("cat-file", "-p", "HEAD:no-such-file")
	var ce *CommandError
	if !errors.As(err, &ce) || ce.Status == 0 || !strings.HasPrefix(ce.Error(), "git cat-file -p HEAD:no-such-file failed (status ") {
		t.Fatalf("error = %v", err)
	}
	// A warning on stderr does not leak into the parsed path list.
	f.write(t, "a.txt", "x\n")
	f.git(t, "add", "a.txt")
	paths := must(f.ChangedPaths())
	equal(t, "paths", strings.Join(paths, ","), "a.txt")
}

func TestChildrenDoNotInheritRepositoryLocation(t *testing.T) {
	f := newFixture(t)
	other := t.TempDir()
	run(t, other, f.Env, "init", "-q")
	env := append(append([]string{}, f.Env...),
		"GIT_DIR="+filepath.Join(other, ".git"), "GIT_WORK_TREE="+other,
		"GIT_INDEX_FILE="+filepath.Join(other, "no-such-index"), "GIT_OBJECT_DIRECTORY="+filepath.Join(other, "objects"))
	r := New(f.Dir, env)
	equal(t, "head", r.Head(), f.Head())
	root, err := Open(f.Dir, env)
	if err != nil || root.Dir != f.Dir {
		t.Fatalf("Open = %v, %v", root, err)
	}
	equal(t, "identity", r.Identity(), "Fixture <fixture@example.invalid>")
	if tree, err := r.Tree("HEAD", nil); err != nil || len(tree) < 40 {
		t.Fatalf("Tree = %q, %v", tree, err)
	}
	clean := CleanEnv(env)
	for _, kv := range clean {
		if strings.HasPrefix(kv, "GIT_DIR=") || strings.HasPrefix(kv, "GIT_INDEX_FILE=") || strings.HasPrefix(kv, "GIT_WORK_TREE=") {
			t.Fatalf("CleanEnv kept %s", kv)
		}
	}
	// Explicitly passed variables reach the child.
	idx := filepath.Join(t.TempDir(), "idx")
	must(r.OKEnv([]string{"GIT_INDEX_FILE=" + idx}, "read-tree", "HEAD"))
	if _, err := os.Stat(idx); err != nil {
		t.Fatalf("explicit GIT_INDEX_FILE ignored: %v", err)
	}
}

func TestReadOnlyObservationLeavesTheRepositoryAlone(t *testing.T) {
	f := newFixture(t)
	marker := filepath.Join(t.TempDir(), "fsmonitor-ran")
	monitor := filepath.Join(t.TempDir(), "fsmonitor")
	if err := os.WriteFile(monitor, []byte("#!/bin/sh\ntouch '"+marker+"'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	f.configure(t, "core.fsmonitor", monitor)
	// A tracked file whose stat data differs from the index makes a normal status refresh it.
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(filepath.Join(f.Dir, "README.md"), old, old); err != nil {
		t.Fatal(err)
	}
	before := must(f.IndexBytes())

	paths := must(f.Observing().ChangedPaths())
	equal(t, "paths", len(paths), 0)
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("read-only status ran the fsmonitor hook")
	}
	if !bytes.Equal(must(f.IndexBytes()), before) {
		t.Fatal("read-only status rewrote the index")
	}
	if !f.Observing().ReadOnly || f.ReadOnly {
		t.Fatal("Observing must copy, not mutate")
	}

	must(f.ChangedPaths()) // the contrast: a normal status does both
	if _, err := os.Stat(marker); err != nil {
		t.Fatal("test is not meaningful: normal status did not run the fsmonitor hook")
	}
	if bytes.Equal(must(f.IndexBytes()), before) {
		t.Fatal("test is not meaningful: normal status did not refresh the index")
	}
}

func TestReadOnlyKeepsExplicitEnvironment(t *testing.T) {
	f := newFixture(t)
	idx := filepath.Join(t.TempDir(), "idx")
	must(f.Observing().OKEnv([]string{"GIT_INDEX_FILE=" + idx}, "read-tree", "HEAD"))
	if _, err := os.Stat(idx); err != nil {
		t.Fatal("explicit GIT_INDEX_FILE dropped in read-only mode")
	}
}

func TestChangedPathsStagedRenameIntoAnIntentFolderReportsBothPaths(t *testing.T) {
	f := newFixture(t)
	f.write(t, "README.md", strings.Repeat("a substantial fixture line\n", 30))
	f.git(t, "commit", "-qam", "longer")
	os.MkdirAll(filepath.Join(f.Dir, ".kogen/intents/staged"), 0o755)
	f.git(t, "mv", "README.md", ".kogen/intents/staged/original-readme.md")
	got := must(f.ChangedPaths())
	sameSet(t, "paths", got, []string{".kogen/intents/staged/original-readme.md", "README.md"})
}

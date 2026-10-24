package git

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestIndexCustodyRestoresWhatTheUserStaged(t *testing.T) {
	f, spec := candidate(t)
	f.write(t, "user-staged.txt", "staged by the user\n")
	f.git(t, "add", "user-staged.txt")
	backup := filepath.Join(t.TempDir(), "index-at-start")
	before := must(f.IndexBytes())
	beforeMode := must(os.Stat(must(f.IndexPath()))).Mode().Perm()
	staged := f.git(t, "diff", "--cached", "--name-only")
	if err := f.SaveIndex(backup); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(must(os.ReadFile(backup)), before) {
		t.Fatal("the custody copy differs from the index")
	}

	// A failing commit leaves the candidate staged ...
	f.hook(t, "pre-commit", "exit 1\n")
	s, _ := f.session()
	if _, err := f.Commit(s, spec); err == nil {
		t.Fatal("commit should fail")
	}
	equal(t, "index replaced by the candidate", bytes.Equal(must(f.IndexBytes()), before), false)
	equal(t, "candidate staged", f.git(t, "diff", "--cached", "--name-only"), "README.md\napp.txt\n")

	// ... and the custody copy puts the user's own staging back.
	if err := f.RestoreIndex(backup); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(must(f.IndexBytes()), before) {
		t.Fatal("the index is not what it was")
	}
	equal(t, "staged", f.git(t, "diff", "--cached", "--name-only"), staged)
	gitDir := must(f.GitDir())
	leftovers := must(filepath.Glob(filepath.Join(gitDir, "index.kogen-restore-*")))
	equal(t, "leftovers", len(leftovers), 0)
	equal(t, "mode", must(os.Stat(filepath.Join(gitDir, "index"))).Mode().Perm(), beforeMode)
}

func TestIndexCustodyErrors(t *testing.T) {
	f := newFixture(t)
	if err := f.RestoreIndex(filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Fatal("restored from a missing custody copy")
	}
	before := must(f.IndexBytes())
	if !bytes.Equal(must(f.IndexBytes()), before) {
		t.Fatal("a failed restore changed the index")
	}
	os.Remove(must(f.IndexPath()))
	if err := f.SaveIndex(filepath.Join(t.TempDir(), "x")); err == nil {
		t.Fatal("saved a missing index")
	}
	path := must(f.IndexPath())
	equal(t, "path", path, filepath.Join(must(f.GitDir()), "index"))
}

func TestReadTreeStagesATree(t *testing.T) {
	f := newFixture(t)
	start := f.Head()
	f.write(t, "a.txt", "a\n")
	tree := must(f.Tree(start, nil))
	if err := f.ReadTree(tree); err != nil {
		t.Fatal(err)
	}
	equal(t, "staged", f.git(t, "diff", "--cached", "--name-only"), "a.txt\n")
	equal(t, "head", f.Head(), start)
}

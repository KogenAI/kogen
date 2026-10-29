package git

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func (f *fixture) chmod(t *testing.T, rel string, mode os.FileMode) {
	t.Helper()
	if err := os.Chmod(filepath.Join(f.Dir, rel), mode); err != nil {
		t.Fatal(err)
	}
}

// cleanInputFixture is the repository of the clean-input scenario: a tracked ignored file,
// a candidate with an edit, a new executable-free file, a symlink and an ignored output.
func cleanInputFixture(t *testing.T) (f *fixture, tree string) {
	f = newFixture(t)
	f.write(t, ".gitignore", "build/\n")
	f.write(t, "app.sh", "printf 'before\\n'\n")
	f.write(t, "build/tracked.txt", "tracked ignored input\n")
	f.git(t, "add", "-f", ".gitignore", "app.sh", "build/tracked.txt")
	f.git(t, "commit", "-qm", "Fixture baseline")
	start := f.Head()
	f.write(t, "app.sh", "printf 'candidate\\n'\n")
	f.chmod(t, "app.sh", 0o755)
	f.write(t, "new.txt", "new candidate\n")
	if err := os.Symlink("new.txt", filepath.Join(f.Dir, "link")); err != nil {
		t.Fatal(err)
	}
	f.write(t, "build/undeclared.sh", "workspace only\n")
	return f, must(f.Tree(start, nil))
}

func assertMutations(t *testing.T, m *Materialized, want ...string) {
	t.Helper()
	got := must(m.Mutations())
	if strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("Mutations = %q, want %q", got, want)
	}
}

func TestMaterializeGivesDeclaredCommandsTheExactCleanInputs(t *testing.T) {
	f, tree := cleanInputFixture(t)
	scratch := filepath.Join(t.TempDir(), "copy")
	m := must(f.Materialize(tree, scratch))
	s := f.At(scratch)

	equal(t, "scratch HEAD tree", strings.TrimSpace(must(s.OK("rev-parse", "HEAD^{tree}"))), tree)
	equal(t, "app.sh", must(s.OK("show", "HEAD:app.sh")), "printf 'candidate\\n'\n")
	equal(t, "link", must(s.OK("show", "HEAD:link")), "new.txt")
	equal(t, "tracked", must(s.OK("ls-files", "--error-unmatch", "new.txt")), "new.txt\n")
	equal(t, "status", must(s.OK("status", "--porcelain")), "")
	if _, err := os.Stat(filepath.Join(scratch, "build/undeclared.sh")); err == nil {
		t.Fatal("ignored workspace output was materialized")
	}
	assertMutations(t, m)

	st := must(os.Lstat(filepath.Join(scratch, "app.sh")))
	equal(t, "app.sh mode", st.Mode().Perm(), os.FileMode(0o755))
	st = must(os.Lstat(filepath.Join(scratch, "new.txt")))
	equal(t, "new.txt mode", st.Mode().Perm(), os.FileMode(0o644))
	equal(t, "link", must(os.Readlink(filepath.Join(scratch, "link"))), "new.txt")

	// The user's repository got nothing from the copy: no hooks, no history.
	if hooks, err := os.ReadDir(filepath.Join(scratch, ".git", "hooks")); err == nil && len(hooks) > 0 {
		t.Fatalf("hooks copied into the verification repository: %v", hooks)
	}
	equal(t, "commits", strings.TrimSpace(must(s.OK("rev-list", "--count", "HEAD"))), "1")
	equal(t, "author", strings.TrimSpace(must(s.OK("log", "-1", "--format=%an <%ae>"))), "Kogen Verification <verification@kogen.invalid>")

	chmod := func(rel string, mode os.FileMode) {
		if err := os.Chmod(filepath.Join(scratch, rel), mode); err != nil {
			t.Fatal(err)
		}
	}
	chmod("app.sh", 0o644)
	assertMutations(t, m, "app.sh")
	chmod("app.sh", 0o755)
	assertMutations(t, m)

	os.Remove(filepath.Join(scratch, "link"))
	os.Symlink("app.sh", filepath.Join(scratch, "link"))
	assertMutations(t, m, "link")
	os.Remove(filepath.Join(scratch, "link"))
	os.Symlink("new.txt", filepath.Join(scratch, "link"))

	os.Remove(filepath.Join(scratch, "new.txt"))
	assertMutations(t, m, "new.txt")
	os.WriteFile(filepath.Join(scratch, "new.txt"), []byte("new candidate\n"), 0o644)
	assertMutations(t, m)

	// An addition is found even when the command staged it.
	os.WriteFile(filepath.Join(scratch, "check-input.txt"), []byte("added by a declared command\n"), 0o644)
	must(s.OK("add", "check-input.txt"))
	assertMutations(t, m, "check-input.txt")
	must(s.OK("rm", "-q", "-f", "check-input.txt"))

	// An ignored generated output is not an input, even force-added.
	os.WriteFile(filepath.Join(scratch, "build/generated.sh"), []byte("declared output\n"), 0o644)
	must(s.OK("add", "-f", "build/generated.sh"))
	assertMutations(t, m)

	// A tracked ignored input always counts.
	os.WriteFile(filepath.Join(scratch, "build/tracked.txt"), []byte("mutated\n"), 0o644)
	assertMutations(t, m, "build/tracked.txt")
}

func TestMaterializedGitlinksKeepTheirExactCommit(t *testing.T) {
	f := newFixture(t)
	dates := []string{"GIT_AUTHOR_DATE=2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE=2026-01-01T00:00:00Z"}
	dependency := func(dir string) {
		os.MkdirAll(dir, 0o755)
		env := append(append([]string{}, f.Env...), dates...)
		run(t, dir, f.Env, "init", "-q", "--template=")
		for k, v := range map[string]string{"user.name": "Fixture", "user.email": "fixture@example.invalid", "commit.gpgsign": "false", "core.hooksPath": f.Hooks} {
			run(t, dir, f.Env, "config", k, v)
		}
		os.WriteFile(filepath.Join(dir, "app.txt"), []byte("candidate dependency\n"), 0o644)
		os.WriteFile(filepath.Join(dir, ".gitignore"), []byte("cache/\n"), 0o644)
		run(t, dir, f.Env, "add", ".")
		run(t, dir, env, "commit", "-qm", "Candidate dependency")
	}
	dependency(filepath.Join(f.Dir, "module"))
	expected := f.At(filepath.Join(f.Dir, "module")).Head()
	f.write(t, ".gitignore", "module/cache/\n")
	f.git(t, "add", ".")
	f.git(t, "commit", "-qm", "Fixture")
	tree := must(f.Tree(f.Head(), nil))
	scratch := filepath.Join(t.TempDir(), "copy")
	m := must(f.Materialize(tree, scratch))
	equal(t, "gitlink pinned", m.Gitlinks["module"], expected)
	module := filepath.Join(scratch, "module")
	assertMutations(t, m)

	os.WriteFile(filepath.Join(module, "untracked.txt"), []byte("added input\n"), 0o644)
	assertMutations(t, m, "module/untracked.txt")
	os.Remove(filepath.Join(module, "untracked.txt"))

	os.MkdirAll(filepath.Join(module, "cache"), 0o755)
	os.WriteFile(filepath.Join(module, "cache/generated.txt"), []byte("declared output\n"), 0o644)
	assertMutations(t, m)

	dependency(module) // the same commit again
	equal(t, "rebuilt dependency", f.At(module).Head(), expected)
	assertMutations(t, m)
	run(t, module, f.Env, "add", "-f", "cache/generated.txt")
	assertMutations(t, m)

	os.WriteFile(filepath.Join(module, "untracked.txt"), []byte("added input\n"), 0o644)
	run(t, module, f.Env, "add", "untracked.txt")
	assertMutations(t, m, "module")
	run(t, module, f.Env, "rm", "-q", "-f", "untracked.txt")

	os.WriteFile(filepath.Join(module, "app.txt"), []byte("different dependency\n"), 0o644)
	assertMutations(t, m, "module")
	run(t, module, f.Env, "add", "app.txt")
	run(t, module, f.Env, "commit", "-qm", "Different dependency")
	if f.At(module).Head() == expected {
		t.Fatal("fixture commit did not move the dependency")
	}
	assertMutations(t, m, "module")
}

func TestTreeIsBuiltInAPrivateIndexAndExcludesOtherIntents(t *testing.T) {
	f := newFixture(t)
	start := f.Head()
	f.write(t, ".kogen/intents/mine/INTENT.md", "mine\n")
	f.write(t, ".kogen/intents/other/INTENT.md", "other\n")
	f.write(t, ".kogen/intents/other/new sibling.feature", "new sibling\n")
	f.write(t, "src/app.go", "package app\n")
	f.write(t, "staged.txt", "staged before the Build\n")
	f.git(t, "add", "staged.txt")
	if err := os.Remove(filepath.Join(f.Dir, "staged.txt")); err != nil {
		t.Fatal(err)
	}
	indexBefore := must(f.IndexBytes())

	tree := must(f.Tree(start, []string{".kogen/intents/other"}))

	listed := must(f.OK("ls-tree", "-r", "--name-only", "-z", tree))
	sameSet(t, "tree", splitNUL(listed), []string{"README.md", ".kogen/intents/mine/INTENT.md", "src/app.go"})
	if !bytes.Equal(must(f.IndexBytes()), indexBefore) {
		t.Fatal("the user's index changed")
	}
	// The tree equals what the plain tracked-plus-unignored listing says, minus exclusions.
	equal(t, "start unchanged", f.Head(), start)
	entries := must(f.TreeEntries(tree))
	equal(t, "entries", len(entries), 3)
	changed := must(f.Changed(start, tree))
	sameSet(t, "changed", changed, []string{".kogen/intents/mine/INTENT.md", "src/app.go"})
}

func TestTreeOfACleanCheckoutIsHeadsTree(t *testing.T) {
	f := newFixture(t)
	equal(t, "tree", must(f.Tree(f.Head(), nil)), must(f.Resolve("HEAD^{tree}")))
}

func TestChangedAndDiff(t *testing.T) {
	f := newFixture(t)
	start := f.Head()
	f.write(t, "a b.txt", "one\n")
	f.write(t, "README.md", "readme\nmore\n")
	f.git(t, "mv", "README.md", "RENAMED.md")
	tree := must(f.Tree(start, nil))
	sameSet(t, "no rename detection", must(f.Changed(start, tree)), []string{"README.md", "RENAMED.md", "a b.txt"})
	equal(t, "same", len(must(f.Changed(tree, tree))), 0)

	all := must(f.DiffAll(start, tree))
	for _, want := range []string{"diff --git a/a b.txt b/a b.txt", "+one", "diff --git a/README.md b/README.md"} {
		if !strings.Contains(all, want) {
			t.Fatalf("diff lacks %q:\n%s", want, all)
		}
	}
	one := must(f.Diff(start, tree, []string{"a b.txt"}))
	if !strings.Contains(one, "+one") || strings.Contains(one, "README") {
		t.Fatalf("literal diff:\n%s", one)
	}
	equal(t, "no paths", must(f.Diff(start, tree, nil)), "")
	// Pathspec magic in a name is taken literally.
	equal(t, "magic", must(f.Diff(start, tree, []string{"*.txt"})), "")
}

func TestMaterializeRefusesUnsafeTargets(t *testing.T) {
	dir := t.TempDir()
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(dir, "evil")); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(dir, "file"), []byte("x"), 0o644)
	for _, p := range []string{"../escape", "a/../../escape", "/abs", "", "a//b", "./a", ".git/config", "x/.GIT/hooks/post-commit", "evil/file", "file/inside"} {
		if got, err := safeTarget(dir, p); err == nil {
			t.Errorf("safeTarget(%q) = %q, want a refusal", p, got)
		}
	}
	if _, err := os.Stat(filepath.Join(outside, "file")); err == nil {
		t.Fatal("wrote through a symlink")
	}
	got, err := safeTarget(dir, "deep/er/file.txt")
	if err != nil || got != filepath.Join(dir, "deep/er/file.txt") {
		t.Fatalf("safeTarget = %q, %v", got, err)
	}
	if st, err := os.Stat(filepath.Join(dir, "deep/er")); err != nil || !st.IsDir() {
		t.Fatal("folders above the target were not created")
	}
}

func TestMaterializeKeepsFilesWithOddNamesAndEmptyTrees(t *testing.T) {
	f := newFixture(t)
	f.write(t, "new\nline.txt", "newline in the name\n")
	f.write(t, "dir with space/ünï.txt", "unicode\n")
	f.write(t, "big.bin", strings.Repeat("0123456789abcdef", 100000))
	tree := must(f.Tree(f.Head(), nil))
	scratch := filepath.Join(t.TempDir(), "x")
	m := must(f.Materialize(tree, scratch))
	assertMutations(t, m)
	for _, p := range []string{"new\nline.txt", "dir with space/ünï.txt", "big.bin"} {
		want := must(os.ReadFile(filepath.Join(f.Dir, p)))
		got := must(os.ReadFile(filepath.Join(scratch, p)))
		if !bytes.Equal(got, want) {
			t.Errorf("%q differs", p)
		}
	}
	equal(t, "clean", must(f.At(scratch).OK("status", "--porcelain")), "")

	empty := must(f.OK("hash-object", "-t", "tree", "--stdin"))
	m2 := must(f.Materialize(strings.TrimSpace(empty), filepath.Join(t.TempDir(), "empty")))
	equal(t, "empty paths", len(m2.Paths), 0)
	assertMutations(t, m2)
}

func TestMaterializeIntoARelativeDirectoryAndMissingTree(t *testing.T) {
	f := newFixture(t)
	tree := must(f.Tree(f.Head(), nil))
	wd, _ := os.Getwd()
	base := t.TempDir()
	if err := os.Chdir(base); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(wd)
	m := must(f.Materialize(tree, "rel/copy"))
	equal(t, "dir", must(filepath.EvalSymlinks(m.Dir)), must(filepath.EvalSymlinks(filepath.Join(base, "rel/copy"))))
	if !filepath.IsAbs(m.Dir) {
		t.Fatalf("Dir %q is not absolute", m.Dir)
	}
	assertMutations(t, m)
	equal(t, "file", string(must(os.ReadFile("rel/copy/README.md"))), "readme\n")
	if _, err := f.Materialize(strings.Repeat("0", 40), filepath.Join(base, "none")); err == nil {
		t.Fatal("materialized a tree that does not exist")
	}
}

func TestRestoreTreePutsBackExactlyTheDifferingPaths(t *testing.T) {
	f := newFixture(t)
	f.write(t, ".gitignore", "*.log\n")
	f.write(t, "keep.txt", "kept\n")
	f.write(t, "dir/gone.txt", "gone\n")
	f.write(t, "run.sh", "#!/bin/sh\n")
	f.chmod(t, "run.sh", 0o755)
	f.write(t, "swap", "was a file\n")
	if err := os.Symlink("keep.txt", filepath.Join(f.Dir, "link")); err != nil {
		t.Fatal(err)
	}
	f.git(t, "add", ".")
	f.git(t, "commit", "-qm", "candidate")
	green := must(f.Resolve("HEAD^{tree}"))

	// Uncommitted edits: a modification, a mode change, a deletion that leaves a folder empty,
	// a file replaced by a folder, a retargeted symlink, additions in new folders, an ignored file.
	f.write(t, "README.md", "edited\n")
	f.chmod(t, "run.sh", 0o644)
	os.Remove(filepath.Join(f.Dir, "dir/gone.txt"))
	os.Remove(filepath.Join(f.Dir, "swap"))
	f.write(t, "swap/inside.txt", "now a folder\n")
	os.Remove(filepath.Join(f.Dir, "link"))
	if err := os.Symlink("elsewhere", filepath.Join(f.Dir, "link")); err != nil {
		t.Fatal(err)
	}
	f.write(t, "new/deep/added.txt", "added\n")
	f.write(t, "build.log", "ignored output\n")
	current := must(f.Tree(f.Head(), nil))
	if current == green {
		t.Fatal("the edits changed nothing")
	}
	head, index := f.Head(), must(f.IndexBytes())

	got := must(f.RestoreTree(current, green))
	changes := map[string]string{}
	for _, r := range got {
		changes[r.Path] = r.Change
	}
	want := map[string]string{
		"README.md": "modified", "run.sh": "modified", "dir/gone.txt": "deleted", "swap": "deleted", "swap/inside.txt": "added",
		"link": "modified", "new/deep/added.txt": "added",
	}
	if len(changes) != len(want) {
		t.Fatalf("restored %v, want %v", changes, want)
	}
	for path, change := range want {
		equal(t, "change of "+path, changes[path], change)
	}
	equal(t, "tree", must(f.Tree(f.Head(), nil)), green)
	equal(t, "README", f.read(t, "README.md"), "readme\n")
	equal(t, "swap", f.read(t, "swap"), "was a file\n")
	equal(t, "deleted file", f.read(t, "dir/gone.txt"), "gone\n")
	if st, err := os.Stat(filepath.Join(f.Dir, "run.sh")); err != nil || st.Mode().Perm()&0o111 == 0 {
		t.Fatalf("run.sh mode %v %v", st, err)
	}
	if target, err := os.Readlink(filepath.Join(f.Dir, "link")); err != nil || target != "keep.txt" {
		t.Fatalf("link %q %v", target, err)
	}
	if _, err := os.Stat(filepath.Join(f.Dir, "new")); !os.IsNotExist(err) {
		t.Fatalf("the folders of the added file stayed: %v", err)
	}
	equal(t, "ignored output", f.read(t, "build.log"), "ignored output\n")
	equal(t, "HEAD", f.Head(), head)
	if !bytes.Equal(must(f.IndexBytes()), index) {
		t.Fatal("the index changed")
	}
	// Nothing differs any more: a second restore is a no-op.
	equal(t, "second restore", len(must(f.RestoreTree(green, green))), 0)
}

func TestRestoreTreeRefusesAGitlinkAndUnsafePaths(t *testing.T) {
	f := newFixture(t)
	green := must(f.Resolve("HEAD^{tree}"))
	f.git(t, "update-index", "--add", "--cacheinfo", "160000,"+f.Head()+",sub")
	withLink := strings.TrimSpace(f.git(t, "write-tree"))
	if _, err := f.RestoreTree(withLink, green); err == nil || !strings.Contains(err.Error(), "gitlink") {
		t.Fatalf("gitlink: %v", err)
	}
	if _, err := f.RestoreTree("", green); err == nil {
		t.Fatal("an empty revision was accepted")
	}
}

func (f *fixture) read(t *testing.T, rel string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(f.Dir, rel))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

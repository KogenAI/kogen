package git

import (
	"bytes"
	"crypto/sha1"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
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

// touch rewrites a tracked file with its own bytes and a later mtime, then lets `git status`
// refresh the index's stat cache.
func (f *fixture) touch(t *testing.T, rel string) {
	t.Helper()
	path := filepath.Join(f.Dir, rel)
	data := must(os.ReadFile(path))
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	later := time.Now().Add(3 * time.Second)
	if err := os.Chtimes(path, later, later); err != nil {
		t.Fatal(err)
	}
	f.git(t, "status", "--porcelain")
}

func TestAStatCacheRefreshKeepsTheStagingEquivalent(t *testing.T) {
	for _, format := range []string{"sha1", "sha256"} {
		t.Run(format, func(t *testing.T) {
			f := newFixture(t)
			if format == "sha256" {
				root := t.TempDir()
				run(t, root, f.Env, "init", "-q", "--object-format=sha256")
				f = &fixture{Repo: New(root, f.Env), Hooks: f.Hooks, Env: f.Env}
				f.write(t, "README.md", "readme\n")
				f.git(t, "add", ".")
			}
			f.write(t, "other.txt", "other\n")
			f.git(t, "add", "other.txt")
			// Version 3 with extended flags, kept on both sides.
			f.git(t, "update-index", "--skip-worktree", "other.txt")
			equal(t, "object format", must(f.ObjectFormat()), format)
			before := must(f.IndexBytes())
			f.touch(t, "README.md")
			after := must(f.IndexBytes())
			if bytes.Equal(before, after) {
				t.Fatal("status did not refresh the index")
			}
			equal(t, "version", before[7], byte(3))
			equal(t, "equivalent", StagedEquivalent(before, after, format), true)
			equal(t, "other format", StagedEquivalent(before, after, map[string]string{"sha1": "sha256", "sha256": "sha1"}[format]), false)
		})
	}
}

func TestStagingDifferencesAndUnsupportedFormsAreNotEquivalent(t *testing.T) {
	f := newFixture(t)
	f.write(t, "other.txt", "other\n")
	f.git(t, "add", "other.txt")
	f.git(t, "write-tree") // a complete cache-tree extension
	base := must(f.IndexBytes())
	reset := func() {
		f.write(t, "other.txt", "other\n")
		if err := os.WriteFile(must(f.IndexPath()), base, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	mutate := map[string]func(){
		"content":         func() { f.write(t, "other.txt", "changed\n"); f.git(t, "add", "other.txt") },
		"removed path":    func() { f.git(t, "rm", "-q", "--cached", "other.txt") },
		"mode":            func() { f.git(t, "update-index", "--chmod=+x", "other.txt") },
		"assume-valid":    func() { f.git(t, "update-index", "--assume-unchanged", "other.txt") },
		"skip-worktree":   func() { f.git(t, "update-index", "--skip-worktree", "other.txt") },
		"intent-to-add":   func() { f.write(t, "new.txt", "n\n"); f.git(t, "add", "-N", "new.txt") },
		"version 4":       func() { f.git(t, "update-index", "--index-version", "4") },
		"split index":     func() { f.git(t, "update-index", "--split-index") },
		"untracked cache": func() { f.git(t, "update-index", "--untracked-cache"); f.git(t, "status", "--porcelain") },
		// The entries return to their saved staging, but Git's cache-tree extension was
		// invalidated: still not equivalent (fail closed).
		"restaged identically": func() {
			f.git(t, "update-index", "--chmod=+x", "other.txt")
			f.git(t, "update-index", "--chmod=-x", "other.txt")
		},
	}
	for name, change := range mutate {
		t.Run(name, func(t *testing.T) {
			reset()
			change()
			after := must(f.IndexBytes())
			if bytes.Equal(base, after) {
				t.Fatal("no change reached the index")
			}
			equal(t, "equivalent", StagedEquivalent(base, after, "sha1"), false)
		})
	}
	reset()
	// Damaged, truncated or forged bytes fail closed, even with unchanged staging.
	damaged := bytes.Clone(base)
	damaged[len(damaged)-1] ^= 1
	equal(t, "damaged checksum", StagedEquivalent(base, damaged, "sha1"), false)
	equal(t, "truncated", StagedEquivalent(base, base[:len(base)-5], "sha1"), false)
	equal(t, "empty", StagedEquivalent(base, nil, "sha1"), false)
	equal(t, "identical bytes", StagedEquivalent(damaged, damaged, "sha1"), true)
	// A stat-only change with a recomputed checksum is equivalent; the same change to the name
	// length is not.
	forge := func(edit func(b []byte)) []byte {
		b := bytes.Clone(base[:len(base)-20])
		edit(b)
		s := sha1.Sum(b)
		return append(b, s[:]...)
	}
	equal(t, "forged stat", StagedEquivalent(base, forge(func(b []byte) { b[12+8] ^= 0xff; b[12+36] ^= 1 }), "sha1"), true)
	equal(t, "forged mode", StagedEquivalent(base, forge(func(b []byte) { b[12+27] ^= 1 }), "sha1"), false)
	equal(t, "forged name length", StagedEquivalent(base, forge(func(b []byte) { b[12+61] ^= 1 }), "sha1"), false)
	// Git's skipHash writes a zero checksum: unsupported, so only identical bytes match.
	zero := append(bytes.Clone(base[:len(base)-20]), make([]byte, 20)...)
	equal(t, "zero checksum", StagedEquivalent(zero, forge(func(b []byte) { b[12+8] ^= 0xff }), "sha1"), false)
	zeroStat := append(bytes.Clone(zero[:len(zero)-20]), make([]byte, 20)...)
	zeroStat[12+8] ^= 0xff
	equal(t, "zero checksums on both sides", StagedEquivalent(zero, zeroStat, "sha1"), false)
}

func TestALongPathAndASha256IndexKeepTheirStagingExact(t *testing.T) {
	f := newFixture(t)
	// A 5001-byte name (flags hold 0xFFF), staged without a working-tree file; it sorts first.
	long := "A" + strings.Repeat("x", 5000)
	oid := strings.TrimSpace(f.git(t, "rev-parse", "HEAD:README.md"))
	f.git(t, "update-index", "--add", "--cacheinfo", "100644,"+oid+","+long)
	base := must(f.IndexBytes())
	equal(t, "first entry is the long name", string(base[12+62:12+62+len(long)]), long)
	forge := func(edit func(b []byte)) []byte {
		b := bytes.Clone(base[:len(base)-20])
		edit(b)
		s := sha1.Sum(b)
		return append(b, s[:]...)
	}
	// Stat bytes of the long entry and of the entry after it (whose offset depends on the long
	// name's padding).
	next := 12 + (62+len(long)+8)&^7
	equal(t, "next entry is README.md", string(base[next+62:next+62+9]), "README.md")
	equal(t, "long path stat", StagedEquivalent(base, forge(func(b []byte) { b[12+8] ^= 1; b[next+8] ^= 1 }), "sha1"), true)
	equal(t, "long path mode", StagedEquivalent(base, forge(func(b []byte) { b[12+27] ^= 1 }), "sha1"), false)
	equal(t, "next entry mode", StagedEquivalent(base, forge(func(b []byte) { b[next+27] ^= 1 }), "sha1"), false)

	root := t.TempDir()
	run(t, root, f.Env, "init", "-q", "--object-format=sha256")
	g := &fixture{Repo: New(root, f.Env), Hooks: f.Hooks, Env: f.Env}
	g.write(t, "README.md", "readme\n")
	g.git(t, "add", ".")
	before := must(g.IndexBytes())
	g.write(t, "README.md", "changed\n")
	g.git(t, "add", ".")
	equal(t, "sha256 content", StagedEquivalent(before, must(g.IndexBytes()), "sha256"), false)
}

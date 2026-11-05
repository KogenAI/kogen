package tools

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func linkParentRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "dest", "child"), 0755); err != nil {
		t.Fatal(err)
	}
	return root
}

func linkParentWrite(t *testing.T, tool *Tools, path string) Classified {
	t.Helper()
	got, err := tool.RunClassified(context.Background(), WriteFileTool, map[string]any{"path": path, "content": "written"})
	if err != nil {
		t.Fatal(err)
	}
	return got
}

func exists(p string) bool { _, err := os.Lstat(p); return err == nil }

func TestWriteFollowsLinkBeforeParent(t *testing.T) {
	root := linkParentRoot(t)
	out := linkParentRoot(t)
	for name, target := range map[string]string{"rel": "dest/child", "abs": filepath.Join(out, "dest", "child")} {
		t.Run(name, func(t *testing.T) {
			if err := os.Symlink(target, filepath.Join(root, "link")); err != nil {
				t.Fatal(err)
			}
			defer os.Remove(filepath.Join(root, "link"))
			tool := newTools(root, WriteFileTool, ReadFileTool)
			if got := linkParentWrite(t, tool, "link/../note.txt"); got.Text != "ok" {
				t.Fatalf("%+v", got)
			}
			beside := filepath.Join(root, filepath.Dir(target), "note.txt")
			if filepath.IsAbs(target) {
				beside = filepath.Join(filepath.Dir(target), "note.txt")
			}
			if data, err := os.ReadFile(beside); err != nil || string(data) != "written" {
				t.Fatalf("%q %v", data, err)
			}
			if exists(filepath.Join(root, "note.txt")) {
				t.Fatal("wrote the lexical location")
			}
		})
	}
	tool := newTools(root, WriteFileTool, ReadFileTool)
	if err := os.Symlink("dest/child", filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	got, err := tool.RunClassified(context.Background(), ReadFileTool, map[string]any{"path": "link/../note.txt"})
	if err != nil || got.Text != "1\twritten" {
		t.Fatalf("read %+v %v", got, err)
	}
}

func TestWriteWithoutLinkBeforeParentIsCleaned(t *testing.T) {
	for path, want := range map[string]string{"a/../b.txt": "b.txt", "./sub/../b.txt": "b.txt", "a/../new/b.txt": "new/b.txt"} {
		root := linkParentRoot(t)
		if err := os.Mkdir(filepath.Join(root, "sub"), 0755); err != nil {
			t.Fatal(err)
		}
		if got := linkParentWrite(t, newTools(root, WriteFileTool), path); got.Text != "ok" {
			t.Fatalf("%s: %+v", path, got)
		}
		if !exists(filepath.Join(root, want)) || exists(filepath.Join(root, "a")) || exists(filepath.Join(root, "sub", "b.txt")) {
			t.Fatalf("%s: wrong layout", path)
		}
	}
}

func TestWriteLinkBeforeParentProtection(t *testing.T) {
	const msg = "refused: dest/note.txt is part of the approved acceptance baseline"
	root := linkParentRoot(t)
	if err := os.Symlink("dest/child", filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "dest", "note.txt"), []byte("keep"), 0644); err != nil {
		t.Fatal(err)
	}
	tool := newTools(root, WriteFileTool)
	tool.Protected = []string{"dest/note.txt"}
	if got := linkParentWrite(t, tool, "link/../note.txt"); got.Text != msg || got.ErrorKind != "protected" {
		t.Fatalf("%+v", got)
	}
	if data, _ := os.ReadFile(filepath.Join(root, "dest", "note.txt")); string(data) != "keep" {
		t.Fatalf("changed: %q", data)
	}
	// A protected lexical form alone does not refuse a write that resolves elsewhere.
	if err := os.WriteFile(filepath.Join(root, "note.txt"), []byte("keep"), 0644); err != nil {
		t.Fatal(err)
	}
	tool.Protected = []string{"note.txt"}
	if got := linkParentWrite(t, tool, "link/../note.txt"); got.Text != "ok" {
		t.Fatalf("%+v", got)
	}
	if data, _ := os.ReadFile(filepath.Join(root, "note.txt")); string(data) != "keep" {
		t.Fatalf("changed: %q", data)
	}
	// Without a link before "..", the cleaned protected form keeps its refusal.
	tool.Protected = []string{"b.txt"}
	if got := linkParentWrite(t, tool, "a/../b.txt"); got.Text != "refused: b.txt is part of the approved acceptance baseline" || exists(filepath.Join(root, "a")) {
		t.Fatalf("%+v", got)
	}
}

func TestWriteUnresolvableLinkBeforeParent(t *testing.T) {
	for name, c := range map[string]struct{ target, want string }{
		"loop": {"loop", "eloop"},
		"gone": {"missing/dir", "enoent"},
		"file": {"file.txt", "enotdir"},
	} {
		t.Run(name, func(t *testing.T) {
			root := linkParentRoot(t)
			if err := os.WriteFile(filepath.Join(root, "file.txt"), nil, 0644); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(c.target, filepath.Join(root, name)); err != nil {
				t.Fatal(err)
			}
			tool := newTools(root, WriteFileTool)
			path := name + "/../note.txt"
			got := linkParentWrite(t, tool, path)
			if got.Text != "error: "+path+": "+c.want || got.ErrorKind != "file_error" {
				t.Fatalf("%+v", got)
			}
			if exists(filepath.Join(root, "note.txt")) || exists(filepath.Join(root, "missing")) {
				t.Fatal("created something")
			}
			if fp := tool.footprint(WriteFileTool, map[string]any{"path": path, "content": "x"}); !fp.Barrier {
				t.Fatalf("not a barrier: %+v", fp)
			}
		})
	}
}

func TestWriteFootprintFollowsLinkBeforeParent(t *testing.T) {
	root := linkParentRoot(t)
	if err := os.Symlink("dest/child", filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	tool := newTools(root, WriteFileTool)
	fp := tool.footprint(WriteFileTool, map[string]any{"path": "link/../note.txt", "content": "x"})
	if fp.Barrier || len(fp.Writes) != 1 || fp.Writes[0] != filepath.Join(root, "dest", "note.txt") {
		t.Fatalf("%+v", fp)
	}
}

func TestWriteLinkBeforeParentThroughOtherLinks(t *testing.T) {
	// The link's relative target steps up from where its folder really is: l2 -> dest/deep,
	// dest/deep/link -> ../other, so l2/link/../n.txt is dest/n.txt, as the shell writes it.
	root := linkParentRoot(t)
	for _, d := range []string{"dest/deep", "dest/other"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink("dest/deep", filepath.Join(root, "l2")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../other", filepath.Join(root, "dest", "deep", "link")); err != nil {
		t.Fatal(err)
	}
	if got := linkParentWrite(t, newTools(root, WriteFileTool), "l2/link/../n.txt"); got.Text != "ok" {
		t.Fatalf("%+v", got)
	}
	if !exists(filepath.Join(root, "dest", "n.txt")) {
		t.Fatal("dest/n.txt not written")
	}

	// A Root reached through a link still compares the root-relative form: dest/x is a
	// protected link reached through link/.. and is refused, not followed to elsewhere.txt.
	alias := filepath.Join(t.TempDir(), "alias")
	if err := os.Symlink(root, alias); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../elsewhere.txt", filepath.Join(root, "dest", "x")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("dest/child", filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	tool := newTools(alias, WriteFileTool)
	tool.Protected = []string{"dest/x"}
	if got := linkParentWrite(t, tool, "link/../x"); got.Text != "refused: dest/x is part of the approved acceptance baseline" {
		t.Fatalf("%+v", got)
	}
	if exists(filepath.Join(root, "elsewhere.txt")) {
		t.Fatal("wrote through the protected link")
	}
}

package tools

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestProtectedWriteDestinations(t *testing.T) {
	for _, name := range []string{"direct", "link", "chain", "directory", "dangling", "unprotected"} {
		t.Run(name, func(t *testing.T) {
			root, err := filepath.EvalSymlinks(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			if err := os.Mkdir(filepath.Join(root, "checks"), 0755); err != nil {
				t.Fatal(err)
			}
			target := "checks/accept.txt"
			if name == "unprotected" {
				target = "checks/free.txt"
			}
			if name != "dangling" {
				if err := os.WriteFile(filepath.Join(root, target), []byte("keep"), 0640); err != nil {
					t.Fatal(err)
				}
			}
			path := target
			links := map[string]string{}
			switch name {
			case "link", "dangling", "unprotected":
				links["shortcut"] = target
				path = "shortcut"
			case "chain":
				links["shortcut"] = "second"
				links["second"] = target
				path = "shortcut"
			case "directory":
				links["alias"] = "checks"
				path = "alias/accept.txt"
			}
			for p, v := range links {
				if err := os.Symlink(v, filepath.Join(root, p)); err != nil {
					t.Fatal(err)
				}
			}
			tool := newTools(root, WriteFileTool)
			tool.Protected = []string{"checks/accept.txt"}
			got, err := tool.RunClassified(context.Background(), WriteFileTool, map[string]any{"path": path, "content": "replace"})
			if err != nil {
				t.Fatal(err)
			}
			if name == "unprotected" {
				if got.Text != "ok" || got.ErrorKind != "" {
					t.Fatalf("%+v", got)
				}
			} else if got.Text != "refused: checks/accept.txt is part of the approved acceptance baseline" || got.ErrorKind != "protected" {
				t.Fatalf("%+v", got)
			}
			data, err := os.ReadFile(filepath.Join(root, target))
			if name == "dangling" {
				if !os.IsNotExist(err) {
					t.Fatalf("missing target: %v", err)
				}
			} else {
				want := "keep"
				if name == "unprotected" {
					want = "replace"
				}
				if err != nil || string(data) != want {
					t.Fatalf("content %q: %v", data, err)
				}
				st, err := os.Stat(filepath.Join(root, target))
				if err != nil || st.Mode().Perm() != 0640 {
					t.Fatalf("mode: %v %v", st, err)
				}
			}
			for p, v := range links {
				got, err := os.Readlink(filepath.Join(root, p))
				if err != nil || got != v {
					t.Fatalf("link %s: %q %v", p, got, err)
				}
			}
		})
	}
}

func TestProtectedWriteMissingDestinationDoesNotCreateDirectories(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("missing/deep/file", filepath.Join(root, "shortcut")); err != nil {
		t.Fatal(err)
	}
	tool := newTools(root, WriteFileTool)
	tool.Protected = []string{"missing/deep/file"}
	got, err := tool.RunClassified(context.Background(), WriteFileTool, map[string]any{"path": "shortcut", "content": "replace"})
	if err != nil || got.ErrorKind != "protected" || got.Text != "refused: missing/deep/file is part of the approved acceptance baseline" {
		t.Fatalf("%+v %v", got, err)
	}
	if _, err := os.Stat(filepath.Join(root, "missing")); !os.IsNotExist(err) {
		t.Fatalf("directory created: %v", err)
	}
	if link, err := os.Readlink(filepath.Join(root, "shortcut")); err != nil || link != "missing/deep/file" {
		t.Fatalf("link: %q %v", link, err)
	}
}

func TestProtectedWriteWithSymlinkRoot(t *testing.T) {
	parent, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(parent, "root")
	if err := os.Mkdir(root, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "protected"), []byte("keep"), 0640); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(root, filepath.Join(parent, "root-link")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("protected", filepath.Join(root, "shortcut")); err != nil {
		t.Fatal(err)
	}
	tool := newTools(filepath.Join(parent, "root-link"), WriteFileTool)
	tool.Protected = []string{"protected"}
	got, err := tool.RunClassified(context.Background(), WriteFileTool, map[string]any{"path": "shortcut", "content": "replace"})
	if err != nil || got.ErrorKind != "protected" || got.Text != "refused: protected is part of the approved acceptance baseline" {
		t.Fatalf("%+v %v", got, err)
	}
	data, err := os.ReadFile(filepath.Join(root, "protected"))
	if err != nil || string(data) != "keep" {
		t.Fatalf("%q %v", data, err)
	}
}

func TestProtectedWriteCreatesMissingRoot(t *testing.T) {
	root := filepath.Join(t.TempDir(), "new-root")
	tool := newTools(root, WriteFileTool)
	tool.Protected = []string{"protected"}
	got, err := tool.RunClassified(context.Background(), WriteFileTool, map[string]any{"path": "nested/file", "content": "replace"})
	if err != nil || got.Text != "ok" {
		t.Fatalf("%+v %v", got, err)
	}
	data, err := os.ReadFile(filepath.Join(root, "nested/file"))
	if err != nil || string(data) != "replace" {
		t.Fatalf("%q %v", data, err)
	}
}

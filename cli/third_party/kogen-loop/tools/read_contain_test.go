package tools

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// readContainWorld is a root next to outside files: a fixture home with a credential-like
// file, an outside folder and a decoy of the same name inside the root.
type readContainWorld struct {
	base, root, home, outside string
}

const (
	homeSecret    = "HOME-SECRET-PAYLOAD"
	outsideSecret = "OUTSIDE-SECRET-PAYLOAD"
	insideDecoy   = "INSIDE-DECOY"
)

func newReadContainWorld(t *testing.T) readContainWorld {
	t.Helper()
	base, root := newRepo(t)
	w := readContainWorld{base: base, root: root, home: filepath.Join(base, "home"), outside: filepath.Join(base, "outside")}
	t.Setenv("HOME", w.home)
	write(t, w.home, "x", homeSecret+"\n")
	write(t, w.home, ".kogen/credentials/chatgpt.json", `{"token":"`+homeSecret+`"}`)
	write(t, w.outside, "secret.txt", outsideSecret+"\n")
	write(t, w.outside, "sub/deep.txt", outsideSecret+"\n")
	write(t, root, "secret.txt", insideDecoy+"\n")
	write(t, root, "a/b.txt", "bee\n")
	return w
}

func link(t *testing.T, target, name string) {
	t.Helper()
	if err := os.Symlink(target, name); err != nil {
		t.Fatal(err)
	}
}

// wantRefused asserts a tool result is a containment or home refusal that carries no
// fixture payload.
func wantRefused(t *testing.T, got string, wantReason containError) {
	t.Helper()
	if !strings.HasPrefix(got, "error: ") || !strings.Contains(got, string(wantReason)) {
		t.Errorf("not refused as %q: %q", wantReason, got)
	}
	for _, payload := range []string{homeSecret, outsideSecret, insideDecoy} {
		if strings.Contains(got, payload) {
			t.Errorf("payload %s returned: %q", payload, got)
		}
	}
}

func TestReadContainFaults(t *testing.T) {
	w := newReadContainWorld(t)
	tools := newTools(w.root, ReadFileTool)
	for _, c := range []struct {
		name, path string
		reason     containError
	}{
		{"home file", "~/x", errHome},
		{"home credentials", "~/.kogen/credentials/chatgpt.json", errHome},
		{"home itself", "~", errHome},
		{"absolute home file", filepath.Join(w.home, "x"), errOutside},
		{"absolute outside", filepath.Join(w.outside, "secret.txt"), errOutside},
		{"absolute outside folder", w.outside, errOutside},
		{"parent escape", "../outside/secret.txt", errOutside},
		{"parent escape to home", "../home/x", errOutside},
		{"parent of root", "..", errOutside},
		{"escape after descending", "a/../../outside/secret.txt", errOutside},
		{"absolute with parent", w.root + "/../outside/secret.txt", errOutside},
		{"absolute missing outside", filepath.Join(w.outside, "missing"), errOutside},
		{"double slash root", "//etc/passwd", errOutside},
	} {
		t.Run(c.name, func(t *testing.T) {
			wantRefused(t, run(t, tools, ReadFileTool, map[string]any{"path": c.path}), c.reason)
		})
	}
	// A refused read is a tool result, never a Go error.
	if _, err := tools.Run(ReadFileTool, map[string]any{"path": "~/x"}); err != nil {
		t.Errorf("Go error: %v", err)
	}
}

func TestReadContainSymlinkEscapes(t *testing.T) {
	w := newReadContainWorld(t)
	write(t, w.root, "ok.txt", "ok\n")
	link(t, "../outside/secret.txt", filepath.Join(w.root, "leaf-rel"))
	link(t, filepath.Join(w.outside, "secret.txt"), filepath.Join(w.root, "leaf-abs"))
	link(t, "../outside", filepath.Join(w.root, "dir-rel"))
	link(t, w.outside, filepath.Join(w.root, "dir-abs"))
	link(t, "../outside/sub", filepath.Join(w.root, "dir-sub"))
	link(t, "leaf-rel", filepath.Join(w.root, "chain"))
	link(t, "../home", filepath.Join(w.root, "home-link"))
	if err := os.MkdirAll(filepath.Join(w.root, "d"), 0o755); err != nil {
		t.Fatal(err)
	}
	link(t, "../../outside", filepath.Join(w.root, "d", "up"))
	tools := newTools(w.root, ReadFileTool)
	for _, c := range []struct{ name, path string }{
		{"relative leaf", "leaf-rel"},
		{"absolute leaf", "leaf-abs"},
		{"chained leaf", "chain"},
		{"relative folder", "dir-rel/secret.txt"},
		{"absolute folder", "dir-abs/secret.txt"},
		{"nested folder", "dir-rel/sub/deep.txt"},
		{"nested folder link", "dir-sub/deep.txt"},
		{"folder in folder", "d/up/secret.txt"},
		{"home through link", "home-link/x"},
		{"absolute path through link", filepath.Join(w.root, "dir-rel", "secret.txt")},
		// The decoy secret.txt is inside; the traversal's real parent is outside.
		{"link before parent", "dir-sub/../secret.txt"},
		{"link before parent, absolute link", "dir-abs/sub/../secret.txt"},
		{"link before parent and back", "dir-rel/../repo/ok.txt"},
	} {
		t.Run(c.name, func(t *testing.T) {
			wantRefused(t, run(t, tools, ReadFileTool, map[string]any{"path": c.path}), errOutside)
		})
	}
}

func TestReadContainInside(t *testing.T) {
	_, root := newRepo(t)
	write(t, root, "a.txt", "one\ntwo\nthree\n")
	write(t, root, "sub/b.txt", "bee\n")
	write(t, root, "sub/deep/c.txt", "sea\n")
	link(t, "a.txt", filepath.Join(root, "file-rel"))
	link(t, filepath.Join(root, "a.txt"), filepath.Join(root, "file-abs"))
	link(t, "sub", filepath.Join(root, "dir-rel"))
	link(t, filepath.Join(root, "sub"), filepath.Join(root, "dir-abs"))
	link(t, "file-abs", filepath.Join(root, "chain"))
	link(t, "../a.txt", filepath.Join(root, "sub", "up"))
	aliasBase, _ := filepath.EvalSymlinks(t.TempDir())
	alias := filepath.Join(aliasBase, "alias")
	link(t, root, alias)

	tools := newTools(root, ReadFileTool)
	viaAlias := newTools(alias, ReadFileTool)
	const a = "1\tone\n2\ttwo\n3\tthree"
	for _, c := range []struct {
		name  string
		tools *Tools
		args  map[string]any
		want  string
	}{
		{"relative", tools, map[string]any{"path": "a.txt"}, a},
		{"dot relative", tools, map[string]any{"path": "./sub/../a.txt"}, a},
		{"absolute", tools, map[string]any{"path": filepath.Join(root, "a.txt")}, a},
		{"absolute with parent", tools, map[string]any{"path": filepath.Join(root, "sub", "..", "a.txt")}, a},
		{"relative file link", tools, map[string]any{"path": "file-rel"}, a},
		{"absolute file link", tools, map[string]any{"path": "file-abs"}, a},
		{"chained file link", tools, map[string]any{"path": "chain"}, a},
		{"relative folder link", tools, map[string]any{"path": "dir-rel/b.txt"}, "1\tbee"},
		{"absolute folder link", tools, map[string]any{"path": "dir-abs/deep/c.txt"}, "1\tsea"},
		{"link before parent", tools, map[string]any{"path": "dir-rel/../a.txt"}, a},
		{"link inside folder", tools, map[string]any{"path": "sub/up"}, a},
		{"absolute through link", tools, map[string]any{"path": filepath.Join(root, "dir-abs", "b.txt")}, "1\tbee"},
		{"range", tools, map[string]any{"path": "a.txt", "start_line": int64(2), "end_line": int64(3)}, "2\ttwo\n3\tthree"},
		{"start only", tools, map[string]any{"path": "file-rel", "start_line": int64(3)}, "3\tthree"},
		{"end only", tools, map[string]any{"path": "dir-rel/../a.txt", "end_line": int64(1)}, "1\tone"},
		{"root alias, relative", viaAlias, map[string]any{"path": "a.txt"}, a},
		{"root alias, alias path", viaAlias, map[string]any{"path": filepath.Join(alias, "sub", "b.txt")}, "1\tbee"},
		{"root alias, real path", viaAlias, map[string]any{"path": filepath.Join(root, "a.txt")}, a},
		{"root alias, link", viaAlias, map[string]any{"path": "dir-abs/b.txt"}, "1\tbee"},
		{"real root, alias path", tools, map[string]any{"path": filepath.Join(alias, "a.txt")}, a},
		{"missing", tools, map[string]any{"path": "nope.txt"}, "error: nope.txt does not exist"},
		{"folder", tools, map[string]any{"path": "dir-rel"}, "error: dir-rel is a folder; use list_files"},
		{"root folder", tools, map[string]any{"path": "."}, "error: . is a folder; use list_files"},
	} {
		t.Run(c.name, func(t *testing.T) {
			if got := run(t, c.tools, ReadFileTool, c.args); got != c.want {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
}

func TestReadContainOtherTools(t *testing.T) {
	w := newReadContainWorld(t)
	write(t, w.root, "src/a.txt", "needle in src\n")
	write(t, w.root, "src/pix.png", string(png(1, 1, []byte{0, 1, 2, 3}, nil, nil)))
	write(t, w.root, "top.txt", "needle at top\n")
	write(t, w.outside, "secret.png", string(png(1, 1, []byte{0, 9, 9, 9}, nil, nil)))
	write(t, w.outside, "sub/needle.txt", "needle "+outsideSecret+"\n")
	write(t, w.home, "x.png", string(png(1, 1, []byte{0, 9, 9, 9}, nil, nil)))
	link(t, "src", filepath.Join(w.root, "src-link"))
	link(t, "../outside", filepath.Join(w.root, "out-rel"))
	link(t, w.outside, filepath.Join(w.root, "out-abs"))
	commitAll(t, w.root)
	tools := newTools(w.root, ViewImageTool, ListFilesTool, SearchTextTool)

	escapes := []struct {
		name, path string
		reason     containError
	}{
		{"home", "~/x.png", errHome},
		{"home itself", "~", errHome},
		{"absolute outside", filepath.Join(w.outside, "secret.png"), errOutside},
		{"absolute outside folder", w.outside, errOutside},
		{"parent escape", "../outside/secret.png", errOutside},
		{"parent of root", "..", errOutside},
		{"relative link", "out-rel/secret.png", errOutside},
		{"absolute link", "out-abs/secret.png", errOutside},
		{"folder link", "out-rel", errOutside},
		{"link before parent", "out-rel/sub/../../repo/top.txt", errOutside},
	}
	for _, c := range escapes {
		t.Run("view_image "+c.name, func(t *testing.T) {
			out, err := tools.Run(ViewImageTool, map[string]any{"path": c.path})
			if err != nil || out.Typed() {
				t.Fatalf("typed result or error: %v %v", err, out.Parts)
			}
			wantRefused(t, out.Text, c.reason)
			if strings.Contains(out.Text, "invalid PNG") {
				t.Errorf("incidental image error: %q", out.Text)
			}
		})
		t.Run("list_files "+c.name, func(t *testing.T) {
			got := run(t, tools, ListFilesTool, map[string]any{"path": c.path})
			wantRefused(t, got, c.reason)
			if strings.Contains(got, "fatal") {
				t.Errorf("incidental Git error: %q", got)
			}
		})
		t.Run("search_text "+c.name, func(t *testing.T) {
			got := run(t, tools, SearchTextTool, map[string]any{"pattern": "needle", "path": c.path})
			wantRefused(t, got, c.reason)
			if strings.Contains(got, "fatal") {
				t.Errorf("incidental Git error: %q", got)
			}
		})
	}

	for _, path := range []string{"src/pix.png", filepath.Join(w.root, "src", "pix.png"), "src-link/pix.png", "src/../src/pix.png"} {
		t.Run("view_image inside "+path, func(t *testing.T) {
			out, err := tools.Run(ViewImageTool, map[string]any{"path": path})
			if err != nil || !out.Typed() {
				t.Fatalf("not typed pixels: %v %q", err, out.Text)
			}
		})
	}
	for _, c := range []struct {
		name string
		args map[string]any
		want string
	}{
		{"default", nil, "a/b.txt\nout-abs\nout-rel\nsecret.txt\nsrc-link\nsrc/a.txt\nsrc/pix.png\ntop.txt"},
		{"folder", map[string]any{"path": "src"}, "src/a.txt\nsrc/pix.png"},
		{"dot", map[string]any{"path": "."}, "a/b.txt\nout-abs\nout-rel\nsecret.txt\nsrc-link\nsrc/a.txt\nsrc/pix.png\ntop.txt"},
		{"absolute folder", map[string]any{"path": filepath.Join(w.root, "src")}, "src/a.txt\nsrc/pix.png"},
		{"absolute root", map[string]any{"path": w.root}, "a/b.txt\nout-abs\nout-rel\nsecret.txt\nsrc-link\nsrc/a.txt\nsrc/pix.png\ntop.txt"},
		{"missing", map[string]any{"path": "nope"}, "(no files)"},
	} {
		t.Run("list_files "+c.name, func(t *testing.T) {
			if got := run(t, tools, ListFilesTool, c.args); got != c.want {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
	for _, c := range []struct {
		name string
		args map[string]any
		want string
	}{
		{"default", map[string]any{"pattern": "needle"}, "src/a.txt:1:needle in src\ntop.txt:1:needle at top"},
		{"folder", map[string]any{"pattern": "needle", "path": "src"}, "src/a.txt:1:needle in src"},
		{"absolute folder", map[string]any{"pattern": "needle", "path": filepath.Join(w.root, "src")}, "src/a.txt:1:needle in src"},
		{"no match", map[string]any{"pattern": "absent", "path": "src"}, "(no matches)"},
	} {
		t.Run("search_text "+c.name, func(t *testing.T) {
			if got := run(t, tools, SearchTextTool, c.args); got != c.want {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
}

// Git's worktree can be larger than Tools.Root; top pathspec magic must not
// let a caller search or list its parent directory.
func TestReadContainGitTopPathspec(t *testing.T) {
	_, root := newRepo(t)
	write(t, root, "outside.txt", "outside-payload\n")
	write(t, root, "sub/inside.txt", "inside\n")
	commitAll(t, root)
	tools := newTools(filepath.Join(root, "sub"), ListFilesTool, SearchTextTool)
	for _, path := range []string{":(top)outside.txt", ":/outside.txt", ":(top,glob)*"} {
		t.Run(path, func(t *testing.T) {
			for _, name := range []string{ListFilesTool, SearchTextTool} {
				got := run(t, tools, name, map[string]any{"path": path, "pattern": "outside-payload"})
				wantRefused(t, got, errOutside)
				if strings.Contains(got, "outside-payload") || strings.Contains(got, "../outside.txt") {
					t.Errorf("outside result: %q", got)
				}
			}
		})
	}
}

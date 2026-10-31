package loop

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	"kogen-loop/tools"
)

func olCall(id, name string, args map[string]any) map[string]any {
	b, _ := json.Marshal(args)
	return fcall(id, name, string(b))
}

// olSearchIn is a search_text call restricted to path.
func olSearchIn(id, pattern, path string) map[string]any {
	return olCall(id, "search_text", map[string]any{"pattern": pattern, "path": path})
}

// olFiles are the regular files below root, relative and sorted; write temporaries excluded.
func olFiles(root string) string {
	var files []string
	filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err == nil && d.Type().IsRegular() && !strings.HasPrefix(d.Name(), ".kogen-write-") {
			rel, _ := filepath.Rel(root, p)
			files = append(files, rel)
		}
		return nil
	})
	slices.Sort(files)
	return strings.Join(files, ",")
}

// olConflict starts a round of the legacy requester over real tools in a fresh root.
func olConflict(t *testing.T, setup func(root string), items ...map[string]any) (*olRun, *olRepo, string, *scriptRequester) {
	t.Helper()
	root := t.TempDir()
	if setup != nil {
		setup(root)
	}
	repo := newOLRepo(t)
	repo.snap = func(string) string { return olFiles(root) }
	rq := &scriptRequester{script: [][]map[string]any{items, {fcall("end", "finish", `{}`)}}}
	tl := olTools(root, repo, nil)
	tl.Probe = nil
	return olStart(context.Background(), Round{Tools: tl}, []any{userMsg("go")}, rq, Hooks{}), repo, root, rq
}

func olOutputs(t *testing.T, res Result, err error) []string {
	t.Helper()
	if err != nil || res.Ending != EndTerminal {
		t.Fatalf("%+v %v", res, err)
	}
	var out []string
	for _, it := range res.Input {
		if m, ok := it.(map[string]any); ok && m["type"] == "function_call_output" {
			out = append(out, m["call_id"].(string)+"="+m["output"].(string))
		}
	}
	return out
}

// A later call never bypasses an earlier one it can conflict with, and calls that cannot
// conflict do not wait for each other.
func TestToolOverlapConflicts(t *testing.T) {
	big := strings.Repeat("x", 4<<20)

	// Writes to one file serialize, however the file is named: the last call's content wins
	// although the first is far larger and so would finish last if they overlapped.
	t.Run("same target", func(t *testing.T) {
		for name, paths := range map[string][2]string{
			"same path":     {"a/f.txt", "a/f.txt"},
			"lexical alias": {"a/f.txt", "a/../a/./f.txt"},
			"symlink alias": {"real/f.txt", "lnk/f.txt"},
		} {
			t.Run(name, func(t *testing.T) {
				run, repo, root, _ := olConflict(t, func(root string) {
					if err := os.MkdirAll(filepath.Join(root, "real"), 0o755); err != nil {
						t.Fatal(err)
					}
					if err := os.Symlink("real", filepath.Join(root, "lnk")); err != nil {
						t.Fatal(err)
					}
				}, olWrite("w1", paths[0], big), olWrite("w2", paths[1], "two"))
				_ = repo
				res, err := run.wait(t)
				if got := olOutputs(t, res, err); !reflect.DeepEqual(got, []string{"w1=ok", "w2=ok"}) {
					t.Fatalf("outputs %v", got)
				}
				b, err := os.ReadFile(filepath.Join(root, paths[1]))
				if err != nil || string(b) != "two" {
					t.Fatalf("the second write did not win: %d bytes, %v", len(b), err)
				}
			})
		}
	})

	t.Run("read after write", func(t *testing.T) {
		run, repo, _, _ := olConflict(t, nil, olWrite("w", "d/f.txt", big), olSearchIn("r", "r", "d"))
		repo.startedKeys(t, "r")
		if got := repo.snapshot("r"); got != "d/f.txt" {
			t.Fatalf("the read started before the write finished: files %q", got)
		}
		repo.release("r")
		res, err := run.wait(t)
		if got := olOutputs(t, res, err); !reflect.DeepEqual(got, []string{"w=ok", "r=r"}) {
			t.Fatalf("outputs %v", got)
		}
	})

	// Git reads ignore files beside the listed path and receives the path as written, not as
	// resolved: a write to either is ordered before the listing.
	t.Run("Git inputs of a listing", func(t *testing.T) {
		for name, c := range map[string]struct{ write, list, key, want string }{
			"ignore file":                 {".gitignore", "d", "ls:d", ".gitignore"},
			"pathspec as written":         {"b/f.txt", "a/../b", "ls:b", "b/f.txt"},
			"ignore file of a parent dir": {"d/.gitignore", "d/e", "ls:d/e", "d/.gitignore"},
		} {
			t.Run(name, func(t *testing.T) {
				run, repo, _, _ := olConflict(t, func(root string) {
					for _, dir := range []string{"x/y", "b", "d/e"} {
						if err := os.MkdirAll(filepath.Join(root, dir), 0o755); err != nil {
							t.Fatal(err)
						}
					}
					if err := os.Symlink("x/y", filepath.Join(root, "a")); err != nil {
						t.Fatal(err)
					}
				}, olWrite("w", c.write, big), olList("l", c.list))
				repo.startedKeys(t, c.key)
				if got := repo.snapshot(c.key); got != c.want {
					t.Fatalf("the listing began with files %q, before the write finished", got)
				}
				repo.release(c.key)
				res, err := run.wait(t)
				if got := olOutputs(t, res, err); !reflect.DeepEqual(got, []string{"w=ok", "l=" + c.key}) {
					t.Fatalf("outputs %v", got)
				}
			})
		}
	})

	// A read through a missing folder and ".." opens only once the earlier write created it.
	t.Run("read through a folder a write creates", func(t *testing.T) {
		run, _, _, _ := olConflict(t, func(root string) {
			if err := os.WriteFile(filepath.Join(root, "b.txt"), []byte("bee\n"), 0o644); err != nil {
				t.Fatal(err)
			}
		}, olWrite("w", "a/x.txt", big), olCall("r", "read_file", map[string]any{"path": "a/../b.txt"}))
		res, err := run.wait(t)
		if got := olOutputs(t, res, err); !reflect.DeepEqual(got, []string{"w=ok", "r=1\tbee"}) {
			t.Fatalf("outputs %q", got)
		}
	})

	t.Run("write after read", func(t *testing.T) {
		run, repo, root, _ := olConflict(t, nil,
			olSearchIn("r", "r", "d"), olWrite("w", "d/f.txt", "x"), olSearchIn("z", "z", "elsewhere"))
		// The unrelated read after the write starts beside the first read; the write, which
		// overlaps the first read's folder, does not.
		repo.startedKeys(t, "r", "z")
		if got := repo.snapshot("z"); got != "" {
			t.Fatalf("the write ran under a running read: files %q", got)
		}
		repo.release("z", "r")
		res, err := run.wait(t)
		if got := olOutputs(t, res, err); !reflect.DeepEqual(got, []string{"r=r", "w=ok", "z=z"}) {
			t.Fatalf("outputs %v", got)
		}
		if olFiles(root) != "d/f.txt" {
			t.Fatalf("files %q", olFiles(root))
		}
	})

	// Distinct files overlap each other and independent reads: the second write and the read
	// of its folder finish while the first write is still waiting behind a held read.
	t.Run("disjoint writes and reads", func(t *testing.T) {
		run, repo, root, _ := olConflict(t, nil,
			olSearchIn("ra", "ra", "a"), olWrite("wa", "a/f.txt", "A"), olWrite("wb", "b/g.txt", "B"), olSearchIn("rb", "rb", "b"),
			olSearchIn("x", "x", "x"), olList("l", "y"))
		repo.startedKeys(t, "ra", "rb", "x", "ls:y")
		if got := repo.snapshot("rb"); got != "b/g.txt" {
			t.Fatalf("the read of b began with files %q, want only the second write's", got)
		}
		if repo.finished("ra") {
			t.Fatal("the held read finished")
		}
		repo.release("ra", "rb", "x", "ls:y")
		res, err := run.wait(t)
		want := []string{"ra=ra", "wa=ok", "wb=ok", "rb=rb", "x=x", "l=ls:y"}
		if got := olOutputs(t, res, err); !reflect.DeepEqual(got, want) {
			t.Fatalf("outputs %v", got)
		}
		if olFiles(root) != "a/f.txt,b/g.txt" {
			t.Fatalf("files %q", olFiles(root))
		}
	})

	t.Run("view_image reads the whole tree", func(t *testing.T) {
		run, repo, _, _ := olConflict(t, func(root string) {
			img := image.NewRGBA(image.Rect(0, 0, 1, 1))
			img.Set(0, 0, color.RGBA{R: 1, G: 2, B: 3, A: 255})
			var buf bytes.Buffer
			if err := png.Encode(&buf, img); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(root, "img.png"), buf.Bytes(), 0o644); err != nil {
				t.Fatal(err)
			}
		}, olWrite("w", "d/f.txt", big), olCall("v", "view_image", map[string]any{"path": "img.png"}))
		repo.startedKeys(t, "tree")
		if got := repo.snapshot("tree"); got != "d/f.txt,img.png" {
			t.Fatalf("the candidate tree was read before the write finished: files %q", got)
		}
		repo.release("tree")
		res, err := run.wait(t)
		if err != nil || res.Ending != EndTerminal {
			t.Fatalf("%+v %v", res, err)
		}
	})

	t.Run("write then shell", func(t *testing.T) {
		run, _, _, _ := olConflict(t, nil, olWrite("w", "f.txt", big), olShell("s", "cat f.txt | wc -c | tr -d ' '"))
		res, err := run.wait(t)
		if got := olOutputs(t, res, err); !reflect.DeepEqual(got, []string{"w=ok", "s=exit status: 0\n4194304\n"}) {
			t.Fatalf("outputs %q", got)
		}
	})

	t.Run("shell then read and shell", func(t *testing.T) {
		root := t.TempDir()
		ready, gate := olFifo(t, root, "ready"), olFifo(t, root, "gate")
		repo := newOLRepo(t)
		repo.snap = func(string) string { return olFiles(root) }
		rq := &scriptRequester{script: [][]map[string]any{{
			olShell("s1", olHold(ready, gate, "mkdir -p d && echo one >> order.txt && echo x > d/new")),
			olShell("s2", "echo two >> order.txt"),
			olSearchIn("r", "r", "d"),
		}, {fcall("end", "finish", `{}`)}}}
		run := olStart(context.Background(), Round{Tools: olTools(root, repo, nil)}, []any{userMsg("go")}, rq, Hooks{})
		olReadPid(t, ready) // the first shell is running
		repo.idle(t, "a call after a running shell")
		olOpen(gate)
		repo.startedKeys(t, "r")
		if got := repo.snapshot("r"); got != "d/new,order.txt" {
			t.Fatalf("the read began with files %q: it must follow both shells", got)
		}
		repo.release("r")
		res, err := run.wait(t)
		want := []string{"s1=exit status: 0\n", "s2=exit status: 0\n", "r=r"}
		if got := olOutputs(t, res, err); !reflect.DeepEqual(got, want) {
			t.Fatalf("outputs %q", got)
		}
		if b, _ := os.ReadFile(filepath.Join(root, "order.txt")); string(b) != "one\ntwo\n" {
			t.Fatalf("shells ran out of order: %q", b)
		}
	})

	// Calls whose effects are unknown, whether not enabled or opaque like probe, are ordered
	// against everything around them.
	t.Run("unknown effects", func(t *testing.T) {
		root := t.TempDir()
		repo := newOLRepo(t)
		probeStarted, probeGate := make(chan struct{}), make(chan struct{})
		tl := olTools(root, repo, nil)
		tl.Enabled = append(tl.Enabled, tools.ProbeTool)
		tl.Probe = func(command string, files any) (string, error) {
			close(probeStarted)
			<-probeGate
			return "probed " + command, nil
		}
		t.Cleanup(func() {
			select {
			case <-probeGate:
			default:
				close(probeGate)
			}
		})
		rq := &scriptRequester{script: [][]map[string]any{{
			olSearch("r1", "x"),
			olCall("u", "mystery", map[string]any{}),
			olCall("p", "probe", map[string]any{"command": "c"}),
			olSearch("r2", "y"),
		}, {fcall("end", "finish", `{}`)}}}
		run := olStart(context.Background(), Round{Tools: tl}, []any{userMsg("go")}, rq, Hooks{})
		repo.startedKeys(t, "x")
		select {
		case <-probeStarted:
			t.Fatal("probe started beside a running read")
		default:
		}
		repo.release("x")
		<-probeStarted
		if !repo.finished("x") {
			t.Fatal("probe started before the earlier read finished")
		}
		repo.idle(t, "a read after a running probe")
		close(probeGate)
		repo.startedKeys(t, "y")
		repo.release("y")
		res, err := run.wait(t)
		want := []string{"r1=x", "u=error: unknown tool mystery", "p=probed c", "r2=y"}
		if got := olOutputs(t, res, err); !reflect.DeepEqual(got, want) {
			t.Fatalf("outputs %q", got)
		}
	})

	// A call after one that is not complete in the stream waits for it, even when it is itself
	// complete: the earlier call's effects are unknown.
	t.Run("earlier incomplete call", func(t *testing.T) {
		repo := newOLRepo(t)
		sent, proceed := make(chan struct{}), make(chan struct{})
		prov := newOLProvider(t, "responses",
			func(s *olStream) {
				s.frag(0, "a", "search_text", `{"pattern":"fi`)
				s.call(1, "b", "search_text", `{"pattern":"second"}`)
				close(sent)
				s.wait(proceed)
				s.done(0, "a", "search_text", `{"pattern":"first"}`)
				s.end()
			},
			olFinish,
		)
		d, role, sess := olDirect(t, prov)
		rd := Round{Role: role, Definitions: olDefs(), Tools: olTools(t.TempDir(), repo, sess)}
		run := olStart(context.Background(), rd, []any{userMsg("go")}, d, Hooks{})
		<-sent
		repo.idle(t, "a complete call behind an incomplete one")
		close(proceed)
		repo.startedKeys(t, "first", "second")
		repo.release("first", "second")
		res, err := run.wait(t)
		if got := olOutputs(t, res, err); !reflect.DeepEqual(got, []string{"a=first", "b=second"}) {
			t.Fatalf("outputs %q", got)
		}
	})
}

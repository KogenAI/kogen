package shape

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen/agent"
	"kogen/project"
)

// These conversations deliberately issue four identical calls, then terminate normally.
func TestKNoProgNativeRoles(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		t.Run(fmt.Sprint(enabled), func(t *testing.T) {
			t.Run("shape", func(t *testing.T) {
				f := newShpFx(t)
				for i := 0; i < 4; i++ {
					f.Prov.seq = append(f.Prov.seq, shpAnswer(shpCall(fmt.Sprint(i), "read_file", map[string]any{"path": "README.md"})))
				}
				f.Prov.seq = append(f.Prov.seq, shpSubmit("end", map[string]any{"questions": []any{shpQuestion("Q?")}}))
				sh := f.shaping()
				sh.role = sh.cfg.Models["shape"]
				sh.role.NoProgress = enabled
				build := sh.cfg.Models["build"]
				build.NoProgress = true
				sh.cfg.Models["build"] = build
				sh.toolDefs = agent.AsAny(agent.Defs(append(sh.mainTools(), agent.SubmitTool)...))
				input := []any{map[string]any{"role": "user", "content": "test"}}
				sh.window = newShapeWindow(sh.root, sh.slug, input)
				sh.cacheID = startConversation(sh.ev, "shape")
				out, _, err := sh.converse(context.Background(), input)
				if err != nil || out.kind != outQuestions || len(f.Prov.requests()) != 5 {
					t.Fatalf("out=%+v err=%v requests=%d", out, err, len(f.Prov.requests()))
				}
				if len(shpNamed(f.events(), "native_no_progress")) != 0 {
					t.Fatal("unexpected stop event")
				}
			})
			t.Run("worker", func(t *testing.T) {
				f := newShpFx(t)
				f.withWorkers()
				sh := f.shaping()
				role := sh.cfg.ShapeWorkers.Roles["read"]
				role.NoProgress = enabled
				sh.cfg.ShapeWorkers.Roles["read"] = role
				b := sh.cfg.Models["build"]
				b.NoProgress = true
				sh.cfg.Models["build"] = b
				for i := 0; i < 4; i++ {
					f.Prov.seq = append(f.Prov.seq, shpAnswer(shpCall(fmt.Sprint(i), "read_file", map[string]any{"path": "app.txt"})))
				}
				f.Prov.seq = append(f.Prov.seq, shpWorkerResult("end", "done"))
				got, err := sh.runBatch(context.Background(), map[string]any{"brief": f.brief(), "jobs": []any{shpJob("inspect", "read", []any{"app.txt"})}})
				if err != nil || got["status"] != "completed" || len(f.Prov.requests()) != 5 {
					t.Fatalf("%v %v requests=%d", got, err, len(f.Prov.requests()))
				}
				if len(shpNamed(f.events(), "native_no_progress")) != 0 {
					t.Fatal("unexpected stop event")
				}
			})
			t.Run("refine", func(t *testing.T) {
				f := newRefFx(t, refOpts{})
				for i := 0; i < 4; i++ {
					f.Prov.seq = append(f.Prov.seq, shpAnswer(shpCall(fmt.Sprint(i), "read_file", map[string]any{"path": "README.md"})))
				}
				f.Prov.seq = append(f.Prov.seq, shpAnswer(shpCall("end", "submit_refinement", map[string]any{"constraint": "outside scope"})))
				cfg, err := project.LoadConfig(f.Root)
				if err != nil {
					t.Fatal(err)
				}
				role := cfg.Models["shape"]
				role.NoProgress = enabled
				b := cfg.Models["build"]
				b.NoProgress = true
				cfg.Models["build"] = b
				head := f.Repo.Head()
				tree, err := f.Repo.Tree(head, nil)
				if err != nil {
					t.Fatal(err)
				}
				indexPath, err := f.Repo.IndexPath()
				if err != nil {
					t.Fatal(err)
				}
				index, err := refineIndexDigest(indexPath)
				if err != nil {
					t.Fatal(err)
				}
				ev := f.shpFx.evidence()
				input := []any{map[string]any{"role": "user", "content": "test"}}
				r := &refine{s: f.S, repo: f.Repo, root: f.Root, slug: shpSlug, cfg: cfg, client: f.Client, expected: f.hash0, head: head, tree: tree, indexPath: indexPath, index: index, ev: ev, evidence: ev.Dir, scratch: f.Root, scratchR: f.Repo, originals: map[string][]byte{}, proposed: map[string]string{}, window: newRefineWindow(ev.Dir, input)}
				r.cacheID = startConversation(ev, "refine")
				_, _, _, err = r.converse(context.Background(), role, agent.AsAny(agent.Defs("read_file", "submit_refinement")), input)
				if err == nil || !strings.Contains(err.Error(), "outside scope") || len(f.Prov.requests()) != 5 {
					t.Fatalf("err=%v requests=%d", err, len(f.Prov.requests()))
				}
				if len(shpNamed(f.events(), "native_no_progress")) != 0 {
					t.Fatal("unexpected stop event")
				}
			})
		})
	}
	doc, err := os.ReadFile(filepath.Join("..", "..", "docs", "configuration.md"))
	if err != nil || !strings.Contains(string(doc), "Shape, Refine, Shape workers and independent Review ignore") {
		t.Fatalf("missing unsupported role documentation: %v", err)
	}
}

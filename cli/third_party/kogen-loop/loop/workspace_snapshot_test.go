package loop

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/KogenAI/kogen-loop/tools"
)

// Run is the engine Kogen's builder calls: it sends the caller's input, never a snapshot.
func TestRunSendsTheCallersInputWithoutASnapshot(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("a\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("git", "-C", root, "init", "-q").CombinedOutput(); err != nil {
		t.Fatalf("git init: %v\n%s", err, out)
	}
	tl := &tools.Tools{Root: root, Enabled: []string{tools.ListFilesTool, tools.ReadFileTool}}
	if tl.Snapshot() == "" {
		t.Fatal("the root has no snapshot to leave out")
	}
	rq := &scriptRequester{script: [][]map[string]any{prose("done")}}
	rd := Round{Owner: "loop", Definitions: nil, Terminal: []string{"finish"}, Tools: tl}
	input := []any{userMsg("task")}
	if _, err := Run(context.Background(), rd, input, rq, Hooks{}); err != nil {
		t.Fatal(err)
	}
	if len(rq.requests) != 1 || !reflect.DeepEqual(rq.requests[0], input) {
		t.Fatalf("requests %v", rq.requests)
	}
}

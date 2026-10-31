package loop

import (
	"context"
	"encoding/json"
	"os"
	"testing"

	"kogen-loop/sys"
	"kogen-loop/tools"
)

func TestDiscardedAttemptStopsYieldedShell(t *testing.T) {
	root := t.TempDir()
	tl := &tools.Tools{Root: root, Session: sys.NewWith(os.Environ(), root), Enabled: []string{tools.ShellTool}}
	defer tl.EndShellRound()
	st := newStage(context.Background(), tl, nil)
	st.Done(0, olShell("c", "while :; do sleep 1; done"))
	st.mu.Lock()
	g := st.gen
	for len(g.slots) == 0 || g.slots[0].state != finished {
		st.cond.Wait()
	}
	text := g.slots[0].out.Text
	st.mu.Unlock()
	var result struct {
		Status string `json:"status"`
		Handle string `json:"handle"`
	}
	if err := json.Unmarshal([]byte(text), &result); err != nil || result.Status != "running" || result.Handle == "" {
		t.Fatalf("yield: %q %v", text, err)
	}
	st.Abort()
	out, err := tl.Run(tools.ShellTool, map[string]any{"handle": result.Handle})
	if err != nil || out.Text != "error: unknown shell handle" {
		t.Fatalf("discarded handle: %q %v", out.Text, err)
	}
}

package conformance

import (
	"context"
	"testing"

	"github.com/KogenAI/kogen-loop/api"
	"github.com/KogenAI/kogen-loop/loop"
)

// A shell call that returns a completed command's result carries "exit_status" in its
// tool.result; refused, malformed, unknown-handle and non-shell calls carry none.
func TestSessionToolResultCarriesExitStatusOnlyForCompletedShellResults(t *testing.T) {
	t.Parallel()
	w := newWorld(t).signIn()
	f := newFakeProvider(t, []exchange{
		{Items: []map[string]any{
			call("ok", "shell", map[string]any{"command": "exit 0"}),
			call("three", "shell", map[string]any{"command": "exit 3"}),
			call("killed", "shell", map[string]any{"command": "kill -9 $$"}),
			call("printed", "shell", map[string]any{"command": "printf 'exit status: 9\\n'"}),
			call("refused", "shell", map[string]any{"command": "pkill -f nothing-at-all"}),
			call("unknown", "shell", map[string]any{"handle": "nope"}),
			call("malformed", "shell", map[string]any{}),
			call("list", "list_files", map[string]any{}),
		}},
		{Items: []map[string]any{call("end", "finish", map[string]any{"summary": "done"})}},
	})
	var events []api.Event
	s, err := loop.NewSession(sessionConfig(w, f, &events))
	if err != nil {
		t.Fatal(err)
	}
	if res, err := s.Round(context.Background(), "open"); err != nil || res.Ending != loop.EndTerminal {
		t.Fatalf("%v %v", res, err)
	}
	want := map[string]any{"ok": 0, "three": 3, "killed": 137, "printed": 0}
	seen := 0
	for _, e := range events {
		if e.Type != api.EventToolResult {
			continue
		}
		seen++
		id, _ := e.Fields["call_id"].(string)
		got, has := e.Fields["exit_status"]
		if n, ok := want[id]; ok {
			if !has || got != n {
				t.Errorf("%s: exit_status %v (present %v), want %v", id, got, has, n)
			}
			if _, bad := e.Fields["error_kind"]; bad {
				t.Errorf("%s: a non-zero exit status is not a tool error: %v", id, e.Fields)
			}
		} else if has {
			t.Errorf("%s: unexpected exit_status %v", id, got)
		}
	}
	if seen != 8 {
		t.Errorf("tool.result events %d, want 8", seen)
	}
}

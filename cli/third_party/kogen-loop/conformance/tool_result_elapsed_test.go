package conformance

import (
	"context"
	"testing"

	"github.com/KogenAI/kogen-loop/api"
	"github.com/KogenAI/kogen-loop/loop"
)

// Every non-terminal call of a loop.Session has a tool.result with a non-negative integer
// elapsed_ms, whichever tool or kind of failure; the terminal call has no tool.result.
func TestSessionToolResultCarriesElapsedMS(t *testing.T) {
	t.Parallel()
	w := newWorld(t).signIn()
	f := newFakeProvider(t, []exchange{
		{Items: []map[string]any{
			call("c1", "shell", map[string]any{"command": "exit 3"}),
			call("c2", "shell", map[string]any{"command": "pkill -f nothing-at-all"}),
			call("c3", "shell", map[string]any{}),
			call("c4", "list_files", map[string]any{}),
			call("c5", "l_no_such_tool", map[string]any{}),
			call("c6", "read_file", map[string]any{"path": "missing.txt"}),
		}},
		{Items: []map[string]any{call("c7", "finish", map[string]any{"summary": "done"})}},
	})
	var events []api.Event
	s, err := loop.NewSession(sessionConfig(w, f, &events))
	if err != nil {
		t.Fatal(err)
	}
	res, err := s.Round(context.Background(), "open")
	if err != nil || res.Ending != loop.EndTerminal {
		t.Fatalf("%v %v", res, err)
	}
	results := map[string]map[string]any{}
	for _, e := range events {
		if e.Type == api.EventToolResult {
			results[e.Fields["call_id"].(string)] = e.Fields
		}
	}
	if len(results) != 6 {
		t.Fatalf("tool.result events %v", results)
	}
	for id, fields := range results {
		if ms, ok := fields["elapsed_ms"].(int64); !ok || ms < 0 {
			t.Errorf("%s: elapsed_ms %T %v", id, fields["elapsed_ms"], fields["elapsed_ms"])
		}
	}
	if _, ok := results["c7"]; ok {
		t.Errorf("terminal call has a tool.result: %v", results["c7"])
	}
}

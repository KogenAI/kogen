package conformance

import (
	"context"
	"regexp"
	"testing"

	"kogen-loop/api"
	"kogen-loop/loop"
)

var shellWaitInstant = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{9}Z$`)

// The tool.result of a shell call that reaches its wait carries "shell_wait" with exactly four
// keys; a refusal keeps its rule beside it with spawned null; a read and a malformed shell call
// carry none.
func TestSessionToolResultCarriesShellWaitOnlyForShellCallsThatReachTheWait(t *testing.T) {
	t.Parallel()
	w := newWorld(t).signIn()
	f := newFakeProvider(t, []exchange{
		{Items: []map[string]any{call("c1", "shell", map[string]any{"command": "exit 3"})}},
		{Items: []map[string]any{call("c2", "shell", map[string]any{"command": "pkill -f nothing-at-all"})}},
		{Items: []map[string]any{call("c3", "shell", map[string]any{})}},
		{Items: []map[string]any{call("c4", "list_files", map[string]any{})}},
		{Items: []map[string]any{call("c5", "finish", map[string]any{"summary": "done"})}},
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
	if len(results) != 4 {
		t.Fatalf("tool.result events %v", results)
	}
	check := func(id string, spawned bool) {
		t.Helper()
		sw, ok := results[id]["shell_wait"].(map[string]any)
		if !ok || len(sw) != 4 {
			t.Fatalf("%s: shell_wait %v", id, results[id]["shell_wait"])
		}
		for _, k := range []string{"wait_started", "wait_ended"} {
			if s, _ := sw[k].(string); !shellWaitInstant.MatchString(s) {
				t.Errorf("%s: %s %v", id, k, sw[k])
			}
		}
		if s, ok := sw["spawned"].(string); spawned != ok || (ok && !shellWaitInstant.MatchString(s)) {
			t.Errorf("%s: spawned %v", id, sw["spawned"])
		}
		if sw["ended_by"] != api.ShellWaitExit {
			t.Errorf("%s: ended_by %v", id, sw["ended_by"])
		}
	}
	check("c1", true)
	check("c2", false)
	if results["c2"]["rule"] != "pkill-killall" || results["c2"]["error_kind"] != api.ToolErrorForeignKill {
		t.Errorf("refusal keeps its fields: %v", results["c2"])
	}
	for _, id := range []string{"c3", "c4"} {
		if _, ok := results[id]["shell_wait"]; ok {
			t.Errorf("%s carries shell_wait: %v", id, results[id])
		}
	}
}

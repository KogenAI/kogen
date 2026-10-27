package conformance

import (
	"context"
	"testing"

	"kogen-loop/api"
	"kogen-loop/loop"
)

// A refused shell call is ordinary tool feedback: its tool.result carries "rule", an
// ordinary call's does not, and the round continues to its ending.
func TestSessionToolResultCarriesRuleOnlyForRefusedShellCall(t *testing.T) {
	w := newWorld(t).signIn()
	f := newFakeProvider(t, []exchange{
		{Items: []map[string]any{call("c1", "shell", map[string]any{"command": "pkill -f nothing-at-all"})}},
		{Items: []map[string]any{call("c2", "shell", map[string]any{"command": "echo next"})}},
		{Items: []map[string]any{call("c3", "finish", map[string]any{"summary": "done"})}},
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
	var results []map[string]any
	for _, e := range events {
		if e.Type == api.EventToolResult {
			results = append(results, e.Fields)
		}
	}
	if len(results) != 2 {
		t.Fatalf("tool.result events %v", results)
	}
	if results[0]["call_id"] != "c1" || results[0]["rule"] != "pkill-killall" {
		t.Errorf("refused call event %v", results[0])
	}
	if _, ok := results[1]["rule"]; ok || results[1]["call_id"] != "c2" {
		t.Errorf("ordinary call event %v", results[1])
	}
	in := f.requests()[1]["input"].([]any)
	out := in[len(in)-1].(map[string]any)
	if out["call_id"] != "c1" || out["output"] != "refused: this command would stop processes this run did not start (rule: no pkill or killall; kill only pids this run created). Stop what you started with its own pid, for example kill $!, or its process group." {
		t.Errorf("refusal output %v", out)
	}
}

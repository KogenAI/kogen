package claudecode

import (
	"context"
	"encoding/json"
	"os"
	"testing"

	"kogen/executor"
	"kogen/executor/conformance"
)

// Observation only: it mounts as a test with go -overlay and changes no production source. It
// runs the real adapter against the existing fake claude of this package.
func TestK12AdapterObservation(t *testing.T) {
	mode := os.Getenv("KOGEN_K12_MODE")
	shape := mode == "shape" || mode == "shape-no-hook"
	cfg := fakeConfig{}
	round := conformance.RoundScript{End: "finish", Claim: "done", Structured: json.RawMessage(`{"files":[]}`)}
	round1 := round
	if mode == "shape-no-hook" || mode == "build-no-hook" {
		cfg.SkipHook = true
		// Only round 1 makes the one guarded Write call; round 2 finishes without a tool call,
		// so exactly one executor_hook deny event is expected.
		round1.Actions = []conformance.Action{{Write: &conformance.WriteAction{Path: "a.txt", Content: "a\n"}}}
	}
	cfg.Script = conformance.Script{Name: "k12", Rounds: []conformance.RoundScript{round1, round}}
	h := newHarness(t, cfg)
	if shape {
		h.task.Role = executor.RoleShape
		h.task.Schema = json.RawMessage(`{"type":"object"}`)
	}
	s := h.startOK()
	out := map[string]any{"mode": mode, "round1_error": "", "round1_ending": "", "round2_error": "", "round2_ending": ""}
	for i, in := range []executor.Input{{}, {Feedback: "Kogen feedback"}} {
		key := []string{"round1", "round2"}[i]
		res, err := s.Round(context.Background(), in)
		if err != nil {
			out[key+"_error"] = err.Error()
			break
		}
		out[key+"_ending"] = string(res.Ending)
	}
	out["argv"] = h.f.argv(1)
	out["env"] = h.f.env(1)
	var hooks, tools []map[string]any
	for _, e := range h.events {
		switch e["event"] {
		case "executor_hook":
			hooks = append(hooks, e)
		case "executor_tool":
			tools = append(tools, e)
		}
	}
	out["hook_events"], out["tool_events"] = hooks, tools
	raw, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(os.Getenv("KOGEN_K12_OUTPUT"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
}

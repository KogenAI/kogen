package shape

import (
	"kogen-loop/provider"
	"kogen/project"
)

// noToolLimit is the finite protection against repeated prose: a native shaping conversation
// stops at this many answers without any tool call. It is separate from the invalid-submission
// budget.
const noToolLimit = 3

// Reminders for a tool-free answer. They are sent after every such answer, whether or not the
// route can also require the submission tool at API level.
const (
	shapeReminder  = "End by calling submit with either questions or files."
	refineReminder = "Call submit_refinement with a nonempty files array of complete existing owned artifact contents (edits or readiness acknowledgment), or constraint."
)

// turnCounter counts the tool-free answers and invalid submissions of one native invocation, both
// cumulative across local working-window resets, and whether the next inference must require
// the terminal submission tool: only the inference immediately after a tool-free answer.
type turnCounter struct {
	owner, target, reminder string
	noTool, invalid         int
	forced                  bool
}

func newTurns(owner string) *turnCounter {
	if owner == "refine" {
		return &turnCounter{owner: owner, target: "submit_refinement", reminder: refineReminder}
	}
	return &turnCounter{owner: owner, target: "submit", reminder: shapeReminder}
}

// answered folds one response in: a tool-free answer schedules a forced inference (reported
// true), any answer with tool calls clears it.
func (t *turnCounter) answered(calls int) bool {
	t.forced = calls == 0
	if t.forced {
		t.noTool++
	}
	return t.forced
}

// exhausted reports whether the no-tool ceiling is reached.
func (t *turnCounter) exhausted() bool { return t.noTool >= noToolLimit }

// apply makes the request name the terminal tool when a forced inference is pending and the
// route can force a tool. Without support the request keeps the existing reminder only.
func (t *turnCounter) apply(req *provider.Request) {
	if t.forced && provider.SupportsToolChoice(req.Role) {
		req.ToolChoice = t.target
	}
}

// announce records the enforcement of the request about to be sent, whether or not the API
// forces it.
func (t *turnCounter) announce(req provider.Request, role project.Role, ev *Evidence) {
	if !t.forced {
		return
	}
	name := role.Provider
	if name == "" {
		name = "chatgpt"
	}
	ev.Record(map[string]any{
		"event": "forced_submit_turn", "owner": t.owner, "target": t.target, "provider": name,
		"api_forcing_supported": req.ToolChoice != "", "no_tool_turns": t.noTool, "invalid_submissions": t.invalid,
	})
}

// counts records the final counters of an invocation.
func (t *turnCounter) counts(ev *Evidence) {
	ev.Record(map[string]any{
		"event": "shaping_turn_counts", "owner": t.owner, "no_tool_turns": t.noTool, "invalid_submissions": t.invalid,
	})
}

// extend adds the counters and pending enforcement to a reset handoff, only when they differ
// from the start, so an ordinary handoff keeps its exact bytes.
func (t *turnCounter) extend(state map[string]any) map[string]any {
	if t.noTool > 0 {
		state["no_tool_turns"] = t.noTool
	}
	if t.forced {
		state["forced_submit_pending"] = t.target
	}
	return state
}

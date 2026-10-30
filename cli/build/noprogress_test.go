package build

import (
	"fmt"
	"os"
	"strings"
	"testing"

	"kogen/project"
)

// A native round that answers the red feedback without a tool call, into the same red, stops
// the Build (LOOP-7) instead of verifying again and again.

// says is a response of text only: the builder ends its turn without a tool call.
func says(text string) handler {
	return sse(map[string]any{"type": "message", "id": "msg-say", "role": "assistant",
		"content": []any{map[string]any{"type": "output_text", "text": text}}})
}

// sayings are enough text-only answers to show an unbounded loop if the Build kept asking.
func sayings(n int) []handler {
	var h []handler
	for i := 0; i < n; i++ {
		h = append(h, says("Pass remains red; I made no correction and cannot finish."))
	}
	return h
}

func passEvents(t *testing.T, e *env, id string) int {
	t.Helper()
	log, err := os.ReadFile(e.runPath(id, "log.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	return strings.Count(string(log), `"event":"pass"`)
}

func TestARedAnswerWithoutAToolCallAfterTheSameRedStopsWithTheCandidatePreserved(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	head := e.head()
	e.prov.then(e.prov.calls("write_file", map[string]any{"path": "app.txt", "content": "red\n"}, "finish", map[string]any{"summary": "first"}))
	e.prov.then(sayings(12)...)
	a := e.build()
	if a.exit != 1 || a.err != nil {
		t.Fatalf("exit %d err %v\n%s", a.exit, a.err, a.shown())
	}
	id := e.onlyRun()
	out := a.out.String()
	contains(t, "stdout", out, "failed fixture: no_progress (Build "+id+")\n")
	contains(t, "stdout", out, "candidate/no_progress: the builder was told which required acceptance items are missing and answered again without a tool call; verification pass 3 is the same red as the pass before it; edits are left in place\n")
	contains(t, "stdout", out, "  failing: acceptance\n  missing: failed: First (line 2)\n  missing: failed: Second (line 5)\n")
	contains(t, "stdout", out, "  edited: app.txt\n")
	eq(t, "model requests", e.prov.count(), 3)
	eq(t, "pass events", passEvents(t, e, id), 3)
	res := e.result(id)
	eq(t, "outcome", res["outcome"], any("no_progress"))
	eq(t, "passes", res["passes"], any(float64(3)))
	eq(t, "candidate", e.read("app.txt"), "red\n")
	eq(t, "head", e.head(), head)
}

// lastInput is the text the builder received last in a request: a user message or the output
// that answers its finish call.
func lastInput(req map[string]any) string {
	items, _ := req["input"].([]any)
	if len(items) == 0 {
		return ""
	}
	it, _ := items[len(items)-1].(map[string]any)
	if s, ok := it["output"].(string); ok {
		return s
	}
	switch c := it["content"].(type) {
	case string:
		return c
	case []any:
		var parts []string
		for _, p := range c {
			if m, ok := p.(map[string]any); ok {
				if s, ok := m["text"].(string); ok {
					parts = append(parts, s)
				}
			}
		}
		return strings.Join(parts, "\n")
	}
	return ""
}

const missingItemsNoticeText = "Required acceptance items are still missing: verification pass 2 is the same red as the pass before it, " +
	"and your last round ended without a tool call. The Build is not complete until each of these acceptance scenarios passes:\n" +
	"- failed: First (line 2)\n- failed: Second (line 5)\n" +
	"Work on them now with your tools (write the missing tests and the implementation they need), then call finish. " +
	"Another round without a tool call into the same red stops the Build as no_progress.\n\n"

func TestAToolFreeRoundIntoTheSameRedGetsOneNoticeNamingTheMissingItemsAndTheBuildLands(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	f := e.prov
	f.then(
		f.calls("write_file", map[string]any{"path": "app.txt", "content": "red\n"}, "finish", map[string]any{"summary": "first"}),
		says("The round is complete."),
		f.calls("write_file", map[string]any{"path": "app.txt", "content": "green\n"}, "finish", map[string]any{"summary": "the rest"}),
	)
	a := e.build()
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	id := e.onlyRun()
	reqs := f.requests()
	eq(t, "model requests", len(reqs), 3)
	eq(t, "outcome", e.result(id)["outcome"], any("landed"))
	eq(t, "passes", e.result(id)["passes"], any(float64(3)))
	notice := lastInput(reqs[2])
	if !strings.HasPrefix(notice, missingItemsNoticeText+"Verification pass 2 is not green.") {
		t.Fatalf("the builder's next message is not the notice then the pass feedback:\n%s", notice)
	}
	if strings.Contains(lastInput(reqs[1]), "Required acceptance items") {
		t.Fatalf("the first red pass got a notice:\n%s", lastInput(reqs[1]))
	}
	notices := eventsNamed(e.events(id), "missing_items_notice")
	eq(t, "notices", len(notices), 1)
	eq(t, "notice pass", notices[0]["pass"], any(float64(2)))
	eq(t, "notice missing", fmt.Sprint(notices[0]["missing"]), "[failed: First (line 2) failed: Second (line 5)]")
}

func TestAnIdenticalRedGetsNoSecondNoticeAfterARoundWithToolCallsThatChangedNothing(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	f := e.prov
	f.then(
		f.calls("write_file", map[string]any{"path": "app.txt", "content": "red\n"}, "finish", map[string]any{"summary": "first"}),
		says("The round is complete."),
		f.calls("shell", map[string]any{"command": "cat app.txt"}, "finish", map[string]any{"summary": "diagnosed"}),
	)
	f.then(sayings(12)...)
	a := e.build()
	eq(t, "exit", a.exit, 1)
	id := e.onlyRun()
	contains(t, "stdout", a.out.String(), "candidate/no_progress: the builder was told which required acceptance items are missing and answered again without a tool call; verification pass 4 is the same red")
	contains(t, "stdout", a.out.String(), "  missing: failed: First (line 2)\n  missing: failed: Second (line 5)\n")
	eq(t, "model requests", f.count(), 4)
	eq(t, "notices", len(eventsNamed(e.events(id), "missing_items_notice")), 1)
}

func TestARoundWithAToolCallIsProgressEvenWhenTheTreeAndTheRedAreUnchanged(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	f := e.prov
	f.then(
		f.calls("write_file", map[string]any{"path": "app.txt", "content": "red\n"}, "finish", map[string]any{"summary": "first"}),
		f.calls("shell", map[string]any{"command": "cat app.txt"}, "finish", map[string]any{"summary": "diagnosed"}),
		f.calls("read_file", map[string]any{"path": "app.txt"}, "finish", map[string]any{"summary": "read"}),
		f.calls("write_file", map[string]any{"path": "app.txt", "content": "green\n"}, "finish", map[string]any{"summary": "repaired"}),
	)
	a := e.build()
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	eq(t, "passes", e.result(e.onlyRun())["passes"], any(float64(4)))
	eq(t, "model requests", f.count(), 4)
}

func TestARoundWithoutAToolCallContinuesWhenTheFixersChangedTheCandidate(t *testing.T) {
	t.Parallel()
	// Each fixer run changes an untracked candidate file, so every pass verifies a new tree.
	e := newEnv(t, func(c *project.Config) { c.Fix = []string{"printf x >> tick.txt"} })
	f := e.prov
	f.then(
		f.calls("write_file", map[string]any{"path": "app.txt", "content": "red\n"}, "finish", map[string]any{"summary": "first"}),
		says("Nothing to add yet."),
		says("Still thinking."),
		f.calls("write_file", map[string]any{"path": "app.txt", "content": "green\n"}, "finish", map[string]any{"summary": "repaired"}),
	)
	a := e.build()
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	eq(t, "passes", e.result(e.onlyRun())["passes"], any(float64(4)))
	eq(t, "model requests", f.count(), 4)
}

func TestAChangedFileModeIsProgressForARoundWithoutAToolCall(t *testing.T) {
	t.Parallel()
	// The fixer flips the executable bit each round: same content, different candidate tree.
	e := newEnv(t, func(c *project.Config) {
		c.Fix = []string{"if test -x run.sh; then chmod -x run.sh; else chmod +x run.sh; fi"}
	})
	f := e.prov
	f.then(
		f.calls("write_file", map[string]any{"path": "app.txt", "content": "red\n"},
			"write_file", map[string]any{"path": "run.sh", "content": "#!/bin/sh\n"}, "finish", map[string]any{"summary": "first"}),
		says("Nothing to add yet."),
		f.calls("write_file", map[string]any{"path": "app.txt", "content": "green\n"}, "finish", map[string]any{"summary": "repaired"}),
	)
	a := e.build()
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	eq(t, "model requests", f.count(), 3)
}

func TestAnIgnoredFileChangeIsNotProgressBecauseVerificationSeesOnlyTheCandidateTree(t *testing.T) {
	t.Parallel()
	e := newEnv(t, func(c *project.Config) { c.Fix = []string{"printf x >> .kogen/local/ignored-tick"} })
	e.prov.then(e.prov.calls("write_file", map[string]any{"path": "app.txt", "content": "red\n"}, "finish", map[string]any{"summary": "first"}))
	e.prov.then(sayings(5)...)
	a := e.build()
	eq(t, "exit", a.exit, 1)
	contains(t, "stdout", a.out.String(), "candidate/no_progress:")
	eq(t, "model requests", e.prov.count(), 3)
}

func TestARedStageGateRepeatedWithoutAToolCallStopsAtTheStage(t *testing.T) {
	t.Parallel()
	checks := []string{"if grep -qx red app.txt; then echo scoped-red; exit 23; fi"}
	e, _ := stagedEnv(t, checks)
	f := e.prov
	f.then(f.calls(stageWrite(f, "red")...), f.calls(stageFinish()...))
	f.then(sayings(12)...)
	a := e.build()
	eq(t, "exit", a.exit, 1)
	out := a.out.String()
	contains(t, "stdout", out, "candidate/no_progress:")
	contains(t, "stdout", out, "  failing: stage-foundation-1\n")
	eq(t, "model requests", f.count(), 3) // write, finish, the answer without a tool call
	eq(t, "candidate", e.read("app.txt"), "red\n")
	_, _, state := e.stageCheckpoint()
	eq(t, "active", state["stage_progress"].(map[string]any)["active"], any("foundation"))
}

func TestAStoppedNoProgressBuildResumesFromItsCheckpoint(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	f := e.prov
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": "red\n"}, "finish", map[string]any{"summary": "first"}), says("No change."), says("Still no change."))
	a := e.build()
	eq(t, "exit", a.exit, 1)
	id := e.onlyRun()
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": "green\n"}, "finish", map[string]any{"summary": "repaired"}))
	r := e.resume(id)
	if r.exit != 0 {
		t.Fatalf("resume exit %d\n%s", r.exit, r.shown())
	}
	eq(t, "candidate", e.read("app.txt"), "green\n")
}

package build

import (
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
	contains(t, "stdout", out, "candidate/no_progress: the builder answered the failure feedback without a tool call, and verification pass 2 is the same red as the pass before it; edits are left in place\n")
	contains(t, "stdout", out, "  failing: acceptance\n")
	contains(t, "stdout", out, "  edited: app.txt\n")
	eq(t, "model requests", e.prov.count(), 2)
	eq(t, "pass events", passEvents(t, e, id), 2)
	res := e.result(id)
	eq(t, "outcome", res["outcome"], any("no_progress"))
	eq(t, "passes", res["passes"], any(float64(2)))
	eq(t, "candidate", e.read("app.txt"), "red\n")
	eq(t, "head", e.head(), head)
}

func TestARoundWithAToolCallIsProgressEvenWhenTheTreeAndTheRedAreUnchanged(t *testing.T) {
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
	e := newEnv(t, func(c *project.Config) { c.Fix = []string{"printf x >> .kogen/local/ignored-tick"} })
	e.prov.then(e.prov.calls("write_file", map[string]any{"path": "app.txt", "content": "red\n"}, "finish", map[string]any{"summary": "first"}))
	e.prov.then(sayings(5)...)
	a := e.build()
	eq(t, "exit", a.exit, 1)
	contains(t, "stdout", a.out.String(), "candidate/no_progress:")
	eq(t, "model requests", e.prov.count(), 2)
}

func TestARedStageGateRepeatedWithoutAToolCallStopsAtTheStage(t *testing.T) {
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
	e := newEnv(t)
	f := e.prov
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": "red\n"}, "finish", map[string]any{"summary": "first"}), says("No change."))
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

package build

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"kogen/agent"
	"kogen/project"
)

// Staged Builds: one approved Intent, durable verified stages, explicit continuation.

func stagePlanText(first []string) string {
	plan := map[string]any{"version": 1, "stages": []any{
		map[string]any{"id": "foundation", "title": "Foundation", "goal": "First runnable section", "checks": first},
		map[string]any{"id": "surface", "title": "Surface", "goal": "Integrated section", "checks": []any{"true"}},
	}}
	b, _ := json.Marshal(plan)
	return "\n## Stages\n```json\n" + string(b) + "\n```\n"
}

// stagedEnv is a repository whose Intent has the two stage plan, approved; every setup run
// (in the checkout and in each verification copy) is traced, and a second run in the same
// copy fails (a fresh copy is made for every pass).
func stagedEnv(t *testing.T, checks []string, whole ...project.Check) (*env, string) {
	t.Helper()
	trace := filepath.Join(t.TempDir(), "setup-trace")
	setup := "test ! -f .kogen/local/warm || exit 26; touch .kogen/local/warm; printf '%s\\n' \"$PWD\" >> " + shellQuote(trace)
	e := newEnv(t, func(c *project.Config) {
		c.Setup = []string{setup}
		c.Checks = whole
	})
	md := filepath.Join(e.root, project.IntentMDPath(testSlug))
	text, err := os.ReadFile(md)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(md, []byte(string(text)+stagePlanText(checks)), 0o644); err != nil {
		t.Fatal(err)
	}
	e.approve()
	return e, trace
}

func traceLines(t *testing.T, trace string) int {
	t.Helper()
	b, err := os.ReadFile(trace)
	if err != nil {
		return 0
	}
	return len(strings.Split(strings.TrimSpace(string(b)), "\n"))
}

func stageWrite(f *fakeProvider, text string) []any {
	return []any{"write_file", map[string]any{"path": "app.txt", "content": text + "\n"}}
}

func stageFinish() []any { return []any{"finish", map[string]any{"summary": "Verify"}} }

func (e *env) stageCheckpoint() (string, map[string]any, map[string]any) {
	e.t.Helper()
	id := e.lastRun()
	doc, state := e.checkpoint(id)
	return id, doc, state
}

// lastRun is the Build whose checkpoint is the newest.
func (e *env) lastRun() string {
	e.t.Helper()
	var newest string
	var when int64
	for _, id := range e.runIDs() {
		st, err := os.Stat(e.runPath(id, "checkpoint.json"))
		if err == nil && st.ModTime().UnixNano() >= when {
			newest, when = id, st.ModTime().UnixNano()
		}
	}
	if newest == "" {
		e.t.Fatal("no run")
	}
	return newest
}

func TestStageScratchMutationsAreRedOrderedRedStopsCommandsAndMilestoneCustodySurvivesResume(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/stages_test.exs: stage scratch mutations are red, ordered red stops commands, fresh setup and milestone custody survive Resume
	checks := []string{
		"if grep -qx mutate app.txt; then printf 'scratch mutation\\n' > app.txt; fi; if grep -qx red app.txt; then echo scoped-red; exit 23; fi",
		"echo later-command",
	}
	e, trace := stagedEnv(t, checks)
	f := e.prov
	f.then(
		f.calls(stageWrite(f, "mutate")...), f.calls(stageFinish()...),
		f.calls(stageWrite(f, "red")...), f.calls(stageFinish()...),
		f.calls(stageWrite(f, "ready")...), f.calls(stageFinish()...),
		refused(),
	)
	a := e.build()
	eq(t, "exit", a.exit, 4)
	contains(t, "progress", a.errs.String(), "kogen: stage foundation gate failed")
	id, doc, state := e.stageCheckpoint()
	evidence := state["stage_evidence"].([]any)
	var greens []any
	for _, x := range evidence {
		greens = append(greens, x.(map[string]any)["green"])
	}
	eq(t, "greens", greens, []any{false, false, true})
	mutated, red, green := evidence[0].(map[string]any), evidence[1].(map[string]any), evidence[2].(map[string]any)
	eq(t, "mutated moved", mutated["moved"], any([]any{"app.txt"}))
	eq(t, "mutated failing", mutated["failing"], any([]any{}))
	eq(t, "red not run", red["not_run"], any([]any{"stage-foundation-2"}))
	eq(t, "red failing", red["failing"], any([]any{"stage-foundation-1"}))
	contains(t, "red output", red["checks"].([]any)[0].(map[string]any)["output"].(string), "scoped-red")
	eq(t, "green", green["clean"].(bool) && green["green"].(bool), true)
	wantProgress := map[string]any{"total": float64(2), "completed": []any{"foundation"}, "active": "surface", "phase": "stage"}
	eq(t, "progress", state["stage_progress"], any(wantProgress))
	eq(t, "envelope progress", doc["stage_progress"], any(wantProgress))
	eq(t, "app", e.read("app.txt"), "ready\n")
	// The setup ran in the checkout once and in a fresh copy for each of the three stage passes.
	eq(t, "setup runs", traceLines(t, trace), 4)
	facts := e.jsonFile(filepath.Join(e.root, ".kogen/local/facts", id+".json"))
	eq(t, "inspect progress", facts["stage_progress"], any(wantProgress))
	res := e.result(id)
	eq(t, "result progress", res["stage_progress"], any(wantProgress))
	originalResult, _ := os.ReadFile(e.runPath(id, "result.json"))
	originalCheckpoint, _ := os.ReadFile(e.runPath(id, "checkpoint.json"))
	requests := f.count()

	// Corrupt navigation or its bound proof, never reinterpret it as unstaged.
	mutations := map[string]func(doc, state map[string]any){
		"progress removed": func(doc, state map[string]any) { delete(state, "stage_progress") },
		"completed cleared": func(doc, state map[string]any) {
			state["stage_progress"].(map[string]any)["completed"] = []any{}
		},
		"active changed": func(doc, state map[string]any) { state["stage_progress"].(map[string]any)["active"] = "foundation" },
		"evidence tree": func(doc, state map[string]any) {
			state["stage_evidence"].([]any)[0].(map[string]any)["tree"] = strings.Repeat("0", 40)
		},
	}
	for name, mutate := range mutations {
		var changed map[string]any
		if err := json.Unmarshal(originalCheckpoint, &changed); err != nil {
			t.Fatal(err)
		}
		mutate(changed, changed["state"].(map[string]any))
		e.writeCheckpoint(id, changed)
		before, _ := os.ReadFile(e.runPath(id, "checkpoint.json"))
		r := e.resume(id)
		eq(t, name+" exit", r.exit, 1)
		contains(t, name, r.shown(), "resume_refused")
		after, _ := os.ReadFile(e.runPath(id, "checkpoint.json"))
		if string(after) != string(before) || f.count() != requests {
			t.Fatalf("%s: a file or request changed", name)
		}
		now, _ := os.ReadFile(e.runPath(id, "result.json"))
		if string(now) != string(originalResult) {
			t.Fatalf("%s: result.json changed", name)
		}
	}

	if err := os.WriteFile(e.runPath(id, "checkpoint.json"), originalCheckpoint, 0o600); err != nil {
		t.Fatal(err)
	}
	f.then(f.calls(stageFinish()...), submit(f, "approve"))
	r := e.resumeReviewed(id)
	if r.exit != 0 {
		t.Fatalf("exit %d\n%s\n%s", r.exit, r.shown(), r.errs.String())
	}
	contains(t, "progress", r.errs.String(), "kogen: stage surface gate passed")
	lacks(t, "progress", r.errs.String(), "kogen: stage foundation gate passed")
	now, _ := os.ReadFile(e.runPath(id, "result.json"))
	if string(now) != string(originalResult) {
		t.Fatal("the stopped result changed")
	}
	// A fresh copy for the surface pass and one for the final pass.
	eq(t, "setup runs after resume", traceLines(t, trace), 6)
	if _, err := os.Stat(filepath.Join(e.root, ".kogen/local/warm")); err != nil {
		t.Fatal("the checkout's own setup run is gone")
	}
}

// stagePhaseRefused rewrites the saved progress phase and checks that Resume refuses each
// before any effect, then restores the checkpoint.
func stagePhaseRefused(t *testing.T, e *env, trace string, phases ...string) (string, map[string]any) {
	t.Helper()
	id := e.lastRun()
	original, _ := os.ReadFile(e.runPath(id, "checkpoint.json"))
	approval, _ := os.ReadFile(project.ApprovalPath(e.root, testSlug))
	before := func() map[string]string {
		s := e.state()
		s["result"] = readString(t, e.runPath(id, "result.json"))
		s["trace"] = itoa(traceLines(t, trace))
		return s
	}
	was := before()
	requests := e.prov.count()
	for _, phase := range phases {
		var doc map[string]any
		if err := json.Unmarshal(original, &doc); err != nil {
			t.Fatal(err)
		}
		doc["state"].(map[string]any)["stage_progress"].(map[string]any)["phase"] = phase
		doc["stage_progress"].(map[string]any)["phase"] = phase
		e.writeCheckpoint(id, doc)
		damaged, _ := os.ReadFile(e.runPath(id, "checkpoint.json"))
		r := e.resume(id)
		eq(t, phase+" exit", r.exit, 1)
		contains(t, phase, r.shown(), "resume_refused")
		if now, _ := os.ReadFile(e.runPath(id, "checkpoint.json")); string(now) != string(damaged) {
			t.Fatalf("%s: the checkpoint changed", phase)
		}
		if got := before(); !reflect.DeepEqual(got, was) {
			t.Fatalf("%s: custody changed", phase)
		}
		eq(t, phase+" requests", e.prov.count(), requests)
	}
	if err := os.WriteFile(e.runPath(id, "checkpoint.json"), original, 0o600); err != nil {
		t.Fatal(err)
	}
	_ = approval
	_, state := e.checkpoint(id)
	return id, state
}

func TestResumeRefusesPhaseClaimsInconsistentWithFinalWorkReviewerOwnershipOrLanding(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/stages_test.exs: Resume refuses phase claims inconsistent with final work, reviewer ownership or landing
	e, trace := stagedEnv(t, []string{"true"}, project.Check{Name: "whole", Run: "! grep -qx broken app.txt"})
	f := e.prov
	f.then(f.calls(stageWrite(f, "broken")...), f.calls(stageFinish()...), f.calls(stageFinish()...), refused())
	if a := e.build(); a.exit != 4 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	id, state := stagePhaseRefused(t, e, trace, "review", "landed")
	eq(t, "final phase", state["stage_progress"].(map[string]any)["phase"], any("final"))
	eq(t, "final stage", state["continuation"].(map[string]any)["stage"], any("builder"))

	f.then(f.calls(stageWrite(f, "ready")...), f.calls(stageFinish()...), refused())
	if r := e.resumeReviewed(id); r.exit != 4 {
		t.Fatalf("exit %d\n%s", r.exit, r.shown())
	}
	id, state = stagePhaseRefused(t, e, trace, "final", "landed")
	eq(t, "review phase", state["stage_progress"].(map[string]any)["phase"], any("review"))
	eq(t, "review stage", state["continuation"].(map[string]any)["stage"], any("review"))

	f.then(submit(f, "approve"))
	if r := e.resumeReviewed(id); r.exit != 0 {
		t.Fatalf("exit %d\n%s\n%s", r.exit, r.shown(), r.errs.String())
	}
	id, state = stagePhaseRefused(t, e, trace, "final", "review")
	eq(t, "landed phase", state["stage_progress"].(map[string]any)["phase"], any("landed"))
	r := e.resumeReviewed(id)
	eq(t, "landed exit", r.exit, 0)
	contains(t, "landed", r.out.String(), "already landed")
}

func TestInterruptingAStageGateRetainsNoCompletedEvidenceAndResumeRerunsSetupAndCommands(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/stages_test.exs: interrupting a stage gate retains no completed evidence and Resume reruns fresh setup and commands
	marker := filepath.Join(t.TempDir(), "stage-interrupted-marker")
	quoted := shellQuote(marker)
	e, trace := stagedEnv(t, []string{"if ! test -f " + quoted + "; then touch " + quoted + "; sleep 600; fi", "echo complete"})
	f := e.prov
	f.then(f.calls(stageWrite(f, "candidate")...), f.calls(stageFinish()...), refused())
	a, done := e.start()
	waitFor(t, marker)
	a.s.Interrupt("SIGINT")
	<-done
	eq(t, "exit", a.exit, 130)
	contains(t, "stdout", a.out.String(), "interrupted")
	id, _, state := e.stageCheckpoint()
	eq(t, "continuation", state["continuation"].(map[string]any)["stage"], any("builder_verify"))
	if list, _ := state["stage_evidence"].([]any); len(list) != 0 {
		t.Fatal("evidence of an interrupted gate")
	}
	eq(t, "completed", state["stage_progress"].(map[string]any)["completed"], any([]any{}))
	old, _ := os.ReadFile(e.runPath(id, "result.json"))
	r := e.resume(id)
	eq(t, "resume exit", r.exit, 4)
	contains(t, "progress", r.errs.String(), "kogen: stage foundation gate passed")
	_, _, resumed := e.stageCheckpoint()
	eq(t, "completed after resume", resumed["stage_progress"].(map[string]any)["completed"], any([]any{"foundation"}))
	eq(t, "records", len(resumed["stage_evidence"].([]any)), 1)
	eq(t, "setup runs", traceLines(t, trace), 3)
	now, _ := os.ReadFile(e.runPath(id, "result.json"))
	if string(now) != string(old) {
		t.Fatal("the interrupted run's result changed")
	}
}

func TestStageProgressOwnerClaimsAreCheckedAgainstTheSavedContinuation(t *testing.T) {
	t.Parallel()
	// ExUnit: test/kogen/stages_test.exs: stage navigation cannot claim builder work under another saved owner
	plan := []stageDef{{ID: "foundation", Title: "Foundation", Goal: "First", Checks: []string{"first"}}, {ID: "surface", Title: "Surface", Goal: "Integrate", Checks: []string{"third"}}}
	text := "# T\n\nSlug: fixture\n" + stagePlanText([]string{"first"})
	plan[0].Goal, plan[1].Goal = "First runnable section", "Integrated section"
	plan[1].Checks = []string{"true"}
	st := &State{IntentText: text, StagePlan: plan, StageProgress: initialProgress(plan), Config: &project.Config{}}
	valid := []Continuation{{Stage: StageStartup}, {Stage: StageBuilder}, {Stage: StageBuilderVerify}, {Stage: StageTool, Owner: "build"}}
	invalid := []Continuation{
		{Stage: StageReview}, {Stage: StageReviewVerify}, {Stage: StageReviewRetry}, {Stage: StageCommit}, {Stage: StageLanded},
		{Stage: StageTool, Owner: "review"}, {Stage: StageTool, Owner: "build", Request: true},
	}
	for _, c := range valid {
		s := *st
		s.Continuation = c
		if !s.stagesValid() {
			t.Fatalf("%+v refused", c)
		}
	}
	for _, c := range invalid {
		s := *st
		s.Continuation = c
		if s.stagesValid() {
			t.Fatalf("%+v accepted", c)
		}
	}
}

func TestAnUnstagedBuildKeepsNoStageState(t *testing.T) {
	t.Parallel()
	// ExUnit: test/kogen/stages_test.exs: absent plan is unchanged
	e := newEnv(t)
	f := e.prov
	f.then(f.calls(stageFinish()...))
	a := e.build()
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	doc, state := e.checkpoint(e.onlyRun())
	for _, k := range []string{"stage_plan", "stage_progress", "stage_evidence"} {
		if _, ok := state[k]; ok {
			t.Fatalf("state has %s", k)
		}
		if _, ok := doc[k]; ok {
			t.Fatalf("envelope has %s", k)
		}
	}
	lacks(t, "progress", a.errs.String(), "kogen: stage ")
	lacks(t, "opening", requestText(e.prov.requests()[0]), "Staged plan progress")
	res := e.result(e.onlyRun())
	if _, ok := res["stage_progress"]; ok {
		t.Fatal("result has stage_progress")
	}
	eq(t, "recovery_raw", doc["recovery_raw"], nil)
}

func TestAStagedBuildGivesTheBuilderItsNavigationAndKeepsInstructionsFrozen(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/stages_test.exs (navigation reaches the builder in the opening message and with each passed stage)
	e, _ := stagedEnv(t, []string{"true"})
	f := e.prov
	f.then(f.calls(stageWrite(f, "one")...), f.calls(stageFinish()...), f.calls(stageFinish()...), submit(f, "approve"))
	a := e.reviewed()
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s\n%s", a.exit, a.shown(), a.errs.String())
	}
	reqs := f.requests()
	opening := requestText(reqs[0])
	contains(t, "opening", opening, `Staged plan progress: {\"active\":\"foundation\",\"completed\":[],\"phase\":\"stage\",\"total\":2}`)
	contains(t, "opening", opening, "Active stage 1/2: ")
	var instructions []string
	for _, req := range reqs {
		if requestInstructions(req) == agent.Prompt(agent.Builder) {
			instructions = append(instructions, requestInstructions(req))
		}
	}
	if len(instructions) < 3 {
		t.Fatalf("builder requests %d", len(instructions))
	}
	for _, in := range instructions {
		eq(t, "instructions", in, instructions[0])
	}
	// The next stage's navigation answers the builder's finish call.
	var passed string
	for _, out := range f.toolOutputs() {
		if strings.HasPrefix(out, "Stage foundation passed. Continue the next stage. ") {
			passed = out
		}
	}
	if passed == "" {
		t.Fatalf("no navigation answer in %q", f.toolOutputs())
	}
	contains(t, "answer", passed, `"active":"surface"`)
	contains(t, "answer", passed, "Historical stage evidence: ")
	// The reviewer is told that stage evidence is historical, in its own leading message.
	reviews := f.reviewRequests()
	if len(reviews) == 0 {
		t.Fatal("no review request")
	}
	contains(t, "review", requestText(reviews[0]), "All scoped stages completed. Continue whole-Intent review.")
	contains(t, "review", requestText(reviews[0]), "Stage evidence is historical for its recorded tree, not current whole-Intent proof.")
}

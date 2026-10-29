package build

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"kogen-loop/provider"
	agent "kogen-loop/tools"
	"kogen/executor"
	"kogen/project"
)

// useExternalReviewer puts only the review role on the external executor; the builder stays
// native (an external builder's checkpoint is never resumed).
func (e *env) useExternalReviewer() {
	e.t.Helper()
	path := filepath.Join(e.root, ".kogen/project.yaml")
	b, err := os.ReadFile(path)
	if err != nil {
		e.t.Fatal(err)
	}
	review := regexp.MustCompile(`(?m)^  review:\n(    .*\n)+`)
	writeFile(e.t, path, review.ReplaceAllString(string(b), "  review:\n    executor: claude-code\n    model: claude-opus-5-5\n    effort: xhigh\n"), 0o644)
	e.run("git", "add", ".kogen/project.yaml")
	e.run("git", "commit", "-qm", "claude-code review")
	e.approve()
}

func withLineupResume(f *lineupExec) func(*ResumeInput) {
	return func(in *ResumeInput) {
		in.External = func(project.Role) (executor.Executor, error) { return f, nil }
		in.Reviewer = nil
	}
}

func (e *env) checkpointStage(id string) string {
	_, state := e.checkpoint(id)
	s, _ := state["continuation"].(map[string]any)["stage"].(string)
	return s
}

// stopNatively builds until two reviews ended without a verdict, in this process.
func (e *env) stopNatively() (string, *attempt) {
	e.t.Helper()
	f := e.prov
	f.then(landScript(f)...)
	f.then(prose("a"), prose("b"), prose("c"), prose("d"))
	a := e.reviewed()
	wantStop(e.t, a, "candidate/review_invalid")
	return e.onlyRun(), a
}

// TestKReviewRetrySafetyBoundaries: retry consumption and the separate counters survive
// checkpoints; native and external fresh reviews keep their delivery rules; only a completed
// review of the exact green tree gets the new treatment; blockers are not invalid
// reviews; and no limit, timeout or option was raised.
func TestKReviewRetrySafetyBoundaries(t *testing.T) {
	t.Run("consumption and counters survive a checkpoint", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		f := e.prov
		f.then(landScript(f)...)
		opened := make(chan struct{})
		// Review 1: both turns prose. Review 2 (its automatic retry): one prose turn, then the
		// forced reminder request hangs and the Build is interrupted.
		f.then(prose("a"), prose("b"), prose("c"), hang(opened))
		a, done := e.startReviewed()
		<-opened
		a.s.Interrupt("SIGINT")
		<-done
		eq(t, "exit", a.exit, 130)
		id := e.onlyRun()
		cont, session := sessionOfRun(t, e, id)
		eq(t, "stage", cont["stage"], any("review"))
		eq(t, "no-tool counter in the checkpoint", session["no_tool_reminders"], any(float64(1)))
		eq(t, "pending reminder choice in the checkpoint", session["remind"], any(true))
		if session["rejected_verdicts"] != nil {
			t.Fatalf("rejected counter %v", session["rejected_verdicts"])
		}
		_, state := e.checkpoint(id)
		rr := state["review_retry"].(map[string]any)
		eq(t, "automatic retry already spent", rr["automatic"], any(true))
		eq(t, "review in progress", state["review"], any(float64(2)))
		reqs := f.reviewRequests()
		eq(t, "interrupted request was the reminder", reqs[3]["tool_choice"], any(forcedSubmit))

		// The resumed request is still the reminder; one more prose turn spends the no-tool
		// allowance of review 2 and, the automatic retry being spent, no review 3 starts.
		f.replace(prose("again"))
		r := e.resumeReviewed(id)
		wantStop(t, r, "candidate/review_invalid")
		reqs = f.reviewRequests()
		eq(t, "review requests: no review 3", len(reqs), 5)
		eq(t, "resumed request", reqs[4]["tool_choice"], any(forcedSubmit))
		resumed := e.runIDs()
		var second string
		for _, run := range resumed {
			if run != id {
				second = run
			}
		}
		eq(t, "stage", e.checkpointStage(second), "review_only")
		verdicts := e.reviewVerdicts(second)
		eq(t, "invalid event", len(verdicts), 1)
		eq(t, "review", verdicts[0]["review"], any(float64(2)))
		eq(t, "counters", counters(verdicts[0]), [2]float64{0, 1})
		eq(t, "reviews", e.result(second)["reviews"], any(float64(2)))
	})

	t.Run("a reviewer that used edit tools without changing anything still gets its one fresh review", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		f := e.prov
		f.then(landScript(f)...)
		f.then(f.calls("shell", map[string]any{"command": "true"}), prose("a"), prose("b"), submit(f, "approve"))
		a := e.reviewed()
		eq(t, "exit", a.exit, 0)
		id := e.onlyRun()
		eq(t, "review requests: the fresh review ran", len(f.reviewRequests()), 4)
		only := eventsNamed(e.events(id), "review_only")
		eq(t, "review-only events", len(only), 1)
		eq(t, "eligible", only[0]["eligible"], any(true))
		eq(t, "retry events", len(eventsNamed(e.events(id), "review_retry")), 1)
		eq(t, "nothing to discard", len(eventsNamed(e.events(id), "review_edits_discarded")), 0)
	})

	t.Run("a review-only checkpoint refuses stale or drifted custody", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		id, _ := e.stopNatively()
		eq(t, "stage", e.checkpointStage(id), StageReviewOnly)
		doc, state := e.checkpoint(id)
		raw, err := os.ReadFile(e.runPath(id, "checkpoint.json"))
		if err != nil {
			t.Fatal(err)
		}
		indexPath := filepath.Join(e.root, ".git", "index")
		index, err := os.ReadFile(indexPath)
		if err != nil {
			t.Fatal(err)
		}
		restoreIndex := func() {
			if err := os.WriteFile(indexPath, index, 0o644); err != nil {
				t.Fatal(err)
			}
		}
		approvalPath := project.ApprovalPath(e.root, testSlug)
		approval, _ := os.ReadFile(approvalPath)
		featurePath := filepath.Join(e.root, project.FeaturePath(testSlug))
		tamper := func(edit func(cont map[string]any)) {
			cont := state["continuation"].(map[string]any)
			edit(cont)
			doc["state"] = state
			e.writeCheckpoint(id, doc)
		}
		restoreCheckpoint := func() {
			if err := os.WriteFile(e.runPath(id, "checkpoint.json"), raw, 0o600); err != nil {
				t.Fatal(err)
			}
		}
		// Each drift is applied, the real resume refuses it without touching anything, and the
		// drift is undone before the next one: the checkout is the stopped one again each time.
		for _, drift := range []struct {
			name        string
			apply, undo func()
		}{
			{"HEAD moved", func() { e.run("git", "commit", "-q", "--allow-empty", "-m", "elsewhere") }, func() { e.run("git", "reset", "-q", "--soft", "HEAD~1"); restoreIndex() }},
			{"index", func() { e.write("staged.txt", "x\n"); e.run("git", "add", "staged.txt") }, func() {
				os.Remove(filepath.Join(e.root, "staged.txt"))
				restoreIndex()
			}},
			{"approval", func() { writeFile(t, approvalPath, string(approval)+"\n", 0o644) }, func() { writeFile(t, approvalPath, string(approval), 0o644) }},
			{"protected baseline", func() { writeFile(t, featurePath, testFeature+"\n", 0o644) }, func() { writeFile(t, featurePath, testFeature, 0o644) }},
			{"candidate", func() { e.write("app.txt", "drifted\n") }, func() { e.write("app.txt", "candidate\n") }},
			{"candidate mode", func() { os.Chmod(filepath.Join(e.root, "app.txt"), 0o755) }, func() { os.Chmod(filepath.Join(e.root, "app.txt"), 0o644) }},
			{"stale green evidence", func() {
				tamper(func(cont map[string]any) { cont["pass"].(map[string]any)["green"] = false })
			}, restoreCheckpoint},
			{"another pass's tree", func() {
				tamper(func(cont map[string]any) { cont["pass"].(map[string]any)["tree"] = strings.Repeat("0", 40) })
			}, restoreCheckpoint},
			{"tool boundary", func() {
				state["continuation"] = map[string]any{"stage": "tool", "owner": "review"}
				doc["state"] = state
				e.writeCheckpoint(id, doc)
			}, restoreCheckpoint},
		} {
			drift.apply()
			before, requests := e.snapshot(), e.prov.count()
			r := e.resumeReviewed(id)
			if r.exit != 1 || !strings.Contains(r.shown(), "candidate/") {
				t.Fatalf("%s: exit %d, want a refusal\n%s", drift.name, r.exit, r.shown())
			}
			eq(t, drift.name+": provider requests", e.prov.count(), requests)
			after := e.snapshot()
			eq(t, drift.name+": files", after.files, before.files)
			eq(t, drift.name+": index", after.index, before.index)
			eq(t, drift.name+": HEAD", after.head, before.head)
			eq(t, drift.name+": approval", after.approval, before.approval)
			eq(t, drift.name+": runs", after.runs, before.runs)
			eq(t, drift.name+": no commit", e.commitsSince(before.head), "0")
			drift.undo()
			// Reload the state the undo restored (the checkpoint bytes themselves).
			doc, state = e.checkpoint(id)
		}
		// With everything undone the same checkpoint resumes: the refusals were the drifts'.
		e.prov.then(submit(e.prov, "approve"))
		if r := e.resumeReviewed(id); r.exit != 0 {
			t.Fatalf("control resume exit %d\n%s\n%s", r.exit, r.shown(), r.errs)
		}
	})

	t.Run("a substantive blocker is not an invalid review", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		f := e.prov
		f.then(landScript(f)...)
		f.then(submit(f, "changes", finding("blocking", "app.txt is wrong")))
		a := e.reviewed()
		wantStop(t, a, "candidate/review_blocked")
		id := e.onlyRun()
		eq(t, "review requests", len(f.reviewRequests()), 1)
		for _, name := range []string{"review_retry", "review_only"} {
			eq(t, name+" events", len(eventsNamed(e.events(id), name)), 0)
		}
		if e.checkpointStage(id) == StageReviewOnly {
			t.Fatal("a blocker produced a review-only checkpoint")
		}
		// The explicit resume reopens the blocker with the same reviewer. If that reopened review
		// then ends without a verdict, no fresh review may stand in for the blocker's decision.
		f.then(prose("a"), prose("b"))
		r := e.resumeReviewed(id)
		wantStop(t, r, "candidate/review_invalid")
		eq(t, "review requests: no fresh review", len(f.reviewRequests()), 3)
		second := ""
		for _, run := range e.runIDs() {
			if run != id {
				second = run
			}
		}
		only := eventsNamed(e.events(second), "review_only")
		eq(t, "review-only events", len(only), 1)
		eq(t, "eligible", only[0]["eligible"], any(false))
		contains(t, "why", only[0]["why"].(string), "blocked review")
		eq(t, "reviews", e.result(second)["reviews"], any(float64(1)))
		if e.checkpointStage(second) == StageReviewOnly {
			t.Fatal("a reopened blocker produced a review-only checkpoint")
		}
	})

	t.Run("an external reviewer: fresh sessions keep delivery rules and a review-only resume starts another", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		e.useExternalReviewer()
		f := e.prov
		f.then(landScript(f)...)
		x := newLineupExec(t)
		x.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
			// Every round of the first two sessions is invalid; the explicit resume's session approves.
			if len(x.starts[executor.RoleReview]) >= 3 {
				return executor.RoundResult{Structured: verdictJSON("approve"), Usage: harnessUsage(10, 5, 2, 0.01)}, nil
			}
			return executor.RoundResult{Structured: verdictJSON("approve", blockingFinding), Usage: harnessUsage(10, 5, 2, 0.01)}, nil
		}
		start := e.head()
		a := e.build(withLineup(x))
		wantStop(t, a, "candidate/review_invalid")
		id := e.onlyRun()
		eq(t, "sessions", len(x.starts[executor.RoleReview]), 2)
		tasks := x.starts[executor.RoleReview]
		eq(t, "same material and rules", tasks[1].Brief, tasks[0].Brief)
		eq(t, "same model", []string{tasks[1].Model, tasks[1].Effort}, []string{tasks[0].Model, tasks[0].Effort})
		eq(t, "stage", e.checkpointStage(id), StageReviewOnly)
		// Each review's retained material was delivered in its own completed session round.
		dir := filepath.Join(e.root, ".kogen/local/runs", id, "executor-review")
		for _, n := range []string{"1", "2"} {
			m := e.jsonFile(filepath.Join(dir, "review-"+n+"-material.json"))
			eq(t, "review "+n+" delivered", m["delivered"], any(true))
		}
		m1, m2 := e.jsonFile(filepath.Join(dir, "review-1-material.json")), e.jsonFile(filepath.Join(dir, "review-2-material.json"))
		eq(t, "same authority bytes", m2["authority"].(map[string]any)["sha256"], m1["authority"].(map[string]any)["sha256"])
		eq(t, "same source bytes", m2["source"].(map[string]any)["sha256"], m1["source"].(map[string]any)["sha256"])
		if m1["session_id"] == m2["session_id"] {
			t.Fatal("review 2 reused the invalid session")
		}
		eq(t, "builder rounds", len(x.rounds(executor.RoleBuild)), 0)
		// An external executor's reminder is text only, and the log says so.
		for _, ev := range eventsNamed(e.events(id), "review_tool_choice") {
			eq(t, "external mode", ev["mode"], any("text_fallback"))
			eq(t, "external executor", ev["executor"], any("claude-code"))
		}
		if len(eventsNamed(e.events(id), "review_tool_choice")) != 2 {
			t.Fatal("each external session's correction is logged")
		}
		contains(t, "text correction", x.rounds(executor.RoleReview)[1].Feedback, "Not a valid verdict:")

		// The explicit resume: no resume capability is needed, a third fresh session is started.
		r := e.resume(id, withLineupResume(x))
		if r.exit != 0 {
			t.Fatalf("resume exit %d\n%s", r.exit, r.shown())
		}
		eq(t, "sessions", len(x.starts[executor.RoleReview]), 3)
		eq(t, "commits", e.commitsSince(start), "1")
		eq(t, "committed", e.gitOut("show", "HEAD:app.txt"), "candidate")
		eq(t, "builder rounds", len(x.rounds(executor.RoleBuild)), 0)
		var second string
		for _, run := range e.runIDs() {
			if run != id {
				second = run
			}
		}
		res := e.result(second)
		eq(t, "reviews", res["reviews"], any(float64(3)))
		usage := res["review_executor"].(map[string]any)["usage"].(map[string]any)
		eq(t, "cumulative known reviewer usage", usage["input"], any(float64(50)))
	})

	t.Run("no limit, timeout or option was raised", func(t *testing.T) {
		eq(t, "response budget", provider.ResponseBudget, 30*time.Minute)
		eq(t, "request ceiling", agent.InputBudgetBytes, 524288)
		eq(t, "output reserve", agent.OutputReserveTokens, 131072)
		eq(t, "api forcing needs a supporting route", provider.SupportsToolChoice(provider.Role{Provider: "anthropic", Model: "claude-sonnet-5-5"}), false)
		eq(t, "compatible hosts force through Chat Completions tool_choice", provider.SupportsToolChoice(provider.Role{Provider: "openai-compatible", Model: "local"}), true)
	})
}

var unreadOfApproval = regexp.MustCompile(`before approving: (\d+) unread part`)

// unreadIn is the unread count a native approval rejection names.
func unreadIn(problem string) int {
	n, _ := strconv.Atoi(unreadOfApproval.FindStringSubmatch(problem + " before approving: 0 unread part")[1])
	return n
}

package build

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"kogen-loop/sys"
	"kogen/executor"
	"kogen/project"
)

// An external executor's builder no longer blocks resuming a review stage, and a stopped
// external review resumes as one fresh review of the green pass it started from.

func cpContinuation(e *env, id string) map[string]any {
	_, state := e.checkpoint(id)
	c, _ := state["continuation"].(map[string]any)
	return c
}

// redReviewer edits app.txt to a red tree and approves it in every round.
func redReviewer(t *testing.T) func(int, string, executor.Input, executor.Task) (executor.RoundResult, error) {
	return func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
		lineupWriteApp(t, root, "red\n")
		return executor.RoundResult{Structured: verdictJSON("approve")}, nil
	}
}

func TestExternalReviewCheckpointsRecordTheGreenBase(t *testing.T) {
	t.Parallel()
	t.Run("an external review keeps its base through failed repairs", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		e.useLineup("    max_rounds: 2\n")
		f := newLineupExec(t)
		f.review = redReviewer(t)
		wantStop(t, e.build(withLineup(f)), "candidate/executor_round_limit")
		c := cpContinuation(e, e.onlyRun())
		eq(t, "stage", c["stage"], any("review_verify"))
		base, pass := c["base"].(map[string]any), c["pass"].(map[string]any)
		if base == nil || base["green"] != true {
			t.Fatalf("no green base: %v", c)
		}
		if pass["green"] == true || pass["n"] == base["n"] || pass["tree"] == base["tree"] {
			t.Fatalf("the current pass is not a later red pass: base %v pass %v", base, pass)
		}
	})
	t.Run("a native review has no base", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		f := e.prov
		f.then(landScript(f)...)
		f.then(submit(f, "changes", finding("blocking", "app.txt is wrong")))
		wantStop(t, e.reviewed(), "candidate/review_blocked")
		if _, ok := cpContinuation(e, e.onlyRun())["base"]; ok {
			t.Fatal("a native review checkpoint carries a base")
		}
	})
}

func TestExternalReviewResumeStartsOneFreshReviewOfTheBase(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	e.useLineup("    max_rounds: 2\n")
	start := e.head()
	f := newLineupExec(t)
	f.review = redReviewer(t)
	wantStop(t, e.build(withLineup(f)), "candidate/executor_round_limit")
	id := e.onlyRun()
	eq(t, "stopped review's edit", e.read("app.txt"), "red\n")
	parent := e.result(id)

	g := newLineupExec(t)
	g.build = func(n int, root string, in executor.Input) (executor.RoundResult, error) {
		t.Error("a resumed review stage ran the builder")
		return executor.RoundResult{}, executor.Fail(executor.ReasonProtocol, "builder")
	}
	g.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
		return executor.RoundResult{Structured: verdictJSON("approve")}, nil
	}
	r := e.resume(id, func(in *ResumeInput) {
		in.External = func(project.Role) (executor.Executor, error) { return g, nil }
		in.Reviewer = nil
	})
	eq(t, "resume exit", r.exit, 0)
	out := r.out.String()
	contains(t, "stdout", out, "review 1 by executor claude-code cannot be continued (resume capability: none); starting fresh review 2 of the green candidate verified in pass 1, with no builder round and no rerun of its checks")
	contains(t, "stdout", out, "discarded review 1's uncommitted edits, which are not part of that green candidate: app.txt")
	eq(t, "landed app.txt", e.gitOut("show", "HEAD:app.txt"), "candidate")
	eq(t, "commits", e.gitOut("rev-list", "--count", start+"..HEAD"), "1")
	eq(t, "review sessions", len(g.starts[executor.RoleReview]), 1)
	eq(t, "builder sessions", len(g.starts[executor.RoleBuild]), 0)
	eq(t, "no native request", e.prov.count(), 0)
	child := ""
	for _, other := range e.runIDs() {
		if other != id {
			child = other
		}
	}
	res := e.result(child)
	eq(t, "passes rerun", res["passes"], parent["passes"])
	eq(t, "reviews", res["reviews"], any(float64(2)))
	discarded := eventsNamed(e.events(child), "review_edits_discarded")
	eq(t, "discard events", len(discarded), 1)
	eq(t, "discarded review", discarded[0]["review"], any(float64(1)))
}

func TestExternalReviewResumeRefusals(t *testing.T) {
	t.Parallel()
	t.Run("a checkpoint without a complete green base is refused", func(t *testing.T) {
		t.Parallel()
		for name, mutate := range map[string]func(c map[string]any){
			"absent":    func(c map[string]any) { delete(c, "base") },
			"not green": func(c map[string]any) { c["base"].(map[string]any)["green"] = false },
		} {
			t.Run(name, func(t *testing.T) {
				t.Parallel()
				e := newEnv(t)
				e.useLineup("    max_rounds: 2\n")
				f := newLineupExec(t)
				f.review = redReviewer(t)
				wantStop(t, e.build(withLineup(f)), "candidate/executor_round_limit")
				id := e.onlyRun()
				doc, state := e.checkpoint(id)
				mutate(state["continuation"].(map[string]any))
				e.writeCheckpoint(id, doc)
				before, _ := os.ReadFile(e.runPath(id, "checkpoint.json"))
				g := newLineupExec(t)
				r := e.resume(id, func(in *ResumeInput) {
					in.External = func(project.Role) (executor.Executor, error) { return g, nil }
					in.Reviewer = nil
				})
				se := wantRefused(t, r)
				contains(t, "refusal", se, "review 1 by executor claude-code cannot be continued (resume capability: none) and this checkpoint records no complete green pass that review started from")
				after, _ := os.ReadFile(e.runPath(id, "checkpoint.json"))
				if string(after) != string(before) || e.read("app.txt") != "red\n" || len(e.runIDs()) != 1 || len(g.starts[executor.RoleReview]) != 0 {
					t.Fatal("the refused resume changed something")
				}
			})
		}
	})
	t.Run("a blocker at review_retry_verify is refused", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		e.useLineup("")
		f := newLineupExec(t)
		f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
			return executor.RoundResult{Structured: verdictJSON("changes", blockingFinding)}, nil
		}
		wantStop(t, e.build(withLineup(f)), "candidate/review_blocked")
		id := e.onlyRun()
		doc, state := e.checkpoint(id)
		state["continuation"].(map[string]any)["stage"] = "review_retry_verify"
		e.writeCheckpoint(id, doc)
		r := e.resume(id, func(in *ResumeInput) {
			in.External = func(project.Role) (executor.Executor, error) { return f, nil }
			in.Reviewer = nil
		})
		contains(t, "refusal", wantRefused(t, r), "ended with a blocking finding that only that reviewer's own new decision can clear")
	})
}

// wantRefused asserts candidate/resume_refused and returns its detail.
func wantRefused(t *testing.T, a *attempt) string {
	t.Helper()
	se, ok := sys.AsError(a.err)
	if !ok || se.Class != "candidate" || se.Reason != "resume_refused" {
		t.Fatalf("error %v\n%s", a.err, a.shown())
	}
	return se.Detail
}

// A claude-code builder with a native reviewer, stopped while the reviewer's approved repair is
// verified finally: the builder has finished, so the resume lands the repair as a native
// Build's does, without a builder session or a new request.
func TestExternalBuilderReviewStageResumes(t *testing.T) {
	t.Parallel()
	paused := filepath.Join(t.TempDir(), "paused")
	e := newEnv(t, func(c *project.Config) {
		c.Checks = []project.Check{{Name: "pause", Run: "if grep -qx 'reviewer repair' app.txt && ! test -f '" + paused + "'; then touch '" + paused + "'; sleep 600; fi"}}
	})
	e.useExecutor("")
	fx := newFakeExecutor(t, externalWritesApp("candidate\n", harnessUsage(1, 0, 1, 0)))
	p := e.prov
	p.then(p.calls(append(writeApp("reviewer repair\n"), "submit_review", map[string]any{"verdict": "approve", "findings": []any{}})...))
	a, done := e.start(func(in *Input) {
		in.External = func(project.Role) (executor.Executor, error) { return fx, nil }
		in.Reviewer = nil
	})
	for i := 0; i < 2400; i++ {
		if _, err := os.Stat(paused); err == nil {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if _, err := os.Stat(paused); err != nil {
		t.Fatal("the final verification never started")
	}
	a.s.Interrupt("SIGTERM")
	<-done
	id := e.onlyRun()
	eq(t, "stage", cpContinuation(e, id)["stage"], any("review_verify"))
	requests, builds := p.count(), len(fx.tasks)
	r := e.resume(id, func(in *ResumeInput) {
		in.External = func(project.Role) (executor.Executor, error) { return fx, nil }
		in.Reviewer = nil
	})
	eq(t, "resume exit", r.exit, 0)
	if !strings.Contains(r.out.String(), "landed fixture ") {
		t.Fatalf("not landed:\n%s", r.shown())
	}
	eq(t, "landed app.txt", e.gitOut("show", "HEAD:app.txt"), "reviewer repair")
	eq(t, "new requests", p.count()-requests, 0)
	eq(t, "new builder sessions", len(fx.tasks)-builds, 0)
}

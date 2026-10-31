package build

import (
	"strings"
	"testing"
)

// repairThenApprove is a review that repairs app.txt to a tree the fixture's checks reject and
// approves it: the final verification is red and goes back to the same reviewer.
func repairThenApprove(f *fakeProvider) handler {
	return f.calls(append(writeApp("red\n"), "submit_review", map[string]any{"verdict": "approve", "findings": []any{}})...)
}

func rejectedApprove(f *fakeProvider) handler {
	return submit(f, "approve", finding("blocking", "An approve verdict cannot contain a blocking finding."))
}

func (e *env) childRun(parent string) string {
	e.t.Helper()
	for _, id := range e.runIDs() {
		if id != parent {
			return id
		}
	}
	e.t.Fatal("no resumed run")
	return ""
}

// TestKReviewInvalidResumeRepaired: a native review that had repaired (its own pass is red) and
// then ended without a valid verdict stops with a review-only checkpoint of the builder's green
// pass, and its resume lands that candidate after one fresh review, with no new pass.
func TestKReviewInvalidResumeRepaired(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	f := e.prov
	f.then(landScript(f)...)
	f.then(repairThenApprove(f), rejectedApprove(f), rejectedApprove(f))
	start := e.head()
	wantStop(t, e.reviewed(), "candidate/review_invalid")
	id := e.onlyRun()

	eq(t, "stage", e.checkpointStage(id), StageReviewOnly)
	cont, _ := sessionOfRun(t, e, id)
	pass := cont["pass"].(map[string]any)
	eq(t, "the checkpoint pass is the builder's pass 1", pass["n"], any(float64(1)))
	eq(t, "green", pass["green"], any(true))
	_, state := e.checkpoint(id)
	rr := state["review_retry"].(map[string]any)
	eq(t, "retry record tree", rr["tree"], pass["tree"])
	invalid := rr["invalid"].([]any)
	eq(t, "the review is the only invalid one", len(invalid), 1)
	eq(t, "next", invalid[0].(map[string]any)["next"], any("stop"))
	only := eventsNamed(e.events(id), "review_only")
	eq(t, "review-only events", len(only), 1)
	eq(t, "eligible", only[0]["eligible"], any(true))
	eq(t, "tree", only[0]["tree"], pass["tree"])
	eq(t, "no automatic fresh review for a review that repaired", len(eventsNamed(e.events(id), "review_retry")), 0)
	eq(t, "the reviewer's repair is left in place", e.read("app.txt"), "red\n")
	eq(t, "head", e.head(), start)

	f.then(submit(f, "approve", finding("note", "fine")))
	r := e.resumeReviewed(id)
	if r.exit != 0 {
		t.Fatalf("resume exit %d\n%s", r.exit, r.shown())
	}
	contains(t, "stdout", r.shown(), "discarded review 1's uncommitted edits, which are not part of that green candidate: app.txt")
	child := e.childRun(id)
	discarded := eventsNamed(e.events(child), "review_edits_discarded")
	eq(t, "discard events", len(discarded), 1)
	eq(t, "discard tree", discarded[0]["tree"], pass["tree"])
	eq(t, "retry events", len(eventsNamed(e.events(child), "review_retry")), 1)
	eq(t, "committed app.txt", e.gitOut("show", "HEAD:app.txt"), "candidate")
	eq(t, "commits", e.commitsSince(start), "1")
	res := e.result(child)
	eq(t, "no new pass", res["passes"], e.result(id)["passes"])
	eq(t, "reviews", res["reviews"], any(float64(2)))
}

// TestKReviewInvalidResumeNativeBase: an interrupted native review that had repaired resumes
// from its checkpoint with the recorded base and, ending without a valid verdict, stops with a
// review-only checkpoint of pass 1. A checkpoint written before the base was recorded gives a
// repaired session no base: nothing is saved but the review checkpoint.
func TestKReviewInvalidResumeNativeBase(t *testing.T) {
	t.Parallel()
	interrupted := func(t *testing.T) (*env, string) {
		e := newEnv(t)
		f := e.prov
		f.then(landScript(f)...)
		opened := make(chan struct{})
		f.then(repairThenApprove(f), hang(opened))
		a, done := e.startReviewed()
		<-opened
		a.s.Interrupt("SIGINT")
		<-done
		eq(t, "exit", a.exit, 130)
		id := e.onlyRun()
		cont, session := sessionOfRun(t, e, id)
		eq(t, "stage", cont["stage"], any("review"))
		eq(t, "repaired", session["repaired"], any(true))
		base := cont["base"].(map[string]any)
		eq(t, "base is the builder's pass", base["n"], any(float64(1)))
		pass := cont["pass"].(map[string]any)
		if pass["green"] == true {
			t.Fatalf("the current pass is not the red repair: %v", pass)
		}
		return e, id
	}

	t.Run("the recorded base survives the resume", func(t *testing.T) {
		t.Parallel()
		e, id := interrupted(t)
		f := e.prov
		f.replace(rejectedApprove(f))
		f.then(rejectedApprove(f))
		wantStop(t, e.resumeReviewed(id), "candidate/review_invalid")
		child := e.childRun(id)
		eq(t, "stage", e.checkpointStage(child), StageReviewOnly)
		cont, _ := sessionOfRun(t, e, child)
		eq(t, "the checkpoint pass is pass 1", cont["pass"].(map[string]any)["n"], any(float64(1)))
		only := eventsNamed(e.events(child), "review_only")
		eq(t, "eligible", only[len(only)-1]["eligible"], any(true))
	})

	t.Run("a repaired session without a recorded base has none", func(t *testing.T) {
		t.Parallel()
		e, id := interrupted(t)
		doc, state := e.checkpoint(id)
		delete(state["continuation"].(map[string]any), "base")
		doc["state"] = state
		e.writeCheckpoint(id, doc)
		f := e.prov
		f.replace(rejectedApprove(f))
		f.then(rejectedApprove(f))
		wantStop(t, e.resumeReviewed(id), "candidate/review_invalid")
		child := e.childRun(id)
		if stage := e.checkpointStage(child); stage == StageReviewOnly {
			t.Fatalf("a review-only checkpoint without a base: stage %q", stage)
		}
		only := eventsNamed(e.events(child), "review_only")
		eq(t, "review-only events", len(only), 1)
		eq(t, "eligible", only[0]["eligible"], any(false))
		if why, _ := only[0]["why"].(string); !strings.Contains(why, "already had a verdict judged") {
			t.Fatalf("why = %q", why)
		}
	})
}

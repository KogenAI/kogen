package build

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"kogen-loop/sys"
	"kogen/verify"
)

// scriptedReviewer stands in for the independent review: it records what it is given.
type scriptedReviewer struct {
	review func(ctx context.Context, b *Attempt, pass verify.Pass) (Approved, error)
	resume func(ctx context.Context, b *Attempt) (Approved, error)
	passes []verify.Pass
}

func (r *scriptedReviewer) Review(ctx context.Context, b *Attempt, pass verify.Pass) (Approved, error) {
	r.passes = append(r.passes, pass)
	return r.review(ctx, b, pass)
}

func (r *scriptedReviewer) Resume(ctx context.Context, b *Attempt) (Approved, error) {
	return r.resume(ctx, b)
}

func approve(b *Attempt, pass verify.Pass) Approved {
	b.Review++
	rec := ReviewRecord{N: b.Review, Verdict: "approve", Tree: pass.Tree, Findings: []map[string]any{
		{"severity": "note", "path": "app.txt", "line": float64(1), "message": "looks fine"},
		{"severity": "note", "path": "README.md", "line": nil, "message": "second"},
	}}
	b.LastReview = &rec
	return Approved{Pass: pass, Review: rec}
}

func TestTheReviewHookRunsAfterAGreenPassAndItsApprovalIsCommitted(t *testing.T) {
	// ExUnit: lib/kogen/build.ex verify_and_review/1 (a green pass goes to review; an approved candidate is committed)
	e := newEnv(t)
	e.prov.then(landScript(e.prov)...)
	rev := &scriptedReviewer{review: func(ctx context.Context, b *Attempt, pass verify.Pass) (Approved, error) {
		return approve(b, pass), nil
	}}
	a := e.build(func(in *Input) { in.Reviewer = rev })
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	if len(rev.passes) != 1 || !rev.passes[0].Green || rev.passes[0].N != 1 {
		t.Fatalf("passes %v", rev.passes)
	}
	out := a.out.String()
	contains(t, "stdout", out, "  review: approved, 2 note(s)\n  note: app.txt:1: looks fine\n  note: README.md:: second\n")
}

func TestAReviewThatBlocksStopsTheBuildWithoutACommit(t *testing.T) {
	// ExUnit: lib/kogen/review.ex evaluate/8 (an unresolved blocker ends the Build instead of restarting the builder)
	e := newEnv(t)
	e.prov.then(landScript(e.prov)...)
	rev := &scriptedReviewer{review: func(ctx context.Context, b *Attempt, pass verify.Pass) (Approved, error) {
		b.Review++
		b.LastReview = &ReviewRecord{N: b.Review, Verdict: "changes", Tree: pass.Tree, Findings: []map[string]any{
			{"severity": "blocking", "path": "app.txt", "line": float64(1), "message": "wrong"}}}
		e := sys.Fail("candidate", "review_blocked", "the reviewer could not resolve a substantive blocker within the approved Intent; edits are left in place", 1)
		e.Lines = []string{"review: app.txt:1: wrong"}
		return Approved{}, e
	}}
	start := e.head()
	a := e.build(func(in *Input) { in.Reviewer = rev })
	eq(t, "exit", a.exit, 1)
	out := a.out.String()
	contains(t, "stdout", out, "failed fixture: review_blocked (Build "+e.onlyRun()+")\ncandidate/review_blocked: ")
	contains(t, "stdout", out, "  review: app.txt:1: wrong\n")
	contains(t, "stdout", out, "  still failing: review\n")
	eq(t, "head", e.head(), start)
	facts := e.jsonFile(e.root + "/.kogen/local/facts/" + e.onlyRun() + ".json")
	blockers := facts["blockers"].([]any)
	if len(blockers) != 1 || blockers[0].(map[string]any)["paths"].([]any)[0] != "app.txt" {
		t.Fatalf("blockers %v", blockers)
	}
	eq(t, "resume_status", facts["resume_status"], any("potentially_available"))
}

func TestAResumeInAReviewStageContinuesWithTheReviewer(t *testing.T) {
	// ExUnit: test/integration/build_boundaries_test.exs: resuming pending reviewer verification keeps repairs with the reviewer (the Build side)
	e := newEnv(t)
	e.prov.then(landScript(e.prov)...)
	session := json.RawMessage(`{"input":[{"role":"user","content":"review"}]}`)
	rev := &scriptedReviewer{review: func(ctx context.Context, b *Attempt, pass verify.Pass) (Approved, error) {
		b.Review++
		b.LastReview = &ReviewRecord{N: b.Review, Verdict: "pending", Findings: []map[string]any{}}
		if err := b.Save(Continuation{Stage: StageReview, Pass: &pass, Review: session}); err != nil {
			return Approved{}, err
		}
		return Approved{}, sys.Fail("provider", "unavailable", "the reviewer's provider is down", 4)
	}}
	a := e.build(func(in *Input) { in.Reviewer = rev })
	eq(t, "exit", a.exit, 4)
	id := e.onlyRun()
	facts := e.jsonFile(e.root + "/.kogen/local/facts/" + id + ".json")
	eq(t, "resume_status", facts["resume_status"], any("potentially_available"))
	_, state := e.checkpoint(id)
	cont := state["continuation"].(map[string]any)
	eq(t, "stage", cont["stage"], any("review"))

	resumed := false
	rev2 := &scriptedReviewer{resume: func(ctx context.Context, b *Attempt) (Approved, error) {
		resumed = true
		if b.Continuation.Stage != StageReview || b.Continuation.Pass == nil || !bytes.Equal(b.Continuation.Review, session) {
			t.Errorf("continuation %+v", b.Continuation)
		}
		return approve(b, *b.Continuation.Pass), nil
	}}
	r := e.resume(id, func(in *ResumeInput) { in.Reviewer = rev2 })
	if r.exit != 0 || !resumed {
		t.Fatalf("exit %d resumed %v\n%s", r.exit, resumed, r.shown())
	}
	contains(t, "stdout", r.out.String(), "landed fixture ")
	eq(t, "requests", e.prov.count(), 1)
	// The stub reviewer cannot continue a review.
	e2 := newEnv(t)
	e2.prov.then(landScript(e2.prov)...)
	a2 := e2.build(func(in *Input) { in.Reviewer = rev })
	eq(t, "exit", a2.exit, 4)
	r2 := e2.resume(e2.onlyRun())
	eq(t, "stub resume exit", r2.exit, 1)
	contains(t, "stub resume", r2.shown(), "candidate/resume_refused: no reviewer is available to continue this review")
}

func TestTheStubReviewerApprovesAndRecordsItself(t *testing.T) {
	// ExUnit: lib/kogen/build.ex Review.run/3 (the hook's default until the independent review is wired)
	e := newEnv(t)
	e.prov.then(landScript(e.prov)...)
	a := e.build()
	eq(t, "exit", a.exit, 0)
	id := e.onlyRun()
	review := e.jsonFile(e.runPath(id, "review-1.json"))
	eq(t, "verdict", review["verdict"], any("approve"))
	events := eventsNamed(e.events(id), "review")
	if len(events) != 1 || events[0]["stub"] == nil {
		t.Fatalf("review events %v", events)
	}
}

func TestVersion3CheckpointsGoThroughTheImporter(t *testing.T) {
	// ExUnit: lib/kogen/run.ex decode_checkpoint/1 (version 3 is the Elixir Kogen's; the importer hook reads it)
	e := newEnv(t)
	id, _ := e.interruptedAtRequest()
	doc, _ := e.checkpoint(id)
	doc["version"] = 3
	e.writeCheckpoint(id, doc)
	var seen []byte
	importer := func(raw []byte) (*Loaded, error) {
		seen = raw
		l, why := decodeCheckpoint(bytes.Replace(raw, []byte(`"version":3`), []byte(`"version":4`), 1), nil)
		if l == nil {
			return nil, errors.New(why)
		}
		return l, nil
	}
	e.prov.replace(e.prov.calls("write_file", map[string]any{"path": "app.txt", "content": "candidate\n"}, "finish", map[string]any{"summary": "done"}))
	r := e.resume(id, func(in *ResumeInput) { in.Legacy = importer })
	if r.exit != 0 {
		t.Fatalf("exit %d\n%s", r.exit, r.shown())
	}
	if !strings.Contains(string(seen), `"version":3`) {
		t.Fatalf("the importer saw %.80s", seen)
	}
	contains(t, "stdout", r.out.String(), "landed fixture ")
}

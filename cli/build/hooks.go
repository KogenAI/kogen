package build

import (
	"context"
	"encoding/json"

	"kogen-loop/provider"
	"kogen/executor"
	"kogen/project"
	"kogen/verify"
)

// Deps are what a Build needs from outside: the provider client, Kogen's own tools and the
// two hooks a later change fills in (the independent review of a green pass and the import
// of version 3 checkpoints written by the Elixir Kogen).
type Deps struct {
	// NativeRoundLimits is internal and research-only. Only build is supported;
	// shape (including Refine) and review keys are ignored for now. Zero is unlimited.
	NativeRoundLimits map[string]int
	// BuildRequestBudget is internal, like NativeRoundLimits, and applies to the native builder
	// only. A positive N allows N builder requests over the whole Build (every verification
	// pass and explicit resume); review requests are not counted. Zero is off. The limit and the
	// count are kept in the checkpoint: a resume takes them from there, not from this field.
	BuildRequestBudget int

	// Client sends the model requests; its prompt-cache is not used, the Build keeps its own
	// (restored from a checkpoint).
	Client *provider.Client
	// Tools are Kogen's own Node, Quint and Cucumber.
	Tools verify.Tools
	// Reviewer runs the independent review of a green pass. Nil: see newReviewer.
	Reviewer Reviewer
	// Legacy reads a version 3 checkpoint. Nil: see newLegacy.
	Legacy LegacyDecoder
	// External returns the executor of a build role that selects an external executor
	// (`executor: claude-code`). Nil: such a role stops with executor/unavailable ("not
	// available in this program"). The native builder never uses it.
	External func(role project.Role) (executor.Executor, error)
}

// Approved is the result of a review that approves: the green pass whose exact tree was
// reviewed (the final one, after any repairs the reviewer made and verification repeated)
// and the review.
type Approved struct {
	Pass   verify.Pass
	Review ReviewRecord
}

// Reviewer is the independent review and repair of a green pass (chapter 06). The Build
// calls it after every green verification pass and commits what it approves.
//
// An implementation works on the *Attempt it is given, in the Build's own state:
//
//   - b.Review counts reviews; it sets b.LastReview (verdict "pending" while a repair is
//     being verified) and keeps b.Continuation current with b.Save, using the review stages;
//   - b.Request sends a conversation request with the shared bookkeeping (working context,
//     checkpoint, usage, provider attempts, image delivery);
//   - b.Verify runs a verification pass over the current candidate (fixers are the Build's
//     round end, not part of it) and b.BaselineIntact guards the approved baseline;
//   - a stop (`candidate/review_blocked`, `candidate/review_invalid`, ...) is a *sys.Error:
//     return it and the Build ends as it ends for any other stop.
//
// An approval returns the pass and review it rests on; anything else is an error.
type Reviewer interface {
	// Review reviews pass, a green pass.
	Review(ctx context.Context, b *Attempt, pass verify.Pass) (Approved, error)
	// Resume continues a Build whose checkpoint is in a review stage (b.Continuation.Stage is
	// StageReview, StageReviewVerify or StageReviewRetry).
	Resume(ctx context.Context, b *Attempt) (Approved, error)
}

// LegacyDecoder reads a version 3 checkpoint, as the Elixir Kogen wrote it, into this
// package's own state. The raw argument is the whole checkpoint file. It returns the
// envelope fields and the state, or an error whose text is the reason a resume is refused.
type LegacyDecoder func(raw []byte) (*Loaded, error)

// Checkpoint is the envelope of a checkpoint file: the identity of the checkout, the
// candidate tree, the user's index and the approval as they were saved (index and approval
// are base64), and the state.
type Checkpoint struct {
	Version   int             `json:"version"`
	Identity  string          `json:"identity"`
	Candidate string          `json:"candidate"`
	Index     string          `json:"index"`
	Approval  string          `json:"approval"`
	State     json.RawMessage `json:"state"`
	// StageProgress repeats the staged progress of State (absent without a plan).
	StageProgress *StageProgress `json:"stage_progress,omitempty"`
	// RecoveryRaw is the raw identity of a builder-reported blocker's candidate (see
	// Recover), null while there is no blocker.
	RecoveryRaw map[string]*RawMeta `json:"recovery_raw"`
}

// Loaded is a decoded checkpoint.
type Loaded struct {
	Doc   Checkpoint
	State *State
}

// newReviewer is the reviewer a Build uses when Deps.Reviewer is nil: the independent
// review and repair of chapter 06 (review.go).
func newReviewer(Deps) Reviewer { return reviewIndependent{} }

// newLegacy is the version 3 decoder a resume uses when Deps.Legacy is nil: the reader of
// the checkpoints the Elixir Kogen wrote (legacy.go).
func newLegacy(Deps) LegacyDecoder { return legacyDecode }

func (d Deps) reviewer() Reviewer {
	if d.Reviewer != nil {
		return d.Reviewer
	}
	return newReviewer(d)
}

func (d Deps) legacy() LegacyDecoder {
	if d.Legacy != nil {
		return d.Legacy
	}
	return newLegacy(d)
}

// approveWithoutReview is the STUB reviewer: it approves the green pass as it is. It records
// the review the way a real one does (the number, the run log event, `review-<n>.json`) so
// that everything after it can be exercised, and marks itself in both.
type approveWithoutReview struct{}

func (approveWithoutReview) Review(_ context.Context, b *Attempt, pass verify.Pass) (Approved, error) {
	b.Review++
	review := ReviewRecord{N: b.Review, Verdict: "approve", Findings: []map[string]any{}, Tree: pass.Tree}
	b.LastReview = &review
	b.Track()
	b.Run.Write(reviewFile(review.N), map[string]any{
		"verdict": "approve", "findings": []any{}, "tree": pass.Tree, "stub": "no independent review ran",
	})
	b.Run.Event(map[string]any{"event": "review", "review": review.N, "pass": pass.N, "tree": pass.Tree,
		"verdict": "approve", "findings": []any{}, "stub": "no independent review ran"})
	return Approved{Pass: pass, Review: review}, nil
}

func (approveWithoutReview) Resume(context.Context, *Attempt) (Approved, error) {
	return Approved{}, resumeRefused("no reviewer is available to continue this review")
}

func reviewFile(n int) string { return "review-" + itoa(n) + ".json" }

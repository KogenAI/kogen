package build

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"

	"kogen-loop/sys"
	"kogen/git"
	"kogen/project"
	"kogen/verify"
)

// An independent review that ends without a valid verdict must not strand a green candidate
// that nothing is wrong with. For the exact verified tree there is one automatic fresh review
// (a new conversation of the same kind with the same material and rules, numbered as the next
// review), and after that allowance is spent an explicit `kogen intent resume` of the
// review-only checkpoint starts one more fresh review per resume. Neither reuses the invalid
// conversation, replays the builder, or reruns completed verification. A substantive blocker
// is a valid verdict and never goes through here.

// readOnlyReviewTools are the reviewer's tools that cannot change the checkout; a review that
// called any other tool is never a safe review-only boundary.
var readOnlyReviewTools = []string{"read_file", "view_image", "list_files", "search_text"}

// invalidReview is what a review that ended without a valid verdict leaves for the Build: the
// reason, the consumed allowances and what the review did to the checkout.
type invalidReview struct {
	Review          int
	Reason          string
	Problems        []string
	RejectedVerdict int
	NoToolReminder  int
	Pass            verify.Pass
	// Mutating: the conversation called a tool that could change the checkout. Reopened: it
	// was the reopened conversation of a blocked review, whose blocker only a new explicit
	// decision of that reviewer can clear.
	Mutating, Reopened bool
}

// allowance records a consumption of the review's allowances in the run log.
func (r *reviewRun) allowance(why string) {
	r.b.Run.Event(map[string]any{
		"event": "review_allowance", "review": r.b.Review, "why": why,
		"rejected_verdicts": r.sess.Rejected, "no_tool_reminders": r.sess.NoTool,
	})
}

// invalidStop ends the review without a verdict (the second spending of an allowance). It
// records the reason with both counters, notes the review for the retry gate and returns
// candidate/review_invalid.
func (r *reviewRun) invalidStop(problems []string, reason string) error {
	b := r.b
	b.Run.Event(map[string]any{
		"event": "review", "review": b.Review, "verdict": "invalid", "problems": problems, "reason": reason,
		"rejected_verdicts": r.sess.Rejected, "no_tool_reminders": r.sess.NoTool,
	})
	b.LastReview = &ReviewRecord{N: b.Review, Verdict: "invalid", Findings: []map[string]any{}}
	b.invalid = &invalidReview{
		Review: b.Review, Reason: reason, Problems: problems, RejectedVerdict: r.sess.Rejected, NoToolReminder: r.sess.NoTool,
		Pass: r.pass, Mutating: r.sess.Mutating, Reopened: r.sess.Reopened,
	}
	return reviewInvalidError()
}

func reviewInvalidError() *sys.Error {
	return sys.Fail("candidate", "review_invalid", "the reviewer did not return a valid verdict; edits are left in place", 1)
}

// takeInvalid is the fact of the review that just ended invalid, or nil when err is anything
// else.
func (b *Attempt) takeInvalid(err error) *invalidReview {
	inv := b.invalid
	b.invalid = nil
	if e, ok := sys.AsError(err); !ok || e.Class != "candidate" || e.Reason != "review_invalid" {
		return nil
	}
	return inv
}

// reviewWithRetry runs first, the Build's ordinary review (or the resume of a saved one), and
// handles a review that ended without a valid verdict. At a safe boundary of an unchanged
// green candidate the review-only checkpoint is saved; if the candidate's one automatic retry
// is still unspent it is recorded as spent first and a fresh review follows at once. Any other
// ending, and an invalid review at an unsafe boundary, is returned unchanged.
func (b *Attempt) reviewWithRetry(ctx context.Context, first func() (Approved, error)) (Approved, error) {
	run := first
	for {
		b.invalid = nil
		approved, err := run()
		if err == nil {
			return approved, nil
		}
		inv := b.takeInvalid(err)
		if inv == nil {
			return Approved{}, err
		}
		if why := b.reviewOnlyBlocked(inv); why != "" {
			b.Run.Event(map[string]any{"event": "review_only", "review": inv.Review, "eligible": false, "why": why})
			return Approved{}, err
		}
		pass := inv.Pass
		rr := b.reviewRetryOf(pass.Tree)
		automatic := !rr.Automatic
		next := "stop"
		if automatic {
			rr.Automatic, next = true, "automatic"
		}
		rr.Invalid = append(rr.Invalid, InvalidReview{
			Review: inv.Review, Reason: inv.Reason, RejectedVerdict: inv.RejectedVerdict, NoToolReminder: inv.NoToolReminder,
			Run: b.Run.ID, Next: next,
		})
		b.setPhase(phaseReview)
		if err := b.Save(Continuation{Stage: StageReviewOnly, Pass: &pass}); err != nil {
			return Approved{}, err
		}
		b.Run.Event(map[string]any{
			"event": "review_only", "review": inv.Review, "eligible": true, "tree": pass.Tree, "next": next,
			"rejected_verdicts": inv.RejectedVerdict, "no_tool_reminders": inv.NoToolReminder,
		})
		if !automatic {
			return Approved{}, err
		}
		b.Run.Event(map[string]any{
			"event": "review_retry", "kind": "automatic", "from_review": inv.Review, "review": inv.Review + 1, "tree": pass.Tree,
		})
		b.s.Progress(fmt.Sprintf("kogen: review %d ended without a valid verdict; starting one fresh review of the unchanged candidate", inv.Review))
		run = func() (Approved, error) { return b.deps.reviewer().Review(ctx, b, pass) }
	}
}

// reviewRetryOf is the retry record of the green tree: the Build's own while it concerns that
// tree, otherwise a new one (a different tree is a different candidate with its own allowance).
func (b *Attempt) reviewRetryOf(tree string) *ReviewRetry {
	if b.ReviewRetry == nil || b.ReviewRetry.Tree != tree {
		b.ReviewRetry = &ReviewRetry{Tree: tree, Invalid: []InvalidReview{}}
	}
	return b.ReviewRetry
}

// reviewOnlyBlocked says why the review that ended invalid is not a safe boundary for a fresh
// review of the same candidate ("" when it is): the review must have used only read-only
// tools, and the candidate must be exactly the tree of its complete green pass with every
// ordinary precondition of the checkout intact (HEAD, index, approval, baseline and
// configuration, custody).
func (b *Attempt) reviewOnlyBlocked(inv *invalidReview) string {
	switch {
	case inv.Mutating:
		return "the review used tools that can change the checkout"
	case inv.Reopened:
		return "the review reopened a blocked review; only its own new decision clears the blocker"
	case !inv.Pass.Green || !b.completePass(&inv.Pass, b.model):
		return "the verified pass is not complete green evidence"
	}
	tree, err := b.repo.Tree(b.Start, b.Excluded)
	if err != nil {
		return "the candidate tree cannot be read"
	}
	if tree != inv.Pass.Tree {
		return "the candidate changed after its green pass"
	}
	for _, check := range []func() error{b.headIntact, b.BaselineIntact, b.approvalIntact, b.indexIntact} {
		if err := check(); err != nil {
			return err.Error()
		}
	}
	return ""
}

// approvalIntact is the exact approval record the Build started from.
func (b *Attempt) approvalIntact() error {
	current, err := os.ReadFile(project.ApprovalPath(b.Root, b.Slug))
	saved, derr := decodeBase64(b.ApprovalBytes)
	if err != nil || derr != nil || !bytes.Equal(current, saved) {
		return fmt.Errorf("the approval changed")
	}
	return nil
}

// indexIntact is the user's index as this run found it: the same bytes, or the same staged
// entries after a status refreshed its stat cache.
func (b *Attempt) indexIntact() error {
	current, err := os.ReadFile(b.GitIndex)
	if err != nil {
		return fmt.Errorf("the index cannot be read")
	}
	original, err := os.ReadFile(filepath.Join(b.Run.Dir, "index-at-start"))
	if err != nil {
		return fmt.Errorf("the original index backup is missing")
	}
	if bytes.Equal(current, original) {
		return nil
	}
	format, err := b.repo.ObjectFormat()
	if err != nil || !git.StagedEquivalent(current, original, format) {
		return fmt.Errorf("the staged index changed")
	}
	return nil
}

// reviewOnlyResume is the explicit resume of a review-only checkpoint: the candidate must be
// exactly the tree of the saved green pass (after the ordinary custody checks of Resume), then
// one fresh review starts, with no builder round and no verification rerun. The automatic
// retry of this tree is recorded as spent, so a resume never grants another one.
func (b *Attempt) reviewOnlyResume(ctx context.Context) error {
	c := b.Continuation
	pass := *c.Pass
	tree, err := b.repo.Tree(b.Start, b.Excluded)
	if err != nil {
		return err
	}
	if tree != pass.Tree || b.LastPass == nil || b.LastPass.Tree != pass.Tree || !pass.Green {
		return resumeRefused("the candidate is not the verified green tree of the saved review-only checkpoint")
	}
	rr := b.reviewRetryOf(pass.Tree)
	rr.Automatic = true
	var invalid []map[string]any
	for _, i := range rr.Invalid {
		invalid = append(invalid, map[string]any{
			"review": i.Review, "reason": i.Reason, "rejected_verdicts": i.RejectedVerdict, "no_tool_reminders": i.NoToolReminder, "run": i.Run,
		})
	}
	from := 0
	if n := len(rr.Invalid); n > 0 {
		from = rr.Invalid[n-1].Review
	}
	b.Run.Event(map[string]any{
		"event": "review_retry", "kind": "resume", "from_review": from, "review": b.Review + 1, "tree": pass.Tree,
		"parent": nonNilString(b.Parent), "invalid_reviews": nonNil(invalid),
	})
	if err := b.Save(c); err != nil {
		return err
	}
	approved, err := b.reviewWithRetry(ctx, func() (Approved, error) { return b.deps.reviewer().Review(ctx, b, pass) })
	if err != nil {
		return err
	}
	if err := b.Track(); err != nil {
		return err
	}
	feedback, landed, err := b.commit(ctx, approved)
	if err != nil {
		return err
	}
	if !landed {
		return fmt.Errorf("candidate changed after review in a resumed commit: %s", feedback)
	}
	return nil
}

func nonNilString(s *string) any {
	if s == nil {
		return nil
	}
	return *s
}

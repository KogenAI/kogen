package build

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"

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
// is a valid verdict and never goes through here. Any ending without a valid verdict qualifies,
// whatever its reason. A reviewer that edited the checkout without committing is no obstacle:
// its uncommitted edits are discarded (and logged) so that the fresh review starts from the
// exact green candidate tree.

// invalidReview is what a review that ended without a valid verdict leaves for the Build: the
// reason, the consumed allowances and what the review did to the checkout.
type invalidReview struct {
	Review          int
	Reason          string
	Problems        []string
	RejectedVerdict int
	NoToolReminder  int
	Pass            verify.Pass
	// Reopened: it was the reopened conversation of a blocked review, whose blocker only a
	// new explicit decision of that reviewer can clear. Repaired: it had already judged and
	// sent back a verdict, so its pass may hold its own verified edits.
	Reopened, Repaired bool
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
		Pass: r.pass, Reopened: r.sess.Reopened, Repaired: r.sess.Repaired,
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
		pass := inv.Pass
		automatic := b.ReviewRetry == nil || b.ReviewRetry.Tree != pass.Tree || !b.ReviewRetry.Automatic
		if why := b.reviewOnlyBlocked(inv, automatic); why != "" {
			b.Run.Event(map[string]any{"event": "review_only", "review": inv.Review, "eligible": false, "why": why})
			return Approved{}, err
		}
		rr := b.reviewRetryOf(pass.Tree)
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
// review of the same candidate ("" when it is): the candidate must be exactly the tree of its
// complete green pass with every ordinary precondition of the checkout intact (HEAD, index,
// approval, baseline and configuration, custody). Tools the reviewer used are no obstacle: when
// the fresh review is starting at once (discard) and the checkout holds only uncommitted edits
// of the reviewer, they are discarded and logged first, so that the review starts from the exact
// green tree. A committed change moved HEAD and never qualifies.
func (b *Attempt) reviewOnlyBlocked(inv *invalidReview, discard bool) string {
	switch {
	case inv.Reopened:
		return "the review reopened a blocked review; only its own new decision clears the blocker"
	case inv.Repaired:
		return "the review already had a verdict judged and its verified edits are part of the pass"
	case !inv.Pass.Green || !b.completePass(&inv.Pass, b.model):
		return "the verified pass is not complete green evidence"
	}
	// Higher-priority causes first: a moved HEAD, a changed approval, baseline or index is
	// reported as itself, never as drift of the candidate's contents.
	for _, check := range []func() error{b.headIntact, b.BaselineIntact, b.approvalIntact, b.indexIntact} {
		if err := check(); err != nil {
			return err.Error()
		}
	}
	tree, err := b.repo.Tree(b.Start, b.Excluded)
	if err != nil {
		return "the candidate tree cannot be read: " + err.Error()
	}
	if tree != inv.Pass.Tree && !discard {
		return "the candidate changed after its green pass: " + b.treeDrift(tree, inv.Pass.Tree)
	}
	if tree != inv.Pass.Tree {
		if _, err := b.discardReviewEdits(inv, tree); err != nil {
			return "the reviewer's uncommitted edits could not be discarded: " + err.Error()
		}
	}
	return ""
}

// treeDrift states, from observation, how the candidate tree differs from the green tree of
// its pass: both identities and the changed paths, or the concrete reason the paths cannot be
// listed.
func (b *Attempt) treeDrift(observed, green string) string {
	fact := fmt.Sprintf("observed tree %s, green tree %s", short(observed), short(green))
	paths, err := b.repo.Changed(green, observed)
	if err != nil {
		return fact + "; the changed paths cannot be inspected: " + err.Error()
	}
	if len(paths) == 0 {
		return fact + "; no path differs in the compared trees"
	}
	return fact + "; changed paths: " + strings.Join(paths, ", ")
}

// discardReviewEdits puts the checkout back to the green tree of the review's pass: the
// reviewer's uncommitted modifications, deletions and additions go, in that one step, and
// the discarded paths are recorded in the run log. The result must be exactly the green tree.
func (b *Attempt) discardReviewEdits(inv *invalidReview, current string) ([]string, error) {
	green := inv.Pass.Tree
	paths, err := b.repo.RestoreTree(current, green)
	if err != nil {
		return nil, err
	}
	discarded := make([]map[string]any, 0, len(paths))
	names := make([]string, 0, len(paths))
	for _, p := range paths {
		discarded = append(discarded, map[string]any{"path": p.Path, "change": p.Change})
		names = append(names, p.Path)
	}
	b.Run.Event(map[string]any{
		"event": "review_edits_discarded", "review": inv.Review, "tree": green, "candidate": current, "paths": discarded,
	})
	now, err := b.repo.Tree(b.Start, b.Excluded)
	if err != nil {
		return names, err
	}
	if now != green {
		return names, fmt.Errorf("the checkout is not the green tree after the restore")
	}
	return names, nil
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
		if tree != pass.Tree {
			return resumeRefused("the candidate is not the green tree of the saved review-only pass: " + b.treeDrift(tree, pass.Tree))
		}
		return resumeRefused("the saved review-only pass is not the checkpoint's own complete green pass, although the candidate tree equals its tree")
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

// ---- resume of an external review stage ----

// An external reviewer's session has resume capability none, so resuming a review stage of one
// never continues it: it starts one fresh review of the green pass that session was started
// from (Continuation.Base), discarding the stopped session's uncommitted edits first. Work
// only a blocker's own reviewer can clear, and checkpoints that record no complete green base,
// are refused before anything is changed.

// externalReviewStage is whether the checkpoint is a review stage of an external reviewer.
func (b *Attempt) externalReviewStage() bool {
	return b.Config.Models["review"].External() &&
		slices.Contains([]string{StageReview, StageReviewVerify, StageReviewRetry}, b.Continuation.Stage)
}

// externalReviewRefusal is why the external review stage of the checkpoint cannot be resumed
// ("" when a fresh review can start, and for every other checkpoint).
func (b *Attempt) externalReviewRefusal() string {
	if !b.externalReviewStage() {
		return ""
	}
	c, x := b.Continuation, b.Config.Models["review"].Executor
	who := fmt.Sprintf("review %d by executor %s", b.Review, x)
	blocked := c.Stage == StageReviewRetry
	if c.Stage == StageReviewVerify {
		sess, err := reviewDecode(c.Review)
		if err != nil {
			return who + " cannot be continued (resume capability: none) and its saved state cannot be read"
		}
		blocked = sess.Verdict != nil && sess.Verdict.Verdict == "changes"
	}
	if blocked {
		return who + " ended with a blocking finding that only that reviewer's own new decision can clear, and its session cannot be resumed (resume capability: none); " +
			"inspect the preserved candidate and evidence read-only and preserve them manually, then start a fresh Build from a Build-clean checkout " +
			"under the still-current exact approval (ordinary Refine and new approval if the authority must change)"
	}
	if base := c.Base; base == nil || !base.Valid() || !base.Green || !b.completePass(base, b.model) {
		return who + " cannot be continued (resume capability: none) and this checkpoint records no complete green pass that review started from, " +
			"so no fresh review can start from verified work; start a fresh Build from a Build-clean checkout under the still-current exact approval"
	}
	return ""
}

// resumeExternalReview starts the one fresh review of the saved green base, with no builder
// round and no verification rerun, and commits what that review approves.
func (b *Attempt) resumeExternalReview(ctx context.Context) error {
	base := *b.Continuation.Base
	n, x := b.Review, b.Config.Models["review"].Executor
	b.s.Puts(fmt.Sprintf("review %d by executor %s cannot be continued (resume capability: none); starting fresh review %d of the green candidate verified in pass %d, with no builder round and no rerun of its checks",
		n, x, n+1, base.N))
	tree, err := b.repo.Tree(b.Start, b.Excluded)
	if err != nil {
		return err
	}
	if tree != base.Tree {
		paths, err := b.discardReviewEdits(&invalidReview{Review: n, Pass: base}, tree)
		if err != nil {
			return resumeRefused("review " + fmt.Sprint(n) + "'s uncommitted edits could not be discarded: " + err.Error())
		}
		b.s.Puts(fmt.Sprintf("discarded review %d's uncommitted edits, which are not part of that green candidate: %s", n, strings.Join(paths, ", ")))
	}
	// The fresh review judges the base, as an ordinary Build's review follows its green pass.
	b.LastPass = &base
	if err := b.Track(); err != nil {
		return err
	}
	approved, err := b.reviewWithRetry(ctx, func() (Approved, error) { return b.deps.reviewer().Review(ctx, b, base) })
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

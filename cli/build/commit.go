package build

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"kogen-loop/sys"
	"kogen/executor"
	"kogen/git"
	"kogen/project"
)

// commit is the verified commit (GIT-3..8) of what review approved. When the candidate is no
// longer the reviewed tree, verification and review start over (the feedback or the landing
// of that is returned). On a commit it reports the landing and returns landed true.
func (b *Attempt) commit(ctx context.Context, ap Approved) (feedback string, landed bool, err error) {
	return b.commitApproved(ctx, ap, true)
}

// commitApproved is commit. With restart false, a candidate that is no longer the reviewed
// tree stops the Build instead of starting verification and review again: the resume of a
// failed commit never runs a new cycle.
func (b *Attempt) commitApproved(ctx context.Context, ap Approved, restart bool) (feedback string, landed bool, err error) {
	b.s.Progress("kogen: committing")
	if err := b.s.Err(); err != nil {
		return "", false, err
	}
	if err := b.BaselineIntact(); err != nil {
		return "", false, err
	}
	if err := b.headIntact(); err != nil {
		return "", false, err
	}
	pass, review := ap.Pass, ap.Review
	tree, err := b.repo.Tree(b.Start, b.Excluded)
	if err != nil {
		return "", false, err
	}
	if !(pass.Green && pass.Clean && review.Tree == pass.Tree) || tree != pass.Tree {
		if !restart {
			return "", false, resumeRefused("the candidate is no longer the reviewed tree " + pass.Tree + "; " + b.treeDrift(tree, pass.Tree))
		}
		// Something changed after the reviewed pass: verify and review again.
		return b.verifyAndReview(ctx)
	}
	if err := b.Save(Continuation{Stage: StageCommit, Tree: pass.Tree}); err != nil {
		return "", false, err
	}
	if err := b.facts.update(b, "committing", ""); err != nil {
		return "", false, err
	}
	b.Run.Event(map[string]any{"event": "commit", "tree": pass.Tree})
	commit, err := b.repo.Commit(b.s, git.CommitSpec{
		Tree: pass.Tree, Start: b.Start, Title: b.intent.Title, Slug: b.Slug,
		MessageFile: filepath.Join(b.Run.Dir, "commit-message.txt"),
	})
	if err != nil {
		// A definite failure with HEAD still at the start leaves the verified candidate intact
		// and resumable; an interrupt, a crash or a hook-undone commit stays an uncertain
		// commit boundary.
		var failure *sys.Error
		if errors.As(err, &failure) && failure.Class == "environment" && failure.Reason == "commit_failed" && b.repo.Head() == b.Start {
			b.Continuation = Continuation{Stage: StageCommitFailed, Tree: pass.Tree}
		}
		return "", false, err
	}
	os.Remove(project.ApprovalPath(b.Root, b.Slug))
	b.setPhase(phaseLanded)
	if err := b.Save(Continuation{Stage: StageLanded, Commit: commit}); err != nil {
		return "", false, err
	}
	var notes []map[string]any
	for _, f := range review.Findings {
		if f["severity"] == "note" {
			notes = append(notes, f)
		}
	}
	b.Run.Event(map[string]any{"event": "outcome", "outcome": "landed", "commit": commit})
	if err := b.Run.Write("result.json", b.result("landed", map[string]any{"commit": commit})); err != nil {
		return "", false, err
	}
	if err := b.facts.update(b, "", "landed"); err != nil {
		return "", false, err
	}
	b.s.Puts(fmt.Sprintf("landed %s %s (Build %s)", b.Slug, short(commit), b.Run.ID))
	b.s.Puts("  checks: " + pass.ChecksLine())
	for _, line := range b.comparisonLines() {
		b.s.Puts(line)
	}
	line := "  review: approved"
	if len(notes) > 0 {
		line += fmt.Sprintf(", %d note(s)", len(notes))
	}
	b.s.Puts(line)
	for _, f := range notes {
		b.s.Puts(fmt.Sprintf("  note: %s:%s: %s", display(f["path"]), display(f["line"]), display(f["message"])))
	}
	b.s.Puts(fmt.Sprintf("  repairs: %d · tokens: %s · time: %s", b.Repairs, b.Usage.Total(), duration(b.elapsed())))
	if x := b.Executor; x != nil && x.Name != executor.Native {
		b.s.Puts("  executor: " + x.Name + " (" + x.Usage.line() + ")")
	}
	if x := b.ReviewExecutor; x != nil {
		b.s.Puts("  review executor: " + x.Name + " (" + x.Usage.line() + ")")
	}
	return "", true, nil
}

func duration(d interface{ Seconds() float64 }) string {
	s := int(d.Seconds())
	switch {
	case s >= 3600:
		return fmt.Sprintf("%dh%02dm%02ds", s/3600, s/60%60, s%60)
	case s >= 60:
		return fmt.Sprintf("%dm%02ds", s/60, s%60)
	}
	return fmt.Sprintf("%ds", s)
}

// commitFailedResume is the explicit resume of a commit_failed checkpoint: the saved approved
// pass and review go straight to the commit step, with no builder round, review or rerun of
// the checks. A candidate that is no longer the reviewed tree stops the Build.
func (b *Attempt) commitFailedResume(ctx context.Context) error {
	pass, review := *b.LastPass, *b.LastReview
	b.s.Puts(fmt.Sprintf("finishing the commit of the candidate verified in pass %d and approved in review %d, "+
		"with no builder round, no review and no rerun of its checks", pass.N, review.N))
	_, _, err := b.commitApproved(ctx, Approved{Pass: pass, Review: review}, false)
	return err
}

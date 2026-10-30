package build

import (
	"fmt"
	"path/filepath"
	"strings"

	"kogen-loop/sys"
	"kogen/agent"
	"kogen/verify"
)

// result is `result.json`: the Build's outcome and counts, with extra fields of the outcome.
func (b *Attempt) result(outcome string, extra map[string]any) map[string]any {
	notRun := []string{}
	if b.LastPass != nil {
		notRun = nonNil(b.LastPass.NotRun)
	}
	var parent, rootRun any
	if b.Parent != nil {
		parent = *b.Parent
	}
	if b.RootRun != nil {
		rootRun = *b.RootRun
	}
	m := map[string]any{
		"slug":             b.Slug,
		"build":            b.Run.ID,
		"outcome":          outcome,
		"start_head":       b.Start,
		"passes":           b.Pass,
		"not_run":          notRun,
		"reviews":          b.Review,
		"repairs":          b.Repairs,
		"usage":            b.Usage,
		"model_active_ms":  b.ModelActiveMS,
		"unknown_requests": b.UnknownRequests,
		"attempt_usage":    b.AttemptUsage,
		"resumed_from":     parent,
		"root_build":       rootRun,
	}
	for k, v := range extra {
		m[k] = v
	}
	if b.Executor != nil {
		m["executor"] = b.Executor
	}
	if b.ReviewExecutor != nil {
		m["review_executor"] = b.ReviewExecutor
	}
	if b.StageProgress != nil {
		m["stage_progress"] = b.StageProgress.value()
	}
	if c := b.comparisonRecord(); c != nil {
		m["check_comparison"] = c
	}
	return m
}

// stopped reports a Build that ends without a commit on an error (GIT-8, CLI-7) and returns
// the error's exit code.
func (b *Attempt) stopped(e *sys.Error) (int, error) {
	if e.Class == "provider" && e.Reason == "context_too_long" {
		e = &sys.Error{
			Class: "candidate", Reason: "context_exhausted", Exit: 1, Lines: e.Lines, ProviderFailure: e.ProviderFailure,
			Detail: "the conversation no longer fits " + b.Config.Models["build"].Model + "'s context; edits are left in place",
		}
	}
	e = agent.WithOriginHint(e)
	report := b.Phase != "startup"
	if report {
		b.s.Puts(fmt.Sprintf("failed %s: %s (Build %s)", b.Slug, e.Reason, b.Run.ID))
	}
	b.s.Out(e.Render())
	b.facts.fail(e)
	if err := b.details(e.Reason, report, e.ProviderFailure); err != nil {
		return 70, err
	}
	return e.Exit, nil
}

// interrupted reports a Build the caller interrupted; the Build leaves its edits in place
// (a commit an interrupt let land is undone by the commit itself).
func (b *Attempt) interrupted(signal string) error {
	b.s.Puts(fmt.Sprintf("stopped %s: interrupted (Build %s)", b.Slug, b.Run.ID))
	b.s.Puts(fmt.Sprintf("candidate/interrupted: Build %s stopped by %s; edits are left in place", b.Run.ID, signal))
	return b.details("interrupted", true, nil)
}

// details ends the Build's records: the user's index put back, what is still failing and
// what the Build edited, the outcome in the run log, `result.json` and the final
// checkpoint.
func (b *Attempt) details(reason string, report bool, providerFailure map[string]any) error {
	if err := b.repo.RestoreIndex(filepath.Join(b.Run.Dir, "index-at-start")); err != nil {
		return err
	}
	still := []string{}
	var notRun []string
	if p := b.LastPass; p != nil {
		still = append(still, p.Failing...)
		if len(p.Moved) > 0 {
			still = append(still, "verification")
		}
		notRun = p.NotRun
	}
	if r := b.LastReview; r != nil && r.Verdict != "approve" {
		still = append(still, "review")
	}
	tree, err := b.repo.Tree(b.Start, b.Excluded)
	if err != nil {
		return err
	}
	edited, err := b.repo.Changed(b.StartTree, tree)
	if err != nil {
		return err
	}
	if report {
		if len(notRun) > 0 {
			b.s.Puts("  " + verify.NotRunNotice(notRun))
		}
		if len(still) > 0 {
			b.s.Puts("  still failing: " + strings.Join(still, ", "))
		}
		for _, line := range b.comparisonLines() {
			b.s.Puts(line)
		}
		if len(edited) > 0 {
			b.s.Puts("  edited: " + strings.Join(edited, ", "))
		}
		b.s.Puts("  run log: " + b.Run.LogPath)
	}
	outcome := map[string]any{"event": "outcome", "outcome": reason}
	if providerFailure != nil {
		outcome["provider_failure"] = providerFailure
	}
	b.Run.Event(outcome)
	extra := map[string]any{"edited": nonNil(edited), "still_failing": still}
	if b.Blocker != nil {
		extra["blocker"] = b.Blocker
	}
	if providerFailure != nil {
		extra["provider_failure"] = providerFailure
	}
	if err := b.Run.Write("result.json", b.result(reason, extra)); err != nil {
		return err
	}
	if err := b.Save(b.Continuation); err != nil {
		return err
	}
	if err := b.facts.update(b, "", reason); err != nil {
		return err
	}
	phase, _ := b.facts.record["phase"].(string)
	b.s.Puts(fmt.Sprintf("  %s Build %s stopped in %s: %s; candidate: %s; evidence: %s; index: %s/index-at-start",
		b.Slug, b.Run.ID, phase, reason, b.Root, b.Run.Dir, b.Run.Dir))
	if b.Blocker != nil {
		b.s.Puts("  kogen intent recover " + b.Run.ID + " --output <new-external-directory> --project " + shellQuote(b.Root))
		b.s.Puts("  Recovery preserves and clears only implementation; the builder-reported claim is unproven. " +
			"Independently Refine, freshly approve and start a fresh Build; resume cannot override a protected blocker.")
	}
	if b.Continuation.Stage == StageReviewOnly {
		b.s.Puts("  review-only checkpoint kept: kogen intent resume " + b.Run.ID + " --project " + shellQuote(b.Root) +
			" starts one fresh review of this unchanged green candidate")
	}
	b.s.Puts("  kogen intent inspect " + b.Run.ID + " --project " + shellQuote(b.Root))
	return nil
}

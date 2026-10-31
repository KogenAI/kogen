package build

import (
	"context"
	"fmt"
	"strings"

	"kogen-loop/sys"
	"kogen/verify"
)

// The check baseline (AUT-5): every configured check, run in configured order on the
// unchanged tree before the builder edits anything. A nonzero exit is recorded evidence, not a
// refusal and never a waiver: the whole-Intent gate still requires every check to pass before
// landing. Execution errors, interrupts and missing tools keep their own stops.

// Check states of the before/after comparison.
const (
	checkPassed = "passed"
	checkFailed = "failed"
	checkNotRun = "not run"
)

// checkState is one side of a check's comparison: whether it passed, failed or did not run,
// and for a result its actual status and output.
type checkState struct {
	State  string `json:"state"`
	Status *int   `json:"status,omitempty"`
	Output string `json:"output,omitempty"`
}

// checkComparison is one configured check, before the Build changed anything and after the
// last whole-Intent verification pass.
type checkComparison struct {
	Name    string     `json:"name"`
	Command string     `json:"command"`
	Before  checkState `json:"before"`
	After   checkState `json:"after"`
}

func stateOf(r verify.CommandResult) checkState {
	status := r.Status
	if status != 0 {
		return checkState{State: checkFailed, Status: &status, Output: r.Output}
	}
	return checkState{State: checkPassed, Status: &status}
}

// recordBaseline runs every configured check once on the unchanged tree and keeps each
// name, command, exit status and output, in order. A check that exits nonzero does not stop
// the collection. Only an execution error (or an interrupt) does.
func (b *Attempt) recordBaseline(ctx context.Context) error {
	b.CheckBaseline = nil
	for _, c := range b.Config.Checks {
		b.s.Progress("kogen: checking " + c.Name + " before the Build changes anything")
		b.Run.Event(map[string]any{"event": "command", "name": c.Name, "command": c.Run, "before_change": true})
		r, err := verify.RunWatched(b.s, c.Name, c.Run, b.Run, func() (sys.Result, error) {
			return b.s.Run(c.Run, b.Root, sys.Options{KillGroupOnExit: true})
		})
		if err != nil {
			return err
		}
		b.Run.Event(map[string]any{"event": "command_result", "name": c.Name, "status": r.Status, "output": Cap(r.Output)})
		b.CheckBaseline = append(b.CheckBaseline, verify.CommandResult{Name: c.Name, Command: c.Run, Status: r.Status, Output: verify.Cap(r.Output)})
	}
	if len(b.CheckBaseline) == 0 {
		return nil
	}
	failing := b.baselineFailures()
	names := make([]string, 0, len(failing))
	for _, r := range failing {
		names = append(names, r.Name)
	}
	b.Run.Event(map[string]any{"event": "baseline_checks", "checks": len(b.CheckBaseline), "failing": nonNil(names)})
	if len(failing) == 0 {
		return nil
	}
	b.s.Puts(fmt.Sprintf("baseline: %d of %d configured check(s) fail before the Build changes anything; recorded as evidence, "+
		"not as a waiver: every configured check must pass before this Build lands", len(failing), len(b.CheckBaseline)))
	for _, r := range failing {
		b.s.Puts(fmt.Sprintf("  check %s (%s) failed (status=%d)", r.Name, r.Command, r.Status))
		for _, line := range strings.Split(verify.Diagnostic(r.Output), "\n") {
			b.s.Puts("    " + line)
		}
	}
	return nil
}

func (b *Attempt) baselineFailures() []verify.CommandResult {
	var out []verify.CommandResult
	for _, r := range b.CheckBaseline {
		if r.Status != 0 {
			out = append(out, r)
		}
	}
	return out
}

// comparison is every configured check in configured order with its baseline and its state in
// the last whole-Intent verification pass (nil: no pass yet). A check without a recorded
// baseline or without a result in that pass is "not run": nothing is inferred as unchanged or
// green. It is nil when no baseline was collected.
func (b *Attempt) comparison() []checkComparison {
	if len(b.CheckBaseline) == 0 {
		return nil
	}
	out := make([]checkComparison, 0, len(b.Config.Checks))
	for i, c := range b.Config.Checks {
		row := checkComparison{Name: c.Name, Command: c.Run, Before: checkState{State: checkNotRun}, After: checkState{State: checkNotRun}}
		if i < len(b.CheckBaseline) && b.CheckBaseline[i].Name == c.Name {
			row.Before = stateOf(b.CheckBaseline[i])
		}
		if p := b.LastPass; p != nil && i < len(p.Checks) && p.Checks[i].Name == c.Name {
			row.After = stateOf(p.Checks[i])
		}
		out = append(out, row)
	}
	return out
}

func (s checkState) String() string {
	if s.State == checkFailed && s.Status != nil {
		return fmt.Sprintf("%s (status=%d)", s.State, *s.Status)
	}
	return s.State
}

// comparisonLines is the human account of the comparison, shown whenever the Build ends:
// one line per check, then the actual output of every failure.
func (b *Attempt) comparisonLines() []string {
	rows := b.comparison()
	if len(rows) == 0 {
		return nil
	}
	after := "no verification pass"
	if b.LastPass != nil {
		after = fmt.Sprintf("verification pass %d", b.LastPass.N)
	}
	lines := []string{fmt.Sprintf("  checks, before the Build → after (%s):", after)}
	for i, r := range rows {
		lines = append(lines, fmt.Sprintf("    %d. %s: %s → %s", i+1, r.Name, r.Before, r.After))
		for _, side := range []struct {
			label string
			state checkState
		}{{"before", r.Before}, {"after", r.After}} {
			if side.state.State != checkFailed {
				continue
			}
			lines = append(lines, "       "+side.label+" output:")
			for _, line := range strings.Split(verify.Diagnostic(side.state.Output), "\n") {
				lines = append(lines, "         "+line)
			}
		}
	}
	return lines
}

// comparisonRecord is the comparison as result.json keeps it.
func (b *Attempt) comparisonRecord() map[string]any {
	rows := b.comparison()
	if len(rows) == 0 {
		return nil
	}
	var afterPass any
	if b.LastPass != nil {
		afterPass = b.LastPass.N
	}
	return map[string]any{"after_pass": afterPass, "checks": rows}
}

// baselineText is the baseline for the repair owners' prompts: the actual before-state of every
// check, in order, and the rule that it waives nothing. Empty when every check passed (or none
// is configured), so that Builds without a baseline failure see exactly what they saw before.
func (b *Attempt) baselineText() string {
	if len(b.baselineFailures()) == 0 {
		return ""
	}
	lines := []string{"# Baseline check results (before any edit)", "",
		"These are the actual results of every configured check, in configured order, on the unchanged tree. " +
			"They are diagnostics, not a waiver and not green verification: every configured check must pass on the final tree " +
			"before this Build can land, whether it failed at the start or not, and a check that passes now must not regress. " +
			"Do not remove, weaken or skip any check; repair what the checks report within the approved Intent.", ""}
	for i, r := range b.CheckBaseline {
		st := stateOf(r)
		lines = append(lines, fmt.Sprintf("%d. %s (%s): %s", i+1, r.Name, r.Command, st))
		if st.State == checkFailed {
			for _, line := range strings.Split(verify.Diagnostic(r.Output), "\n") {
				lines = append(lines, "   "+line)
			}
		}
	}
	return strings.Join(lines, "\n") + "\n\n"
}

// reviewBaselineMessage tells the independent reviewer the baseline and the actual final
// results of the green pass it reviews, check by check. Nil when there is no baseline failure.
func (b *Attempt) reviewBaselineMessage(pass verify.Pass) []any {
	if len(b.baselineFailures()) == 0 {
		return nil
	}
	lines := []string{"Check baseline and actual final results for this independent review (diagnostic evidence, not approval, not a waiver).",
		fmt.Sprintf("The baseline is the unchanged tree before the Build edited anything; the final results are verification pass %d of the candidate you review.", pass.N),
		"Every configured check must pass for the Build to land. Check by check, in configured order:"}
	for i, r := range b.CheckBaseline {
		final := checkState{State: checkNotRun}
		if i < len(pass.Checks) && pass.Checks[i].Name == r.Name {
			final = stateOf(pass.Checks[i])
		}
		lines = append(lines, fmt.Sprintf("%d. %s (%s): baseline %s → final %s", i+1, r.Name, r.Command, stateOf(r), final))
		if st := stateOf(r); st.State == checkFailed {
			for _, line := range strings.Split(verify.Diagnostic(r.Output), "\n") {
				lines = append(lines, "   baseline output: "+line)
			}
		}
		if final.State == checkFailed {
			for _, line := range strings.Split(verify.Diagnostic(final.Output), "\n") {
				lines = append(lines, "   final output: "+line)
			}
		}
	}
	return []any{map[string]any{"role": "user", "content": strings.Join(lines, "\n") + "\n"}}
}

// validBaseline is the checkpoint check of the recorded baseline: at most one result per
// configured check, in configured order, with its command.
func (s *State) validBaseline() bool {
	if len(s.CheckBaseline) > len(s.Config.Checks) {
		return false
	}
	for i, r := range s.CheckBaseline {
		c := s.Config.Checks[i]
		if r.Name != c.Name || r.Command != c.Run {
			return false
		}
	}
	return true
}

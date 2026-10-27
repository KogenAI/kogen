package build

import (
	"context"
	"os"
	"path/filepath"
	"strconv"

	"kogen-loop/sys"
	"kogen/executor"
	"kogen/project"
)

// externalBuild is what a Build keeps of an external build executor (docs/executor-contract.md):
// the executor Deps.External gave for the role, its validated descriptor and the round cap.
// A Build with the native builder has none.
type externalBuild struct {
	exec      executor.Executor
	desc      executor.Descriptor
	maxRounds int
}

// selectExecutor is the external executor the build role selects, or nil for the native
// builder. A role that selects one the program cannot provide stops with executor/unavailable
// before any run exists; an executor whose descriptor does not fit the contract does too.
func selectExecutor(d Deps, role project.Role) (*externalBuild, error) {
	if !role.External() {
		return nil, nil
	}
	if d.External == nil {
		return nil, executor.Fail(executor.ReasonUnavailable, "executor "+role.Executor+" is not available in this program")
	}
	ex, err := d.External(role)
	if err != nil {
		return nil, err
	}
	if ex == nil {
		return nil, executor.Fail(executor.ReasonUnavailable, "executor "+role.Executor+" is not available in this program")
	}
	desc := ex.Describe()
	if err := desc.Validate(); err != nil {
		return nil, err
	}
	if desc.Name != role.Executor {
		return nil, executor.Fail(executor.ReasonUnavailable, "executor "+role.Executor+" was configured, but the program provided "+desc.Name)
	}
	max := role.MaxRounds
	if max == 0 {
		max = desc.Capabilities.MaxRounds
	}
	return &externalBuild{exec: ex, desc: desc, maxRounds: max}, nil
}

// selectReviewer is the reviewer the review role selects. The native role keeps the native
// reviewer (nil). An external role is served through the Deps.Reviewer seam when one is given,
// otherwise by the executor Deps.External provides for it; a program that cannot provide one
// stops with executor/unavailable before any run exists, and never reviews natively instead.
func selectReviewer(d Deps, role project.Role) (Reviewer, error) {
	if !role.External() {
		return nil, nil
	}
	if d.Reviewer != nil {
		return d.Reviewer, nil
	}
	if d.External == nil {
		return nil, executor.Fail(executor.ReasonUnavailable, "executor "+role.Executor+" is not available in this program; Kogen does not review with the native reviewer instead")
	}
	ex, err := d.External(role)
	if err != nil {
		return nil, err
	}
	if ex == nil {
		return nil, executor.Fail(executor.ReasonUnavailable, "executor "+role.Executor+" is not available in this program; Kogen does not review with the native reviewer instead")
	}
	desc := ex.Describe()
	if err := desc.ValidateRole(executor.RoleReview); err != nil {
		return nil, err
	}
	if desc.Name != role.Executor {
		return nil, executor.Fail(executor.ReasonUnavailable, "executor "+role.Executor+" was configured, but the program provided "+desc.Name)
	}
	caps, _ := desc.For(executor.RoleReview)
	max := role.MaxRounds
	if max == 0 {
		max = caps.MaxRounds
	}
	if max == 0 {
		max = project.DefaultExternalRounds
	}
	return reviewExternal{exec: ex, desc: desc, maxRounds: max}, nil
}

// task is the Build's task for an executor: the brief and the constraints Kogen keeps (the
// protected baseline, the excluded paths), never Kogen's own builder prompt.
func (b *Attempt) task(brief executor.Brief) (executor.Task, error) {
	role := b.Config.Models["build"]
	approval, err := decodeBase64(b.ApprovalBytes)
	if err != nil {
		return executor.Task{}, err
	}
	t := executor.Task{
		Role: executor.RoleBuild, Root: b.Root, Brief: brief, Protected: b.Baseline, Excluded: b.Excluded,
		Model: role.Model, Effort: role.Effort, Approval: hashHex(approval), StartTree: b.Start, RunID: b.Run.ID,
		Home: b.s.Getenv("HOME"), MaxRounds: role.MaxRounds,
	}
	if b.ext != nil {
		t.MaxRounds = b.ext.maxRounds
	}
	return t, nil
}

// startBuilder opens the builder's session for a fresh Build: the native conversation, or the
// configured external executor on a private artifacts folder in the run folder.
func (b *Attempt) startBuilder(ctx context.Context, brief executor.Brief) (executor.Session, error) {
	task, err := b.task(brief)
	if err != nil {
		return nil, err
	}
	if b.ext == nil {
		var tail []any
		if b.diag != nil {
			tail = []any{b.diag.message()}
		}
		return nativeExecutor{b: b, tail: tail}.Start(ctx, task, nil)
	}
	task.Dir = filepath.Join(b.Run.Dir, "executor")
	if err := os.MkdirAll(task.Dir, 0o700); err != nil {
		return nil, err
	}
	if err := os.Chmod(task.Dir, 0o700); err != nil {
		return nil, err
	}
	sess, err := b.ext.exec.Start(ctx, task, func(event map[string]any) { b.Run.Event(event) })
	if err != nil {
		return nil, err
	}
	h := sess.Handle()
	b.Executor = &ExecutorState{
		Name: b.ext.desc.Name, Version: b.ext.desc.Version, SessionID: h.SessionID,
		Usage: ExecutorUsage{Input: count(0), Cached: count(0), Output: count(0), Reasoning: count(0), State: executor.UsageComplete,
			Source: b.ext.desc.Capabilities.Usage, CostUSD: new(float64)},
	}
	return sess, nil
}

// runRound runs one builder round. An external round's context carries the Session's
// interrupt as its cause, so the executor can return the interrupt with its own exit code.
func (b *Attempt) runRound(ctx context.Context, sess executor.Session, in executor.Input) (executor.RoundResult, error) {
	if b.ext == nil {
		return sess.Round(ctx, in)
	}
	return b.runGuardedRound(ctx, sess, in)
}

// runGuardedRound runs one external round of any role with Kogen's independent custody checks.
func (b *Attempt) runGuardedRound(ctx context.Context, sess executor.Session, in executor.Input) (executor.RoundResult, error) {
	rctx, cancel := context.WithCancelCause(ctx)
	defer cancel(nil)
	stop := context.AfterFunc(b.s.Context(), func() { cancel(b.s.Err()) })
	defer stop()
	res, err := sess.Round(rctx, in)
	// Detection is independent of the executor's protocol: even a failed round may
	// have mutated protected files or moved HEAD before returning its error.
	if guardErr := b.BaselineIntact(); guardErr != nil {
		return res, guardErr
	}
	if guardErr := b.headIntact(); guardErr != nil {
		return res, guardErr
	}
	if err != nil {
		if e, ok := sys.AsError(err); ok && e.Class == "executor" && e.Reason == executor.ReasonInterrupted {
			if ie := b.s.Err(); ie != nil {
				return res, ie
			}
		}
		return res, err
	}
	return res, nil
}

// afterExternalRound is the Build's side of an external round: it records what the executor
// reported and checkpoints the round's boundary after runRound's custody checks. The round
// itself is only a claim; its verification, review and commit follow (roundEnd).
func (b *Attempt) afterExternalRound(res executor.RoundResult, rounds int) error {
	if res.Ending != executor.EndFinish && res.Ending != executor.EndNoCall && res.Ending != executor.EndBlocker {
		return executor.Fail(executor.ReasonProtocol, "executor "+b.ext.desc.Name+" returned the unknown round ending "+inspectString(string(res.Ending)))
	}
	b.recordExecutor(res, rounds)
	b.Run.Event(map[string]any{
		"event": "executor_round", "round": b.Round, "executor": b.Executor.Name, "ending": string(res.Ending),
		"claim": res.Claim, "usage": res.Usage, "session_id": res.Handle.SessionID,
	})
	if res.Ending == executor.EndBlocker {
		if rc, _ := b.ext.desc.For(executor.RoleBuild); !rc.Blocker {
			return executor.Fail(executor.ReasonProtocol, "executor "+b.ext.desc.Name+" reported a protected-contract blocker, which it does not support")
		}
		var claim executor.BlockerClaim
		if res.Blocker != nil {
			claim = *res.Blocker
		}
		paths := make([]any, 0, len(claim.Paths))
		for _, p := range claim.Paths {
			paths = append(paths, p)
		}
		args := map[string]any{"paths": paths, "reason": claim.Reason, "evidence": claim.Evidence}
		if validBlocker(args, b.Baseline) {
			// Checkpointed like the native stop, so recovery works on it unchanged.
			if err := b.Save(Continuation{Stage: StageBuilderVerify}); err != nil {
				return err
			}
			return b.stopBlocked(args, func() {})
		}
		b.blockerNote = invalidBlockerMessage
	}
	// The round's boundary: resume of an external executor's checkpoint is refused.
	return b.Save(Continuation{Stage: StageBuilderVerify})
}

// recordExecutor adds a round's reported identity and usage to the Build's executor state.
func (b *Attempt) recordExecutor(res executor.RoundResult, rounds int) {
	x := b.Executor
	x.Rounds = rounds
	if res.Handle.Version != "" {
		x.Version = res.Handle.Version
	}
	if res.Handle.SessionID != "" {
		x.SessionID = res.Handle.SessionID
	}
	x.Usage = x.Usage.plus(res.Usage, rounds == 1)
}

// plus adds a round's reported usage. A count is nil as soon as one round lacks it; the cost
// is the harness's own estimate and unknown the same way. The state is the rounds' own state
// when they agree and partial when they differ (first: no round was added before).
func (u ExecutorUsage) plus(r executor.Usage, first bool) ExecutorUsage {
	out := ExecutorUsage{
		Input: addCounts(u.Input, r.Input), Cached: addCounts(u.Cached, r.Cached),
		Output: addCounts(u.Output, r.Output), Reasoning: addCounts(u.Reasoning, r.Reasoning), Source: u.Source,
	}
	if r.Source != "" {
		out.Source = r.Source
	}
	if u.CostUSD != nil && r.CostUSD != nil {
		sum := *u.CostUSD + *r.CostUSD
		out.CostUSD = &sum
	}
	state := r.State
	if state == "" {
		state = executor.UsageUnknown
	}
	switch {
	case first || state == u.State:
		out.State = state
	default:
		out.State = executor.UsagePartial
	}
	return out
}

// line is the commit summary's account of an executor's usage: harness-reported figures and
// the harness's own cost estimate, never a bill.
func (u ExecutorUsage) line() string {
	t := Tokens{u.Input, u.Cached, u.Output, u.Reasoning}
	cost := "unknown"
	if u.CostUSD != nil {
		cost = "$" + strconv.FormatFloat(*u.CostUSD, 'f', 4, 64)
	}
	return u.Source + "-reported tokens " + t.Line() + ", estimate " + cost
}

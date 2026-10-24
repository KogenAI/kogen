package build

import (
	"context"
	"fmt"
	"slices"
	"strings"

	"kogen/agent"
	"kogen/project"
	"kogen/provider"
	"kogen/sys"
	"kogen/verify"
)

// The builder's tools: the file and command tools plus the two terminal tools.
var (
	builderTools = []string{"shell", "read_file", "view_image", "write_file"}
	builderDefs  = []string{"shell", "read_file", "view_image", "write_file", "finish", "report_blocker"}
)

// openingMessage is the builder's first message (LOOP-2): the Intent, its acceptance
// feature and model, the project's README and testing rules, the configured commands, the
// protected paths and the file list, as two blocks (the stable authority and the dynamic
// evidence behind it).
func (b *Attempt) openingMessage() ([]any, error) {
	modelText := ""
	if t, err := readFile(b.Root, project.ModelPath(b.Slug)); err == nil {
		modelText = "\n# model.qnt\n\n```quint\n" + string(t) + "```\n"
	}
	feature, err := readFile(b.Root, project.FeaturePath(b.Slug))
	if err != nil {
		return nil, err
	}
	readme := "(no README.md)"
	if t, err := readFile(b.Root, "README.md"); err == nil {
		readme = string(t)
	}
	var checks []string
	for _, c := range b.Config.Checks {
		checks = append(checks, c.Name+": "+c.Run)
	}
	acceptanceRun := ""
	if b.Config.Acceptance != nil {
		acceptanceRun = b.Config.Acceptance.Run
	}
	var baseline []string
	for _, p := range b.Baseline {
		baseline = append(baseline, "- "+p)
	}
	featurePath := project.FeaturePath(b.Slug)
	stable := project.SourceMessage(b.SourceProvenance) + "\n\n" +
		"# Intent: " + b.intent.Title + "\n\n" +
		"```markdown\n" + b.intent.Text + "```\n\n" +
		"# Acceptance feature (" + featurePath + ")\n\n" +
		"```gherkin\n" + string(feature) + "```\n" +
		modelText + "\n" +
		"# Project instructions (README.md)\n\n" + readme + "\n\n" +
		"# Testing rules (docs/testing-rules.md)\n\n" + agent.Prompt(agent.TestingRules) + "\n\n" +
		b.State.navigation() + "\n" +
		"# Configured commands\n\n" +
		"setup: " + inspectStrings(b.Config.Setup) + "\n" +
		"fix (run once after each of your rounds): " + inspectStrings(b.Config.Fix) + "\n" +
		"checks: " + strings.Join(checks, "; ") + "\n" +
		"acceptance: " + acceptanceRun + " (runs " + featurePath + ")\n\n" +
		"# Protected paths\n\n" +
		protectedIntro + "\n" + strings.Join(baseline, "\n") + "\n\n" +
		manifestNotice + "\n\n"
	files, err := b.repo.OK("ls-files", "--cached", "--others", "--exclude-standard")
	if err != nil {
		return nil, err
	}
	return provider.ContractBlocks(stable, "# Files\n\n"+files), nil
}

// drive is the builder's conversation (LOOP-1..7): a request, its tool calls, and after the
// builder finishes (or answers without a tool call) the fixers and a verification pass; a
// red pass goes back to the same builder, a green one to review and commit. newRound starts
// a numbered round before the first request.
func (b *Attempt) drive(ctx context.Context, input []any, newRound bool) error {
	for {
		if newRound {
			if err := b.facts.update(b, "building", ""); err != nil {
				return err
			}
			b.Round++
			if err := b.Track(); err != nil {
				return err
			}
			b.s.Progress(fmt.Sprintf("kogen: building (round %d)", b.Round))
		}
		next, again, landed, err := b.turn(ctx, input)
		if err != nil || landed {
			return err
		}
		input, newRound = next, again
	}
}

// turn is one builder request with the tool calls it asks for. It returns the conversation
// for the next request and whether that request starts a new round; landed means the Build
// committed.
func (b *Attempt) turn(ctx context.Context, input []any) (next []any, newRound, landed bool, err error) {
	if err := b.facts.update(b, "building", ""); err != nil {
		return nil, false, false, err
	}
	if err := b.Save(Continuation{Stage: StageBuilder, Input: input}); err != nil {
		return nil, false, false, err
	}
	role := b.Config.Models["build"]
	resp, active, err := b.Request(ctx, RequestSpec{
		Owner: "build", Role: role, Instructions: agent.Prompt(agent.Builder), Input: input,
		Tools: agent.AsAny(agent.Defs(builderDefs...)),
	})
	if err != nil {
		return nil, false, false, err
	}
	if err := b.Track(); err != nil {
		return nil, false, false, err
	}
	input = slices.Concat(active, agent.Replay(resp.Items))
	calls := agent.Calls(resp.Items)
	tools := &agent.Tools{
		Root: b.Root, Session: b.s, Repo: b.repo, Enabled: builderTools, Protected: b.Baseline, Excluded: b.Excluded,
	}
	var outs []any
	var finish *agent.Call
	for i := range calls {
		call := calls[i]
		if err := b.s.Err(); err != nil {
			return nil, false, false, err
		}
		args := call.Args()
		if err := b.validateStagesAs(Continuation{Stage: StageBuilder, Input: input}); err != nil {
			return nil, false, false, err
		}
		if err := b.validateWorkingContext(); err != nil {
			return nil, false, false, err
		}
		if err := project.ValidateSource(b.SourceProvenance); err != nil {
			return nil, false, false, err
		}
		if err := b.Save(Continuation{Stage: StageTool, Owner: "build", Input: slices.Concat(input, outs)}); err != nil {
			return nil, false, false, err
		}
		var result agent.Output
		isFinish := false
		switch call.Name {
		case "finish":
			isFinish = true
		case "report_blocker":
			text, err := b.reportBlocker(args, call)
			if err != nil {
				return nil, false, false, err
			}
			result = agent.Output{Text: text}
		default:
			out, err := tools.Call(call)
			if err != nil {
				return nil, false, false, err
			}
			result = out.Cut()
		}
		if !isFinish {
			if event := agent.ReadEvent(call, result, "build"); event != nil {
				b.Run.Event(event)
			}
		}
		var resultLog any = "finish"
		if !isFinish {
			resultLog = provider.Fingerprint(result.Value())
		}
		b.Run.Event(map[string]any{
			"event": "tool_call", "call_id": call.CallID(), "name": call.Name,
			"arguments": provider.Fingerprint(call.Arguments), "result": resultLog,
		})
		done := &Completed{Call: call.Item, Result: "finish"}
		if !isFinish {
			done.Result = result.Value()
		}
		if err := b.Save(Continuation{Stage: StageTool, Owner: "build", Input: slices.Concat(input, outs), Completed: done}); err != nil {
			return nil, false, false, err
		}
		if call.Name == "shell" {
			if err := b.BaselineIntact(); err != nil {
				return nil, false, false, err
			}
		}
		if isFinish {
			finish = &calls[i]
		} else {
			outs = append(outs, call.Output(result))
		}
	}
	if finish == nil && len(calls) > 0 {
		return slices.Concat(input, outs), false, false, nil
	}
	var finishItem map[string]any
	if finish != nil {
		finishItem = finish.Item
	}
	input = slices.Concat(input, outs)
	if err := b.Save(Continuation{Stage: StageBuilderVerify, Input: input, Finish: finishItem}); err != nil {
		return nil, false, false, err
	}
	feedback, landed, err := b.roundEnd(ctx)
	if err != nil || landed {
		return nil, false, landed, err
	}
	return b.afterRound(input, finishItem, feedback), true, false, nil
}

// afterRound is the conversation after a round's verification: the feedback answers the
// finish call, or is a user message when the builder ended without one.
func (b *Attempt) afterRound(input []any, finish map[string]any, feedback string) []any {
	if finish != nil {
		return append(slices.Clone(input), agent.OutputItem(finish["call_id"], agent.Cut(feedback)))
	}
	return append(slices.Clone(input), map[string]any{"role": "user", "content": feedback})
}

// reportBlocker handles the builder's report_blocker call (LOOP-7). A valid report (exactly
// nonempty unique current protected paths, a reason and observed evidence) stops the Build
// as BUILDER-REPORTED build_blocked, provided HEAD and the protected bytes are still the
// original; anything else is feedback and grants nothing.
func (b *Attempt) reportBlocker(args map[string]any, call agent.Call) (string, error) {
	if !validBlocker(args, b.Baseline) {
		return "invalid blocker: supply exactly nonempty unique current protected paths, reason and observed evidence strings; " +
			"no write permission is granted; continue ordinary implementation repairs", nil
	}
	if err := b.BaselineIntact(); err != nil {
		return "", err
	}
	if err := b.headIntact(); err != nil {
		return "", err
	}
	blocker := map[string]any{}
	for k, v := range args {
		blocker[k] = v
	}
	blocker["classification"] = "BUILDER-REPORTED"
	b.Blocker = blocker
	if err := b.Track(); err != nil {
		return "", err
	}
	b.Run.Event(map[string]any{
		"event": "tool_call", "call_id": call.CallID(), "name": "report_blocker",
		"arguments": provider.Fingerprint(call.Arguments), "result": "BUILDER-REPORTED build_blocked",
	})
	b.Run.Event(map[string]any{"event": "builder_blocker", "blocker": blocker})
	var paths []string
	for _, p := range args["paths"].([]any) {
		paths = append(paths, p.(string))
	}
	e := sys.Fail("candidate", "build_blocked",
		"BUILDER-REPORTED protected-baseline contradiction; edits are left in place; this report is not independently proven", 1)
	e.Lines = []string{
		"paths: " + strings.Join(paths, ", "),
		"reason: " + agent.Cut(args["reason"].(string)),
		"evidence: " + agent.Cut(args["evidence"].(string)),
	}
	return "", e
}

func validBlocker(args map[string]any, baseline []string) bool {
	if len(args) != 3 {
		return false
	}
	for _, k := range []string{"evidence", "paths", "reason"} {
		if _, ok := args[k]; !ok {
			return false
		}
	}
	paths, ok := args["paths"].([]any)
	if !ok || len(paths) == 0 {
		return false
	}
	seen := map[string]bool{}
	for _, p := range paths {
		s, ok := p.(string)
		if !ok || !slices.Contains(baseline, s) || seen[s] {
			return false
		}
		seen[s] = true
	}
	for _, k := range []string{"reason", "evidence"} {
		if s, ok := args[k].(string); !ok || strings.TrimSpace(s) == "" {
			return false
		}
	}
	return true
}

// roundEnd runs the fixers once, then passes and reviews until the builder has work again
// (feedback) or the Build landed.
func (b *Attempt) roundEnd(ctx context.Context) (feedback string, landed bool, err error) {
	if err := verify.Fix(ctx, b.s, b.verifyInput(b.Pass)); err != nil {
		return "", false, err
	}
	if b.StageProgress != nil && b.StageProgress.Phase == phaseStage {
		return b.stageGate(ctx)
	}
	return b.verifyAndReview(ctx)
}

// stageGate is the scoped gate of the active stage after a builder round: a pass of the
// stage's own checks only, recorded as durable private evidence. A green gate advances the
// plan and the next stage's navigation answers the builder's finish call; the last one
// leaves the whole-Intent gates, independent review and commit. A red gate keeps the builder
// at the same stage.
func (b *Attempt) stageGate(ctx context.Context) (string, bool, error) {
	p := b.StageProgress.clone()
	index := len(p.Completed) + 1
	stage := b.StagePlan[index-1]
	b.s.Progress(fmt.Sprintf("kogen: stage %d/%d: %s", index, p.Total, stage.ID))
	pass, err := b.verifyStage(ctx, stage)
	if err != nil {
		return "", false, err
	}
	evidence, err := b.retainStage(StageEvidence{Pass: pass, StageID: stage.ID, Index: index, Contract: b.ApprovalBytes})
	if err != nil {
		return "", false, err
	}
	b.StageEvidence = append(slices.Clone(b.StageEvidence), evidence)
	b.Run.Event(map[string]any{
		"event": "stage_pass", "stage_id": stage.ID, "stage_index": index, "tree": pass.Tree,
		"green": pass.Green, "failing": nonNil(pass.Failing), "not_run": nonNil(pass.NotRun),
	})
	if pass.Green {
		b.s.Progress("kogen: stage " + stage.ID + " gate passed")
	} else {
		b.s.Progress("kogen: stage " + stage.ID + " gate failed")
	}
	if !pass.Green {
		b.Repairs++
		if err := b.Track(); err != nil {
			return "", false, err
		}
		return "Stage " + stage.ID + " failed; remain at this stage.\n" + b.PassFeedback(pass, "finish"), false, nil
	}
	p.Completed = append(p.Completed, stage.ID)
	p.Active, p.Phase = nil, phaseFinal
	if index < len(b.StagePlan) {
		next := b.StagePlan[index].ID
		p.Active, p.Phase = &next, phaseStage
	}
	b.StageProgress = &p
	if err := b.Track(); err != nil {
		return "", false, err
	}
	if p.Active == nil {
		// Every scoped stage is verified: the whole Intent's own gates, review and commit.
		if err := b.Save(b.Continuation); err != nil {
			return "", false, err
		}
		return b.verifyAndReview(ctx)
	}
	// The verified milestone and its navigation are durable before the next request.
	feedback := "Stage " + stage.ID + " passed. Continue the next stage. " + b.State.navigation()
	c := b.Continuation
	next := b.afterRound(c.Input, c.Finish, feedback)
	if err := b.Save(Continuation{Stage: StageBuilder, Input: next}); err != nil {
		return "", false, err
	}
	return feedback, false, nil
}

// verifyStage runs the stage's scoped pass: numbered like any pass, but never recorded as the
// Build's last pass (a milestone is historical evidence, not whole-Intent proof).
func (b *Attempt) verifyStage(ctx context.Context, stage stageDef) (verify.Pass, error) {
	b.Pass++
	if err := b.Track(); err != nil {
		return verify.Pass{}, err
	}
	if err := b.facts.update(b, "verifying", ""); err != nil {
		return verify.Pass{}, err
	}
	in := b.verifyInput(b.Pass)
	in.Stage = &verify.Stage{ID: stage.ID, Checks: stage.Checks}
	pass, err := verify.Verify(ctx, b.s, in)
	if err != nil {
		return verify.Pass{}, err
	}
	return pass, b.Track()
}

func (b *Attempt) verifyAndReview(ctx context.Context) (string, bool, error) {
	pass, err := b.Verify(ctx)
	if err != nil {
		return "", false, err
	}
	if !pass.Green {
		b.Repairs++
		return b.PassFeedback(pass, "finish"), false, nil
	}
	approved, err := b.deps.reviewer().Review(ctx, b, pass)
	if err != nil {
		return "", false, err
	}
	if err := b.Track(); err != nil {
		return "", false, err
	}
	return b.commit(ctx, approved)
}

// ---- resume of a conversation stage ----

// resumeStage continues the Build from its checkpointed stage.
func (b *Attempt) resumeStage(ctx context.Context) error {
	if err := provider.RequireLogin(b.s.Getenv("HOME"), buildRoles(b.Config)); err != nil {
		return err
	}
	c := b.Continuation
	switch c.Stage {
	case StageBuilder:
		return b.drive(ctx, c.Input, false)
	case StageBuilderVerify:
		feedback, landed, err := b.roundEnd(ctx)
		if err != nil || landed {
			return err
		}
		return b.drive(ctx, b.afterRound(c.Input, c.Finish, feedback), true)
	default: // the review stages
		approved, err := b.deps.reviewer().Resume(ctx, b)
		if err != nil {
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
}

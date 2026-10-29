package build

import (
	"context"
	"errors"
	"slices"
	"time"

	"kogen-loop/api"
	"kogen-loop/loop"
	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
	"kogen/agent"
	"kogen/executor"
	"kogen/internal/research"
	"kogen/project"
)

// The builder's tools: the file and command tools plus the two terminal tools.
var (
	builderTools = []string{"shell", "read_file", "view_image", "write_file"}
	builderDefs  = []string{"shell", "read_file", "view_image", "write_file", "finish", "report_blocker"}
)

// nativeExecutor is the default build executor (docs/executor-contract.md): Kogen's own
// builder round, run by kogen-loop's engine with hooks that keep every checkpoint, run-log
// event and custody check of the Build in the order the builder always had them. It works on
// the Build it belongs to, so Start takes only the brief, the deadline and nothing else from
// the Task; the checkout, the baseline and the role are the Attempt's.
type nativeExecutor struct {
	b *Attempt
	// tail are the messages that follow the opening message (the caller's diagnostic data).
	tail []any
}

// nativeVersion identifies the engine the native builder runs on.
const nativeVersion = "kogen-loop " + api.Library

func (nativeExecutor) Describe() executor.Descriptor {
	return executor.Descriptor{
		Name:     executor.Native,
		Contract: executor.Contract,
		Version:  nativeVersion,
		Capabilities: executor.Capabilities{
			Roles:        []string{executor.RoleBuild},
			Resume:       executor.ResumeExact,
			Continuation: true,
			Usage:        executor.UsageProvider,
			Prevention:   []string{executor.PreventWriteTool},
			Blocker:      true,
			Images:       true,
			MaxRounds:    0,
		},
	}
}

// Start opens the native conversation with the brief as the opening message, byte for byte
// the message the builder has always opened with.
func (n nativeExecutor) Start(_ context.Context, t executor.Task, _ executor.Sink) (executor.Session, error) {
	opening := map[string]any{"role": "user", "content": provider.ContractBlocks(t.Brief.Stable, t.Brief.Dynamic)}
	s := n.b.nativeSession(append([]any{opening}, n.tail...), nil, nil)
	s.deadline = t.Deadline
	return s, nil
}

// nativeSession is the builder's conversation across rounds.
type nativeSession struct {
	b *Attempt
	// pending is the exact input of the next round when it has no feedback: the opening
	// message of a fresh Build, or the saved input of a resumed builder stage.
	pending []any
	// input and finish are the conversation after the last round and the finish call that
	// ended it (nil after an answer without a tool call); feedback answers it.
	input  []any
	finish map[string]any
	// deadline bounds a round (zero: none).
	deadline time.Time
}

func (b *Attempt) nativeSession(pending, input []any, finish map[string]any) *nativeSession {
	return &nativeSession{b: b, pending: pending, input: input, finish: finish}
}

func (n *nativeSession) Handle() executor.Handle {
	return executor.Handle{Executor: executor.Native, Version: nativeVersion, SessionID: n.b.Run.ID, Resume: executor.ResumeExact}
}

func (n *nativeSession) Close() error { return nil }

// attemptRequester sends the builder's requests through the Build's own bookkeeping
// (Attempt.Request): custody checks, working context, checkpoints, usage and image delivery.
type attemptRequester struct {
	b    *Attempt
	role project.Role
}

func (r attemptRequester) Request(ctx context.Context, q loop.Request) (*provider.Response, []any, error) {
	return r.b.Request(ctx, RequestSpec{Owner: q.Owner, Role: r.role, Instructions: q.Instructions, Input: q.Input, Tools: q.Tools})
}

// Round runs one builder round: the builder's requests and the tool calls it asks for, until
// it finishes or answers without a tool call. The round's end is the builder's claim; the
// fixers, verification and review are the Build's (drive).
func (n *nativeSession) Round(ctx context.Context, in executor.Input) (executor.RoundResult, error) {
	b := n.b
	b.watch.tools = 0
	var input []any
	if in.Feedback == "" && n.pending != nil {
		input, n.pending = n.pending, nil
	} else {
		input = b.afterRound(n.input, n.finish, in.Feedback)
	}
	if !n.deadline.IsZero() {
		var cancel context.CancelFunc
		ctx, cancel = context.WithDeadline(ctx, n.deadline)
		defer cancel()
	}
	role := b.Config.Models["build"]
	tl := research.ApplyTools(&tools.Tools{Root: b.Root, Session: b.s, Repo: agent.Git(b.repo), Enabled: builderTools, Protected: b.Baseline, Excluded: b.Excluded, ShellTimeout: b.Config.ShellTimeout})
	rd := loop.Round{
		Owner: "build", Role: providerRole(role), Instructions: agent.Prompt(agent.Builder),
		Definitions: shellDefinitions(tl, builderDefs),
		Tools:       tl,
		Terminal:    []string{agent.FinishTool},
	}
	var batch []tools.Call
	var base []any // the round's input after replay, as the stage validation sees it
	var usages []api.Usage
	hooks := loop.Hooks{
		BeforeRequest: func(ctx context.Context, input []any) error {
			if err := b.facts.update(b, "building", ""); err != nil {
				return err
			}
			return b.Save(Continuation{Stage: StageBuilder, Input: input})
		},
		AfterResponse: func(ctx context.Context, resp *provider.Response, sent []any) error {
			if err := b.Track(); err != nil {
				return err
			}
			if role.NoProgress {
				batch = tools.Calls(resp.Items)
			}
			base = slices.Concat(sent, tools.Replay(resp.Items))
			usages = append(usages, loop.UsageOf(resp))
			return nil
		},
		BeforeCall: func(ctx context.Context, call tools.Call, input []any) error {
			if err := b.s.Err(); err != nil {
				return err
			}
			if err := b.validateStagesAs(Continuation{Stage: StageBuilder, Input: base}); err != nil {
				return err
			}
			if err := b.validateWorkingContext(); err != nil {
				return err
			}
			if err := project.ValidateSource(b.SourceProvenance); err != nil {
				return err
			}
			return b.Save(Continuation{Stage: StageTool, Owner: "build", Input: input})
		},
		HandleCall: func(ctx context.Context, call tools.Call) (loop.Handled, error) {
			if call.Name != agent.ReportBlockerTool {
				return loop.Handled{}, nil
			}
			text, err := b.reportBlocker(call.Args(), call)
			if err != nil {
				return loop.Handled{}, err
			}
			return loop.Handled{Handled: true, Output: tools.Output{Text: text}}, nil
		},
		AfterCall: func(ctx context.Context, call tools.Call, out tools.Output, terminal bool, input []any) error {
			b.watch.tools++
			if !terminal {
				if event := tools.ReadEvent(call, out, "build"); event != nil {
					b.Run.Event(event)
				}
			}
			var resultLog any = "finish"
			if !terminal {
				resultLog = provider.Fingerprint(out.Value())
			}
			event := map[string]any{
				"event": "tool_call", "call_id": call.CallID(), "name": call.Name,
				"arguments": provider.Fingerprint(call.Arguments), "result": resultLog,
			}
			if !terminal {
				for k, v := range b.toolRecordFields(call, out, func(string) (int, bool) { return 0, false }) {
					event[k] = v
				}
			}
			b.Run.Event(event)
			done := &Completed{Call: call.Item, Result: "finish"}
			if !terminal {
				done.Result = out.Value()
			}
			if err := b.Save(Continuation{Stage: StageTool, Owner: "build", Input: input, Completed: done}); err != nil {
				return err
			}
			if call.Name == "shell" {
				return b.BaselineIntact()
			}
			return nil
		},
	}
	if role.NoProgress {
		hooks.Progress = func(_ context.Context, _ int) (string, error) {
			fp := nativeFingerprint(batch)
			batch = nil
			return fp, nil
		}
	}
	res, err := loop.Run(ctx, rd, input, attemptRequester{b, role}, hooks)
	var noProgress *loop.NoProgressError
	if errors.As(err, &noProgress) {
		b.nativeNoProgress = noProgress
		b.Run.Event(map[string]any{"event": "native_no_progress", "fingerprint": noProgress.Fingerprint, "count": len(noProgress.Rounds), "rounds": noProgress.Rounds})
	}
	if err != nil {
		return executor.RoundResult{}, n.stop(ctx, err)
	}
	n.input, n.finish = res.Input, nil
	if res.Terminal != nil {
		n.finish = res.Terminal.Item
	}
	if err := b.Save(Continuation{Stage: StageBuilderVerify, Input: n.input, Finish: n.finish}); err != nil {
		return executor.RoundResult{}, err
	}
	out := executor.RoundResult{Ending: executor.EndNoCall, Usage: executorUsage(loop.SumUsage(usages...), res.Response), Handle: n.Handle()}
	claim := finalText(res.Response)
	if res.Terminal != nil {
		out.Ending = executor.EndFinish
		claim = res.Terminal.Arguments
		if summary, ok := res.Terminal.Args()["summary"].(string); ok {
			claim = summary
		}
	}
	out.Claim = tools.Cut(claim)
	return out, nil
}

// stop is the error a round ends with. A cancelled round is an interrupt or the deadline
// (a sys.Interrupted, and the Session's own interrupt, keep their exit codes); every other
// stop (a custody stop, a builder-reported blocker, a provider failure) is returned unchanged.
func (n *nativeSession) stop(ctx context.Context, err error) error {
	var interrupted *sys.Interrupted
	if errors.As(err, &interrupted) || ctx.Err() == nil {
		return err
	}
	var typed *sys.Error
	if errors.As(err, &typed) && typed.Class == "candidate" {
		return err
	}
	if ie := n.b.s.Err(); ie != nil {
		return ie
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return executor.Fail(executor.ReasonDeadline, "the round deadline passed; the builder's commands were stopped")
	}
	return executor.Fail(executor.ReasonInterrupted, "the round was interrupted; the builder's commands were stopped")
}

// executorUsage is a round's provider-reported usage as the executor contract states it.
func executorUsage(u api.Usage, last *provider.Response) executor.Usage {
	out := executor.Usage{Input: u.Input, Cached: u.Cached, Output: u.Output, Reasoning: u.Reasoning, State: u.State, Source: executor.UsageProvider}
	if last != nil {
		out.Model = last.Model
	}
	return out
}

// finalText is the text of the answers in a response (the claim of a round that ended
// without a tool call).
func finalText(resp *provider.Response) string {
	if resp == nil {
		return ""
	}
	var text string
	for _, it := range resp.Items {
		if it["type"] != "message" {
			continue
		}
		content, _ := it["content"].([]any)
		for _, c := range content {
			if part, ok := c.(map[string]any); ok && part["type"] == "output_text" {
				if t, ok := part["text"].(string); ok {
					if text != "" {
						text += "\n"
					}
					text += t
				}
			}
		}
	}
	return text
}

// shellDefinitions keeps all other definitions unchanged while using the executing tool's policy.
func shellDefinitions(t *tools.Tools, names []string) []any {
	defs := agent.Defs(names...)
	for i, name := range names {
		if name == "shell" {
			defs[i], _ = t.Definition(name)
		}
	}
	return agent.AsAny(defs)
}

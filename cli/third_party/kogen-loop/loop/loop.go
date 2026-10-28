// Package loop is kogen-loop's round engine (contract loop/v1, docs/contract/loop-v1.md): it
// sends a model request, runs the tool calls the model asks for and repeats until the model
// ends the round with a terminal tool call or with an answer that has no tool call. A round
// ending is the model's claim, never proof that the work is done.
//
// Round.MaxRounds (0: no limit, no default) stops a run that would continue after that many
// requests with *RoundLimitError. Hooks.Progress (nil: disabled, no default) returns a
// fingerprint after each continuing round; NoProgressRounds identical ones stop the run with
// *NoProgressError, checked before the round limit.
//
// Run is the engine. Callers attach custody, checkpoints, events and policy with Hooks and
// intercept calls with Hooks.HandleCall; Session is the standalone multi-round conversation.
package loop

import (
	"context"
	"fmt"
	"slices"
	"strings"

	"kogen-loop/api"
	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
)

// Request is one model request of a round.
type Request struct {
	Owner        string        // conversation owner label (e.g. "build"); used for cache identity and events
	Role         provider.Role // provider, model, effort, base URL
	Instructions string
	Input        []any // Responses-style input items
	Tools        []any // model-facing tool definitions, sent verbatim
	// DisableParallelToolCalls asks the provider not to generate parallel tool calls; a batch
	// that is returned is still executed in full unless Round.StopAfterTerminal is set.
	DisableParallelToolCalls bool
}

// Requester sends one request. It returns the response and the input actually sent (a
// context policy may reduce it).
type Requester interface {
	Request(ctx context.Context, r Request) (*provider.Response, []any, error)
}

// ContextPolicy prepares the input of a request. The default refuses an over-budget request
// (typed error loop/context_budget_exceeded) instead of silently clipping. Compaction,
// working-window and summary experiments implement this interface.
type ContextPolicy interface {
	Prepare(ctx context.Context, r Request) ([]any, error)
}

// FailOverBudget is the default ContextPolicy: it measures the complete rendered request and
// refuses one that exceeds the role's input budget (provider.InputBudgetBytes, or a smaller
// documented bound of the model family) with loop/context_budget_exceeded, before anything is
// sent. It never clips the input.
//
// Client, Cache and CacheID only make the measured body the body that will be sent (cache
// identity placement); Direct fills them in when it uses the zero value. The zero value works
// on its own.
type FailOverBudget struct {
	Client  *provider.Client
	Cache   *provider.Cache
	CacheID string

	// InputBudgetBytes lowers the input ceiling. Zero keeps the default (524288); otherwise it
	// must be in [MinInputBudgetBytes, tools.InputBudgetBytes]. It never raises the role's bound.
	InputBudgetBytes int
}

// MinInputBudgetBytes is the smallest nonzero FailOverBudget.InputBudgetBytes.
const MinInputBudgetBytes = 65536

// Prepare returns r.Input unchanged when the request fits.
func (p FailOverBudget) Prepare(ctx context.Context, r Request) ([]any, error) {
	if b := p.InputBudgetBytes; b != 0 && (b < MinInputBudgetBytes || b > tools.InputBudgetBytes) {
		return nil, sys.Fail(api.ErrClassLoop, api.ErrInvalidTask, fmt.Sprintf(
			"InputBudgetBytes %d is invalid: must be 0 (default) or in [%d, %d]",
			b, MinInputBudgetBytes, tools.InputBudgetBytes), 2)
	}
	if _, ok := provider.Lookup(r.Role.Provider); !ok {
		// Respond refuses an unknown provider with its own error; there is nothing to measure.
		return r.Input, nil
	}
	client := p.Client
	if client == nil {
		client = provider.NewClient("")
	}
	body := client.Body(provider.Request{
		Role: r.Role, Instructions: r.Instructions, Input: r.Input, Tools: r.Tools,
		CacheID: p.CacheID, Cache: p.Cache, DisableParallelToolCalls: r.DisableParallelToolCalls,
	})
	m, err := tools.Measure(body, r.Role)
	if err != nil {
		return nil, err
	}
	limit := m.InputBudgetBytes
	if p.InputBudgetBytes != 0 && p.InputBudgetBytes < limit {
		limit = p.InputBudgetBytes
	}
	if m.RenderedBytes > limit {
		return nil, sys.Fail(api.ErrClassLoop, api.ErrContextBudget, fmt.Sprintf(
			"%s: complete next request %d bytes exceeds %d; reserve %d tokens. Nothing was sent and nothing was clipped.",
			ownerLabel(r.Owner), m.RenderedBytes, limit, m.OutputReserveTokens), 1)
	}
	return r.Input, nil
}

func ownerLabel(owner string) string {
	if owner == "" {
		return "request"
	}
	return owner
}

// Direct is the provider-backed Requester (provider.Client.Respond) with a ContextPolicy and
// an optional provider.Observer for attempt records.
type Direct struct {
	Client   *provider.Client
	Session  *sys.Session
	Policy   ContextPolicy     // nil: FailOverBudget{}
	Observer provider.Observer // nil: none
	CacheID  string            // one cache identity per conversation (kept across rounds)
	Cache    *provider.Cache

	// InputBudgetBytes is passed to the default FailOverBudget only; a non-nil Policy owns
	// policy and this field (even invalid) is ignored.
	InputBudgetBytes int
}

// Request applies the policy, then sends the request with provider.Client.Respond. It
// returns the response and the input the policy let through.
func (d *Direct) Request(ctx context.Context, r Request) (*provider.Response, []any, error) {
	policy := d.Policy
	if policy == nil {
		policy = FailOverBudget{Client: d.Client, Cache: d.Cache, CacheID: d.CacheID,
			InputBudgetBytes: d.InputBudgetBytes}
	}
	sent, err := policy.Prepare(ctx, r)
	if err != nil {
		return nil, nil, err
	}
	client := d.Client
	if client == nil {
		client = provider.NewClient("")
	}
	resp, err := client.Respond(ctx, d.Session, provider.Request{
		Role: r.Role, Instructions: r.Instructions, Input: sent, Tools: r.Tools,
		CacheID: d.CacheID, Cache: d.Cache, DisableParallelToolCalls: r.DisableParallelToolCalls,
	}, d.Observer)
	if err != nil {
		return nil, nil, err
	}
	return resp, sent, nil
}

// Handled is a caller's answer to a tool call it intercepts.
type Handled struct {
	Handled  bool         // false: the engine runs the call with Round.Tools
	Output   tools.Output // the call's output when Handled and not Terminal
	Terminal bool         // the call ends the round after this batch (no output is appended)
}

// Hooks let a caller attach custody, checkpoints, events and policy without forking the
// engine. Every hook is optional. A hook error stops the round and is returned unchanged.
type Hooks struct {
	BeforeRequest func(ctx context.Context, input []any) error
	AfterResponse func(ctx context.Context, resp *provider.Response, sent []any) error
	BeforeCall    func(ctx context.Context, call tools.Call, input []any) error
	HandleCall    func(ctx context.Context, call tools.Call) (Handled, error)
	AfterCall     func(ctx context.Context, call tools.Call, out tools.Output, terminal bool, input []any) error
	// Progress is called after each round that did not end (after its calls) with the 1-based
	// round number and returns a progress fingerprint. nil disables the no-progress stop;
	// there is no default. An error stops the run and is returned unchanged.
	Progress func(ctx context.Context, round int) (string, error)
	// TerminalReminder is called once for each reminder Round.TerminalReminders appends, before
	// the next request, with the 1-based reminder number and the effective terminal names. An
	// error stops the run and is returned unchanged.
	TerminalReminder func(ctx context.Context, reminder int, terminals []string) error
}

// NoProgressRounds is the number of consecutive identical Progress fingerprints that stop a
// run with NoProgressError. It is a constant, not a setting.
const NoProgressRounds = 3

// RoundLimitError is returned by Run when Round.MaxRounds requests were sent and the round
// would have continued. Rounds is the number of rounds run.
type RoundLimitError struct{ Rounds int }

func (e *RoundLimitError) Error() string {
	return fmt.Sprintf("loop: round limit reached after %d rounds", e.Rounds)
}

// NoProgressError is returned by Run when NoProgressRounds consecutive rounds returned an
// identical Progress fingerprint. Rounds holds those round numbers.
type NoProgressError struct {
	Rounds      []int
	Fingerprint string
}

func (e *NoProgressError) Error() string {
	return fmt.Sprintf("loop: no progress in rounds %v (fingerprint %q)", e.Rounds, e.Fingerprint)
}

// Round describes one round.
type Round struct {
	ReadLedger               *ReadLedger // optional caller-owned history across runs
	Owner                    string
	Role                     provider.Role
	Instructions             string
	Definitions              []any        // tool definitions sent to the model
	Tools                    *tools.Tools // executes non-handled calls (enabled set, protected/excluded paths)
	Terminal                 []string     // names that end the round without execution; default ["finish"]
	DisableParallelToolCalls bool         // ask the provider for one tool call per response; unsupported routes refuse
	MaxRounds                int          // stop with RoundLimitError after this many requests when the round would continue; 0 is no limit (no default)
	// TerminalReminders permits that many reminder continuations per Run after a response
	// without a tool call; nonpositive keeps ending such a round with EndNoCall.
	TerminalReminders int
	// StopAfterTerminal (default false) makes the first terminal of a batch the Result.Terminal
	// and answers every later call of that batch with SkippedAfterTerminal instead of running it
	// (BeforeCall and AfterCall still observe it, with terminal false). False keeps the last
	// terminal and runs every call.
	StopAfterTerminal bool
}

// SkippedAfterTerminal is the output of a call skipped because Round.StopAfterTerminal ended
// the round at an earlier terminal call of the same batch.
const SkippedAfterTerminal = "skipped: earlier terminal call ended the round"

// Ending is how a round ended. Both endings are model claims.
type Ending string

const (
	EndTerminal Ending = "terminal" // a terminal tool was called
	EndNoCall   Ending = "no_call"  // the model answered without any tool call
)

// Result is a finished round.
type Result struct {
	Ending   Ending
	Terminal *tools.Call        // last terminal call of the final batch, or the first with StopAfterTerminal (EndTerminal only)
	Input    []any              // conversation after the round: sent input + replayed response items + outputs of non-terminal calls
	Response *provider.Response // last response
	Requests int                // requests sent in this round
}

// DefaultTerminal is the terminal tool name when a Round names none.
var DefaultTerminal = []string{"finish"}

// Run runs one round over input, in the order of the contract (section 2, "Engine order"):
//
//  1. BeforeRequest(input).
//  2. resp, sent := rq.Request(...).
//  3. AfterResponse(resp, sent).
//  4. input = sent ++ tools.Replay(resp.Items); calls = tools.Calls(resp.Items).
//  5. For each call: return ctx.Err() if set; BeforeCall(call, input ++ outs); a Terminal name
//     is marked terminal (the last one wins) and is not executed; otherwise HandleCall when it
//     handles the call, else Tools.CallContext(ctx, call) and Output.Cut; AfterCall(call, out, terminal,
//     input ++ outs); append call.Output(out) to outs unless the call is terminal.
//     With Round.StopAfterTerminal the first terminal wins and each later call is answered with
//     SkippedAfterTerminal without execution or HandleCall (BeforeCall/AfterCall still run).
//  6. No terminal call and at least one call: input = input ++ outs and go to 1.
//  7. Otherwise return the Result.
//
// Unless Round.StopAfterTerminal is set, calls after a terminal call in the same batch still run. A hook error, a tool interrupt
// (a shell stopped by the caller), timeout observation failure or a cancelled context
// stops the round; the error is
// returned unchanged. When ctx ends, every process group started through rd.Tools.Session
// during the round is terminated before Run returns.
func Run(ctx context.Context, rd Round, input []any, rq Requester, h Hooks) (result Result, err error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if rd.Tools != nil {
		if err := rd.Tools.Validate(); err != nil {
			return Result{}, err
		}
	}
	terminal := rd.Terminal
	if len(terminal) == 0 {
		terminal = DefaultTerminal
	}
	if rd.Tools != nil && rd.Tools.Session != nil {
		defer custody(ctx, rd.Tools.Session)()
	}
	requests, reminders := 0, 0
	var streak []int
	var fingerprint string
	for {
		if h.BeforeRequest != nil {
			if err := h.BeforeRequest(ctx, input); err != nil {
				return Result{}, err
			}
		}
		requests++
		resp, sent, err := rq.Request(ctx, Request{
			Owner: rd.Owner, Role: rd.Role, Instructions: rd.Instructions, Input: input, Tools: rd.Definitions,
			DisableParallelToolCalls: rd.DisableParallelToolCalls,
		})
		if err != nil {
			return Result{}, err
		}
		if h.AfterResponse != nil {
			if err := h.AfterResponse(ctx, resp, sent); err != nil {
				return Result{}, err
			}
		}
		input = slices.Concat(sent, tools.Replay(resp.Items))
		calls := tools.Calls(resp.Items)
		var outs []any
		var last *tools.Call
		for i := range calls {
			call := calls[i]
			if err := ctx.Err(); err != nil {
				return Result{}, err
			}
			if h.BeforeCall != nil {
				if err := h.BeforeCall(ctx, call, slices.Concat(input, outs)); err != nil {
					return Result{}, err
				}
			}
			if err := ctx.Err(); err != nil {
				return Result{}, err
			}
			var out tools.Output
			isTerminal := slices.Contains(terminal, call.Name)
			skip := rd.StopAfterTerminal && last != nil
			if skip {
				isTerminal = false
				out = tools.Output{Text: SkippedAfterTerminal}
			} else if !isTerminal {
				handled := false
				if h.HandleCall != nil {
					hd, err := h.HandleCall(ctx, call)
					if err != nil {
						return Result{}, err
					}
					if hd.Handled {
						handled, out, isTerminal = true, hd.Output, hd.Terminal
					}
				}
				if err := ctx.Err(); err != nil {
					return Result{}, err
				}
				if !handled {
					if rd.Tools == nil {
						out = tools.Output{Text: "error: unknown tool " + call.Name}
					} else {
						o, err := rd.Tools.CallContext(ctx, call)
						if err != nil {
							return Result{}, err
						}
						out = o
					}
					if rd.Tools != nil {
						uncut := out.Text
						out = rd.Tools.Cut(out)
						if rd.ReadLedger != nil && out.ReadOK {
							rd.ReadLedger.record(call, out, uncut)
						}
					} else {
						out = out.Cut()
					}
				}
			}
			// A tool can return after custody has terminated its process group.
			// Do not publish that interrupted output or start another request.
			if err := ctx.Err(); err != nil {
				return Result{}, err
			}
			if isTerminal {
				last = &calls[i]
			}
			if h.AfterCall != nil {
				if err := h.AfterCall(ctx, call, out, isTerminal, slices.Concat(input, outs)); err != nil {
					return Result{}, err
				}
			}
			if !isTerminal {
				outs = append(outs, call.Output(out))
			}
		}
		if err := ctx.Err(); err != nil {
			return Result{}, err
		}
		remind := last == nil && len(calls) == 0 && reminders < rd.TerminalReminders
		if last == nil && (len(calls) > 0 || remind) {
			input = slices.Concat(input, outs)
			stop := Result{Input: input, Response: resp, Requests: requests}
			if h.Progress != nil {
				fp, err := h.Progress(ctx, requests)
				if err != nil {
					return Result{}, err
				}
				if len(streak) > 0 && fp == fingerprint {
					streak = append(streak, requests)
				} else {
					streak, fingerprint = []int{requests}, fp
				}
				if len(streak) >= NoProgressRounds {
					return stop, &NoProgressError{Rounds: streak, Fingerprint: fp}
				}
			}
			if err := ctx.Err(); err != nil {
				return Result{}, err
			}
			if rd.MaxRounds > 0 && requests >= rd.MaxRounds {
				return stop, &RoundLimitError{Rounds: requests}
			}
			if remind {
				reminders++
				if h.TerminalReminder != nil {
					if err := h.TerminalReminder(ctx, reminders, slices.Clone(terminal)); err != nil {
						return Result{}, err
					}
				}
				if err := ctx.Err(); err != nil {
					return Result{}, err
				}
				input = slices.Concat(input, []any{map[string]any{
					"role": "user", "content": "Call one of these terminal tools to end this round: " + strings.Join(terminal, ", ") + ".",
				}})
			}
			continue
		}
		res := Result{Ending: EndNoCall, Terminal: last, Input: slices.Concat(input, outs), Response: resp, Requests: requests}
		if last != nil {
			res.Ending = EndTerminal
		}
		return res, nil
	}
}

// custody terminates the process groups the round started when ctx ends or the caller
// interrupts the session, and makes the returned function wait until that termination has
// finished. Groups that the session started before the round are left alone.
func custody(ctx context.Context, s *sys.Session) (wait func()) {
	before := map[int]bool{}
	for _, g := range s.Groups() {
		before[g] = true
	}
	terminate := func() {
		var mine []int
		for _, g := range s.Groups() {
			if !before[g] {
				mine = append(mine, g)
			}
		}
		sys.Terminate(mine)
	}
	done := make(chan struct{})
	stop := context.AfterFunc(ctx, func() {
		defer close(done)
		terminate()
	})
	return func() {
		if !stop() {
			<-done
		} else if s.Err() != nil {
			terminate()
		}
	}
}

// Package loop is kogen-loop's round engine (contract loop/v1, docs/contract/loop-v1.md): it
// sends a model request, runs the tool calls the model asks for and repeats until the model
// ends the round with a terminal tool call or with an answer that has no tool call. A round
// ending is the model's claim, never proof that the work is done.
//
// Run is the engine. Callers attach custody, checkpoints, events and policy with Hooks and
// intercept calls with Hooks.HandleCall; Session is the standalone multi-round conversation.
package loop

import (
	"context"
	"fmt"
	"os"
	"slices"

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
}

// Requester sends one request. It returns the response and the input actually sent.
type Requester interface {
	Request(ctx context.Context, r Request) (*provider.Response, []any, error)
}

// FailOverBudget measures the complete rendered request and
// refuses one that exceeds the role's input budget (provider.InputBudgetBytes, or a smaller
// documented bound of the model family) with loop/context_budget_exceeded, before anything is
// sent. It never clips the input. Direct always applies it.
//
// Client, Cache and CacheID only make the measured body the body that will be sent (cache
// identity placement); Direct fills them in. The zero value works on its own.
type FailOverBudget struct {
	Client  *provider.Client
	Cache   *provider.Cache
	CacheID string
}

// Prepare returns r.Input unchanged when the request fits.
func (p FailOverBudget) Prepare(ctx context.Context, r Request) ([]any, error) {
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
		CacheID: p.CacheID, Cache: p.Cache,
	})
	m, err := tools.Measure(body, r.Role)
	if err != nil {
		return nil, err
	}
	limit := m.InputBudgetBytes
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

// Direct is the provider-backed Requester (provider.Client.Respond) that refuses an
// over-budget request before sending it, with an optional provider.Observer for attempt records.
type Direct struct {
	Client   *provider.Client
	Session  *sys.Session
	Observer provider.Observer // nil: none
	CacheID  string            // one cache identity per conversation (kept across rounds)
	Cache    *provider.Cache
}

// Request refuses an over-budget request, then sends it with provider.Client.Respond. It
// returns the response and the input it sent.
func (d *Direct) Request(ctx context.Context, r Request) (*provider.Response, []any, error) {
	sent, err := FailOverBudget{Client: d.Client, Cache: d.Cache, CacheID: d.CacheID}.Prepare(ctx, r)
	if err != nil {
		return nil, nil, err
	}
	client := d.Client
	if client == nil {
		client = provider.NewClient("")
	}
	resp, err := client.Respond(ctx, d.Session, provider.Request{
		Role: r.Role, Instructions: r.Instructions, Input: sent, Tools: r.Tools,
		CacheID: d.CacheID, Cache: d.Cache,
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
}

// Round describes one round.
type Round struct {
	Owner        string
	Role         provider.Role
	Instructions string
	Definitions  []any        // tool definitions sent to the model
	Tools        *tools.Tools // executes non-handled calls (enabled set, protected/excluded paths)
	Terminal     []string     // names that end the round without execution; default ["finish"]
}

// Ending is how a round ended. Both endings are model claims.
type Ending string

const (
	EndTerminal Ending = "terminal" // a terminal tool was called
	EndNoCall   Ending = "no_call"  // the model answered without any tool call
)

// Result is a finished round.
type Result struct {
	Ending   Ending
	Terminal *tools.Call        // last terminal call of the final batch (EndTerminal only)
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
//  6. No terminal call and at least one call: input = input ++ outs and go to 1.
//  7. Otherwise return the Result.
//
// Calls after a terminal call in the same batch still run. A hook error, a tool interrupt
// (a shell stopped by the caller), timeout observation failure or a cancelled context
// stops the round; the error is
// returned unchanged. Whatever the outcome, every process group started through
// rd.Tools.Session during the round is terminated before Run returns, background
// processes included; they stay alive between the round's calls. A shell that is starting,
// or running when ctx ends is stopped by the call itself (Tools.CallContext forwards ctx).
// Groups started before the round and processes that left their group are untouched.
func Run(ctx context.Context, rd Round, input []any, rq Requester, h Hooks) (result Result, err error) {
	if ctx == nil {
		ctx = context.Background()
	}
	terminal := rd.Terminal
	if len(terminal) == 0 {
		terminal = DefaultTerminal
	}
	if rd.Tools != nil {
		if rd.Tools.Session == nil {
			t := *rd.Tools
			t.Session = sys.NewWith(os.Environ(), t.Root)
			rd.Tools = &t
		}
		defer custody(rd.Tools.Session)()
	}
	requests := 0
	for {
		if h.BeforeRequest != nil {
			if err := h.BeforeRequest(ctx, input); err != nil {
				return Result{}, err
			}
		}
		requests++
		resp, sent, err := rq.Request(ctx, Request{
			Owner: rd.Owner, Role: rd.Role, Instructions: rd.Instructions, Input: input, Tools: rd.Definitions,
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
			if !isTerminal {
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
					out = out.Cut()
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
		if last == nil && len(calls) > 0 {
			input = slices.Concat(input, outs)
			continue
		}
		res := Result{Ending: EndNoCall, Terminal: last, Input: slices.Concat(input, outs), Response: resp, Requests: requests}
		if last != nil {
			res.Ending = EndTerminal
		}
		return res, nil
	}
}

// custody ends the process groups the round started, and makes the returned function wait
// until they are gone. The returned function always stops them, whatever the outcome:
// success, a hook or requester error, cancellation, a deadline or an interrupt. Shell
// calls forward the round's context themselves, so a shell that is starting when ctx ends
// cannot be missed by a snapshot. Groups that the session started before the round are
// left alone.
func custody(s *sys.Session) (end func()) {
	before := map[int]bool{}
	for _, g := range s.Groups() {
		before[g] = true
	}
	return func() {
		var mine []int
		for _, g := range s.LiveGroups() {
			if !before[g] {
				mine = append(mine, g)
			}
		}
		sys.Terminate(mine)
		s.Retire(mine)
	}
}

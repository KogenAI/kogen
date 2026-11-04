package contract_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"kogen-loop/api"
	"kogen-loop/loop"
	"kogen-loop/provider"
	"kogen-loop/tools"
)

// scripted is a loop.Requester that answers each request with the next scripted response,
// as kogen-build's attemptRequester answers through its own bookkeeping, and keeps the requests.
type scripted struct {
	responses []*provider.Response
	requests  []loop.Request
}

func (s *scripted) Request(ctx context.Context, q loop.Request) (*provider.Response, []any, error) {
	s.requests = append(s.requests, q)
	if len(s.requests) > len(s.responses) {
		return nil, nil, errors.New("the script has no response for request " + string(rune('0'+len(s.requests))))
	}
	return s.responses[len(s.requests)-1], q.Input, nil
}

func answer(items ...map[string]any) *provider.Response {
	n := func(v int) *int { return &v }
	return &provider.Response{Items: items, Known: provider.KnownUsage{Input: n(10), Cached: n(2), Output: n(5), Reasoning: n(1)}, Model: "gpt-6.1-sol"}
}

// builderRound is a round like kogen-build's builder round: its own tools, the finish call terminal.
func builderRound(t *testing.T) (loop.Round, string) {
	t.Helper()
	s, root, _ := newSession(t)
	tl := &tools.Tools{Root: root, Session: s, Enabled: []string{tools.ReadFileTool, tools.WriteFileTool}, Protected: []string{"protected.txt"}}
	rd := loop.Round{
		Owner: "build", Role: chatgptRole, Instructions: "builder policy",
		Definitions: tools.AsAny(tools.Defs(tools.ReadFileTool, tools.WriteFileTool)),
		Tools:       tl,
		Terminal:    []string{"finish"},
	}
	return rd, root
}

// TestLoopRunTerminalWithHooks pins how a round with hooks ends: a call named in Round.Terminal is not
// executed and ends the round with EndTerminal and Result.Terminal set to it, and the other calls of the
// batch still run. Adapted from kogen-build build/executor_native.go (the builder's round) and build/hooks_test.go.
func TestLoopRunTerminalWithHooks(t *testing.T) {
	rd, root := builderRound(t)
	finish := callItem("2", "finish", map[string]any{"summary": "all done"})
	rq := &scripted{responses: []*provider.Response{answer(
		callItem("1", "write_file", map[string]any{"path": "a.txt", "content": "one\n"}),
		finish,
		callItem("3", "write_file", map[string]any{"path": "b.txt", "content": "two\n"}),
	)}}
	var order []string
	var terminals []bool
	hooks := loop.Hooks{
		AfterCall: func(ctx context.Context, call tools.Call, out tools.Output, terminal bool, input []any) error {
			order = append(order, call.Name+"="+out.Text)
			terminals = append(terminals, terminal)
			return nil
		},
	}
	res, err := loop.Run(context.Background(), rd, []any{user("do it")}, rq, hooks)
	if err != nil {
		t.Fatal(err)
	}
	if res.Ending != loop.EndTerminal || res.Terminal == nil || res.Terminal.Name != "finish" || res.Terminal.Arguments != `{"summary":"all done"}` || !reflect.DeepEqual(res.Terminal.Item, finish) {
		t.Fatalf("result %+v terminal %+v", res, res.Terminal)
	}
	if res.Requests != 1 || len(rq.requests) != 1 {
		t.Fatalf("%d requests", res.Requests)
	}
	for name, want := range map[string]string{"a.txt": "one\n", "b.txt": "two\n"} {
		if b, err := os.ReadFile(filepath.Join(root, name)); err != nil || string(b) != want {
			t.Errorf("%s: %q, %v: the other calls of the batch must run", name, b, err)
		}
	}
	if !reflect.DeepEqual(order, []string{"write_file=ok", "finish=", "write_file=ok"}) || !reflect.DeepEqual(terminals, []bool{false, true, false}) {
		t.Fatalf("calls %v terminal %v", order, terminals)
	}
	// The conversation after the round: the sent input, the replayed calls and the outputs of the calls that ran.
	if len(res.Input) != 1+3+2 || res.Input[0].(map[string]any)["role"] != "user" {
		t.Fatalf("conversation of %d items: %v", len(res.Input), res.Input)
	}
	outputs := 0
	for _, it := range res.Input {
		if m := it.(map[string]any); m["type"] == "function_call_output" {
			outputs++
			if m["call_id"] == "call-2" {
				t.Errorf("the terminal call was answered: %v", m)
			}
		}
	}
	if outputs != 2 || res.Response == nil || res.Response.Model != "gpt-6.1-sol" {
		t.Fatalf("%d outputs, response %+v", outputs, res.Response)
	}
}

// TestLoopRunDefaultTerminalIsFinish pins the default terminal name: a Round that names none ends on
// finish. Adapted from kogen-build build/executor_native.go and kogen-loop's default (loop.DefaultTerminal).
func TestLoopRunDefaultTerminalIsFinish(t *testing.T) {
	rd, _ := builderRound(t)
	rd.Terminal = nil
	rq := &scripted{responses: []*provider.Response{answer(callItem("1", "finish", map[string]any{"summary": "s"}))}}
	res, err := loop.Run(context.Background(), rd, []any{user("go")}, rq, loop.Hooks{BeforeRequest: func(context.Context, []any) error { return nil }})
	if err != nil || res.Ending != loop.EndTerminal || res.Terminal == nil || res.Terminal.Name != "finish" {
		t.Fatalf("result %+v, %v", res, err)
	}
	rd.Terminal = []string{"done"}
	rq = &scripted{responses: []*provider.Response{answer(callItem("1", "finish", map[string]any{"summary": "s"})), answer(textItem("fine"))}}
	res, err = loop.Run(context.Background(), rd, []any{user("go")}, rq, loop.Hooks{})
	if err != nil || res.Ending != loop.EndNoCall || res.Terminal != nil || res.Requests != 2 {
		t.Fatalf("a round that names another terminal ran finish as a tool: %+v, %v", res, err)
	}
}

// TestLoopRunHooksSeeTheRoundInOrder pins the engine order the hooks see and the hand-over of a handled
// call: BeforeRequest, the request, AfterResponse, BeforeCall, HandleCall, AfterCall; a handled call is not
// run with the round's tools and its output answers the call; the round ends without a call on an answer.
// Adapted from kogen-build build/executor_native.go and build/hooks_test.go.
func TestLoopRunHooksSeeTheRoundInOrder(t *testing.T) {
	rd, root := builderRound(t)
	rq := &scripted{responses: []*provider.Response{
		answer(callItem("1", "report_blocker", map[string]any{"reason": "stuck"}), callItem("2", "write_file", map[string]any{"path": "a.txt", "content": "x"})),
		answer(textItem("I am done")),
	}}
	var events []string
	var lastInput []any
	hooks := loop.Hooks{
		BeforeRequest: func(ctx context.Context, input []any) error {
			events = append(events, "request")
			lastInput = input
			return nil
		},
		AfterResponse: func(ctx context.Context, resp *provider.Response, sent []any) error {
			events = append(events, "response:"+resp.Model)
			return nil
		},
		BeforeCall: func(ctx context.Context, call tools.Call, input []any) error {
			events = append(events, "before:"+call.Name)
			return nil
		},
		HandleCall: func(ctx context.Context, call tools.Call) (loop.Handled, error) {
			if call.Name != "report_blocker" {
				return loop.Handled{}, nil
			}
			events = append(events, "handle:"+call.Name)
			return loop.Handled{Handled: true, Output: tools.Output{Text: "noted: " + call.Args()["reason"].(string)}}, nil
		},
		AfterCall: func(ctx context.Context, call tools.Call, out tools.Output, terminal bool, input []any) error {
			events = append(events, "after:"+call.Name+":"+out.Text)
			return nil
		},
	}
	res, err := loop.Run(context.Background(), rd, []any{user("start")}, rq, hooks)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"request", "response:gpt-6.1-sol",
		"before:report_blocker", "handle:report_blocker", "after:report_blocker:noted: stuck",
		"before:write_file", "after:write_file:ok",
		"request", "response:gpt-6.1-sol",
	}
	if !reflect.DeepEqual(events, want) {
		t.Fatalf("events\n got %v\nwant %v", events, want)
	}
	if res.Ending != loop.EndNoCall || res.Terminal != nil || res.Requests != 2 {
		t.Fatalf("result %+v", res)
	}
	if _, err := os.Stat(filepath.Join(root, "a.txt")); err != nil {
		t.Fatalf("the round's tools did not run the unhandled call: %v", err)
	}
	// The second request carries the first one's replayed calls and both answers.
	q1, q2 := rq.requests[0], rq.requests[1]
	if q1.Owner != "build" || q1.Instructions != "builder policy" || len(q1.Input) != 1 || len(q1.Tools) != 2 || !reflect.DeepEqual(q1.Tools, rd.Definitions) {
		t.Fatalf("first request %+v", q1)
	}
	if len(q2.Input) != 1+2+2 || len(lastInput) != len(q2.Input) {
		t.Fatalf("second request carries %d items", len(q2.Input))
	}
	if out := q2.Input[3].(map[string]any); out["type"] != "function_call_output" || out["call_id"] != "call-1" || out["output"] != "noted: stuck" {
		t.Fatalf("the handled call's answer: %v", out)
	}
	if res.Response == nil || len(res.Response.Items) != 1 || len(res.Input) != len(q2.Input)+1 {
		t.Fatalf("result input %d items, response %+v", len(res.Input), res.Response)
	}
}

// TestLoopRunHookErrorStopsTheRound pins that a hook error stops the round and is returned unchanged. Adapted from kogen-build build/hooks_test.go and build/executor_native.go (stop).
func TestLoopRunHookErrorStopsTheRound(t *testing.T) {
	stop := errors.New("custody stop")
	for name, hooks := range map[string]loop.Hooks{
		"before request": {BeforeRequest: func(context.Context, []any) error { return stop }},
		"after response": {AfterResponse: func(context.Context, *provider.Response, []any) error { return stop }},
		"before call":    {BeforeCall: func(context.Context, tools.Call, []any) error { return stop }},
		"handle call": {HandleCall: func(context.Context, tools.Call) (loop.Handled, error) {
			return loop.Handled{}, stop
		}},
		"after call": {AfterCall: func(context.Context, tools.Call, tools.Output, bool, []any) error { return stop }},
	} {
		rd, _ := builderRound(t)
		rq := &scripted{responses: []*provider.Response{answer(callItem("1", "write_file", map[string]any{"path": "a.txt", "content": "x"})), answer(textItem("done"))}}
		_, err := loop.Run(context.Background(), rd, []any{user("start")}, rq, hooks)
		if err != stop {
			t.Errorf("%s: err %v", name, err)
		}
		if name == "before request" && len(rq.requests) != 0 {
			t.Errorf("%s: a request was sent", name)
		}
	}
}

// TestLoopUsageState pins UsageOf and SumUsage: the state is complete when all four counts are known, unknown
// when none is, partial otherwise, and a sum keeps a category nil when any usage lacks it. Adapted from
// kogen-build build/executor_native.go (executorUsage) and build/records.go.
func TestLoopUsageState(t *testing.T) {
	n := func(v int) *int { return &v }
	complete := loop.UsageOf(&provider.Response{Known: provider.KnownUsage{Input: n(10), Cached: n(2), Output: n(5), Reasoning: n(1)}})
	if complete.State != "complete" || *complete.Input != 10 || *complete.Cached != 2 || *complete.Output != 5 || *complete.Reasoning != 1 {
		t.Fatalf("complete usage %+v", complete)
	}
	if got := loop.UsageOf(&provider.Response{}); got.State != "unknown" || got.Input != nil || got.Cached != nil || got.Output != nil || got.Reasoning != nil {
		t.Fatalf("unknown usage %+v", got)
	}
	if got := loop.UsageOf(nil); got.State != "unknown" {
		t.Fatalf("usage of no response %+v", got)
	}
	partial := loop.UsageOf(&provider.Response{Known: provider.KnownUsage{Input: n(10), Output: n(5)}})
	if partial.State != "partial" || *partial.Input != 10 || partial.Cached != nil || *partial.Output != 5 || partial.Reasoning != nil {
		t.Fatalf("partial usage %+v", partial)
	}
	if got := loop.UsageOf(&provider.Response{UsageState: provider.UsageInconsistent, Known: provider.KnownUsage{Input: n(10), Cached: n(2), Output: n(5), Reasoning: n(1)}}); got.State != "unknown" {
		t.Fatalf("inconsistent usage %+v", got)
	}

	sum := loop.SumUsage(complete, complete)
	if sum.State != "complete" || *sum.Input != 20 || *sum.Cached != 4 || *sum.Output != 10 || *sum.Reasoning != 2 {
		t.Fatalf("sum of complete usages %+v", sum)
	}
	mixed := loop.SumUsage(complete, partial)
	if mixed.State != "partial" || *mixed.Input != 20 || mixed.Cached != nil || *mixed.Output != 10 || mixed.Reasoning != nil {
		t.Fatalf("sum with a partial usage %+v", mixed)
	}
	if got := loop.SumUsage(complete, loop.UsageOf(nil)); got.State != "unknown" || got.Input != nil {
		t.Fatalf("sum with an unknown usage %+v", got)
	}
	if got := loop.SumUsage(); got.State != "unknown" || got.Input != nil {
		t.Fatalf("sum of nothing %+v", got)
	}
	var u api.Usage = sum
	if u.State != api.UsageComplete || strings.Join([]string{api.UsageComplete, api.UsagePartial, api.UsageUnknown}, ",") != "complete,partial,unknown" {
		t.Fatalf("states %q %q %q", api.UsageComplete, api.UsagePartial, api.UsageUnknown)
	}
}

// TestAPIProtocolAndLibrary pins the ids a pin check compares: the process protocol and the library API.
// Adapted from kogen cli/loop_pin_test.go and kogen-build build/executor_native.go.
func TestAPIProtocolAndLibrary(t *testing.T) {
	if api.Protocol != "kogen-loop/v1" || api.Library != "loop/v1" {
		t.Fatalf("protocol %q library %q", api.Protocol, api.Library)
	}
}

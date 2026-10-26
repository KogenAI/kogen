package conformance

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"kogen-loop/api"
	"kogen-loop/loop"
	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
)

// scripted is a Requester that answers with prepared responses and records what it was asked.
type scripted struct {
	log       *[]string
	responses []*provider.Response
	asked     []loop.Request
	sendMore  []any // appended to the input it reports as sent (a context policy)
}

func (s *scripted) Request(ctx context.Context, r loop.Request) (*provider.Response, []any, error) {
	if s.log != nil {
		*s.log = append(*s.log, "Request")
	}
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	s.asked = append(s.asked, r)
	if len(s.asked) > len(s.responses) {
		return nil, nil, errors.New("scripted: no response left")
	}
	return s.responses[len(s.asked)-1], append(append([]any(nil), r.Input...), s.sendMore...), nil
}

func respond(id string, items ...map[string]any) *provider.Response {
	return &provider.Response{ID: id, Items: items}
}

func fakeCall(id, name, args string) map[string]any {
	return map[string]any{"type": "function_call", "call_id": id, "name": name, "arguments": args}
}

func roundWith(t *testing.T, w *world) loop.Round {
	t.Helper()
	return loop.Round{
		Owner: "test", Role: provider.Role{Provider: "chatgpt", Model: "m", Effort: "e"},
		Instructions: "inst", Definitions: []any{"def"},
		Tools: &tools.Tools{Root: w.root, Session: sys.NewWith([]string{"HOME=" + w.home, "PATH=" + os.Getenv("PATH")}, w.root), Enabled: []string{"read_file", "write_file", "shell"}},
	}
}

func userMessage(text string) map[string]any { return map[string]any{"role": "user", "content": text} }

func ids(items []any) []string {
	var out []string
	for _, it := range items {
		m := it.(map[string]any)
		switch m["type"] {
		case "function_call":
			out = append(out, "call:"+m["call_id"].(string))
		case "function_call_output":
			out = append(out, "out:"+m["call_id"].(string))
		default:
			out = append(out, fmt.Sprint(m["role"]))
		}
	}
	return out
}

func TestEngineOrder(t *testing.T) {
	w := newWorld(t).seed(map[string]string{"a.txt": "alpha\n"})
	var log []string
	rq := &scripted{log: &log, responses: []*provider.Response{
		respond("r1",
			fakeCall("c1", "read_file", `{"path":"a.txt"}`),
			fakeCall("c2", "custom", `{}`)),
		respond("r2",
			fakeCall("c3", "read_file", `{"path":"a.txt"}`),
			fakeCall("c4", "finish", `{"summary":"s"}`),
			fakeCall("c5", "finish", `{"summary":"second"}`),
			fakeCall("c6", "read_file", `{"path":"a.txt"}`)),
	}}
	rd := roundWith(t, w)
	hooks := loop.Hooks{
		BeforeRequest: func(ctx context.Context, input []any) error {
			log = append(log, fmt.Sprintf("BeforeRequest%v", ids(input)))
			return nil
		},
		AfterResponse: func(ctx context.Context, resp *provider.Response, sent []any) error {
			log = append(log, fmt.Sprintf("AfterResponse(%s)%v", resp.ID, ids(sent)))
			return nil
		},
		BeforeCall: func(ctx context.Context, call tools.Call, input []any) error {
			log = append(log, fmt.Sprintf("BeforeCall(%s)%v", call.CallID(), ids(input)))
			return nil
		},
		HandleCall: func(ctx context.Context, call tools.Call) (loop.Handled, error) {
			log = append(log, fmt.Sprintf("HandleCall(%s)", call.CallID()))
			if call.Name == "custom" {
				return loop.Handled{Handled: true, Output: tools.Output{Text: "handled"}}, nil
			}
			return loop.Handled{}, nil
		},
		AfterCall: func(ctx context.Context, call tools.Call, out tools.Output, terminal bool, input []any) error {
			log = append(log, fmt.Sprintf("AfterCall(%s,%v)%v", call.CallID(), terminal, ids(input)))
			return nil
		},
	}
	res, err := loop.Run(context.Background(), rd, []any{userMessage("go")}, rq, hooks)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"BeforeRequest[user]",
		"Request",
		"AfterResponse(r1)[user]",
		"BeforeCall(c1)[user call:c1 call:c2]",
		"HandleCall(c1)",
		"AfterCall(c1,false)[user call:c1 call:c2]",
		"BeforeCall(c2)[user call:c1 call:c2 out:c1]",
		"HandleCall(c2)",
		"AfterCall(c2,false)[user call:c1 call:c2 out:c1]",
		// A non-terminal batch: the next request carries sent ++ replay ++ outputs.
		"BeforeRequest[user call:c1 call:c2 out:c1 out:c2]",
		"Request",
		"AfterResponse(r2)[user call:c1 call:c2 out:c1 out:c2]",
		"BeforeCall(c3)[user call:c1 call:c2 out:c1 out:c2 call:c3 call:c4 call:c5 call:c6]",
		"HandleCall(c3)",
		"AfterCall(c3,false)[user call:c1 call:c2 out:c1 out:c2 call:c3 call:c4 call:c5 call:c6]",
		// A terminal call is not handed to HandleCall and not executed.
		"BeforeCall(c4)[user call:c1 call:c2 out:c1 out:c2 call:c3 call:c4 call:c5 call:c6 out:c3]",
		"AfterCall(c4,true)[user call:c1 call:c2 out:c1 out:c2 call:c3 call:c4 call:c5 call:c6 out:c3]",
		"BeforeCall(c5)[user call:c1 call:c2 out:c1 out:c2 call:c3 call:c4 call:c5 call:c6 out:c3]",
		"AfterCall(c5,true)[user call:c1 call:c2 out:c1 out:c2 call:c3 call:c4 call:c5 call:c6 out:c3]",
		// Calls after a terminal call still run.
		"BeforeCall(c6)[user call:c1 call:c2 out:c1 out:c2 call:c3 call:c4 call:c5 call:c6 out:c3]",
		"HandleCall(c6)",
		"AfterCall(c6,false)[user call:c1 call:c2 out:c1 out:c2 call:c3 call:c4 call:c5 call:c6 out:c3]",
	}
	if !reflect.DeepEqual(log, want) {
		t.Errorf("hook order:\n got  %s\n want %s", strings.Join(log, "\n      "), strings.Join(want, "\n      "))
	}
	if res.Ending != loop.EndTerminal || res.Terminal == nil || res.Terminal.CallID() != "c5" {
		t.Errorf("ending %v terminal %v: the last terminal call wins (Kogen's builder at 56eecd57)", res.Ending, res.Terminal)
	}
	if res.Requests != 2 || res.Response.ID != "r2" {
		t.Errorf("requests %d response %s", res.Requests, res.Response.ID)
	}
	// Terminal outputs are not appended; the call after them is.
	wantInput := []string{"user", "call:c1", "call:c2", "out:c1", "out:c2", "call:c3", "call:c4", "call:c5", "call:c6", "out:c3", "out:c6"}
	if got := ids(res.Input); !reflect.DeepEqual(got, wantInput) {
		t.Errorf("result input %v, want %v", got, wantInput)
	}
	// What the second request sent is the conversation of the first round trip.
	if got := ids(rq.asked[1].Input); !reflect.DeepEqual(got, []string{"user", "call:c1", "call:c2", "out:c1", "out:c2"}) {
		t.Errorf("second request input %v", got)
	}
	if rq.asked[0].Owner != "test" || rq.asked[0].Instructions != "inst" || !reflect.DeepEqual(rq.asked[0].Tools, []any{"def"}) {
		t.Errorf("request %+v", rq.asked[0])
	}
}

func TestSentInputOfAContextPolicyIsWhatTheConversationKeeps(t *testing.T) {
	w := newWorld(t)
	rq := &scripted{
		responses: []*provider.Response{respond("r1", fakeCall("c1", "finish", `{}`))},
		sendMore:  []any{userMessage("added by the policy")},
	}
	res, err := loop.Run(context.Background(), roundWith(t, w), []any{userMessage("go")}, rq, loop.Hooks{})
	if err != nil {
		t.Fatal(err)
	}
	if got := ids(res.Input); !reflect.DeepEqual(got, []string{"user", "user", "call:c1"}) {
		t.Errorf("input %v", got)
	}
}

func TestNoCallEnding(t *testing.T) {
	w := newWorld(t)
	rq := &scripted{responses: []*provider.Response{respond("r1", message("hello"))}}
	res, err := loop.Run(context.Background(), roundWith(t, w), []any{userMessage("go")}, rq, loop.Hooks{})
	if err != nil {
		t.Fatal(err)
	}
	if res.Ending != loop.EndNoCall || res.Terminal != nil || res.Requests != 1 {
		t.Errorf("%+v", res)
	}
}

func TestHandledCall(t *testing.T) {
	w := newWorld(t)
	rd := roundWith(t, w)
	big := strings.Repeat("h", 20000)
	t.Run("output replaces execution and is not cut", func(t *testing.T) {
		rq := &scripted{responses: []*provider.Response{
			respond("r1", fakeCall("c1", "write_file", `{"path":"made.txt","content":"x"}`)),
			respond("r2", fakeCall("c2", "finish", `{}`)),
		}}
		res, err := loop.Run(context.Background(), rd, []any{userMessage("go")}, rq, loop.Hooks{
			HandleCall: func(ctx context.Context, call tools.Call) (loop.Handled, error) {
				return loop.Handled{Handled: true, Output: tools.Output{Text: big}}, nil
			},
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(filepath.Join(w.root, "made.txt")); err == nil {
			t.Error("a handled call was executed")
		}
		out := rq.asked[1].Input[len(rq.asked[1].Input)-1].(map[string]any)
		if out["call_id"] != "c1" || out["output"] != big {
			t.Errorf("handled output item %v", out["call_id"])
		}
		if res.Ending != loop.EndTerminal {
			t.Errorf("ending %v", res.Ending)
		}
	})
	t.Run("not handled falls through to the tools", func(t *testing.T) {
		rq := &scripted{responses: []*provider.Response{
			respond("r1", fakeCall("c1", "write_file", `{"path":"made.txt","content":"x"}`)),
			respond("r2", message("done")),
		}}
		_, err := loop.Run(context.Background(), rd, []any{userMessage("go")}, rq, loop.Hooks{
			HandleCall: func(ctx context.Context, call tools.Call) (loop.Handled, error) { return loop.Handled{}, nil },
		})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(filepath.Join(w.root, "made.txt")); err != nil {
			t.Error("the tool did not run")
		}
	})
	t.Run("a handled terminal call ends the round and appends nothing", func(t *testing.T) {
		rq := &scripted{responses: []*provider.Response{
			respond("r1", fakeCall("c1", "report_blocker", `{}`), fakeCall("c2", "report_blocker", `{}`)),
		}}
		var after []string
		res, err := loop.Run(context.Background(), rd, []any{userMessage("go")}, rq, loop.Hooks{
			HandleCall: func(ctx context.Context, call tools.Call) (loop.Handled, error) {
				return loop.Handled{Handled: true, Terminal: true, Output: tools.Output{Text: "ignored"}}, nil
			},
			AfterCall: func(ctx context.Context, call tools.Call, out tools.Output, terminal bool, input []any) error {
				after = append(after, fmt.Sprint(call.CallID(), terminal))
				return nil
			},
		})
		if err != nil {
			t.Fatal(err)
		}
		if res.Ending != loop.EndTerminal || res.Terminal.CallID() != "c2" || res.Requests != 1 {
			t.Errorf("%+v", res)
		}
		if got := ids(res.Input); !reflect.DeepEqual(got, []string{"user", "call:c1", "call:c2"}) {
			t.Errorf("input %v", got)
		}
		if !reflect.DeepEqual(after, []string{"c1true", "c2true"}) {
			t.Errorf("after %v", after)
		}
	})
}

func TestToolResultCutIsAppliedByTheEngine(t *testing.T) {
	w := newWorld(t).seed(map[string]string{"big.txt": strings.Repeat("0123456789\n", 5000)})
	rq := &scripted{responses: []*provider.Response{
		respond("r1", fakeCall("c1", "read_file", `{"path":"big.txt"}`)),
		respond("r2", message("done")),
	}}
	if _, err := loop.Run(context.Background(), roundWith(t, w), []any{userMessage("go")}, rq, loop.Hooks{}); err != nil {
		t.Fatal(err)
	}
	out := rq.asked[1].Input[len(rq.asked[1].Input)-1].(map[string]any)["output"].(string)
	if len(out) > 16384 || !strings.Contains(out, "bytes omitted") {
		t.Errorf("output %d bytes, marker %v", len(out), strings.Contains(out, "bytes omitted"))
	}
	if out != tools.Cut(out) {
		t.Error("the cut is not the tools.Cut form")
	}
}

func TestHookErrorStopsTheRound(t *testing.T) {
	w := newWorld(t).seed(map[string]string{"a.txt": "alpha\n"})
	stop := errors.New("hook stop")
	responses := func() []*provider.Response {
		return []*provider.Response{
			respond("r1", fakeCall("c1", "read_file", `{"path":"a.txt"}`), fakeCall("c2", "read_file", `{"path":"a.txt"}`)),
			respond("r2", message("done")),
		}
	}
	for _, tc := range []struct {
		name         string
		hooks        func(counts map[string]int) loop.Hooks
		requests     int
		calls        int
		callsStarted int
	}{
		{"BeforeRequest", func(c map[string]int) loop.Hooks {
			return loop.Hooks{BeforeRequest: func(context.Context, []any) error { c["br"]++; return stop }}
		}, 0, 0, 0},
		{"AfterResponse", func(c map[string]int) loop.Hooks {
			return loop.Hooks{
				BeforeCall:    func(context.Context, tools.Call, []any) error { c["bc"]++; return nil },
				AfterResponse: func(context.Context, *provider.Response, []any) error { return stop },
			}
		}, 1, 0, 0},
		{"BeforeCall", func(c map[string]int) loop.Hooks {
			return loop.Hooks{
				BeforeCall: func(context.Context, tools.Call, []any) error { c["bc"]++; return stop },
				AfterCall:  func(context.Context, tools.Call, tools.Output, bool, []any) error { c["ac"]++; return nil },
			}
		}, 1, 0, 1},
		{"HandleCall", func(c map[string]int) loop.Hooks {
			return loop.Hooks{
				HandleCall: func(context.Context, tools.Call) (loop.Handled, error) { c["hc"]++; return loop.Handled{}, stop },
				AfterCall:  func(context.Context, tools.Call, tools.Output, bool, []any) error { c["ac"]++; return nil },
			}
		}, 1, 0, 0},
		{"AfterCall", func(c map[string]int) loop.Hooks {
			return loop.Hooks{
				BeforeCall: func(context.Context, tools.Call, []any) error { c["bc"]++; return nil },
				AfterCall:  func(context.Context, tools.Call, tools.Output, bool, []any) error { return stop },
			}
		}, 1, 0, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			counts := map[string]int{}
			rq := &scripted{responses: responses()}
			res, err := loop.Run(context.Background(), roundWith(t, w), []any{userMessage("go")}, rq, tc.hooks(counts))
			if err != stop {
				t.Fatalf("error %v, want the hook's error unchanged", err)
			}
			if res.Response != nil || res.Input != nil {
				t.Errorf("a stopped round returned a result: %+v", res)
			}
			if len(rq.asked) != tc.requests {
				t.Errorf("%d requests, want %d", len(rq.asked), tc.requests)
			}
			if counts["ac"] != 0 || counts["bc"] > tc.callsStarted {
				t.Errorf("later calls still ran: %v", counts)
			}
		})
	}
}

func TestCancelledContextStopsBeforeTheNextCall(t *testing.T) {
	w := newWorld(t).seed(map[string]string{"a.txt": "alpha\n"})
	ctx, cancel := context.WithCancel(context.Background())
	var ran []string
	rq := &scripted{responses: []*provider.Response{
		respond("r1", fakeCall("c1", "read_file", `{"path":"a.txt"}`), fakeCall("c2", "read_file", `{"path":"a.txt"}`)),
	}}
	_, err := loop.Run(ctx, roundWith(t, w), []any{userMessage("go")}, rq, loop.Hooks{
		AfterCall: func(ctx context.Context, call tools.Call, out tools.Output, terminal bool, input []any) error {
			ran = append(ran, fmt.Sprint(call.CallID()))
			cancel()
			return nil
		},
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("error %v", err)
	}
	if !reflect.DeepEqual(ran, []string{"c1"}) {
		t.Errorf("calls run %v", ran)
	}
}

func TestContextEndTerminatesTheShellGroupBeforeRunReturns(t *testing.T) {
	w := newWorld(t)
	rq := &scripted{responses: []*provider.Response{
		respond("r1", fakeCall("c1", "shell", fmt.Sprintf(`{"command":%q}`, sleeper))),
	}}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := loop.Run(ctx, roundWith(t, w), []any{userMessage("go")}, rq, loop.Hooks{})
		done <- err
	}()
	pidSh := readPid(t, filepath.Join(w.root, "pid-sh"))
	pidSleep := readPid(t, filepath.Join(w.root, "pid-sleep"))
	select {
	case err := <-done:
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Errorf("error %v", err)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("Run did not return after its context ended")
	}
	for _, pid := range []int{pidSh, pidSleep} {
		if !pidGone(pid) {
			t.Errorf("process %d survived", pid)
		}
	}
}

func TestInterruptedSessionStopsTheShellAndReturnsTheInterrupt(t *testing.T) {
	w := newWorld(t)
	session := sys.NewWith([]string{"HOME=" + w.home, "PATH=" + os.Getenv("PATH")}, w.root)
	rd := roundWith(t, w)
	rd.Tools.Session = session
	rq := &scripted{responses: []*provider.Response{
		respond("r1", fakeCall("c1", "shell", fmt.Sprintf(`{"command":%q}`, sleeper))),
	}}
	done := make(chan error, 1)
	go func() {
		_, err := loop.Run(session.Context(), rd, []any{userMessage("go")}, rq, loop.Hooks{})
		done <- err
	}()
	pidSh := readPid(t, filepath.Join(w.root, "pid-sh"))
	pidSleep := readPid(t, filepath.Join(w.root, "pid-sleep"))
	session.Interrupt("SIGTERM")
	select {
	case err := <-done:
		var in *sys.Interrupted
		if !errors.As(err, &in) || in.Signal != "SIGTERM" {
			t.Errorf("error %v", err)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("Run did not return")
	}
	for _, pid := range []int{pidSh, pidSleep} {
		if !pidGone(pid) {
			t.Errorf("process %d survived", pid)
		}
	}
}

// ---- Direct and FailOverBudget against the fake provider ----

func direct(t *testing.T, w *world, f *fakeProvider) *loop.Direct {
	t.Helper()
	client := provider.NewClient("kogen-loop test")
	return &loop.Direct{
		Client: client, Session: sys.NewWith(w.env(f), w.root), CacheID: provider.NewCacheID(), Cache: client.Cache,
	}
}

func TestOverBudgetRefusalComesBeforeAnyRequestAndTheInputIsNeverClipped(t *testing.T) {
	w := newWorld(t).signIn()
	f := newFakeProvider(t, []exchange{{Items: []map[string]any{message("never")}}})
	d := direct(t, w, f)
	rd := roundWith(t, w)
	rd.Tools = nil
	var hooked int
	_, err := loop.Run(context.Background(), rd, []any{userMessage(strings.Repeat("a", provider.InputBudgetBytes+1))}, d,
		loop.Hooks{AfterResponse: func(context.Context, *provider.Response, []any) error { hooked++; return nil }})
	se, ok := sys.AsError(err)
	if !ok || se.Class != "loop" || se.Reason != api.ErrContextBudget {
		t.Fatalf("error %v", err)
	}
	if len(f.requests()) != 0 || hooked != 0 {
		t.Errorf("%d requests, %d responses", len(f.requests()), hooked)
	}
	// Just under the budget goes through whole.
	rd2 := roundWith(t, w)
	rd2.Tools = nil
	small := strings.Repeat("a", provider.InputBudgetBytes/2)
	res, err := loop.Run(context.Background(), rd2, []any{userMessage(small)}, d, loop.Hooks{})
	if err != nil {
		t.Fatal(err)
	}
	if m := res.Input[0].(map[string]any); m["content"] != small {
		t.Error("the input was clipped")
	}
}

func TestFailOverBudgetZeroValueMeasuresTheRenderedRequest(t *testing.T) {
	r := loop.Request{Role: provider.Role{Provider: "chatgpt", Model: "m", Effort: "e"}, Instructions: "i", Tools: []any{}}
	r.Input = []any{userMessage("small")}
	if got, err := (loop.FailOverBudget{}).Prepare(context.Background(), r); err != nil || len(got) != 1 {
		t.Errorf("%v %v", got, err)
	}
	r.Input = []any{userMessage(strings.Repeat("a", provider.InputBudgetBytes))}
	_, err := (loop.FailOverBudget{}).Prepare(context.Background(), r)
	if se, ok := sys.AsError(err); !ok || se.Reason != "context_budget_exceeded" || se.Class != "loop" {
		t.Errorf("%v", err)
	}
}

func TestDirectSendsOneCacheIdentityAndTheObserverSeesAttempts(t *testing.T) {
	w := newWorld(t).signIn()
	f := newFakeProvider(t, []exchange{
		{Items: []map[string]any{call("c1", "write_file", map[string]any{"path": "x.txt", "content": "x"})}},
		{Items: []map[string]any{call("c2", "finish", map[string]any{"summary": "s"})}},
	})
	d := direct(t, w, f)
	obs := &recorder{}
	d.Observer = obs
	rd := roundWith(t, w)
	rd.Definitions = tools.AsAny(tools.Defs("write_file"), []map[string]any{loop.TerminalDefinition("finish")})
	res, err := loop.Run(context.Background(), rd, []any{userMessage("go")}, d, loop.Hooks{})
	if err != nil {
		t.Fatal(err)
	}
	if res.Ending != loop.EndTerminal {
		t.Errorf("ending %v", res.Ending)
	}
	reqs := f.requests()
	if len(reqs) != 2 || reqs[0]["prompt_cache_key"] == nil || reqs[0]["prompt_cache_key"] != reqs[1]["prompt_cache_key"] {
		t.Errorf("cache keys %v", reqs)
	}
	if len(obs.records) != 2 {
		t.Errorf("%d attempt records, want 2", len(obs.records))
	}
	if data, err := os.ReadFile(filepath.Join(w.root, "x.txt")); err != nil || string(data) != "x" {
		t.Errorf("tool did not run: %v %q", err, data)
	}
}

type recorder struct{ records []map[string]any }

func (r *recorder) Attempt(record map[string]any) { r.records = append(r.records, record) }

// ---- Session ----

func sessionConfig(w *world, f *fakeProvider, events *[]api.Event) loop.SessionConfig {
	return loop.SessionConfig{
		Root: w.root, Role: provider.Role{Provider: "chatgpt", Model: "fixture-model", Effort: "medium"},
		Client: provider.NewClient("kogen-loop test"), Session: sys.NewWith(w.env(f), w.root),
		Emit: func(e api.Event) { *events = append(*events, e) },
	}
}

func eventTypes(events []api.Event) []string {
	var out []string
	for _, e := range events {
		out = append(out, e.Type)
	}
	return out
}

func TestSessionRoundsInMemoryAndTheFeedbackRule(t *testing.T) {
	w := newWorld(t).signIn()
	f := newFakeProvider(t, []exchange{
		{ID: "r1", Items: []map[string]any{call("c1", "finish", map[string]any{"summary": "one"})}},
		{ID: "r2", Items: []map[string]any{message("two")}},
		{ID: "r3", Items: []map[string]any{message("three")}},
	})
	var events []api.Event
	s, err := loop.NewSession(sessionConfig(w, f, &events))
	if err != nil {
		t.Fatal(err)
	}
	res, err := s.Round(context.Background(), "open")
	if err != nil || res.Ending != loop.EndTerminal {
		t.Fatalf("%v %v", res, err)
	}
	want := []string{"request.started", "request.attempt", "response", "tool.call", "round.ended"}
	if got := eventTypes(events); !reflect.DeepEqual(got, want) {
		t.Errorf("events %v", got)
	}
	for i, e := range events {
		if e.Protocol != api.Protocol || e.Seq != i+1 || e.Time == "" {
			t.Errorf("event %d envelope %+v", i, e)
		}
	}
	// After a terminal ending the feedback answers the terminal call.
	if _, err := s.Round(context.Background(), "feedback"); err != nil {
		t.Fatal(err)
	}
	in := f.requests()[1]["input"].([]any)
	if got := ids(toAny(in)); !reflect.DeepEqual(got, []string{"user", "call:c1", "out:c1"}) {
		t.Errorf("second request %v", got)
	}
	// After a no-call ending it is a user message.
	if _, err := s.Round(context.Background(), "more"); err != nil {
		t.Fatal(err)
	}
	in = f.requests()[2]["input"].([]any)
	if got := ids(toAny(in)); !reflect.DeepEqual(got, []string{"user", "call:c1", "out:c1", "assistant", "user"}) {
		t.Errorf("third request %v", got)
	}
	// An in-memory session writes nothing.
	if entries, _ := os.ReadDir(w.root); len(entries) != 0 {
		t.Errorf("root has %v", entries)
	}
}

func toAny(in []any) []any { return in }

func TestSessionFeedbackAnsweringTerminalIsCut(t *testing.T) {
	w := newWorld(t).signIn()
	f := newFakeProvider(t, []exchange{
		{Items: []map[string]any{call("c1", "finish", map[string]any{"summary": "one"})}},
		{Items: []map[string]any{message("two")}},
	})
	var events []api.Event
	s, _ := loop.NewSession(sessionConfig(w, f, &events))
	s.Round(context.Background(), "open")
	feedback := strings.Repeat("f", 30000)
	if _, err := s.Round(context.Background(), feedback); err != nil {
		t.Fatal(err)
	}
	in := f.requests()[1]["input"].([]any)
	out := in[len(in)-1].(map[string]any)["output"].(string)
	if out != tools.Cut(feedback) || len(out) > 16384 {
		t.Errorf("feedback output %d bytes", len(out))
	}
}

func TestSessionResumeLibraryAndMismatch(t *testing.T) {
	w := newWorld(t).signIn()
	dir := filepath.Join(t.TempDir(), "s")
	f := newFakeProvider(t, []exchange{
		{Items: []map[string]any{message("one")}},
		{Items: []map[string]any{message("two")}},
	})
	var events []api.Event
	cfg := sessionConfig(w, f, &events)
	cfg.Dir = dir
	cfg.Instructions = "custom"
	s, err := loop.NewSession(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Round(context.Background(), "open"); err != nil {
		t.Fatal(err)
	}
	r, err := loop.ResumeSession(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if r.ID() != s.ID() {
		t.Errorf("session id %s, want %s", r.ID(), s.ID())
	}
	if _, err := r.Round(context.Background(), "next"); err != nil {
		t.Fatal(err)
	}
	if got := ids(f.requests()[1]["input"].([]any)); !reflect.DeepEqual(got, []string{"user", "assistant", "user"}) {
		t.Errorf("resumed request %v", got)
	}
	for name, mod := range map[string]func(c *loop.SessionConfig){
		"instructions": func(c *loop.SessionConfig) { c.Instructions = "" },
		"role":         func(c *loop.SessionConfig) { c.Role.Effort = "high" },
		"definitions":  func(c *loop.SessionConfig) { c.Enabled = []string{"shell"} },
		"terminal":     func(c *loop.SessionConfig) { c.Terminal = []string{"end"} },
	} {
		bad := cfg
		mod(&bad)
		_, err := loop.ResumeSession(bad)
		if se, ok := sys.AsError(err); !ok || se.Class != "loop" || se.Reason != api.ErrSessionMismatch {
			t.Errorf("%s: %v", name, err)
		}
	}
	if _, err := loop.ResumeSession(func() loop.SessionConfig { c := cfg; c.Dir = ""; return c }()); err == nil {
		t.Error("resume without a directory succeeded")
	}
}

func TestSessionEmitsToolEventsWithCutAndHashes(t *testing.T) {
	w := newWorld(t).signIn()
	f := newFakeProvider(t, []exchange{
		{Items: []map[string]any{
			call("c1", "shell", map[string]any{"command": "yes abcdefghi | head -c 40000"}),
			call("c2", "shell", map[string]any{"command": "echo small"}),
		}},
		{Items: []map[string]any{message("done")}},
	})
	var events []api.Event
	s, _ := loop.NewSession(sessionConfig(w, f, &events))
	if _, err := s.Round(context.Background(), "go"); err != nil {
		t.Fatal(err)
	}
	var cuts []any
	for _, e := range events {
		if e.Type == api.EventToolResult {
			cuts = append(cuts, e.Fields["cut"])
		}
	}
	if !reflect.DeepEqual(cuts, []any{true, false}) {
		t.Errorf("cut flags %v", cuts)
	}
}

func TestSessionDefaultsAreTheGenericTools(t *testing.T) {
	w := newWorld(t)
	var events []api.Event
	s, err := loop.NewSession(sessionConfig(w, nil, &events))
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, d := range s.Definitions() {
		names = append(names, d.(map[string]any)["name"].(string))
	}
	if !reflect.DeepEqual(names, []string{"read_file", "write_file", "list_files", "search_text", "shell", "finish"}) {
		t.Errorf("definitions %v", names)
	}
	finish := s.Definitions()[5].(map[string]any)
	params := finish["parameters"].(map[string]any)
	if !reflect.DeepEqual(params["required"], []any{"summary"}) || params["additionalProperties"] != false {
		t.Errorf("finish %v", finish)
	}
	if !strings.Contains(loop.DefaultInstructions, "finish") || !strings.Contains(loop.DefaultInstructions, "claim") {
		t.Error("default instructions")
	}
}

func TestUsageHelpers(t *testing.T) {
	five, six := 5, 6
	complete := loop.UsageOf(&provider.Response{Known: provider.KnownUsage{Input: &five, Cached: &five, Output: &six, Reasoning: &five}, UsageState: provider.UsagePartial})
	if complete.State != api.UsageComplete || complete.Source != "provider" || *complete.Output != 6 {
		t.Errorf("%+v", complete)
	}
	partial := loop.UsageOf(&provider.Response{Known: provider.KnownUsage{Input: &five}})
	if partial.State != api.UsagePartial || partial.Output != nil {
		t.Errorf("%+v", partial)
	}
	if u := loop.UsageOf(&provider.Response{UsageState: provider.UsageInconsistent, Known: provider.KnownUsage{Input: &five}}); u.State != api.UsageUnknown || u.Input != nil {
		t.Errorf("inconsistent usage must not be trusted: %+v", u)
	}
	sum := loop.SumUsage(complete, partial)
	if sum.Input == nil || *sum.Input != 10 || sum.Output != nil || sum.State != api.UsagePartial {
		t.Errorf("%+v", sum)
	}
	if u := loop.SumUsage(); u.State != api.UsageUnknown {
		t.Errorf("%+v", u)
	}
}

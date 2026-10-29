package provider

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"

	"kogen-loop/sys"
)

func validationOf(t *testing.T, err error) map[string]any {
	t.Helper()
	se := mustErr(t, err)
	_, js, ok := strings.Cut(se.Detail, "; validation=")
	if !ok || len(js) > 2048 {
		t.Fatalf("no bounded validation in %q", se.Detail)
	}
	v, derr := decodeJSON([]byte(js))
	if derr != nil {
		t.Fatal(derr)
	}
	return v.(map[string]any)
}

func single(e *env, mods ...func(*Request)) (*Response, error) {
	req := Request{Role: fixtureRole, Instructions: "fixture", Single: true}
	for _, m := range mods {
		m(&req)
	}
	return e.c.Respond(context.Background(), e.s, req, nil)
}

func chatEnv(t *testing.T, h ...handler) (*env, *fake) {
	f := newFake(t, h...)
	e := newEnv(t, f)
	e.saveCreds("chatgpt", e.chatgptCreds())
	return e, f
}

// Intent prompt caching: ChatGPT never sends prompt_cache_options or prompt_cache_breakpoint, so
// no HTTP 400 cache-refusal retry exists for it: every such answer is one plain refusal.
func TestChatGPTRetiredOptionsRefusalsNeverStripTheRoutingKey(t *testing.T) {
	for _, single := range []bool{false, true} {
		for _, param := range []any{"absent", nil, "prompt_cache_options", "prompt_cache_key"} {
			t.Run(fmt.Sprintf("single=%v/param=%v", single, param), func(t *testing.T) {
				errBody := map[string]any{"type": "invalid_request_error", "code": "invalid_parameter", "message": "prompt_cache_options is not supported on this model"}
				if param != "absent" {
					errBody["param"] = param
				}
				e, f := chatEnv(t, jsonAnswer(400, map[string]any{"error": errBody}), textAnswer("never asked"))
				obs := &observer{}
				_, err := e.c.Respond(context.Background(), e.s, Request{Role: Role{Model: "gpt-6.1-sol", Effort: "high"}, Instructions: "policy", Single: single,
					Input: []any{map[string]any{"role": "user", "content": "contract"}}, Scope: "evidence-dir"}, obs)
				se := mustErr(t, err)
				if se.Reason != "refused" || se.Detail != "ChatGPT refused the request: 400 prompt_cache_options is not supported on this model" {
					t.Fatalf("err = %v", se)
				}
				reqs := f.requests()
				if len(reqs) != 1 {
					t.Fatalf("%d requests", len(reqs))
				}
				for _, k := range []string{"prompt_cache_options", "prompt_cache_retention"} {
					if _, has := reqs[0].JSON[k]; has {
						t.Fatalf("%s sent", k)
					}
				}
				if strings.Contains(string(reqs[0].Body), "prompt_cache_breakpoint") {
					t.Fatal("a breakpoint marker was sent")
				}
				recs := obs.records()
				if len(recs) != 1 || recs[0]["outcome"] != "failed" || recs[0]["usage_state"] != "unknown" || recs[0]["cache"].(map[string]any)["status"] != "requested" {
					t.Fatalf("records = %s", jsonOf(t, recs))
				}
			})
		}
	}
}

// SuperGrok keeps the bounded refusal of its prompt_cache_key: one retry without the field
// (only that field), remembered by the conversation, with the refused attempt retained.
func TestSuperGrokCacheKeyRefusalRetriesOnceAndIsRemembered(t *testing.T) {
	refusal := jsonAnswer(400, map[string]any{"error": map[string]any{"code": "unknown_parameter", "param": "prompt_cache_key", "message": "unsupported"}})
	completed := events(done(map[string]any{"id": "resp_cache", "model": "grok-4.7", "output": []any{tool()}}))
	f := newFake(t, refusal, completed, completed)
	e := newEnv(t, f)
	e.saveCreds("supergrok", e.supergrokCreds())
	obs := &observer{}
	req := Request{Role: grokRole, Instructions: "policy", Input: []any{map[string]any{"role": "user", "content": "contract"}}, Scope: "conversation"}
	for i := 0; i < 2; i++ {
		if _, err := e.c.Respond(context.Background(), e.s, req, obs); err != nil {
			t.Fatal(err)
		}
	}
	reqs := f.requests()
	if len(reqs) != 3 {
		t.Fatalf("%d requests", len(reqs))
	}
	first, retry, next := reqs[0].JSON, reqs[1].JSON, reqs[2].JSON
	if first["prompt_cache_key"] == nil {
		t.Fatalf("first = %v", first)
	}
	stripped := map[string]any{}
	for k, v := range first {
		if k != "prompt_cache_key" {
			stripped[k] = v
		}
	}
	if !reflect.DeepEqual(retry, stripped) || !reflect.DeepEqual(next, stripped) {
		t.Fatalf("only the key may go\n first %s\n retry %s\n next  %s", jsonOf(t, first), jsonOf(t, retry), jsonOf(t, next))
	}
	recs := obs.records()
	if len(recs) != 3 {
		t.Fatalf("records = %d", len(recs))
	}
	if recs[0]["usage"].(map[string]any)["input"] != nil || recs[0]["outcome"] != "failed" || recs[0]["cache"].(map[string]any)["status"] != "unsupported" ||
		recs[0]["provider_request_id"] != "req-fixture" {
		t.Fatalf("refused attempt = %s", jsonOf(t, recs[0]))
	}
	if recs[2]["provider_response_id"] != "resp_cache" || recs[2]["cache"].(map[string]any)["status"] != "unsupported" {
		t.Fatalf("last = %s", jsonOf(t, recs[2]))
	}
	// The refusal is part of the conversation's saved state: a resume does not retry it.
	states := e.c.Cache.States()
	if len(states) != 1 {
		t.Fatalf("states = %v", states)
	}
	for _, st := range states {
		if !st.Unsupported {
			t.Fatal("the refusal was not remembered")
		}
	}
}

// Only the exact refusal of SuperGrok's key is a compatibility case.
func TestOtherSuperGrokRefusalsNeverStripTheKey(t *testing.T) {
	cases := []struct {
		status int
		body   map[string]any
	}{
		{400, map[string]any{"code": "invalid_request_error", "param": "prompt_cache_key", "message": "x"}},
		{400, map[string]any{"code": "unknown_parameter", "param": "prompt_cache_options", "message": "x"}},
		{400, map[string]any{"code": "unknown_parameter", "message": "prompt_cache_key"}},
		{400, map[string]any{"code": "unsupported_parameter", "param": "input[0].prompt_cache_key", "message": "x"}},
		{402, map[string]any{"code": "unknown_parameter", "param": "prompt_cache_key", "message": "x"}},
		{403, map[string]any{"code": "unknown_parameter", "param": "prompt_cache_key", "message": "x"}},
	}
	for i, c := range cases {
		t.Run(fmt.Sprint(i), func(t *testing.T) {
			f := newFake(t, jsonAnswer(c.status, map[string]any{"error": c.body}), textAnswer("never"))
			e := newEnv(t, f)
			e.saveCreds("supergrok", e.supergrokCreds())
			if _, err := e.c.Respond(context.Background(), e.s, Request{Role: grokRole, Instructions: "policy"}, nil); err == nil {
				t.Fatal("no error")
			}
			if len(f.requests()) != 1 {
				t.Fatalf("%d requests", len(f.requests()))
			}
		})
	}
}

// provider_wait_test: unrelated refusal never strips cache fields or reexecutes.
func TestUnrelatedRefusalNeverStripsOrReexecutes(t *testing.T) {
	e, f := chatEnv(t, jsonAnswer(400, map[string]any{"error": map[string]any{"code": "context_length_exceeded", "param": "input", "message": "full"}}))
	_, err := e.respond(Request{Role: Role{Model: "gpt-6.1-sol", Effort: "medium"}, Instructions: "policy"})
	if se := mustErr(t, err); se.Reason != "context_too_long" || len(f.requests()) != 1 {
		t.Fatalf("err = %v, %d requests", err, len(f.requests()))
	}
}

// provider_wait_test: inconsistent completed usage is retained but not added to totals.
func TestInconsistentUsageIsRetainedButNotTotalled(t *testing.T) {
	e, _ := chatEnv(t, events(done(map[string]any{"output": []any{tool()}, "usage": map[string]any{
		"input_tokens": int64(10), "input_tokens_details": map[string]any{"cached_tokens": int64(11)}, "output_tokens": int64(2)}})))
	resp, err := single(e)
	if err != nil {
		t.Fatal(err)
	}
	if resp.Known.Cached == nil || *resp.Known.Cached != 11 || resp.Known.State() != UsageInconsistent || resp.UsageState != UsageInconsistent || resp.Usage != (Usage{}) {
		t.Fatalf("known %+v state %s usage %+v", resp.Known, resp.UsageState, resp.Usage)
	}
}

// provider_wait_test: malformed optional write counts never leak into analytical usage.
func TestMalformedWriteCountsNeverLeak(t *testing.T) {
	e, _ := chatEnv(t, events(done(map[string]any{"output": []any{tool()}, "usage": map[string]any{
		"input_tokens": int64(10), "input_tokens_details": map[string]any{"cache_write_tokens": map[string]any{"raw": "PRIVATE-WRITE-BODY"}}}})))
	obs := &observer{}
	resp, err := e.c.Respond(context.Background(), e.s, Request{Role: fixtureRole, Instructions: "f", Single: true}, obs)
	if err != nil || !reflect.DeepEqual(resp.Items, []map[string]any{tool()}) || resp.Known.Write != nil || resp.UsageState != UsageInconsistent {
		t.Fatalf("%+v %v", resp, err)
	}
	log := jsonOf(t, obs.records())
	if strings.Contains(log, "PRIVATE-WRITE-BODY") || obs.records()[0]["usage_state"] != "inconsistent" {
		t.Fatalf("log = %s", log)
	}
}

func bad() map[string]any { return with(tool(), "arguments", "PRIVATE-invalid-json") }

// provider_wait_test: terminal evidence retains sticky guards but describes only effective
// replacement items.
func TestTerminalEvidenceRetainsStickyGuards(t *testing.T) {
	e, _ := chatEnv(t, events(
		itemDone(-1, bad()), itemDone(0, bad()),
		map[string]any{"type": "response.output_item.added", "output_index": int64(2)},
		done(map[string]any{"output": []any{tool()}})))
	_, err := single(e)
	ev := validationOf(t, err)
	facts := ev["facts"].(map[string]any)
	if !reflect.DeepEqual(ev["reasons"], []any{"item_event_shape", "terminal_index_coverage"}) ||
		facts["observed_index_count"] != int64(2) || facts["item_count"] != int64(1) || facts["pending_count"] != int64(0) ||
		facts["terminal_output_replaced"] != true || !reflect.DeepEqual(facts["arguments_object"], []any{"yes"}) {
		t.Fatalf("evidence = %v", ev)
	}
	if strings.Contains(mustErr(t, err).Detail, "PRIVATE") || mustErr(t, err).Reason != "invalid_response" {
		t.Fatal("private text leaked")
	}
}

// provider_wait_test: terminal evidence distinguishes effective pending and gap predicates.
func TestTerminalEvidencePendingAndGap(t *testing.T) {
	e, _ := chatEnv(t,
		events(itemDone(1, tool()), done(map[string]any{})),
		events(itemDone(0, tool()), map[string]any{"type": "response.output_item.added", "output_index": int64(1)}, done(map[string]any{})))
	_, err := single(e)
	if ev := validationOf(t, err); !reflect.DeepEqual(ev["reasons"], []any{"noncontiguous_indexes"}) {
		t.Fatalf("gap = %v", ev)
	}
	_, err = single(e)
	ev := validationOf(t, err)
	facts := ev["facts"].(map[string]any)
	if !reflect.DeepEqual(ev["reasons"], []any{"pending_items"}) || facts["pending_count"] != int64(1) || facts["observed_index_count"] != int64(2) || facts["terminal_output_replaced"] != false {
		t.Fatalf("pending = %v", ev)
	}
}

// provider_wait_test: empty terminal metadata retains ordered multiitem output and usage on
// an open socket, and the request is cancelled without waiting for the stream to close.
func TestEmptyTerminalMetadataKeepsOrderedItemsOnAnOpenSocket(t *testing.T) {
	items := []map[string]any{
		{"type": "reasoning", "summary": []any{}},
		{"type": "message", "role": "assistant", "status": "completed", "content": []any{map[string]any{"type": "output_text", "text": "ready", "annotations": []any{}}}},
		with(tool(), "arguments", `{"path":"app.txt"}`),
		with(tool(), "call_id", "second"),
	}
	var frames []any
	for i, it := range items {
		frames = append(frames,
			map[string]any{"type": "response.output_item.added", "output_index": int64(i), "item": it},
			map[string]any{"type": "response.function_call_arguments.delta", "output_index": int64(i), "delta": "PRIVATE-partial"})
	}
	for i := len(items) - 1; i >= 0; i-- { // done events need not arrive in index order
		frames = append(frames, itemDone(i, items[i]))
	}
	usage := map[string]any{"input_tokens": int64(100), "input_tokens_details": map[string]any{"cached_tokens": int64(5)}, "output_tokens": int64(20), "output_tokens_details": map[string]any{"reasoning_tokens": int64(10)}}
	opened, closed := make(chan struct{}), make(chan struct{})
	e, f := chatEnv(t, openEvents(opened, closed, append(frames, done(map[string]any{"output": []any{}, "usage": usage}))...))
	e.realClock()
	resp, err := single(e)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(resp.Items, items) || resp.Usage != (Usage{100, 5, 20, 10}) || resp.Known.Write != nil || resp.Known.Write30m != nil || resp.Known.Write12h != nil || *resp.Known.Input != 100 {
		t.Fatalf("response = %+v", resp)
	}
	<-opened
	select {
	case <-closed:
	case <-time.After(time.Minute): // hang guard only
		t.Fatal("the validated open stream was not cancelled")
	}
	if len(f.requests()) != 1 {
		t.Fatal("retried")
	}
}

// provider_wait_test: empty final output retains refusal predicates and effective facts.
func TestEmptyFinalOutputRetainsRefusalPredicates(t *testing.T) {
	item := tool()
	added := map[string]any{"type": "response.output_item.added", "output_index": int64(1)}
	delta := map[string]any{"type": "response.function_call_arguments.delta", "output_index": int64(0), "delta": "{}"}
	cases := []struct {
		frames                   []any
		meta                     map[string]any
		reasons                  []any
		items, pending, observed int64
	}{
		{[]any{itemDone(0, item), added}, nil, []any{"pending_items"}, 1, 1, 2},
		{[]any{delta}, nil, []any{"empty_output"}, 0, 0, 0},
		{[]any{itemDone(0, with(item, "arguments", "PRIVATE-invalid"))}, nil, []any{"item_shape"}, 1, 0, 1},
		{[]any{itemDone(0, with(item, "arguments", "[]"))}, nil, []any{"item_shape"}, 1, 0, 1},
		{[]any{itemDone(0, with(item, "call_id", ""))}, nil, []any{"item_shape"}, 1, 0, 1},
		{[]any{itemDone(0, map[string]any{"type": "message", "content": []any{map[string]any{"type": "output_text", "text": int64(42)}}})}, nil, []any{"item_shape"}, 1, 0, 1},
		{[]any{itemDone(0, with(item, "status", "in_progress"))}, nil, []any{"item_status"}, 1, 0, 1},
		{[]any{itemDone(1, item)}, nil, []any{"noncontiguous_indexes"}, 1, 0, 1},
		{[]any{itemDone(-1, item), itemDone(0, item)}, nil, []any{"item_event_shape"}, 1, 0, 1},
		{[]any{itemDone(0, item)}, map[string]any{"usage": "bad"}, []any{"usage_shape"}, 1, 0, 1},
		{[]any{itemDone(0, item)}, map[string]any{"usage": map[string]any{"input_tokens_details": int64(42)}}, []any{"usage_shape"}, 1, 0, 1},
		{[]any{itemDone(0, item)}, map[string]any{"status": "incomplete"}, []any{"response_status"}, 1, 0, 1},
		{[]any{itemDone(0, item)}, map[string]any{"error": map[string]any{}}, []any{"response_error"}, 1, 0, 1},
	}
	var script []handler
	for _, c := range cases {
		script = append(script, events(append(c.frames, done(with(c.meta, "output", []any{})))...))
	}
	e, _ := chatEnv(t, script...)
	for i, c := range cases {
		_, err := single(e)
		se := mustErr(t, err)
		ev := validationOf(t, err)
		facts := ev["facts"].(map[string]any)
		if se.Reason != "invalid_response" || !reflect.DeepEqual(ev["reasons"], c.reasons) || facts["terminal_response_present"] != true || facts["terminal_output_present"] != true ||
			facts["terminal_output_replaced"] != false || facts["item_count"] != c.items || facts["pending_count"] != c.pending || facts["observed_index_count"] != c.observed ||
			strings.Contains(se.Detail, "PRIVATE") {
			t.Errorf("case %d: %v", i, se.Detail)
		}
	}
}

// provider_wait_test: failure events win over retained done items and empty completion.
func TestFailureEventsWinOverRetainedItems(t *testing.T) {
	var script []handler
	kinds := []string{"response.failed", "response.incomplete", "error"}
	for _, k := range kinds {
		script = append(script, events(itemDone(0, tool()), map[string]any{"type": k, "response": map[string]any{"error": map[string]any{}}}, done(map[string]any{"output": []any{}})))
	}
	script = append(script, events(itemDone(0, tool())), events(itemDone(0, tool()), done("bad")))
	e, _ := chatEnv(t, script...)
	for range kinds {
		if _, err := single(e); mustErr(t, err).Reason != "refused" {
			t.Fatalf("err = %v", err)
		}
	}
	if _, err := single(e); mustErr(t, err).Reason != "unavailable" {
		t.Fatalf("missing completion: %v", err)
	}
	if _, err := single(e); mustErr(t, err).Reason != "invalid_response" {
		t.Fatalf("bad envelope: %v", err)
	}
}

// provider_wait_test: an expired invocation does not consume the next invocation's budget.
func TestExpiredInvocationDoesNotConsumeTheNextBudget(t *testing.T) {
	e, f := chatEnv(t, jsonAnswer(500, map[string]any{}), textAnswer("fresh"))
	e.c.ResponseBudget = time.Second
	_, err := e.respond(Request{})
	se := mustErr(t, err)
	if se.Reason != "unavailable" || se.Detail != "ChatGPT response wait exceeded 1s" || len(f.requests()) != 1 || !reflect.DeepEqual(e.clk.slept(), []time.Duration{time.Second}) {
		t.Fatalf("err = %v, %d requests, slept %v", se, len(f.requests()), e.clk.slept())
	}
	resp, err := e.respond(Request{})
	if err != nil || resp.Items[0]["content"].([]any)[0].(map[string]any)["text"] != "fresh" || len(f.requests()) != 2 {
		t.Fatalf("%v %v", resp, err)
	}
}

// provider_wait_test: the second backoff also spends the original budget.
func TestSecondBackoffSpendsTheOriginalBudget(t *testing.T) {
	e, f := chatEnv(t, jsonAnswer(500, map[string]any{}), jsonAnswer(500, map[string]any{}), jsonAnswer(500, map[string]any{}))
	e.c.ResponseBudget = 3 * time.Second
	_, err := e.respond(Request{})
	if mustErr(t, err).Detail != "ChatGPT response wait exceeded 3s" || len(f.requests()) != 2 {
		t.Fatalf("err = %v, %d requests", err, len(f.requests()))
	}
	if got := e.clk.slept(); !reflect.DeepEqual(got, []time.Duration{2 * time.Second, time.Second}) {
		t.Fatalf("slept %v", got)
	}
}

func TestBudgetIsCappedAtThirtyMinutes(t *testing.T) {
	f := newFake(t, jsonAnswer(500, map[string]any{}), jsonAnswer(500, map[string]any{}), jsonAnswer(500, map[string]any{}))
	e := newEnv(t, f)
	e.saveCreds("chatgpt", e.chatgptCreds())
	// Credentials wait in the lock share the budget: a held lock expires the call.
	p, _ := Lookup("chatgpt")
	held, err := (Locker{}).Acquire(lockPath(e.home, p))
	if err != nil {
		t.Fatal(err)
	}
	defer held.Release()
	e.saveCreds("chatgpt", e.chatgptCreds("expires_at", e.clk.Now().Unix()+10))
	// Each 100 ms lock wait advances the fake clock by 10 s, to keep the test fast.
	e.c.Sleep = func(ctx context.Context, d time.Duration) error { return e.clk.Sleep(ctx, d*100) }
	start := e.clk.Now()
	_, err = e.respond(Request{})
	if se := mustErr(t, err); se.Detail != "ChatGPT response wait exceeded 30 minutes" {
		t.Fatalf("err = %v", err)
	}
	if elapsed := e.clk.Now().Sub(start); elapsed < ResponseBudget || elapsed > ResponseBudget+11*time.Second || len(f.requests()) != 0 {
		t.Fatalf("waited %v, %d requests", elapsed, len(f.requests()))
	}
}

// provider_wait_test: single attempt does not retry unreadable output or transient failures.
func TestSingleAttemptDoesNotRetry(t *testing.T) {
	e, f := chatEnv(t, events(done(map[string]any{})), jsonAnswer(500, map[string]any{}))
	if _, err := single(e); mustErr(t, err).Reason != "invalid_response" || len(f.requests()) != 1 {
		t.Fatal("unreadable output retried")
	}
	if _, err := single(e); mustErr(t, err).Reason != "unavailable" || len(f.requests()) != 2 {
		t.Fatal("transient retried")
	}
	if len(e.clk.slept()) != 0 {
		t.Fatalf("slept %v", e.clk.slept())
	}
}

func TestSingleAttemptDetailsAndNoRefreshAfter401(t *testing.T) {
	e, f := chatEnv(t, jsonAnswer(401, map[string]any{"error": map[string]any{"code": "unauthorized"}}), httpFail(503, "x", "down"))
	_, err := single(e)
	se := mustErr(t, err)
	if se.Reason != "login" || se.Detail != "the ChatGPT sign-in was rejected; run kogen provider login chatgpt" || len(f.authRequests()) != 0 {
		t.Fatalf("err = %v, %d auth requests", se, len(f.authRequests()))
	}
	_, err = single(e)
	if se := mustErr(t, err); se.Detail != "HTTP 503 down" || se.Reason != "unavailable" {
		t.Fatalf("single transient detail = %q", se.Detail)
	}
	e2, _ := chatEnv(t, rawStream("data: nope\n\n"))
	if _, err := single(e2); mustErr(t, err).Detail != "an event is not JSON" {
		t.Fatalf("single invalid detail = %v", err)
	}
}

// provider_wait_test: completed output is validated, ordered and failures win.
func TestCompletedOutputIsValidatedOrderedAndFailuresWin(t *testing.T) {
	item := tool()
	added := func(i int, it any) map[string]any {
		return map[string]any{"type": "response.output_item.added", "output_index": int64(i), "item": it}
	}
	invalid := [][]any{
		{itemDone(1, item), done(map[string]any{})},
		{itemDone(-1, item), done(map[string]any{})},
		{itemDone(0, with(item, "arguments", "[]")), done(map[string]any{})},
		{itemDone(0, with(item, "call_id", "")), done(map[string]any{})},
		{itemDone(0, map[string]any{"type": "message", "content": []any{map[string]any{"type": "output_text", "text": int64(42)}}}), done(map[string]any{})},
		{map[string]any{"type": "response.completed", "response": "bad"}},
		{done(map[string]any{"output": []any{with(item, "status", "in_progress")}})},
		{done(map[string]any{"output": []any{item}, "status": "incomplete"})},
		{done(map[string]any{"output": []any{item}, "error": map[string]any{"code": "server_error"}})},
		{added(1, item), done(map[string]any{"output": []any{item}})},
		{done(map[string]any{"output": []any{item}, "usage": "bad"})},
		{done(map[string]any{"output": []any{item}, "usage": map[string]any{"input_tokens_details": int64(42)}})},
		{added(0, item), done(map[string]any{})},
		{done(map[string]any{"output": nil})},
		{done(map[string]any{"output": "text"})},
	}
	var script []handler
	for _, c := range invalid {
		script = append(script, events(c...))
	}
	script = append(script,
		events(map[string]any{"type": "response.failed", "response": map[string]any{"error": map[string]any{}}}, done(map[string]any{"output": []any{item}})),
		events(added(0, item), done(map[string]any{"output": []any{item}})),
		events(done(map[string]any{"status": "completed", "output": []any{with(item, "status", "completed")}})))
	e, _ := chatEnv(t, script...)
	for i := range invalid {
		if _, err := single(e); mustErr(t, err).Reason != "invalid_response" {
			t.Fatalf("case %d: %v", i, err)
		}
	}
	if _, err := single(e); mustErr(t, err).Reason != "refused" {
		t.Fatal("failure did not win")
	}
	resp, err := single(e)
	if err != nil || !reflect.DeepEqual(resp.Items, []map[string]any{item}) {
		t.Fatalf("pending item replaced by the final output: %v %v", resp, err)
	}
	completed := with(item, "status", "completed")
	resp, err = single(e)
	if err != nil || !reflect.DeepEqual(resp.Items, []map[string]any{completed}) {
		t.Fatalf("%v %v", resp, err)
	}
}

func TestValidMessageAndReasoningOutput(t *testing.T) {
	msg := map[string]any{"type": "message", "id": "m", "role": "assistant", "phase": "commentary", "content": []any{
		map[string]any{"type": "output_text", "text": "hi"}, map[string]any{"type": "refusal", "refusal": "no"}}}
	e, _ := chatEnv(t, events(itemDone(0, map[string]any{"type": "reasoning", "id": "r", "encrypted_content": "o", "summary": []any{}}), itemDone(1, msg), done(map[string]any{})))
	resp, err := single(e)
	if err != nil || len(resp.Items) != 2 || !reflect.DeepEqual(resp.Items[1], msg) {
		t.Fatalf("%v %v", resp, err)
	}
	// Unknown item types are not valid output.
	e2, _ := chatEnv(t, events(itemDone(0, map[string]any{"type": "web_search_call"}), done(map[string]any{})))
	ev := func() map[string]any { _, err := single(e2); return validationOf(t, err) }()
	if !reflect.DeepEqual(ev["reasons"], []any{"item_shape"}) || !reflect.DeepEqual(ev["facts"].(map[string]any)["item_types"], []any{"other"}) {
		t.Fatalf("%v", ev)
	}
}

// provider_wait_test: a validated open stream is cancelled before the caller exits.
func TestValidatedOpenStreamIsCancelled(t *testing.T) {
	opened, closed := make(chan struct{}), make(chan struct{})
	e, _ := chatEnv(t, openEvents(opened, closed, done(map[string]any{"output": []any{tool()}})))
	e.realClock()
	e.c.ResponseBudget = time.Second
	resp, err := e.respond(Request{})
	if err != nil || !reflect.DeepEqual(resp.Items, []map[string]any{tool()}) {
		t.Fatalf("%v %v", resp, err)
	}
	select {
	case <-closed:
	case <-time.After(2 * time.Second):
		t.Fatal("not cancelled")
	}
}

// provider_wait_test: expiry is checked while data keeps arriving and closes the request.
func TestExpiryIsCheckedWithBusyStreamAndClosesTheRequest(t *testing.T) {
	opened, closed := make(chan struct{}), make(chan struct{})
	busy := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		close(opened)
		tick := time.NewTicker(5 * time.Millisecond)
		defer tick.Stop()
		for {
			select {
			case <-r.Context().Done():
				close(closed)
				return
			case <-tick.C:
				if _, err := w.Write([]byte(": heartbeat\n\n")); err != nil {
					close(closed)
					return
				}
				w.(http.Flusher).Flush()
			}
		}
	}
	e, _ := chatEnv(t, busy)
	e.realClock()
	e.c.ResponseBudget = time.Second
	start := time.Now()
	_, err := e.respond(Request{})
	if mustErr(t, err).Detail != "ChatGPT response wait exceeded 1s" {
		t.Fatalf("err = %v", err)
	}
	if d := time.Since(start); d < time.Second || d > 3*time.Second {
		t.Fatalf("expired after %v", d)
	}
	select {
	case <-closed:
	case <-time.After(2 * time.Second):
		t.Fatal("request not closed")
	}
}

// provider_wait_test: unreadable output retries once within the same invocation.
func TestUnreadableOutputRetriesOnce(t *testing.T) {
	e, f := chatEnv(t, events(done(map[string]any{"output": []any{tool()}, "usage": "bad"})), textAnswer("retry"))
	resp, err := e.respond(Request{})
	if err != nil || resp.Items[0]["content"].([]any)[0].(map[string]any)["text"] != "retry" || len(f.requests()) != 2 {
		t.Fatalf("%v %v %d", resp, err, len(f.requests()))
	}
}

func TestEventFramingTolerance(t *testing.T) {
	// CRLF framing, data: without space, a multi-line data field, comment lines, [DONE], and a
	// completion split across chunks.
	completed := string(mustEncode(done(map[string]any{"output": []any{tool()}})))
	half := len(completed) / 2
	e, _ := chatEnv(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io := func(s string) { w.Write([]byte(s)); w.(http.Flusher).Flush() }
		io(": comment\r\n\r\n")
		io("event: x\r\ndata:" + string(mustEncode(map[string]any{"type": "response.created"})) + "\r\n\r\n")
		io("data: [DONE]\n\n")
		io("data: " + completed[:half])
		time.Sleep(20 * time.Millisecond)
		io(completed[half:] + "\r\n\r\n")
	})
	resp, err := single(e)
	if err != nil || !reflect.DeepEqual(resp.Items, []map[string]any{tool()}) {
		t.Fatalf("%v %v", resp, err)
	}
	// [DONE] alone is not success.
	e2, _ := chatEnv(t, rawStream("data: [DONE]\n\n"))
	if _, err := single(e2); mustErr(t, err).Detail != "the response stream ended before it completed" {
		t.Fatalf("err = %v", err)
	}
}

func TestResponseFailedEventCodesRetryOrRefuse(t *testing.T) {
	for _, code := range []string{"server_error", "rate_limit_exceeded", "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable"} {
		e, f := chatEnv(t,
			events(map[string]any{"type": "response.failed", "response": map[string]any{"error": map[string]any{"code": code, "message": "temp", "type": "capacity"}}}), textAnswer("ok"))
		if _, err := e.respond(Request{}); err != nil || len(f.requests()) != 2 {
			t.Fatalf("%s: %v, %d requests", code, err, len(f.requests()))
		}
	}
}

func TestMarshalOfUsageRecord(t *testing.T) {
	n := 3
	b, _ := json.Marshal(KnownUsage{Input: &n})
	if string(b) != `{"input":3,"cached":null,"write":null,"write_30m":null,"write_12h":null,"output":null,"reasoning":null}` {
		t.Fatal(string(b))
	}
}

var _ = sys.Fail

// The public Responses key has its own narrowly scoped compatibility policy.
func TestChatGPTExactKeyRefusalRetriesOnceAndPersistsAcrossRestore(t *testing.T) {
	for _, single := range []bool{false, true} {
		for _, code := range []string{"unknown_parameter", "unsupported_parameter", "invalid_parameter"} {
			t.Run(fmt.Sprintf("single=%v/code=%s", single, code), func(t *testing.T) {
				refusal := jsonAnswer(400, map[string]any{"error": map[string]any{"code": code, "param": "prompt_cache_key", "message": "prompt_cache_key is not supported on this model"}})
				e, f := chatEnv(t, refusal, textAnswer("accepted"), textAnswer("restored"))
				req := Request{Role: Role{Model: "gpt-6.1-sol", Effort: "high"}, Instructions: "complete policy", Input: user("complete contract"), Scope: "same conversation", Single: single}
				obs := &observer{}
				if _, err := e.c.Respond(context.Background(), e.s, req, obs); err != nil {
					t.Fatal(err)
				}
				e.c.Cache = NewCache(e.c.Cache.States())
				if _, err := e.c.Respond(context.Background(), e.s, req, obs); err != nil {
					t.Fatal(err)
				}
				requests := f.requests()
				if len(requests) != 3 {
					t.Fatalf("requests=%d", len(requests))
				}
				first := requests[0].JSON
				if first["prompt_cache_key"] == nil {
					t.Fatal("first request omitted key")
				}
				stripped := map[string]any{}
				for k, v := range first {
					if k != "prompt_cache_key" {
						stripped[k] = v
					}
				}
				for _, request := range requests[1:] {
					if !reflect.DeepEqual(request.JSON, stripped) {
						t.Fatal("fallback changed authority or retried key after restore")
					}
				}
				records := obs.records()
				if len(records) != 3 || records[0]["usage_state"] != "unknown" {
					t.Fatal("failed attempt was not retained once with unknown usage")
				}
			})
		}
	}
}

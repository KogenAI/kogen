package provider

import (
	"context"
	"fmt"
	"net/http"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"kogen-loop/sys"
)

func headerNames(h http.Header) []string {
	var names []string
	for k := range h {
		names = append(names, k)
	}
	sort.Strings(names)
	return names
}

func readTool(name string) map[string]any {
	return map[string]any{"type": "function", "name": name, "description": "d", "parameters": map[string]any{"type": "object", "properties": map[string]any{"path": map[string]any{"type": "string"}}}}
}

func TestRespondHappyPathWithFunctionCall(t *testing.T) {
	call := map[string]any{"type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "read_file", "arguments": `{"path":"a.txt"}`, "status": "completed"}
	reasoning := map[string]any{"type": "reasoning", "id": "rs_1", "encrypted_content": "opaque", "summary": []any{}}
	f := newFake(t, events(
		map[string]any{"type": "response.created", "response": map[string]any{"id": "resp_1"}},
		map[string]any{"type": "response.output_item.added", "output_index": int64(0), "item": reasoning},
		itemDone(0, reasoning), itemDone(1, call),
		map[string]any{"type": "response.function_call_arguments.delta", "output_index": int64(1), "delta": "PARTIAL"},
		done(map[string]any{
			"id": "resp_1", "model": "gpt-6.1-sol-2026", "service_tier": "default", "reasoning": map[string]any{"effort": "high"},
			"usage": map[string]any{
				"input_tokens": int64(120), "input_tokens_details": map[string]any{"cached_tokens": int64(20), "cache_write_tokens": int64(60),
					"cache_write_tokens_details": map[string]any{"ttl_30m_tokens": int64(60), "ttl_12h_tokens": int64(0)}},
				"output_tokens": int64(30), "output_tokens_details": map[string]any{"reasoning_tokens": int64(10)}},
		})))
	e := newEnv(t, f)
	e.saveCreds("chatgpt", e.chatgptCreds())
	obs := &observer{}
	input := []any{map[string]any{"role": "user", "content": []any{map[string]any{"type": "input_text", "text": "contract"}, map[string]any{"type": "input_text", "text": "files"}}}}
	resp, err := e.c.Respond(context.Background(), e.s, Request{
		Role: Role{Model: "gpt-6.1-sol", Effort: "high"}, Instructions: "policy", Input: input, Tools: []any{readTool("read_file")},
		Scope: []any{"run-1", "build", int64(0)}, Context: map[string]any{"phase": "build", "role": "build", "run_id": "r1", "slug": "is-even"},
	}, obs)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(resp.Items, []map[string]any{reasoning, call}) {
		t.Fatalf("items = %v", resp.Items)
	}
	if resp.Usage != (Usage{Input: 120, Cached: 20, Output: 30, Reasoning: 10}) || resp.UsageState != UsageKnown || *resp.Known.Write != 60 || *resp.Known.Write30m != 60 {
		t.Fatalf("usage = %+v %+v %s", resp.Usage, resp.Known, resp.UsageState)
	}
	if resp.ID != "resp_1" || resp.Model != "gpt-6.1-sol-2026" || resp.Effort != "high" || resp.CacheStatus != "applied" || !strings.HasPrefix(resp.OperationID, "operation-") {
		t.Fatalf("response = %+v", resp)
	}

	reqs := f.requests()
	if len(reqs) != 1 {
		t.Fatal(len(reqs))
	}
	r := reqs[0]
	if r.Method != "POST" || r.Path != "/v1/responses" {
		t.Fatalf("%s %s", r.Method, r.Path)
	}
	// GPT-7: headers are exactly the application headers plus ordinary HTTP framing.
	if got := headerNames(r.Header); !reflect.DeepEqual(got, []string{"Accept", "Authorization", "Connection", "Content-Length", "Content-Type", "Conversation_id", "Session_id"}) {
		t.Fatalf("headers = %v", got)
	}
	if r.Header.Get("Authorization") != "Bearer fake-access-token" || r.Header.Get("Accept") != "text/event-stream" || r.Header.Get("Content-Type") != "application/json" {
		t.Fatalf("headers = %v", r.Header)
	}
	b := r.JSON
	for k, want := range map[string]any{"model": "gpt-6.1-sol", "stream": true, "store": false, "tool_choice": "auto"} {
		if b[k] != want {
			t.Errorf("%s = %v, want %v", k, b[k], want)
		}
	}
	if !reflect.DeepEqual(b["reasoning"], map[string]any{"effort": "high"}) || !reflect.DeepEqual(b["include"], []any{"reasoning.encrypted_content"}) {
		t.Fatalf("reasoning/include = %v %v", b["reasoning"], b["include"])
	}
	if !reflect.DeepEqual(b["tools"], []any{readTool("read_file")}) {
		t.Fatalf("tools = %v", b["tools"])
	}
	if b["instructions"] != "policy" {
		t.Fatalf("instructions = %v", b["instructions"])
	}
	in := b["input"].([]any)
	if len(in) != 1 || !reflect.DeepEqual(in[0], input[0]) {
		t.Fatalf("input is the caller's, unmarked: %v", in)
	}
	for _, k := range []string{"prompt_cache_options", "prompt_cache_retention"} {
		if _, has := b[k]; has {
			t.Fatalf("%s sent", k)
		}
	}
	// The public SIWC route carries the same bounded identity in body and routing headers.
	key, _ := b["prompt_cache_key"].(string)
	if key == "" || len(key) > MaxCacheID || r.Header.Get("Session-Id") != "" || r.Header.Get("session_id") != key || r.Header.Get("conversation_id") != key {
		t.Fatalf("prompt_cache_key %q, session-id %q", key, r.Header.Get("Session-Id"))
	}
	if strings.Contains(string(r.Body), "prompt_cache_breakpoint") {
		t.Fatal("a breakpoint marker was sent")
	}

	recs := obs.records()
	if len(recs) != 1 {
		t.Fatal(len(recs))
	}
	rec := recs[0]
	for k, want := range map[string]any{
		"provider": "chatgpt", "configured_model": "gpt-6.1-sol", "configured_effort": "high", "effective_model": "gpt-6.1-sol-2026",
		"effective_effort": "high", "effective_service_tier": "default", "provider_response_id": "resp_1", "provider_request_id": "req-fixture",
		"outcome": "completed", "usage_state": "known", "error": nil, "requested_service_tier": nil, "ttft_ms": nil,
		"phase": "build", "role": "build", "run_id": "r1", "slug": "is-even", "operation_id": resp.OperationID,
	} {
		if !reflect.DeepEqual(rec[k], want) {
			t.Errorf("record[%s] = %#v, want %#v", k, rec[k], want)
		}
	}
	cache := rec["cache"].(map[string]any)
	if cache["status"] != "applied" || cache["applied_mode"] != nil || cache["applied_ttl"] != nil || cache["configured_ttl"] != nil ||
		len(cache["boundaries"].([]any)) != 0 || rec["conversation_id"] != key {
		t.Fatalf("cache = %v", cache)
	}
	usage := rec["usage"].(map[string]any)
	if usage["input"] != 120 || usage["write_30m"] != 60 || usage["write_12h"] != 0 || usage["reasoning"] != 10 {
		t.Fatalf("usage = %v", usage)
	}
	fp := rec["fingerprints"].(map[string]any)
	for _, k := range []string{"policy", "tools", "schema", "contract", "prefix"} {
		if fp[k] == nil {
			t.Errorf("fingerprint %s missing", k)
		}
	}
	if _, ok := rec["conversation_id"].(string); !ok || rec["attempt_id"] == "" || rec["timestamp"] == "" {
		t.Fatalf("ids = %v %v %v", rec["conversation_id"], rec["attempt_id"], rec["timestamp"])
	}
	if _, err := time.Parse("2006-01-02T15:04:05.000000Z", rec["timestamp"].(string)); err != nil {
		t.Fatal(err)
	}
	if st := e.c.Cache.States(); len(st) != 1 {
		t.Fatalf("cache states = %v", st)
	} else {
		for _, s := range st {
			if s.ID != key || s.Response != "" || s.Unsupported {
				t.Fatalf("state = %+v", s)
			}
		}
	}
}

func TestRespondSuperGrokRequestAndHeaders(t *testing.T) {
	f := newFake(t, textAnswer("hello"))
	e := newEnv(t, f)
	e.saveCreds("supergrok", e.supergrokCreds())
	obs := &observer{}
	resp, err := e.c.Respond(context.Background(), e.s, Request{
		Role: Role{Provider: "supergrok", Model: "grok-4.7", Effort: "xhigh"}, Instructions: "plain policy",
		Input: []any{map[string]any{"role": "user", "content": "do it"}}, Tools: []any{readTool("shell")},
	}, obs)
	if err != nil {
		t.Fatal(err)
	}
	if len(resp.Items) != 1 || resp.CacheStatus != "applied" {
		t.Fatalf("response = %+v", resp)
	}
	r := f.requests()[0]
	if got := headerNames(r.Header); !reflect.DeepEqual(got, []string{"Accept", "Authorization", "Connection", "Content-Length", "Content-Type", "User-Agent"}) {
		t.Fatalf("headers = %v", got)
	}
	if r.Header.Get("Authorization") != "Bearer synthetic-access" || r.Header.Get("User-Agent") != "kogen/dev+12345678" {
		t.Fatalf("headers = %v", r.Header)
	}
	b := r.JSON
	if b["instructions"] != "plain policy" || b["model"] != "grok-4.7" || !reflect.DeepEqual(b["reasoning"], map[string]any{"effort": "xhigh"}) ||
		b["stream"] != true || b["store"] != false || b["tool_choice"] != "auto" {
		t.Fatalf("body = %v", b)
	}
	for _, k := range []string{"prompt_cache_options", "prompt_cache_retention"} {
		if _, has := b[k]; has {
			t.Fatalf("%s sent", k)
		}
	}
	if key, _ := b["prompt_cache_key"].(string); key == "" || len(key) > MaxCacheID || r.Header.Get("Session-Id") != "" || r.Header.Get("session_id") != "" || r.Header.Get("conversation_id") != "" {
		t.Fatalf("SuperGrok routes with the body key only: key=%q session-id=%q", key, r.Header.Get("Session-Id"))
	}
	in := b["input"].([]any)
	if len(in) != 1 || in[0].(map[string]any)["role"] != "user" {
		t.Fatalf("a developer policy message was added: %v", in)
	}
	for _, k := range []string{"previous_response_id", "conversation"} {
		if _, has := b[k]; has {
			t.Fatalf("%s sent", k)
		}
	}
	rec := obs.records()[0]
	if rec["provider"] != "supergrok" || rec["cache"].(map[string]any)["status"] != "applied" || len(rec["cache"].(map[string]any)["boundaries"].([]any)) != 0 || rec["conversation_id"] != b["prompt_cache_key"] {
		t.Fatalf("record = %v", rec)
	}
}

func TestRespondWithoutLoginSendsNothing(t *testing.T) {
	f := newFake(t, textAnswer("x"))
	e := newEnv(t, f)
	_, err := e.respond(Request{})
	if se := mustErr(t, err); se.Detail != "not signed in; run kogen provider login chatgpt" || se.Exit != 4 || se.Reason != "login" {
		t.Fatalf("err = %v", err)
	}
	if len(f.requests()) != 0 {
		t.Fatal("request sent without a login")
	}
}

func TestRespondRefusesNonLoopbackSeams(t *testing.T) {
	e := newEnv(t, nil)
	e.s.Env = append(e.s.Env, "KOGEN_AUTH_URL=https://example.com")
	_, err := e.respond(Request{})
	se := mustErr(t, err)
	if se.Class != "environment" || se.Reason != "invalid_test_seam" || se.Exit != 3 ||
		se.Detail != "KOGEN_AUTH_URL must be http://127.0.0.1:<port> or http://localhost:<port>" {
		t.Fatalf("err = %v", se)
	}
}

func TestStreamCutIsRetriedAfterTwoSeconds(t *testing.T) {
	cut := rawStream(frame(itemDone(0, tool())) + `data: {"type":"response.completed"`) // no blank line, no completion
	f := newFake(t, cut, textAnswer("fresh"))
	e := newEnv(t, f)
	e.saveCreds("chatgpt", e.chatgptCreds())
	obs := &observer{}
	resp, err := e.c.Respond(context.Background(), e.s, Request{Role: fixtureRole, Instructions: "p"}, obs)
	if err != nil {
		t.Fatal(err)
	}
	if got := resp.Items[0]["content"].([]any)[0].(map[string]any)["text"]; got != "fresh" {
		t.Fatalf("items = %v (partial output of the cut stream must be discarded)", resp.Items)
	}
	if !reflect.DeepEqual(e.clk.slept(), []time.Duration{2 * time.Second}) || len(f.requests()) != 2 {
		t.Fatalf("slept %v, %d requests", e.clk.slept(), len(f.requests()))
	}
	recs := obs.records()
	if len(recs) != 2 || recs[0]["outcome"] != "failed" || recs[0]["error"] != "provider_failure" || recs[0]["usage_state"] != "unknown" || recs[1]["outcome"] != "completed" {
		t.Fatalf("records = %v", recs)
	}
	if recs[0]["operation_id"] != recs[1]["operation_id"] || recs[0]["attempt_id"] == recs[1]["attempt_id"] {
		t.Fatal("attempts must share the operation and differ in ID")
	}
	for _, v := range recs[0]["usage"].(map[string]any) {
		if v != nil {
			t.Fatalf("failed attempt has usage: %v", recs[0]["usage"])
		}
	}
}

func TestThreeTransientFailuresStopWithBackoff(t *testing.T) {
	f := newFake(t, httpFail(503, "overloaded", "try later"), httpFail(503, "overloaded", "try later"), httpFail(503, "overloaded", "try later"), textAnswer("never"))
	e := newEnv(t, f)
	e.saveCreds("chatgpt", e.chatgptCreds())
	_, err := e.respond(Request{})
	se := mustErr(t, err)
	if se.Class != "provider" || se.Reason != "unavailable" || se.Exit != 4 || se.Detail != "ChatGPT did not answer after 3 attempts: HTTP 503 try later" {
		t.Fatalf("err = %v", se)
	}
	if !reflect.DeepEqual(e.clk.slept(), []time.Duration{2 * time.Second, 8 * time.Second}) || len(f.requests()) != 3 {
		t.Fatalf("slept %v, %d requests", e.clk.slept(), len(f.requests()))
	}
	if !reflect.DeepEqual(se.ProviderFailure, map[string]any{"code": "overloaded", "type": "invalid_request_error", "http_status": int64(503)}) {
		t.Fatalf("provider failure = %v", se.ProviderFailure)
	}
	if !reflect.DeepEqual(se.Lines, []string{`provider failure: {"code":"overloaded","http_status":503,"type":"invalid_request_error"}`}) {
		t.Fatalf("lines = %q", se.Lines)
	}
}

func TestTransientNetworkFailureWithoutAnswer(t *testing.T) {
	f := newFake(t)
	e := newEnv(t, f)
	e.saveCreds("chatgpt", e.chatgptCreds())
	f.srv.Close() // connection refused
	_, err := e.respond(Request{})
	se := mustErr(t, err)
	if se.Reason != "unavailable" || !strings.HasPrefix(se.Detail, "ChatGPT did not answer after 3 attempts: network error: ") || se.ProviderFailure != nil {
		t.Fatalf("err = %v", se)
	}
	if strings.Contains(se.Detail, "fake-access-token") {
		t.Fatal("token in error")
	}
}

func TestRateLimit429IsRetriedButUsageLimitIsNot(t *testing.T) {
	f := newFake(t, httpFail(429, "rate_limit_exceeded", "slow down"), textAnswer("ok"))
	e := newEnv(t, f)
	e.saveCreds("chatgpt", e.chatgptCreds())
	if _, err := e.respond(Request{}); err != nil {
		t.Fatal(err)
	}
	if len(f.requests()) != 2 || !reflect.DeepEqual(e.clk.slept(), []time.Duration{2 * time.Second}) {
		t.Fatalf("%d requests, slept %v", len(f.requests()), e.clk.slept())
	}
	// A usage limit is a 429 that never retries.
	f2 := newFake(t, jsonAnswer(429, map[string]any{"error": map[string]any{"code": "subscription_sharing_usage_limit_exceeded", "message": "limit", "resets_at": int64(1790000000)}}), textAnswer("no"))
	e2 := newEnv(t, f2)
	e2.saveCreds("chatgpt", e2.chatgptCreds())
	_, err := e2.respond(Request{})
	se := mustErr(t, err)
	if se.Reason != "usage_limit" || se.Detail != "ChatGPT usage limit reached; it resets at 2026-09-21T14:13:20Z" || se.Exit != 4 {
		t.Fatalf("err = %v", se)
	}
	if len(f2.requests()) != 1 {
		t.Fatal("usage limit retried")
	}
}

func TestUsageLimitResetForms(t *testing.T) {
	for name, tc := range map[string]struct {
		resets any
		want   string
	}{
		"unix":    {int64(1760000000), "ChatGPT usage limit reached; it resets at 2025-10-09T08:53:20Z"},
		"string":  {"2026-10-23T10:00:00Z", "ChatGPT usage limit reached; it resets at 2026-10-23T10:00:00Z"},
		"missing": {nil, "ChatGPT usage limit reached"},
		"float":   {1.5, "ChatGPT usage limit reached"},
	} {
		t.Run(name, func(t *testing.T) {
			body := map[string]any{"code": "subscription_sharing_usage_limit_exceeded", "message": "limit"}
			if tc.resets != nil {
				body["resets_at"] = tc.resets
			}
			// The limit also arrives as a failure event inside a 200 stream.
			f := newFake(t, jsonAnswer(429, map[string]any{"error": body}))
			e := newEnv(t, f)
			e.saveCreds("chatgpt", e.chatgptCreds())
			_, err := e.respond(Request{})
			if got := mustErr(t, err).Detail; got != tc.want {
				t.Fatalf("detail = %q", got)
			}
		})
	}
}

func TestRequestErrorsAreClassified(t *testing.T) {
	cases := []struct {
		name    string
		h       handler
		reason  string
		detail  string
		retries bool
	}{
		{"model", httpFail(404, "model_not_found", "no such model"), "model_unavailable", "fixture is not available to this ChatGPT account", false},
		{"capability", jsonAnswer(400, map[string]any{"error": map[string]any{"code": "subscription_sharing_unsupported_capability", "param": "model", "message": "x"}}), "model_unavailable", "fixture is not available to this ChatGPT account", false},
		{"context", httpFail(400, "context_length_exceeded", "full"), "context_too_long", "the conversation no longer fits fixture's context", false},
		{"refused", httpFail(400, "invalid_request_error", "bad request"), "refused", "ChatGPT refused the request: 400 bad request", false},
		{"detail field", jsonAnswer(403, map[string]any{"detail": "forbidden here"}), "refused", "ChatGPT refused the request: 403 forbidden here", false},
		{"plain body", rawAnswer(418, "teapot"), "refused", "ChatGPT refused the request: 418 teapot", false},
		{"no message", jsonAnswer(400, map[string]any{"error": map[string]any{}}), "refused", "ChatGPT refused the request: 400", false},
		{"code as message", jsonAnswer(400, map[string]any{"error": map[string]any{"code": "weird"}}), "refused", "ChatGPT refused the request: 400 weird", false},
		{"stream context", events(map[string]any{"type": "response.failed", "response": map[string]any{"error": map[string]any{"code": "context_length_exceeded", "message": "m"}}}), "context_too_long", "the conversation no longer fits fixture's context", false},
		{"stream refused", events(map[string]any{"type": "error", "error": map[string]any{"message": "no code"}}), "refused", "ChatGPT refused the request: stream no code", false},
		{"incomplete", events(map[string]any{"type": "response.incomplete", "response": map[string]any{"incomplete_details": map[string]any{"reason": "max_output_tokens"}}}), "refused", `ChatGPT refused the request: stream %{"reason" => "max_output_tokens"}`, false},
		{"stream usage limit", events(map[string]any{"type": "response.failed", "response": map[string]any{"error": map[string]any{"code": "subscription_sharing_usage_limit_exceeded", "resets_at": "tomorrow"}}}), "usage_limit", "ChatGPT usage limit reached; it resets at tomorrow", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newFake(t, tc.h, textAnswer("never"))
			e := newEnv(t, f)
			e.saveCreds("chatgpt", e.chatgptCreds())
			_, err := e.respond(Request{})
			se := mustErr(t, err)
			if se.Class != "provider" || se.Reason != tc.reason || se.Detail != tc.detail || se.Exit != 4 {
				t.Fatalf("err = %v (reason %s)", se, se.Reason)
			}
			if len(f.requests()) != 1 {
				t.Fatalf("%d requests: no retry expected", len(f.requests()))
			}
		})
	}
}

func TestSuperGrokBillingAndAccessRefusalsDoNotRetry(t *testing.T) {
	cases := []struct {
		status int
		body   handler
		detail string
	}{
		{402, httpFail(402, "payment_required", "credits exhausted"), "SuperGrok reported a billing or credit limit (402 credits exhausted); Kogen uses only the subscription sign-in and never falls back to paid API usage"},
		{402, jsonAnswer(402, map[string]any{}), "SuperGrok reported a billing or credit limit (402 {}); Kogen uses only the subscription sign-in and never falls back to paid API usage"},
		{403, httpFail(403, "forbidden", "no API access"), "SuperGrok denied API access for this sign-in (403 no API access); Kogen never falls back to an API key or another provider"},
		{403, jsonAnswer(403, map[string]any{"error": map[string]any{}}), "SuperGrok denied API access for this sign-in (403); Kogen never falls back to an API key or another provider"},
	}
	for i, tc := range cases {
		t.Run(fmt.Sprint(tc.status, "/", i), func(t *testing.T) {
			f := newFake(t, tc.body, textAnswer("never"))
			e := newEnv(t, f)
			e.saveCreds("supergrok", e.supergrokCreds())
			_, err := e.respond(Request{Role: grokRole})
			se := mustErr(t, err)
			if se.Reason != "refused" || se.Detail != tc.detail || se.Exit != 4 {
				t.Fatalf("err = %v", se)
			}
			if len(f.requests()) != 1 || len(e.clk.slept()) != 0 {
				t.Fatalf("%d requests, slept %v", len(f.requests()), e.clk.slept())
			}
		})
	}
}

func TestSuperGrokErrorMessages(t *testing.T) {
	cases := []struct {
		name, reason, detail string
		h                    []handler
	}{
		{"model", "model_unavailable", "grok-4.7 is not available to this SuperGrok account", []handler{httpFail(404, "model_not_found", "x")}},
		{"context", "context_too_long", "the conversation no longer fits grok-4.7's context", []handler{httpFail(400, "context_length_exceeded", "x")}},
		{"refused", "refused", "SuperGrok refused the request: 400 nope", []handler{httpFail(400, "other", "nope")}},
		{"unavailable", "unavailable", "SuperGrok did not answer after 3 attempts: HTTP 500 boom", []handler{httpFail(500, "e", "boom"), httpFail(500, "e", "boom"), httpFail(500, "e", "boom")}},
		{"invalid", "invalid_response", "SuperGrok sent a response Kogen cannot read: an event is not JSON", []handler{rawStream("data: nope\n\n"), rawStream("data: nope\n\n")}},
		// ChatGPT-only handling never applies to SuperGrok.
		{"usage limit code is a plain refusal", "refused", "SuperGrok refused the request: 400 limit", []handler{httpFail(400, "subscription_sharing_usage_limit_exceeded", "limit")}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newFake(t, tc.h...)
			e := newEnv(t, f)
			e.saveCreds("supergrok", e.supergrokCreds())
			_, err := e.respond(Request{Role: grokRole})
			se := mustErr(t, err)
			if se.Reason != tc.reason || se.Detail != tc.detail {
				t.Fatalf("err = %v", se)
			}
		})
	}
}

func TestSuperGrokBudgetMessage(t *testing.T) {
	f := newFake(t, httpFail(500, "e", "x"))
	e := newEnv(t, f)
	e.saveCreds("supergrok", e.supergrokCreds())
	_, err := e.respond(Request{Role: grokRole, Budget: time.Second})
	if se := mustErr(t, err); se.Detail != "SuperGrok response wait exceeded 30 minutes" || se.Reason != "unavailable" {
		t.Fatalf("err = %v", se)
	}
}

func TestSuperGrokRefusesCacheRefusalHandling(t *testing.T) {
	f := newFake(t, httpFail(400, "unknown_parameter", "x"))
	e := newEnv(t, f)
	e.saveCreds("supergrok", e.supergrokCreds())
	_, err := e.respond(Request{Role: grokRole})
	if mustErr(t, err).Reason != "refused" || len(f.requests()) != 1 {
		t.Fatal("SuperGrok must not run the ChatGPT cache fallback")
	}
}

func TestInvalidResponsesRetryOnceThenFail(t *testing.T) {
	bad := rawStream("data: not json\n\n")
	f := newFake(t, bad, bad, textAnswer("never"))
	e := newEnv(t, f)
	e.saveCreds("chatgpt", e.chatgptCreds())
	_, err := e.respond(Request{})
	se := mustErr(t, err)
	if se.Reason != "invalid_response" || se.Detail != "ChatGPT sent a response Kogen cannot read: an event is not JSON" || len(f.requests()) != 2 || len(e.clk.slept()) != 0 {
		t.Fatalf("err = %v after %d requests, slept %v", se, len(f.requests()), e.clk.slept())
	}
}

func TestRespondInterrupt(t *testing.T) {
	opened, closed := make(chan struct{}), make(chan struct{})
	f := newFake(t, openEvents(opened, closed, itemDone(0, tool())))
	e := newEnv(t, f).realClock()
	e.saveCreds("chatgpt", e.chatgptCreds())
	obs := &observer{}
	go func() {
		<-opened
		e.s.Interrupt("SIGINT")
	}()
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: fixtureRole, Instructions: "p"}, obs)
	var in *sys.Interrupted
	if ie, ok := err.(*sys.Interrupted); !ok || ie.ExitCode() != 130 {
		t.Fatalf("err = %v (%T)", err, err)
	} else {
		in = ie
	}
	_ = in
	select {
	case <-closed:
	case <-time.After(3 * time.Second):
		t.Fatal("the request was not cancelled")
	}
	recs := obs.records()
	if len(recs) != 1 || recs[0]["outcome"] != "cancelled" || recs[0]["error"] != "provider_failure" || recs[0]["usage_state"] != "unknown" {
		t.Fatalf("records = %v", recs)
	}
	// No attempt starts after an interrupt.
	f2 := newFake(t, textAnswer("x"))
	e2 := newEnv(t, f2)
	e2.saveCreds("chatgpt", e2.chatgptCreds())
	e2.s.Interrupt("SIGTERM")
	_, err = e2.respond(Request{})
	if ie, ok := err.(*sys.Interrupted); !ok || ie.ExitCode() != 143 || len(f2.requests()) != 0 {
		t.Fatalf("err = %v, %d requests", err, len(f2.requests()))
	}
}

func TestSecretsNeverAppearInErrorsOutputOrRecords(t *testing.T) {
	f := newFake(t, httpFail(400, "invalid_request_error", "bad"), jsonAnswer(401, map[string]any{}), jsonAnswer(401, map[string]any{}))
	e := newEnv(t, f)
	e.saveCreds("chatgpt", e.chatgptCreds())
	f.authSeq = []handler{jsonAnswer(200, map[string]any{"access_token": "rotated-secret-access", "refresh_token": "rotated-secret-refresh", "expires_in": int64(3600)})}
	obs := &observer{}
	var all strings.Builder
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: fixtureRole, Instructions: "p"}, obs)
	all.WriteString(err.Error() + sysRender(err))
	e.f.provNext = 1
	_, err = e.c.Respond(context.Background(), e.s, Request{Role: fixtureRole, Instructions: "p"}, obs)
	all.WriteString(err.Error() + sysRender(err))
	all.WriteString(e.out.String() + e.errs.String() + jsonOf(t, obs.records()))
	for _, secret := range []string{"fake-access-token", "fake-refresh-token", "rotated-secret-access", "rotated-secret-refresh"} {
		if strings.Contains(all.String(), secret) {
			t.Errorf("%s leaked", secret)
		}
	}
}

func sysRender(err error) string {
	if se, ok := sys.AsError(err); ok {
		return se.Render()
	}
	return ""
}

func TestBodyDoesNotSendToolsWhenThereAreNone(t *testing.T) {
	c := &Client{Cache: NewCache(nil)}
	b := c.Body(Request{Role: Role{Model: "gpt-5.4", Effort: "low"}, Instructions: "policy", Input: []any{map[string]any{"role": "user", "content": "x"}}})
	if _, has := b["tools"]; has {
		t.Fatal("tools sent")
	}
	if _, has := b["tool_choice"]; has {
		t.Fatal("tool_choice sent")
	}
	if b["instructions"] != "policy" || b["model"] != "gpt-5.4" {
		t.Fatalf("body = %v", b)
	}
	if _, has := b["prompt_cache_options"]; has {
		t.Fatal("old models omit cache controls")
	}
}

func TestRefusalNamesEditableRoleSelection(t *testing.T) {
	for _, tc := range []struct{ role, mapping string }{
		{"shape", "models.shape"},
		{"build", "models.build"},
		{"review", "models.review"},
		{"read", "shape_workers.read"},
		{"probe", "shape_workers.probe"},
		{"draft", "shape_workers.draft"},
	} {
		t.Run(tc.role, func(t *testing.T) {
			f := newFake(t, httpFail(400, "invalid_request_error", "model not found"), textAnswer("never"))
			e := newEnv(t, f)
			e.saveCreds("supergrok", e.supergrokCreds())
			_, err := e.respond(Request{
				Role:    Role{Provider: "supergrok", Model: "no-such-model", Effort: "high"},
				Context: map[string]any{"role": tc.role},
			})
			se := mustErr(t, err)
			if se.Detail != "SuperGrok refused the request: 400 model not found" || se.Exit != 4 {
				t.Fatal(se.Render())
			}
			for _, want := range []string{
				"selection experimental: role " + tc.role + ", provider supergrok, configured model no-such-model, effort high",
				".kogen/project.yaml " + tc.mapping + ".model / " + tc.mapping + ".effort",
			} {
				if !strings.Contains(se.Render(), want) {
					t.Errorf("missing %q in %s", want, se.Render())
				}
			}
			if len(f.requests()) != 1 || len(e.clk.slept()) != 0 {
				t.Fatalf("%d requests, slept %v", len(f.requests()), e.clk.slept())
			}
		})
	}
}

// KOGEN-066: a ChatGPT HTTP refusal's text shares the one-line, 300-byte bound of the other routes.
func TestChatGPTRefusalMessageIsBounded(t *testing.T) {
	long := "bad\nrequest\t" + strings.Repeat("é", 400)
	f := newFake(t, jsonAnswer(400, map[string]any{"error": map[string]any{"type": "invalid_request_error", "message": long}}), textAnswer("never"))
	e := newEnv(t, f)
	e.saveCreds("chatgpt", e.chatgptCreds())
	_, err := e.respond(Request{})
	se := mustErr(t, err)
	msg := strings.TrimPrefix(se.Detail, "ChatGPT refused the request: 400 ")
	if msg == se.Detail || strings.ContainsAny(msg, "\n\t") || !strings.HasPrefix(msg, "bad request é") || len(msg) > 300+len("…") || !strings.HasSuffix(msg, "…") {
		t.Fatalf("detail = %q", se.Detail)
	}
}

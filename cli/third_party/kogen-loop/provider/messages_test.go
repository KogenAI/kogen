package provider

import (
	"context"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"

	"kogen-loop/sys"
)

var claudeRole = Role{Provider: "anthropic", Model: "claude-opus-5-5", Effort: "high"}

func ev(typ string, kv ...any) map[string]any { return with(map[string]any{"type": typ}, kv...) }

func start(usage ...any) map[string]any {
	u := map[string]any{}
	for i := 0; i+1 < len(usage); i += 2 {
		u[usage[i].(string)] = usage[i+1]
	}
	return ev("message_start", "message", map[string]any{"id": "msg_fixture", "model": claudeRole.Model, "usage": u})
}

func block(i int, b map[string]any) []map[string]any {
	return []map[string]any{ev("content_block_start", "index", int64(i), "content_block", b), ev("content_block_stop", "index", int64(i))}
}

func finish(reason string) []map[string]any {
	return []map[string]any{ev("message_delta", "delta", map[string]any{"stop_reason": reason}, "usage", map[string]any{"output_tokens": int64(12)}), ev("message_stop")}
}

func use(id string) map[string]any {
	return map[string]any{"type": "tool_use", "id": id, "name": "read_file", "input": map[string]any{"path": "Δ"}}
}

func flat(parts ...[]map[string]any) []map[string]any {
	var out []map[string]any
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

func one(e map[string]any) []map[string]any { return []map[string]any{e} }

func claudeText(text string) handler {
	return sseAnswer(flat(one(start("input_tokens", int64(10), "cache_read_input_tokens", int64(0), "cache_creation_input_tokens", int64(0))), block(0, map[string]any{"type": "text", "text": text}), finish("end_turn"))...)
}

// ExUnit anthropic_test: ordered native replay retains opaque blocks once and groups parallel results.
func TestAnthropicReplayRetainsOpaqueBlocksOnceAndGroupsParallelResults(t *testing.T) {
	blocks := []map[string]any{
		{"type": "thinking", "thinking": "opaque", "signature": "signature"},
		{"type": "redacted_thinking", "data": "redacted"},
		{"type": "text", "text": "checking"},
		use("b"), use("a"),
	}
	var evs []map[string]any
	evs = append(evs, start("input_tokens", int64(100), "cache_read_input_tokens", int64(20), "cache_creation_input_tokens", int64(10)))
	for i, b := range blocks {
		evs = append(evs, block(i, b)...)
	}
	evs = append(evs, finish("tool_use")...)
	res := parseMessages(sse(evs...))
	if res.kind != resOK || res.usage != (Usage{Input: 130, Cached: 20, Output: 12}) || !reflect.DeepEqual(res.meta, map[string]any{"id": "msg_fixture", "model": claudeRole.Model, "anthropic_stop_reason": "tool_use", "anthropic_end_turn_tool_use": false}) ||
		*res.known.Write != 10 || res.known.Write30m != nil || res.known.Write12h != nil || res.known.Reasoning != nil || *res.known.Input != 130 {
		t.Fatalf("%+v", res)
	}
	input := []any{map[string]any{"role": "user", "content": "original"}}
	for _, it := range res.items {
		input = append(input, it)
	}
	for _, id := range []string{"b", "a"} {
		input = append(input, map[string]any{"type": "function_call_output", "call_id": id, "output": "result " + id})
	}
	input = append(input, map[string]any{"role": "user", "content": "next"})
	tool := map[string]any{"name": "read_file", "description": "Read", "parameters": map[string]any{"type": "object", "additionalProperties": false}}
	c := &Client{}
	body := c.Body(Request{Role: claudeRole, Instructions: "policy", Input: input, Tools: []any{tool}})
	if body["tool_choice"].(map[string]any)["type"] != "auto" || body["max_tokens"] != 128000 || !reflect.DeepEqual(body["thinking"], map[string]any{"type": "adaptive"}) ||
		!reflect.DeepEqual(body["output_config"], map[string]any{"effort": "high"}) {
		t.Fatalf("body = %s", jsonOf(t, body))
	}
	if _, has := body["input"]; has {
		t.Fatal("a Responses field")
	}
	if !reflect.DeepEqual(body["tools"].([]any)[0].(map[string]any)["input_schema"], tool["parameters"]) {
		t.Fatal("tool schema changed")
	}
	rawBlocks := make([]any, len(blocks))
	for i, b := range blocks {
		rawBlocks[i] = b
	}
	messages := body["messages"].([]any)
	if len(messages) != 4 || !reflect.DeepEqual(messages[0], map[string]any{"role": "user", "content": "original"}) ||
		!reflect.DeepEqual(messages[1], map[string]any{"role": "assistant", "content": rawBlocks}) {
		t.Fatalf("messages = %s", jsonOf(t, messages))
	}
	results := []any{
		map[string]any{"type": "tool_result", "tool_use_id": "b", "content": "result b"},
		map[string]any{"type": "tool_result", "tool_use_id": "a", "content": "result a"},
	}
	if !reflect.DeepEqual(messages[2], map[string]any{"role": "user", "content": results}) {
		t.Fatalf("results = %s", jsonOf(t, messages[2]))
	}
	// the newest message carries the rolling breakpoint, as one text block
	if !reflect.DeepEqual(messages[3], map[string]any{"role": "user", "content": []any{map[string]any{"type": "text", "text": "next", "cache_control": map[string]any{"type": "ephemeral"}}}}) {
		t.Fatalf("newest = %s", jsonOf(t, messages[3]))
	}
	// the caller's items were not modified by the marker
	if input[len(input)-1].(map[string]any)["content"] != "next" {
		t.Fatal("caller input modified")
	}
}

// ExUnit: fragments and cumulative usage merge without adding snapshots.
func TestAnthropicFragmentsAndCumulativeUsageMergeWithoutAddingSnapshots(t *testing.T) {
	evs := flat(
		one(start("input_tokens", int64(7), "cache_read_input_tokens", int64(2), "cache_creation_input_tokens", int64(3))),
		one(ev("content_block_start", "index", int64(0), "content_block", map[string]any{"type": "thinking", "thinking": ""})),
		one(ev("content_block_delta", "index", int64(0), "delta", map[string]any{"type": "thinking_delta", "thinking": "opaque"})),
		one(ev("content_block_delta", "index", int64(0), "delta", map[string]any{"type": "signature_delta", "signature": "sig"})),
		one(ev("content_block_stop", "index", int64(0))),
		one(ev("content_block_start", "index", int64(1), "content_block", with(use("a"), "input", map[string]any{}))),
		one(ev("content_block_delta", "index", int64(1), "delta", map[string]any{"type": "input_json_delta", "partial_json": `{"path":`})),
		one(ev("content_block_delta", "index", int64(1), "delta", map[string]any{"type": "input_json_delta", "partial_json": `"Δ"}`})),
		one(ev("content_block_stop", "index", int64(1))),
		one(ev("message_delta", "delta", map[string]any{}, "usage", map[string]any{"input_tokens": int64(9), "output_tokens": int64(3)})),
		one(ev("ping")), one(ev("future_information")),
		finish("tool_use"))
	res := parseMessages(sse(evs...))
	if res.kind != resOK || res.usage != (Usage{Input: 14, Cached: 2, Output: 12}) {
		t.Fatalf("%+v", res)
	}
	if got := res.items[len(res.items)-1]["arguments"]; got != `{"path":"Δ"}` {
		t.Fatalf("arguments = %v", got)
	}
	thinking := res.items[0]["anthropic_message"].(map[string]any)["content"].([]any)[0].(map[string]any)
	if thinking["signature"] != "sig" || thinking["thinking"] != "opaque" {
		t.Fatalf("thinking = %v", thinking)
	}
}

// ExUnit: complete validation precedes exposing any call.
func TestAnthropicCompleteValidationPrecedesExposingAnyCall(t *testing.T) {
	prefix := flat(one(start()), block(0, use("a")))
	with1 := func(b map[string]any) map[string]any { return b }
	for name, later := range map[string][]map[string]any{
		"duplicate id":     block(1, use("a")),
		"gap":              block(2, use("b")),
		"array input":      block(1, with1(with(use("b"), "input", []any{}))),
		"blank name":       block(1, with1(with(use("b"), "name", ""))),
		"server tool":      block(1, map[string]any{"type": "server_tool_use"}),
		"thinking w/o sig": block(1, map[string]any{"type": "thinking", "thinking": "t", "signature": ""}),
	} {
		for _, reason := range []string{"end_turn", "tool_use"} {
			if res := parseMessages(sse(flat(prefix, later, finish(reason))...)); res.kind != resInvalid || len(res.items) != 0 {
				t.Errorf("%s/%s: %+v", reason, name, res)
			}
		}
	}
	for _, reason := range []string{"max_tokens", "refusal", "pause_turn", "stop_sequence"} {
		if res := parseMessages(sse(flat(prefix, finish(reason))...)); res.kind != resInvalid {
			t.Errorf("%s: %+v", reason, res)
		}
		// a second, different stop reason cannot turn it into a success
		changed := flat(prefix, finish(reason)[:1], finish("tool_use"))
		if res := parseMessages(sse(changed...)); res.kind == resOK {
			t.Errorf("%s then tool_use accepted", reason)
		}
	}
	if res := parseMessages(sse(flat(prefix, finish("model_context_window_exceeded"))...)); res.kind != resRefused || res.reason != "context_too_long" {
		t.Errorf("context: %+v", res)
	}
	if res := parseMessages(sse(prefix...)); res.kind != resTransient || res.detail != "Anthropic cut stream" {
		t.Errorf("cut: %+v", res)
	}
	if res := parseMessages(sse(prefix...) + "data: {broken\n\n" + sse(finish("tool_use")...)); res.kind != resInvalid {
		t.Errorf("broken before stop: %+v", res)
	}
	if res := parseMessages(sse(prefix...) + "data: {broken"); res.kind != resTransient {
		t.Errorf("broken tail: %+v", res)
	}
	if res := parseMessages(sse(flat(one(start()), finish("end_turn"))...)); res.kind != resInvalid {
		t.Errorf("empty end_turn: %+v", res)
	}
	if res := parseMessages(sse(flat(one(start()), block(0, map[string]any{"type": "text", "text": "Answer"}), finish("end_turn"))...)); res.kind != resOK {
		t.Errorf("answer: %+v", res)
	}
	for _, typ := range []string{"content_block_start", "content_block_stop"} {
		var bad []map[string]any
		for _, e := range flat(prefix, finish("tool_use")) {
			if e["type"] == typ {
				e = with(e, "index", 0.0)
			}
			bad = append(bad, e)
		}
		if res := parseMessages(sse(bad...)); res.kind != resInvalid {
			t.Errorf("float index in %s: %+v", typ, res)
		}
	}
	// a stream error event, an event after the stop and a mismatched event name are unreadable
	if res := parseMessages(sse(flat(prefix, one(ev("error", "error", map[string]any{"type": "overloaded_error"})))...) + "\n"); res.kind != resTransient {
		t.Errorf("error event: %+v", res)
	}
	if res := parseMessages(sse(flat(prefix, finish("tool_use"), one(ev("content_block_start", "index", int64(1), "content_block", use("z"))))...)); res.kind != resInvalid {
		t.Errorf("event after stop: %+v", res)
	}
	if res := parseMessages(strings.Replace(sse(flat(one(start()), block(0, map[string]any{"type": "text", "text": "A"}), finish("end_turn"))...), "event: message_stop", "event: message_start", 1)); res.kind != resTransient {
		t.Errorf("mismatched name (the stop is unreadable, so the stream is cut): %+v", res)
	}
	// CRLF framing and comment-only frames are tolerated
	crlf := strings.ReplaceAll(sse(flat(one(start()), block(0, map[string]any{"type": "text", "text": "A"}), finish("end_turn"))...), "\n", "\r\n")
	if res := parseMessages(": keep-alive\r\n\r\n" + crlf); res.kind != resOK {
		t.Errorf("crlf: %+v", res)
	}
}

// ExUnit: partial and malformed counts remain unknown, never fabricated zeros.
func TestAnthropicPartialAndMalformedCountsRemainUnknown(t *testing.T) {
	if k, bad := anthropicUsage(map[string]any{}); bad || !reflect.DeepEqual(k, KnownUsage{}) {
		t.Fatalf("%+v", k)
	}
	fields := []string{"input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"}
	for _, field := range fields {
		for _, badValue := range []any{nil, int64(-1), "2", 1.5} {
			counts := map[string]any{"input_tokens": int64(7), "cache_read_input_tokens": int64(2), "cache_creation_input_tokens": int64(3), "output_tokens": int64(4)}
			counts[field] = badValue
			known, inconsistent := anthropicUsage(counts)
			if field != "output_tokens" && known.Input != nil || field == "output_tokens" && known.Output != nil || known.Reasoning != nil {
				t.Errorf("%s=%v: %+v", field, badValue, known)
			}
			if inconsistent != (badValue != nil) {
				t.Errorf("%s=%v inconsistent=%v", field, badValue, inconsistent)
			}
			u := map[string]any{"type": "message_start", "message": map[string]any{"id": "m", "usage": counts}}
			evs := flat(one(u), block(0, map[string]any{"type": "text", "text": "Answer"}),
				[]map[string]any{ev("message_delta", "delta", map[string]any{"stop_reason": "end_turn"}), ev("message_stop")})
			res := parseMessages(sse(evs...))
			if res.kind != resOK || (badValue != nil && res.state != UsageInconsistent) || (badValue != nil && res.usage != (Usage{})) {
				t.Errorf("%s=%v: %+v", field, badValue, res)
			}
		}
	}
}

// The wire: key header, version, cache breakpoints, the stream and what is recorded.
func TestAnthropicWireStreamAndRecord(t *testing.T) {
	evs := flat(
		one(start("input_tokens", int64(30), "cache_read_input_tokens", int64(60), "cache_creation_input_tokens", int64(10))),
		block(0, map[string]any{"type": "text", "text": "Answer"}), finish("end_turn"))
	e, f := keyEnv(t, "anthropic", sseAnswer(evs...))
	obs := &observer{}
	tools := []any{goTool("read_file"), goTool("write_file")}
	resp, err := e.c.Respond(context.Background(), e.s, Request{Role: claudeRole, Instructions: "policy Δ", Input: user("hello"), Tools: tools, Scope: "claude", Context: map[string]any{"phase": "shape"}}, obs)
	if err != nil {
		t.Fatal(err)
	}
	r := f.requests()[0]
	if r.Method != "POST" || r.Path != "/v1/messages" || r.Header.Get("X-Api-Key") != testKey || r.Header.Get("Anthropic-Version") != "2026-10-21" ||
		r.Header.Get("Content-Type") != "application/json" || r.Header.Get("Authorization") != "" || r.Header.Get("User-Agent") != "kogen/dev+12345678" {
		t.Fatalf("%s %s %v", r.Method, r.Path, r.Header)
	}
	for _, h := range []string{"Session-Id", "X-Opencode-Session", "Anthropic-Beta"} {
		if r.Header.Get(h) != "" {
			t.Errorf("%s sent", h)
		}
	}
	eph := map[string]any{"type": "ephemeral"}
	want := map[string]any{
		"model": "claude-opus-5-5", "stream": true, "max_tokens": int64(128000), "thinking": map[string]any{"type": "adaptive"},
		"output_config": map[string]any{"effort": "high"}, "tool_choice": map[string]any{"type": "auto"},
		"system": []any{map[string]any{"type": "text", "text": "policy Δ", "cache_control": eph}},
		"tools": []any{
			map[string]any{"name": "read_file", "description": "d", "input_schema": map[string]any{"type": "object"}},
			map[string]any{"name": "write_file", "description": "d", "input_schema": map[string]any{"type": "object"}, "cache_control": eph},
		},
		"messages": []any{map[string]any{"role": "user", "content": []any{map[string]any{"type": "text", "text": "hello", "cache_control": eph}}}},
	}
	if !reflect.DeepEqual(r.JSON, want) {
		t.Fatalf("body\n got %s\nwant %s", jsonOf(t, r.JSON), jsonOf(t, want))
	}
	if strings.Count(string(r.Body), "cache_control") != 3 {
		t.Fatalf("breakpoints: %d", strings.Count(string(r.Body), "cache_control"))
	}
	if resp.Usage != (Usage{Input: 100, Cached: 60, Output: 12}) || resp.UsageState != UsagePartial || *resp.Known.Write != 10 || resp.ID != "msg_fixture" || resp.Model != "claude-opus-5-5" {
		t.Fatalf("response = %+v / %+v", resp, resp.Known)
	}
	rec := obs.records()[0]
	cache := rec["cache"].(map[string]any)
	if rec["provider"] != "anthropic" || rec["provider_request_id"] != "req_anthropic_fixture" || rec["effective_effort"] != nil || rec["outcome"] != "completed" ||
		cache["configured_mode"] != "explicit" || cache["status"] != "applied" ||
		!reflect.DeepEqual(cache["boundaries"], []any{"tools[1]", "system[0]", "messages[0].content[0]"}) {
		t.Fatalf("record = %s", jsonOf(t, rec))
	}
	u := rec["usage"].(map[string]any)
	if u["input"] != 100 || u["cached"] != 60 || u["write"] != 10 || u["write_30m"] != nil || u["write_12h"] != nil || u["reasoning"] != nil || u["output"] != 12 {
		t.Fatalf("usage = %v", u)
	}
	if strings.Contains(jsonOf(t, rec), testKey) {
		t.Fatal("record leaks the key")
	}
	// without tools there is no tools breakpoint and no tool_choice; two blocks only
	e2, f2 := keyEnv(t, "anthropic", claudeText("ok"))
	if _, err := e2.c.Respond(context.Background(), e2.s, Request{Role: claudeRole, Instructions: "p", Input: user("hi")}, nil); err != nil {
		t.Fatal(err)
	}
	if b := f2.requests()[0]; strings.Count(string(b.Body), "cache_control") != 2 || b.JSON["tools"] != nil || b.JSON["tool_choice"] != nil {
		t.Fatalf("body = %s", b.Body)
	}
}

// Messages: the HTTP statuses of the specification.
func TestAnthropicErrorsAreClassifiedByStatusKeepingOnlyTheBoundedMessage(t *testing.T) {
	typed := func(status int, typ string) handler {
		return jsonAnswer(status, map[string]any{"error": map[string]any{"type": typ, "message": "SECRET_BODY_TEXT\n" + testKey}})
	}
	for _, c := range []struct {
		name   string
		h      handler
		reason string
		detail string
		diag   string
	}{
		{"404", typed(404, "not_found_error"), "model_unavailable", "Anthropic refused HTTP 404; no route or model fallback", `{"http_status":404,"type":"not_found_error"}`},
		{"413", typed(413, "request_too_large"), "context_too_long", "Anthropic refused HTTP 413; no route or model fallback", `{"http_status":413,"type":"request_too_large"}`},
		{"400", typed(400, "invalid_request_error"), "refused", "Anthropic refused HTTP 400; no route or model fallback", `{"http_status":400,"type":"invalid_request_error"}`},
		{"402", typed(402, "billing_error"), "refused", "Anthropic refused HTTP 402; no route or model fallback", `{"http_status":402,"type":"billing_error"}`},
		{"403", typed(403, "permission_error"), "refused", "Anthropic refused HTTP 403; no route or model fallback", `{"http_status":403,"type":"permission_error"}`},
		{"unknown type", typed(400, "SECRET_TYPE"), "refused", "Anthropic refused HTTP 400; no route or model fallback", `{"http_status":400}`},
		{"not json", rawAnswer(400, "SECRET_BODY_TEXT"), "refused", "Anthropic refused HTTP 400; no route or model fallback", `{"http_status":400}`},
		{"redirect", func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, "/elsewhere", 303) }, "refused", "Anthropic refused HTTP 303; no route or model fallback", `{"http_status":303}`},
	} {
		t.Run(c.name, func(t *testing.T) {
			e, f := keyEnv(t, "anthropic", c.h, claudeText("never"))
			obs := &observer{}
			_, err := e.c.Respond(context.Background(), e.s, Request{Role: claudeRole, Instructions: "p", Input: user("x")}, obs)
			se := mustErr(t, err)
			if se.Class != "provider" || se.Reason != c.reason || se.Detail != c.detail || se.Exit != 4 || len(f.requests()) != 1 || len(e.clk.slept()) != 0 {
				t.Fatalf("%v, %d requests", se, len(f.requests()))
			}
			// KOGEN-057: a refusal of the request (400, 404) or the model also names the fix.
			want := "provider failure: " + c.diag
			// KOGEN-066: a 4xx refusal keeps the provider's message, one line with the key redacted;
			// a body that is not JSON, or a redirect, has none.
			if c.name != "not json" && c.name != "redirect" {
				want += "|Anthropic said: SECRET_BODY_TEXT [redacted]"
			}
			if c.reason == "model_unavailable" || strings.Contains(c.diag, `"http_status":400`) {
				want += "|model claude-opus-5-5 with effort high was sent to Anthropic unchanged and not retried; if Anthropic does not offer them, set another model or effort for this role in .kogen/project.yaml"
			}
			want += "|selection experimental: role unknown, provider anthropic, configured model claude-opus-5-5, effort high; edit .kogen/project.yaml (role selection)"
			if strings.Join(se.Lines, "|") != want || strings.Contains(se.Render(), testKey) || ((c.name == "not json" || c.name == "redirect") && strings.Contains(se.Render(), "SECRET")) {
				t.Fatalf("lines = %v", se.Lines)
			}
			rec := obs.records()[0]
			if jsonOf(t, rec["provider_failure"]) != c.diag || rec["outcome"] != "failed" || strings.Contains(jsonOf(t, rec), "SECRET") {
				t.Fatalf("record = %s", jsonOf(t, rec))
			}
		})
	}
	e, f := keyEnv(t, "anthropic", typed(401, "authentication_error"), claudeText("never"))
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: claudeRole, Instructions: "p"}, nil)
	se := mustErr(t, err)
	if se.Reason != "login" || se.Detail != "the Anthropic sign-in was rejected; run kogen provider login anthropic" || len(f.requests()) != 1 ||
		strings.Join(se.Lines, "|") != `provider failure: {"http_status":401,"type":"authentication_error"}` {
		t.Fatalf("401: %v", se)
	}
	e2 := newEnv(t, nil)
	if _, err := e2.c.Respond(context.Background(), e2.s, Request{Role: claudeRole, Instructions: "p"}, nil); mustErr(t, err).Detail != "no usable Anthropic key; run kogen provider login anthropic" {
		t.Fatal(err)
	}
}

// KOGEN-066: a 400 refusal shows the provider's message, bounded and without the key or the request.
func TestAnthropicRefusalShowsBoundedProviderMessage(t *testing.T) {
	long := "messages: tool_use ids were found without tool_result blocks " + testKey + "\n\t" + strings.Repeat("é", 400)
	e, f := keyEnv(t, "anthropic", jsonAnswer(400, map[string]any{"error": map[string]any{"type": "invalid_request_error", "message": long}}))
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: claudeRole, Instructions: "p", Input: user("PRIVATE_REQUEST_PAYLOAD")}, nil)
	se := mustErr(t, err)
	said := ""
	for _, l := range se.Lines {
		if strings.HasPrefix(l, "Anthropic said: ") {
			said = strings.TrimPrefix(l, "Anthropic said: ")
		}
	}
	if said == "" || strings.ContainsAny(said, "\n\t") || len(said) > 300+len("…") || !strings.HasPrefix(said, "messages: tool_use ids were found without tool_result blocks [redacted] é") || !strings.HasSuffix(said, "…") {
		t.Fatalf("said = %q", said)
	}
	if r := se.Render(); strings.Contains(r, testKey) || strings.Contains(r, "PRIVATE_REQUEST_PAYLOAD") || !strings.Contains(r, `"type":"invalid_request_error"`) || len(f.requests()) != 1 {
		t.Fatalf("render = %s", r)
	}
}

func TestAnthropicTransientFailuresRetryAndExhaust(t *testing.T) {
	cut := sseAnswer(flat(one(start()), block(0, use("a")))...)
	for name, tc := range map[string][]handler{
		"cut stream": {cut, cut, claudeText("recovered")}, "429 and 529": {jsonAnswer(429, map[string]any{}), jsonAnswer(529, map[string]any{"error": map[string]any{"type": "overloaded_error"}}), claudeText("recovered")},
		"5xx": {jsonAnswer(500, map[string]any{}), jsonAnswer(503, map[string]any{}), claudeText("recovered")},
	} {
		e, f := keyEnv(t, "anthropic", tc...)
		resp, err := e.c.Respond(context.Background(), e.s, Request{Role: claudeRole, Instructions: "p", Input: user("x")}, nil)
		if err != nil || len(f.requests()) != 3 || !reflect.DeepEqual(e.clk.slept(), []time.Duration{2 * time.Second, 8 * time.Second}) {
			t.Fatalf("%s: %v, %d requests, slept %v", name, err, len(f.requests()), e.clk.slept())
		}
		reqs := f.requests()
		if string(reqs[0].Body) != string(reqs[2].Body) || resp.Items[0]["content"].([]any)[0].(map[string]any)["text"] != "recovered" {
			t.Fatalf("%s: the retried request changed", name)
		}
	}
	e, f := keyEnv(t, "anthropic", cut, cut, cut)
	obs := &observer{}
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: claudeRole, Instructions: "p"}, obs)
	if se := mustErr(t, err); se.Reason != "unavailable" || se.Detail != "Anthropic did not answer after 3 attempts: Anthropic cut stream" || len(f.requests()) != 3 {
		t.Fatalf("%v", se)
	}
	if recs := obs.records(); len(recs) != 3 || recs[0]["usage_state"] != "unknown" || recs[0]["outcome"] != "failed" {
		t.Fatal("failed attempts keep unknown usage")
	}
	e, f = keyEnv(t, "anthropic", jsonAnswer(529, map[string]any{"error": map[string]any{"type": "overloaded_error"}}), jsonAnswer(529, map[string]any{"error": map[string]any{"type": "overloaded_error"}}), jsonAnswer(529, map[string]any{"error": map[string]any{"type": "overloaded_error"}}))
	_, err = e.c.Respond(context.Background(), e.s, Request{Role: claudeRole, Instructions: "p"}, nil)
	if se := mustErr(t, err); se.Detail != "Anthropic did not answer after 3 attempts: Anthropic temporary HTTP 529" || strings.Join(se.Lines, "|") != `provider failure: {"http_status":529,"type":"overloaded_error"}` {
		t.Fatalf("%v", se)
	}
}

// Malformed complete output is never retried; an exhausted context window is a definite refusal.
func TestAnthropicUnreadableAnswersAreNotRetried(t *testing.T) {
	maxTokens := sseAnswer(flat(one(start()), block(0, map[string]any{"type": "text", "text": "partial"}), finish("max_tokens"))...)
	e, f := keyEnv(t, "anthropic", maxTokens, claudeText("never"))
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: claudeRole, Instructions: "p"}, nil)
	if se := mustErr(t, err); se.Reason != "invalid_response" || se.Detail != "malformed Anthropic completion" || len(f.requests()) != 1 {
		t.Fatalf("%v", se)
	}
	window := sseAnswer(flat(one(start()), finish("model_context_window_exceeded"))...)
	e, f = keyEnv(t, "anthropic", window, claudeText("never"))
	obs := &observer{}
	_, err = e.c.Respond(context.Background(), e.s, Request{Role: claudeRole, Instructions: "p"}, obs)
	if se := mustErr(t, err); se.Reason != "context_too_long" || se.Detail != "Anthropic refused HTTP 200; no route or model fallback" || len(f.requests()) != 1 {
		t.Fatalf("%v", se)
	}
	if obs.records()[0]["outcome"] != "failed" {
		t.Fatal("a refused window is not a completed attempt")
	}
}

func TestAnthropicRefusesImagesBeforeAnyRequest(t *testing.T) {
	e, f := keyEnv(t, "anthropic", claudeText("never"))
	input := []any{map[string]any{"type": "function_call_output", "call_id": "c", "output": []any{map[string]any{"type": "input_image", "image_url": "pixels"}}}}
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: claudeRole, Instructions: "p", Input: input}, nil)
	if se := mustErr(t, err); se.Reason != "unsupported_capability" || se.Exit != 4 || se.Detail != "Anthropic images are unsupported; use external image preparation and pixel-review handoff" || len(f.requests()) != 0 {
		t.Fatalf("%v", se)
	}
}

// ExUnit integration anthropic_test: identifiers cannot echo the key; waits close the socket.
func TestAnthropicOpaqueIdentifiersCannotEchoTheKeyAndWaitsEndTheRequest(t *testing.T) {
	// request id and message id equal to the key: nothing is retained
	echo := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Request-Id", testKey)
		m := ev("message_start", "message", map[string]any{"id": testKey, "model": testKey})
		io.WriteString(w, sse(flat(one(m), block(0, map[string]any{"type": "text", "text": "Answer"}), []map[string]any{ev("message_delta", "delta", map[string]any{"stop_reason": "end_turn"}), ev("message_stop")})...))
	}
	e, _ := keyEnv(t, "anthropic", echo)
	obs := &observer{}
	resp, err := e.c.Respond(context.Background(), e.s, Request{Role: claudeRole, Instructions: "p"}, obs)
	if err != nil || resp.ID != "" || resp.Model != "" || strings.Contains(jsonOf(t, obs.records()), testKey) || obs.records()[0]["provider_request_id"] != nil {
		t.Fatalf("%v %+v", err, resp)
	}
	// an error body whose type is the key
	e, _ = keyEnv(t, "anthropic", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Request-Id", testKey)
		w.WriteHeader(400)
		io.WriteString(w, `{"error":{"type":"`+testKey+`","message":"`+testKey+`"}}`)
	})
	obs = &observer{}
	_, err = e.c.Respond(context.Background(), e.s, Request{Role: claudeRole, Instructions: "p"}, obs)
	if se := mustErr(t, err); strings.Contains(se.Render(), testKey) || strings.Contains(jsonOf(t, obs.records()), testKey) {
		t.Fatalf("%v", se)
	}
	// a held stream ends with the budget, closing the socket
	opened, closed := make(chan struct{}), make(chan struct{})
	e, _ = keyEnv(t, "anthropic", openEvents(opened, closed, ev("message_start", "message", map[string]any{"id": "m"})))
	e.realClock()
	start := time.Now()
	_, err = e.c.Respond(context.Background(), e.s, Request{Role: claudeRole, Instructions: "p", Budget: 150 * time.Millisecond}, nil)
	if se := mustErr(t, err); se.Detail != "Anthropic response wait exceeded 30 minutes" || time.Since(start) > 2*time.Second {
		t.Fatalf("%v after %v", err, time.Since(start))
	}
	select {
	case <-closed:
	case <-time.After(2 * time.Second):
		t.Fatal("the socket stayed open")
	}
}

func TestKeyProviderInterruptEndsTheRequest(t *testing.T) {
	for _, name := range []string{"anthropic", "opencode-go"} {
		opened, closed := make(chan struct{}), make(chan struct{})
		h := openEvents(opened, closed, ev("message_start", "message", map[string]any{"id": "m"}))
		role := claudeRole
		if name == "opencode-go" {
			role = goRole
			h = func(w http.ResponseWriter, r *http.Request) {
				close(opened)
				select {
				case <-r.Context().Done():
				case <-time.After(5 * time.Second):
				}
				close(closed)
			}
		}
		e, _ := keyEnv(t, name, h)
		obs := &observer{}
		done := make(chan error, 1)
		go func() {
			_, err := e.c.Respond(context.Background(), e.s, Request{Role: role, Instructions: "p"}, obs)
			done <- err
		}()
		<-opened
		e.s.Interrupt("SIGTERM")
		select {
		case err := <-done:
			if in, ok := err.(*sys.Interrupted); !ok || in.Signal != "SIGTERM" {
				t.Fatalf("%s: %v", name, err)
			}
		case <-time.After(3 * time.Second):
			t.Fatalf("%s: interrupt ignored", name)
		}
		select {
		case <-closed:
		case <-time.After(2 * time.Second):
			t.Fatalf("%s: socket stayed open", name)
		}
		if recs := obs.records(); len(recs) != 1 || recs[0]["outcome"] != "cancelled" || recs[0]["usage_state"] != "unknown" {
			t.Fatalf("%s: records %v", name, recs)
		}
	}
}

func TestAnthropicCompleteToolBatches(t *testing.T) {
	for _, reason := range []string{"end_turn", "tool_use"} {
		for _, count := range []int{1, 2} {
			events := one(start())
			for i := 0; i < count; i++ {
				events = append(events, block(i, use(string(rune('a'+i))))...)
			}
			res := parseMessages(sse(flat(events, finish(reason))...))
			if res.kind != resOK || len(res.items) != count+1 || res.meta["anthropic_stop_reason"] != reason || res.meta["anthropic_end_turn_tool_use"] != (reason == "end_turn") {
				t.Fatalf("%s/%d: %+v", reason, count, res)
			}
		}
	}
}

func TestAnthropicSyntheticEndTurnDeltas(t *testing.T) {
	for _, reason := range []string{"end_turn", "tool_use"} {
		m := start("input_tokens", int64(12), "cache_read_input_tokens", int64(48000), "cache_creation_input_tokens", int64(300))
		m["message"].(map[string]any)["id"] = "msg_synthetic_01"
		m["message"].(map[string]any)["model"] = "claude-sonnet-5-5"
		events := flat(one(m),
			one(ev("content_block_start", "index", int64(0), "content_block", map[string]any{"type": "thinking", "thinking": ""})),
			one(ev("content_block_delta", "index", int64(0), "delta", map[string]any{"type": "thinking_delta", "thinking": "opaque"})),
			one(ev("content_block_delta", "index", int64(0), "delta", map[string]any{"type": "signature_delta", "signature": "opaque-signature"})),
			one(ev("content_block_stop", "index", int64(0))),
			one(ev("content_block_start", "index", int64(1), "content_block", with(use("toolu_synthetic_01"), "input", map[string]any{}))),
			one(ev("content_block_delta", "index", int64(1), "delta", map[string]any{"type": "input_json_delta", "partial_json": `{"path":`})),
			one(ev("content_block_delta", "index", int64(1), "delta", map[string]any{"type": "input_json_delta", "partial_json": `"lib/helper.go"}`})),
			one(ev("content_block_stop", "index", int64(1))),
			one(ev("message_delta", "delta", map[string]any{"stop_reason": reason}, "usage", map[string]any{"output_tokens": int64(812)})), one(ev("message_stop")))
		res := parseMessages(sse(events...))
		if res.kind != resOK || len(res.items) != 2 || res.items[1]["arguments"] != `{"path":"lib/helper.go"}` || res.items[1]["call_id"] != "toolu_synthetic_01" || res.usage != (Usage{Input: 48312, Cached: 48000, Output: 812}) {
			t.Fatalf("%s: %+v", reason, res)
		}
	}
}

func TestAnthropicAttemptTerminalMetadata(t *testing.T) {
	for _, tc := range []struct {
		name, reason string
		blocks       []map[string]any
		ok, marker   bool
	}{
		{"end tools", "end_turn", []map[string]any{use("a")}, true, true},
		{"ordinary tools", "tool_use", []map[string]any{use("a")}, true, false},
		{"text", "end_turn", []map[string]any{{"type": "text", "text": "private-response-text"}}, true, false},
		{"invalid later", "end_turn", []map[string]any{use("a"), with(use("b"), "input", []any{})}, false, false},
		{"disallowed", "max_tokens", []map[string]any{use("a")}, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := start()
			m["message"].(map[string]any)["model"] = testKey
			events := one(m)
			for i, b := range tc.blocks {
				events = append(events, block(i, b)...)
			}
			e, _ := keyEnv(t, "anthropic", sseAnswer(flat(events, finish(tc.reason))...))
			obs := &observer{}
			resp, err := e.c.Respond(context.Background(), e.s, Request{Role: claudeRole, Input: user("hi")}, obs)
			if (err == nil) != tc.ok {
				t.Fatalf("response=%+v err=%v", resp, err)
			}
			rec := obs.records()[0]
			var stop any
			if tc.ok {
				stop = tc.reason
			}
			if rec["anthropic_stop_reason"] != stop || rec["anthropic_end_turn_tool_use"] != tc.marker || rec["effective_model"] != nil {
				t.Fatalf("record = %s", jsonOf(t, rec))
			}
			for _, secret := range []string{testKey, "private-response-text", "lib/helper.go"} {
				if strings.Contains(jsonOf(t, rec), secret) {
					t.Fatalf("record leaks %s", secret)
				}
			}
		})
	}
}

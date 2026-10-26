package provider

import (
	"context"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"kogen-loop/sys"
)

var goRole = Role{Provider: "opencode-go", Model: "kimi-k3", Effort: "high"}

func goCall(id string) map[string]any {
	return map[string]any{"id": id, "type": "function", "function": map[string]any{"name": "read_file", "arguments": `{"path":"Δ"}`}}
}

func goAnswer(raw map[string]any, finish string, extra ...any) map[string]any {
	return with(map[string]any{"id": "chatcmpl-fixture", "model": "kimi-k3", "choices": []any{map[string]any{"message": raw, "finish_reason": finish}}}, extra...)
}

func goText(text string) map[string]any {
	return goAnswer(map[string]any{"role": "assistant", "content": text}, "stop")
}

func user(text string) []any {
	return []any{map[string]any{"role": "user", "content": []any{map[string]any{"type": "input_text", "text": text}}}}
}

func goTool(name string) map[string]any {
	return map[string]any{"type": "function", "name": name, "description": "d", "parameters": map[string]any{"type": "object"}}
}

// ExUnit open_code_go_transport/login/transport: the fixed route, Kogen's own identity, the
// session header and the rendered body.
func TestOpenCodeGoWireRecordAndUsage(t *testing.T) {
	raw := map[string]any{"role": "assistant", "content": "checking", "reasoning": "private scalar",
		"reasoning_details": []any{map[string]any{"type": "reasoning.text", "index": int64(0), "text": "r"}}, "tool_calls": []any{goCall("b"), goCall("a")}}
	answer := goAnswer(raw, "tool_calls", "usage", map[string]any{"prompt_tokens": int64(100), "completion_tokens": int64(20),
		"prompt_tokens_details": map[string]any{"cached_tokens": int64(60)}, "completion_tokens_details": map[string]any{"reasoning_tokens": int64(7)}})
	e, f := keyEnv(t, "opencode-go", jsonAnswer(200, answer))
	obs := &observer{}
	resp, err := e.c.Respond(context.Background(), e.s, Request{Role: goRole, Instructions: "policy", Input: user("original Δ\n"),
		Tools: []any{goTool("read_file")}, Scope: "go", Context: map[string]any{"phase": "build"}}, obs)
	if err != nil {
		t.Fatal(err)
	}
	reqs := f.requests()
	if len(reqs) != 1 {
		t.Fatal(len(reqs))
	}
	r := reqs[0]
	if r.Method != "POST" || r.Path != "/inference/go/openai/v1/chat/completions" {
		t.Fatalf("%s %s", r.Method, r.Path)
	}
	session := r.Header.Get("X-Opencode-Session")
	if r.Header.Get("Authorization") != "Bearer "+testKey || r.Header.Get("User-Agent") != "kogen/dev+12345678" ||
		r.Header.Get("Content-Type") != "application/json" || session == "" || len(session) > MaxCacheID {
		t.Fatalf("headers = %v", r.Header)
	}
	for _, h := range []string{"Session-Id", "X-Grok-Conv-Id", "Anthropic-Version", "X-Api-Key"} {
		if r.Header.Get(h) != "" {
			t.Errorf("%s sent", h)
		}
	}
	want := map[string]any{
		"model": "kimi-k3", "stream": false, "store": false, "reasoning_effort": "high", "tool_choice": "auto",
		"messages": []any{
			map[string]any{"role": "system", "content": "policy"},
			map[string]any{"role": "user", "content": []any{map[string]any{"type": "text", "text": "original Δ\n"}}},
		},
		"tools": []any{map[string]any{"type": "function", "function": map[string]any{"name": "read_file", "description": "d", "parameters": map[string]any{"type": "object"}}}},
	}
	if !reflect.DeepEqual(r.JSON, want) {
		t.Fatalf("body\n got %s\nwant %s", jsonOf(t, r.JSON), jsonOf(t, want))
	}
	if !reflect.DeepEqual(resp.Items[0]["opencode_go_message"], raw) || resp.Items[0]["type"] != "message" ||
		resp.Items[1]["call_id"] != "b" || resp.Items[2]["call_id"] != "a" || resp.Items[1]["arguments"] != `{"path":"Δ"}` {
		t.Fatalf("items = %v", resp.Items)
	}
	if resp.Usage != (Usage{Input: 100, Cached: 60, Output: 20, Reasoning: 7}) || resp.UsageState != UsagePartial || resp.ID != "chatcmpl-fixture" || resp.Model != "kimi-k3" || resp.Effort != "" {
		t.Fatalf("response = %+v", resp)
	}
	rec := obs.records()[0]
	for k, v := range map[string]any{"provider": "opencode-go", "configured_model": "kimi-k3", "configured_effort": "high", "effective_effort": nil,
		"provider_request_id": "req-fixture", "provider_response_id": "chatcmpl-fixture", "outcome": "completed", "conversation_id": session, "phase": "build"} {
		if !reflect.DeepEqual(rec[k], v) {
			t.Errorf("record[%s] = %v, want %v", k, rec[k], v)
		}
	}
	u := rec["usage"].(map[string]any)
	if u["input"] != 100 || u["cached"] != 60 || u["write"] != nil || u["write_30m"] != nil || u["reasoning"] != 7 {
		t.Fatalf("usage = %v", u)
	}
	// Shared analytical evidence never carries the key, the policy text or the reasoning.
	for _, secret := range []string{testKey, "private scalar", "checking"} {
		if strings.Contains(jsonOf(t, rec), secret) {
			t.Errorf("record leaks %q", secret)
		}
	}
	// default effort omits reasoning_effort; the string "default" is never sent.
	e2, f2 := keyEnv(t, "opencode-go", jsonAnswer(200, goText("done")))
	if _, err := e2.c.Respond(context.Background(), e2.s, Request{Role: Role{Provider: "opencode-go", Model: "kimi-k3", Effort: "default"}, Instructions: "p", Input: user("x")}, nil); err != nil {
		t.Fatal(err)
	}
	b := f2.requests()[0].JSON
	if _, has := b["reasoning_effort"]; has || strings.Contains(string(f2.requests()[0].Body), `"default"`) {
		t.Fatalf("body = %s", f2.requests()[0].Body)
	}
	if _, has := b["tools"]; has || b["tool_choice"] != nil {
		t.Fatal("tools without tools")
	}
}

// ExUnit: lossless ordered raw replay suppresses duplicate text and all normalized calls.
func TestOpenCodeGoRawReplayIsLosslessAndOrdered(t *testing.T) {
	raw := map[string]any{"role": "assistant", "content": "unchanged Δ", "reasoning": "private scalar",
		"reasoning_details": []any{map[string]any{"type": "reasoning.text", "index": int64(0), "vendor": []any{int64(2), int64(1)}}},
		"tool_calls":        []any{goCall("b"), goCall("a")}}
	res := adaptChat(goInfo(), goAnswer(raw, "tool_calls"))
	if res.kind != resOK || res.state != UsageUnknown || res.usage != (Usage{}) {
		t.Fatalf("%+v", res)
	}
	input := user("original Δ\n")
	for _, it := range res.items {
		// what Shape.replay_item keeps: the item as received
		input = append(input, it)
	}
	for _, id := range []string{"b", "a"} {
		input = append(input, map[string]any{"type": "function_call_output", "call_id": id, "output": "output " + id})
	}
	c := &Client{}
	body := c.Body(Request{Role: goRole, Instructions: "policy", Input: input})
	want := []any{
		map[string]any{"role": "system", "content": "policy"},
		map[string]any{"role": "user", "content": []any{map[string]any{"type": "text", "text": "original Δ\n"}}},
		raw,
		map[string]any{"role": "tool", "tool_call_id": "b", "content": "output b"},
		map[string]any{"role": "tool", "tool_call_id": "a", "content": "output a"},
	}
	if !reflect.DeepEqual(body["messages"], want) {
		t.Fatalf("messages\n got %s\nwant %s", jsonOf(t, body["messages"]), jsonOf(t, want))
	}
}

func TestOpenCodeGoMalformedAnswersReturnNoExecutableItems(t *testing.T) {
	raw := map[string]any{"role": "assistant", "content": nil, "tool_calls": []any{goCall("a"), goCall("b")}}
	badArgs := goCall("b")
	badArgs["function"] = map[string]any{"name": "read_file", "arguments": "[]"}
	noContent := with(raw)
	delete(noContent, "content")
	for name, answer := range map[string]map[string]any{
		"bad arguments":   goAnswer(with(raw, "tool_calls", []any{goCall("a"), badArgs}), "tool_calls"),
		"refusal":         goAnswer(with(raw, "refusal", "refused"), "tool_calls"),
		"false calls":     goAnswer(map[string]any{"role": "assistant", "content": "text", "tool_calls": false}, "stop"),
		"empty calls":     goAnswer(map[string]any{"role": "assistant", "content": "text", "tool_calls": []any{}}, "tool_calls"),
		"no content":      goAnswer(noContent, "tool_calls"),
		"length":          goAnswer(raw, "length"),
		"explicit error":  goAnswer(raw, "tool_calls", "error", map[string]any{"code": "failure"}),
		"no choices":      {"choices": []any{}},
		"duplicate ids":   goAnswer(with(raw, "tool_calls", []any{goCall("a"), goCall("a")}), "tool_calls"),
		"empty text only": goAnswer(map[string]any{"role": "assistant", "content": ""}, "stop"),
		"null text only":  goAnswer(map[string]any{"role": "assistant", "content": nil}, "stop"),
		"non-text":        goAnswer(map[string]any{"role": "assistant", "content": []any{}}, "stop"),
		"wrong role":      goAnswer(map[string]any{"role": "user", "content": "x"}, "stop"),
		"blank id":        goAnswer(with(raw, "tool_calls", []any{goCall("")}), "tool_calls"),
		"control name":    goAnswer(with(raw, "tool_calls", []any{map[string]any{"id": "a", "type": "function", "function": map[string]any{"name": "a\tb", "arguments": "{}"}}}), "tool_calls"),
		"bad usage":       goAnswer(raw, "tool_calls", "usage", []any{}),
	} {
		if res := adaptChat(goInfo(), answer); res.kind != resInvalid {
			t.Errorf("%s: %+v", name, res)
		}
	}
	// Text with finish tool_calls but no calls, and calls with finish stop, follow the rules.
	if res := adaptChat(goInfo(), goAnswer(map[string]any{"role": "assistant", "content": "x", "tool_calls": []any{goCall("a")}}, "stop")); res.kind != resOK || len(res.items) != 2 {
		t.Fatalf("stop with calls: %+v", res)
	}
	// Through Respond an unreadable answer is never retried and says which provider.
	e, f := keyEnv(t, "opencode-go", jsonAnswer(200, goAnswer(raw, "length")), jsonAnswer(200, goText("never")))
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: goRole, Instructions: "p", Input: user("x")}, nil)
	if se := mustErr(t, err); se.Reason != "invalid_response" || se.Detail != "malformed OpenCode Go completion" || se.Exit != 4 || len(f.requests()) != 1 {
		t.Fatalf("%v, %d requests", se, len(f.requests()))
	}
	// A body that is not a JSON object is the same unreadable answer.
	e, _ = keyEnv(t, "opencode-go", rawAnswer(200, "[1,2]"))
	if _, err := e.c.Respond(context.Background(), e.s, Request{Role: goRole, Instructions: "p"}, nil); mustErr(t, err).Detail != "malformed OpenCode Go completion" {
		t.Fatal(err)
	}
}

// The raw provider fields of cached input are kept: chat-compatible routes name them in
// three ways, the first one reported counts; unknown counts stay null, never zero.
func TestOpenCodeGoUsageNormalization(t *testing.T) {
	text := map[string]any{"role": "assistant", "content": "ok"}
	n := func(v int) *int { return &v }
	for name, tc := range map[string]struct {
		usage any
		known KnownUsage
		state string
	}{
		"none":              {nil, KnownUsage{}, UsageUnknown},
		"details":           {map[string]any{"prompt_tokens": int64(10), "completion_tokens": int64(2), "prompt_tokens_details": map[string]any{"cached_tokens": int64(4)}, "completion_tokens_details": map[string]any{"reasoning_tokens": int64(1)}}, KnownUsage{Input: n(10), Cached: n(4), Output: n(2), Reasoning: n(1)}, UsagePartial},
		"deepseek hit":      {map[string]any{"prompt_tokens": int64(10), "completion_tokens": int64(2), "prompt_cache_hit_tokens": int64(7)}, KnownUsage{Input: n(10), Cached: n(7), Output: n(2)}, UsagePartial},
		"top level":         {map[string]any{"prompt_tokens": int64(10), "cached_tokens": int64(9)}, KnownUsage{Input: n(10), Cached: n(9)}, UsagePartial},
		"details win":       {map[string]any{"prompt_tokens": int64(10), "prompt_tokens_details": map[string]any{"cached_tokens": int64(3)}, "prompt_cache_hit_tokens": int64(7), "cached_tokens": int64(9)}, KnownUsage{Input: n(10), Cached: n(3)}, UsagePartial},
		"invalid skipped":   {map[string]any{"prompt_tokens": int64(10), "prompt_tokens_details": map[string]any{"cached_tokens": int64(-1)}, "prompt_cache_hit_tokens": int64(7)}, KnownUsage{Input: n(10), Cached: n(7)}, UsagePartial},
		"cached over input": {map[string]any{"prompt_tokens": int64(5), "prompt_cache_hit_tokens": int64(7)}, KnownUsage{Input: n(5), Cached: n(7)}, UsageInconsistent},
		"floats unknown":    {map[string]any{"prompt_tokens": 1.5, "completion_tokens": "3"}, KnownUsage{}, UsageUnknown},
	} {
		answer := goAnswer(text, "stop")
		if tc.usage != nil {
			answer["usage"] = tc.usage
		}
		res := adaptChat(goInfo(), answer)
		if res.kind != resOK || !reflect.DeepEqual(res.known, tc.known) || res.state != tc.state {
			t.Errorf("%s: %+v / %+v", name, res.known, res.state)
		}
	}
}

func TestOpenCodeGoErrorsAreClassifiedWithoutFallbackOrBodyText(t *testing.T) {
	cases := []struct {
		name         string
		h            handler
		reason, text string
		diag         string
	}{
		{"402", jsonAnswer(402, map[string]any{"error": map[string]any{"code": "billing", "type": "payment_required", "message": "SECRET_BODY_TEXT"}}), "refused", "OpenCode Go refused HTTP 402; no route or model fallback", `{"code":"billing","http_status":402,"type":"payment_required"}`},
		{"403", jsonAnswer(403, map[string]any{"error": map[string]any{"message": "SECRET_BODY_TEXT"}}), "refused", "OpenCode Go refused HTTP 403; no route or model fallback", `{"http_status":403}`},
		{"400 model", jsonAnswer(400, map[string]any{"error": map[string]any{"code": "model_not_found", "message": "SECRET_BODY_TEXT"}}), "model_unavailable", "OpenCode Go refused HTTP 400; no route or model fallback", `{"code":"model_not_found","http_status":400}`},
		{"404", rawAnswer(404, "not json SECRET_BODY_TEXT"), "refused", "OpenCode Go refused HTTP 404; no route or model fallback", `{"http_status":404}`},
		{"unsafe code", jsonAnswer(400, map[string]any{"error": map[string]any{"code": "has space", "type": strings.Repeat("x", 129)}}), "refused", "OpenCode Go refused HTTP 400; no route or model fallback", `{"http_status":400}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e, f := keyEnv(t, "opencode-go", c.h, jsonAnswer(200, goText("never")))
			obs := &observer{}
			_, err := e.c.Respond(context.Background(), e.s, Request{Role: goRole, Instructions: "p", Input: user("x")}, obs)
			se := mustErr(t, err)
			if se.Class != "provider" || se.Reason != c.reason || se.Detail != c.text || se.Exit != 4 || len(f.requests()) != 1 || len(e.clk.slept()) != 0 {
				t.Fatalf("%v, %d requests", se, len(f.requests()))
			}
			// KOGEN-057: a refusal of the request (400, 404) or the model also names the fix.
			want := "provider failure: " + c.diag
			if c.reason == "model_unavailable" || c.name == "404" || c.name == "unsafe code" {
				want += "|model kimi-k3 with effort high was sent to OpenCode Go unchanged and not retried; if OpenCode Go does not offer them, set another model or effort for this role in .kogen/project.yaml"
			}
			want += "|selection experimental: role unknown, provider opencode-go, configured model kimi-k3, effort high; edit .kogen/project.yaml (role selection)"
			if strings.Join(se.Lines, "|") != want || strings.Contains(se.Render(), "SECRET_BODY_TEXT") {
				t.Fatalf("lines = %v", se.Lines)
			}
			rec := obs.records()[0]
			if rec["outcome"] != "failed" || rec["usage_state"] != "unknown" || jsonOf(t, rec["provider_failure"]) != c.diag {
				t.Fatalf("record = %s", jsonOf(t, rec))
			}
		})
	}
}

func TestOpenCodeGoRejectedKeyIsNotRefreshedOrRetried(t *testing.T) {
	e, f := keyEnv(t, "opencode-go", jsonAnswer(401, map[string]any{"error": map[string]any{"code": "invalid_key", "type": "auth_error", "message": "SECRET"}}), jsonAnswer(200, goText("never")))
	obs := &observer{}
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: goRole, Instructions: "p"}, obs)
	se := mustErr(t, err)
	if se.Reason != "login" || se.Detail != "the OpenCode Go sign-in was rejected; run kogen provider login opencode-go" || se.Exit != 4 || len(f.requests()) != 1 {
		t.Fatalf("%v", se)
	}
	if strings.Join(se.Lines, "|") != `provider failure: {"code":"invalid_key","http_status":401,"type":"auth_error"}` {
		t.Fatalf("lines = %v", se.Lines)
	}
	if jsonOf(t, obs.records()[0]["provider_failure"]) != `{"code":"invalid_key","http_status":401,"type":"auth_error"}` {
		t.Fatalf("%v", obs.records()[0])
	}
	// no key at all: refused before any request
	e2 := newEnv(t, nil)
	_, err = e2.c.Respond(context.Background(), e2.s, Request{Role: goRole, Instructions: "p"}, nil)
	if se := mustErr(t, err); se.Reason != "login" || se.Detail != "no usable OpenCode Go key; run kogen provider login opencode-go" {
		t.Fatal(se)
	}
}

func TestOpenCodeGoTransientFailuresRetryThreeTimesWithTheStandardBackoff(t *testing.T) {
	e, f := keyEnv(t, "opencode-go", jsonAnswer(429, map[string]any{"error": map[string]any{"code": "rate_limit"}}), jsonAnswer(503, map[string]any{}), textHandlerGo("recovered"))
	resp, err := e.c.Respond(context.Background(), e.s, Request{Role: goRole, Instructions: "p", Input: user("x")}, nil)
	if err != nil || len(f.requests()) != 3 || !reflect.DeepEqual(e.clk.slept(), []time.Duration{2 * time.Second, 8 * time.Second}) {
		t.Fatalf("%v, %d requests, slept %v", err, len(f.requests()), e.clk.slept())
	}
	// the same complete logical request every time, the same session
	reqs := f.requests()
	if string(reqs[0].Body) != string(reqs[2].Body) || reqs[0].Header.Get("X-Opencode-Session") != reqs[2].Header.Get("X-Opencode-Session") {
		t.Fatal("a retry changed the request")
	}
	if resp.Items[0]["content"].([]any)[0].(map[string]any)["text"] != "recovered" {
		t.Fatal(resp.Items)
	}
	// exhaustion: unavailable, the last safe diagnostics, three requests
	e, f = keyEnv(t, "opencode-go", jsonAnswer(500, map[string]any{}), jsonAnswer(502, map[string]any{}), jsonAnswer(529, map[string]any{"error": map[string]any{"code": "overloaded", "type": "capacity"}}))
	obs := &observer{}
	_, err = e.c.Respond(context.Background(), e.s, Request{Role: goRole, Instructions: "p"}, obs)
	se := mustErr(t, err)
	if se.Reason != "unavailable" || se.Detail != "OpenCode Go did not answer after 3 attempts: OpenCode Go temporary HTTP 529" || len(f.requests()) != 3 ||
		strings.Join(se.Lines, "|") != `provider failure: {"code":"overloaded","http_status":529,"type":"capacity"}` {
		t.Fatalf("%v", se)
	}
	if recs := obs.records(); len(recs) != 3 || recs[0]["usage_state"] != "unknown" || recs[0]["outcome"] != "failed" || recs[2]["provider_failure"] == nil {
		t.Fatalf("records = %d", len(recs))
	}
}

func textHandlerGo(text string) handler { return jsonAnswer(200, goText(text)) }

func TestOpenCodeGoNetworkFailureIsTransientAndNamesNoAddress(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	url := srv.URL
	srv.Close()
	e := newEnv(t, nil)
	e.s = sys.NewWith([]string{"HOME=" + e.home, "KOGEN_PROVIDER_URL=" + url}, e.home)
	e.saveCreds("opencode-go", map[string]any{"provider": "opencode-go", "api_key": testKey})
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: goRole, Instructions: "p"}, nil)
	se := mustErr(t, err)
	if se.Reason != "unavailable" || se.Detail != "OpenCode Go did not answer after 3 attempts: OpenCode Go network failure" || len(e.clk.slept()) != 2 {
		t.Fatalf("%v", se)
	}
}

// ExUnit open_code_go_transport_test: a redirect cannot carry the key to the paid route.
func TestOpenCodeGoRedirectCannotCarryTheKeyToThePaidRoute(t *testing.T) {
	var paths []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		if r.URL.Path == "/inference/go/openai/v1/chat/completions" {
			http.Redirect(w, r, "/inference/openai/v1/chat/completions", http.StatusSeeOther)
		}
	}))
	defer srv.Close()
	e := newEnv(t, nil)
	e.s = sys.NewWith([]string{"HOME=" + e.home, "KOGEN_PROVIDER_URL=" + srv.URL}, e.home)
	e.saveCreds("opencode-go", map[string]any{"provider": "opencode-go", "api_key": testKey})
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: goRole, Instructions: "p"}, nil)
	se := mustErr(t, err)
	if se.Reason != "refused" || se.Detail != "OpenCode Go refused HTTP 303; no route or model fallback" || !reflect.DeepEqual(paths, []string{"/inference/go/openai/v1/chat/completions"}) {
		t.Fatalf("%v, paths %v", se, paths)
	}
}

func TestOpenCodeGoRefusesImagesBeforeAnyRequest(t *testing.T) {
	e, f := keyEnv(t, "opencode-go", jsonAnswer(200, goText("never")))
	input := []any{map[string]any{"type": "function_call_output", "call_id": "c", "output": []any{map[string]any{"type": "input_image", "image_url": "pixels"}}}}
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: goRole, Instructions: "p", Input: input}, nil)
	se := mustErr(t, err)
	if se.Class != "provider" || se.Reason != "unsupported_capability" || se.Exit != 4 ||
		se.Detail != "OpenCode Go images are unqualified; use external image preparation and pixel-review handoff" || len(f.requests()) != 0 {
		t.Fatalf("%v", se)
	}
	if _, err := e.c.Render(Request{Role: goRole, Instructions: "p", Input: input}); mustErr(t, err).Reason != "unsupported_capability" {
		t.Fatal("Render must refuse too")
	}
	// the other providers keep their image paths: nothing about images is decided here for them
	if _, err := e.c.Render(Request{Role: Role{Model: "m", Effort: "e"}, Instructions: "p", Input: input}); err != nil {
		t.Fatal(err)
	}
}

// ExUnit: the complete selected adapter's bytes, 524287 and 524288 fit, 524289 does not.
func TestRequestBoundaryIsMeasuredOnTheCompleteBodyOfEachAdapter(t *testing.T) {
	for _, role := range []Role{
		{Model: "gpt-6.1-sol", Effort: "high"}, grokRole, goRole,
		{Provider: "anthropic", Model: "claude-opus-5-5", Effort: "high"},
	} {
		t.Run(Name(role), func(t *testing.T) {
			c := &Client{}
			mk := func(n int) Request {
				return Request{Role: role, Instructions: "policy Δ", Input: []any{map[string]any{"role": "user", "content": strings.Repeat("x", n)}}}
			}
			overhead := len(mustEncode(c.Body(mk(0))))
			for _, tc := range []struct {
				size int
				fits bool
			}{{524287, true}, {524288, true}, {524289, false}} {
				req := mk(tc.size - overhead)
				body := c.Body(req)
				if got := len(mustEncode(body)); got != tc.size {
					t.Fatalf("rendered %d bytes, want %d", got, tc.size)
				}
				e, f := keyEnv(t, Name(role))
				if Name(role) == "chatgpt" {
					e.saveCreds("chatgpt", e.chatgptCreds())
				}
				if Name(role) == "supergrok" {
					e.saveCreds("supergrok", e.supergrokCreds())
				}
				_, err := e.c.Respond(context.Background(), e.s, req, nil)
				if tc.fits {
					// the fake answers 400, which is a refusal after the request went out
					if se := mustErr(t, err); se.Reason == "context_budget_exceeded" || len(f.requests()) != 1 {
						t.Fatalf("%d: %v, %d requests", tc.size, se, len(f.requests()))
					}
				} else if se := mustErr(t, err); se.Class != "candidate" || se.Reason != "context_budget_exceeded" || se.Exit != 1 || len(f.requests()) != 0 ||
					!strings.HasPrefix(se.Detail, "Complete next request 524289 bytes exceeds 524288; reserve 131072 tokens.") {
					t.Fatalf("%d: %v, %d requests", tc.size, se, len(f.requests()))
				}
			}
		})
	}
}

func goInfo() Info {
	info, _ := Lookup("opencode-go")
	return info
}

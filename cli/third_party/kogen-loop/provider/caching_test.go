package provider

import (
	"bytes"
	"context"
	"fmt"
	"reflect"
	"regexp"
	"strings"
	"testing"

	"kogen-loop/sys"
)

// Prompt caching (Intent go-core-migration): one cache identity per conversation, the same
// routing value on every request of it, append-only requests behind a frozen front, no
// prompt_cache_options and no breakpoints for any Responses route, at most four Anthropic
// breakpoints, and each provider's raw cache fields in the usage record.

type cachingCase struct {
	name   string
	role   Role
	prep   func(e *env)
	answer func(n int) handler // the n-th answer: one tool call (call_<n>) and cached input
	// routing reads the cache identity a request carries, "" when the provider has none.
	routing func(r recorded) string
}

func responsesAnswer(n int) handler {
	call := map[string]any{"type": "function_call", "id": fmt.Sprintf("fc_%d", n), "call_id": fmt.Sprintf("call_%d", n), "name": "read_file", "arguments": `{"path":"a"}`, "status": "completed"}
	return events(itemDone(0, call), done(map[string]any{"id": fmt.Sprintf("resp_%d", n), "usage": map[string]any{
		"input_tokens": int64(1000 * n), "input_tokens_details": map[string]any{"cached_tokens": int64(900 * n)},
		"output_tokens": int64(5), "output_tokens_details": map[string]any{"reasoning_tokens": int64(1)}}}))
}

var cachingCases = []cachingCase{
	{name: "chatgpt", role: Role{Model: "gpt-6.1-sol", Effort: "high"}, prep: func(e *env) { e.saveCreds("chatgpt", e.chatgptCreds()) }, answer: responsesAnswer,
		routing: func(r recorded) string {
			key, _ := r.JSON["prompt_cache_key"].(string)
			if got := r.Header.Get("session_id"); got != key || r.Header.Get("conversation_id") != key || r.Header.Get("Session-Id") != "" {
				return "MISMATCH " + got + " vs " + key
			}
			return key
		}},
	{name: "supergrok", role: grokRole, prep: func(e *env) { e.saveCreds("supergrok", e.supergrokCreds()) }, answer: responsesAnswer,
		routing: func(r recorded) string {
			if r.Header.Get("session_id") != "" || r.Header.Get("conversation_id") != "" || r.Header.Get("Session-Id") != "" || r.Header.Get("X-Opencode-Session") != "" || r.Header.Get("X-Grok-Conv-Id") != "" {
				return "UNEXPECTED HEADER"
			}
			key, _ := r.JSON["prompt_cache_key"].(string)
			return key
		}},
	{name: "opencode-go", role: goRole, answer: func(n int) handler {
		raw := map[string]any{"role": "assistant", "content": nil, "reasoning": fmt.Sprintf("thought %d", n), "tool_calls": []any{goCall(fmt.Sprintf("call_%d", n))}}
		return jsonAnswer(200, goAnswer(raw, "tool_calls", "usage", map[string]any{"prompt_tokens": int64(1000 * n), "completion_tokens": int64(5), "prompt_cache_hit_tokens": int64(900 * n)}))
	}, routing: func(r recorded) string {
		if _, has := r.JSON["prompt_cache_key"]; has || r.Header.Get("Session-Id") != "" || r.Header.Get("session_id") != "" || r.Header.Get("conversation_id") != "" {
			return "UNEXPECTED FIELD"
		}
		return r.Header.Get("X-Opencode-Session")
	}},
	{name: "anthropic", role: claudeRole, answer: func(n int) handler {
		return sseAnswer(flat(one(start("input_tokens", int64(100*n), "cache_read_input_tokens", int64(900*n), "cache_creation_input_tokens", int64(0))),
			block(0, map[string]any{"type": "thinking", "thinking": fmt.Sprintf("t%d", n), "signature": "sig"}), block(1, use(fmt.Sprintf("call_%d", n))), finish("tool_use"))...)
	}, routing: func(r recorded) string {
		for _, h := range []string{"Session-Id", "session_id", "conversation_id", "X-Opencode-Session", "X-Grok-Conv-Id"} {
			if r.Header.Get(h) != "" {
				return "UNEXPECTED HEADER"
			}
		}
		if _, has := r.JSON["prompt_cache_key"]; has {
			return "UNEXPECTED FIELD"
		}
		return ""
	}},
}

// conversation runs n requests of one conversation (a tool call each time), replaying the
// previous input and the received items like an agent loop.
func conversation(t *testing.T, c cachingCase, n int, scope any, mod ...func(*Request)) (*env, []recorded, []map[string]any) {
	t.Helper()
	var handlers []handler
	for i := 1; i <= n; i++ {
		handlers = append(handlers, c.answer(i))
	}
	e, f := keyEnv(t, c.role.Provider, handlers...)
	if c.name == "chatgpt" || c.name == "supergrok" {
		e = newEnvWithURL(t, f.srv.URL)
	}
	if c.prep != nil {
		c.prep(e)
	}
	obs := &observer{}
	tools := []any{readTool("read_file"), readTool("write_file")}
	input := []any{map[string]any{"role": "user", "content": []any{map[string]any{"type": "input_text", "text": "approved contract"}, map[string]any{"type": "input_text", "text": "evidence"}}}}
	for i := 1; i <= n; i++ {
		req := Request{Role: c.role, Instructions: "frozen policy Δ", Input: input, Tools: tools, Scope: scope, Context: map[string]any{"phase": "build"}}
		for _, m := range mod {
			m(&req)
		}
		resp, err := e.c.Respond(context.Background(), e.s, req, obs)
		if err != nil {
			t.Fatalf("%s request %d: %v", c.name, i, err)
		}
		input = append([]any(nil), input...)
		for _, it := range resp.Items {
			input = append(input, it)
		}
		input = append(input, map[string]any{"type": "function_call_output", "call_id": fmt.Sprintf("call_%d", i), "output": fmt.Sprintf("output %d", i)})
	}
	return e, f.requests(), obs.records()
}

// newEnvWithURL is a world whose provider origin is the keyFake at url (ChatGPT and SuperGrok
// routes use /v1/responses on it).
func newEnvWithURL(t *testing.T, url string) *env {
	e := newEnv(t, nil)
	e.s = sys.NewWith([]string{"HOME=" + e.home, "KOGEN_PROVIDER_URL=" + url, "KOGEN_AUTH_URL=" + url}, e.home)
	e.s.Stdout, e.s.Stderr = e.out, e.errs
	return e
}

var cacheControl = regexp.MustCompile(`"cache_control":\{"type":"ephemeral"\},?`)

// withoutBreakpoints is the body's bytes with the rolling Anthropic markers taken out: the
// markers are not part of what the provider matches.
func withoutBreakpoints(body []byte) []byte { return cacheControl.ReplaceAll(body, nil) }

// frontAndHistory splits an encoded body (conversation field last) at its conversation array.
func frontAndHistory(t *testing.T, body []byte, field string) (front, history string) {
	t.Helper()
	marker := `"` + field + `":[`
	i := bytes.LastIndex(body, []byte(marker))
	if i < 0 || !bytes.HasSuffix(body, []byte("]}")) {
		t.Fatalf("no %s array at the end of %s", field, body)
	}
	return string(body[:i]), string(body[i+len(marker) : len(body)-2])
}

func TestEveryConversationHasOneCacheIdentityAndAppendOnlyRequests(t *testing.T) {
	for _, c := range cachingCases {
		t.Run(c.name, func(t *testing.T) {
			_, reqs, recs := conversation(t, c, 3, "build/0")
			if len(reqs) != 3 {
				t.Fatalf("%d requests", len(reqs))
			}
			field := "input"
			if c.name == "opencode-go" || c.name == "anthropic" {
				field = "messages"
			}
			var ids []string
			for i, r := range reqs {
				ids = append(ids, c.routing(r))
				if strings.Contains(ids[i], "MISMATCH") || strings.Contains(ids[i], "UNEXPECTED") {
					t.Fatalf("request %d: %s", i+1, ids[i])
				}
				if i > 0 && ids[i] != ids[0] {
					t.Fatalf("request %d carries %q, request 1 %q", i+1, ids[i], ids[0])
				}
				if c.name != "anthropic" && (ids[i] == "" || len(ids[i]) > MaxCacheID) {
					t.Fatalf("routing value %q", ids[i])
				}
				for _, forbidden := range []string{"prompt_cache_options", "prompt_cache_breakpoint", "prompt_cache_retention", "previous_response_id", "comparison_response_id"} {
					if bytes.Contains(r.Body, []byte(forbidden)) {
						t.Fatalf("request %d sends %s", i+1, forbidden)
					}
				}
			}
			// the records carry the same identity
			for _, rec := range recs {
				if c.name != "anthropic" && rec["conversation_id"] != ids[0] {
					t.Fatalf("record %v vs %q", rec["conversation_id"], ids[0])
				}
			}
			// frozen front and append-only history: request n+1 is request n plus new items
			for i := 1; i < len(reqs); i++ {
				a, b := withoutBreakpoints(reqs[i-1].Body), withoutBreakpoints(reqs[i].Body)
				frontA, histA := frontAndHistory(t, a, field)
				frontB, histB := frontAndHistory(t, b, field)
				if frontA != frontB {
					t.Fatalf("the front changed between requests %d and %d:\n%s\n%s", i, i+1, frontA, frontB)
				}
				if !strings.HasPrefix(histB, histA) || len(histB) <= len(histA) {
					t.Fatalf("request %d's history does not extend request %d's", i+1, i)
				}
				// the whole request begins with the previous one up to the end of its input
				if !bytes.HasPrefix(b, a[:len(a)-2]) {
					t.Fatalf("request %d's body does not begin with request %d's input", i+1, i)
				}
			}
		})
	}
}

func TestDifferentConversationsNeverShareACacheIdentity(t *testing.T) {
	for _, c := range cachingCases {
		if c.name == "anthropic" {
			continue
		}
		t.Run(c.name, func(t *testing.T) {
			cache := NewCache(nil)
			role := c.role
			a, b := cache.Identity(role, "builder"), cache.Identity(role, "review 1")
			again := cache.Identity(role, "builder")
			other := cache.Identity(Role{Provider: role.Provider, Model: role.Model + "-x", Effort: role.Effort}, "builder")
			if a == b || a != again || a == other || a == "" || len(a) > MaxCacheID {
				t.Fatalf("%q %q %q %q", a, b, again, other)
			}
			if other2 := cache.Identity(Role{Provider: "supergrok", Model: role.Model, Effort: role.Effort}, "builder"); role.Provider != "supergrok" && other2 == a {
				t.Fatal("providers share an identity")
			}
		})
	}
	// through Respond: two scopes, two keys; the same scope after a restart of the process
	// (checkpoint states restored) keeps its key
	c := cachingCases[0]
	_, reqs1, _ := conversation(t, c, 1, "builder")
	_, reqs2, _ := conversation(t, c, 1, "reviewer")
	if k1, k2 := c.routing(reqs1[0]), c.routing(reqs2[0]); k1 == k2 {
		t.Fatalf("scopes share %q", k1)
	}
}

func TestCacheIdentitySurvivesResumeFromCheckpointStates(t *testing.T) {
	for _, c := range cachingCases {
		if c.name == "anthropic" {
			continue
		}
		t.Run(c.name, func(t *testing.T) {
			e, reqs, _ := conversation(t, c, 2, "build")
			first := c.routing(reqs[0])
			states := e.c.Cache.States()
			if len(states) != 1 {
				t.Fatalf("states = %v", states)
			}
			// a resumed process: a new Client with the saved states continues the identity
			f := newKeyFake(t, c.answer(1))
			e2 := newEnvWithURL(t, f.srv.URL)
			if c.prep != nil {
				c.prep(e2)
			}
			if c.name == "opencode-go" {
				e2 = keyEnvAt(t, f)
			}
			e2.c.Cache = NewCache(states)
			if _, err := e2.c.Respond(context.Background(), e2.s, Request{Role: c.role, Instructions: "frozen policy Δ", Input: user("again"), Scope: "build"}, nil); err != nil {
				t.Fatal(err)
			}
			if got := c.routing(f.requests()[0]); got != first {
				t.Fatalf("resumed key %q, original %q", got, first)
			}
			// the caller may instead keep the identity itself
			f2 := newKeyFake(t, c.answer(1))
			e3 := newEnvWithURL(t, f2.srv.URL)
			if c.prep != nil {
				c.prep(e3)
			}
			if c.name == "opencode-go" {
				e3 = keyEnvAt(t, f2)
			}
			if _, err := e3.c.Respond(context.Background(), e3.s, Request{Role: c.role, Instructions: "p", Input: user("x"), CacheID: first}, nil); err != nil {
				t.Fatal(err)
			}
			if got := c.routing(f2.requests()[0]); got != first {
				t.Fatalf("explicit CacheID gave %q", got)
			}
		})
	}
}

// keyEnvAt is a world with a saved OpenCode Go key whose route is the fake f.
func keyEnvAt(t *testing.T, f *keyFake) *env {
	e := newEnvWithURL(t, f.srv.URL)
	e.saveCreds("opencode-go", map[string]any{"provider": "opencode-go", "api_key": testKey})
	return e
}

func TestRetriesKeepTheConversationsIdentity(t *testing.T) {
	// a transient failure and the retry both carry the routing value of the conversation
	e, f := keyEnv(t, "opencode-go", jsonAnswer(503, map[string]any{}), cachingCases[2].answer(1))
	if _, err := e.c.Respond(context.Background(), e.s, Request{Role: goRole, Instructions: "p", Input: user("x"), Scope: "s"}, nil); err != nil {
		t.Fatal(err)
	}
	reqs := f.requests()
	if reqs[0].Header.Get("X-Opencode-Session") == "" || reqs[0].Header.Get("X-Opencode-Session") != reqs[1].Header.Get("X-Opencode-Session") {
		t.Fatal("a retry changed the session")
	}
	e2, f2 := chatEnv(t, events(map[string]any{"type": "error", "error": map[string]any{"code": "server_error"}}), responsesAnswer(1))
	if _, err := e2.c.Respond(context.Background(), e2.s, Request{Role: Role{Model: "gpt-6.1-sol", Effort: "high"}, Instructions: "p", Input: user("x"), Scope: "s"}, nil); err != nil {
		t.Fatal(err)
	}
	r := f2.requests()
	if len(r) != 2 || !bytes.Equal(r[0].Body, r[1].Body) {
		t.Fatal("a transient-stream retry changed the request")
	}
	for _, h := range []string{"session_id", "conversation_id"} {
		if got := r[0].Header.Get(h); got == "" || got != r[0].JSON["prompt_cache_key"] || got != r[1].Header.Get(h) {
			t.Fatalf("a transient-stream retry lost affinity: %s = %q then %q", h, got, r[1].Header.Get(h))
		}
	}
}

func TestChatGPTSendsStatelessCachedRequestsOnEveryModel(t *testing.T) {
	// the old gpt-5.6 split is gone: any model gets the same fields, never cache options
	for _, model := range []string{"gpt-6.1-sol", "gpt-5.5", "gpt-5.4", "gpt-60", "fixture"} {
		e, f := chatEnv(t, responsesAnswer(1))
		_, err := e.c.Respond(context.Background(), e.s, Request{Role: Role{Model: model, Effort: "medium"}, Instructions: "policy", Input: user("x")}, nil)
		if err != nil {
			t.Fatal(err)
		}
		b := f.requests()[0].JSON
		if b["store"] != false || b["stream"] != true || b["instructions"] != "policy" || !reflect.DeepEqual(b["include"], []any{"reasoning.encrypted_content"}) || b["prompt_cache_key"] == nil {
			t.Fatalf("%s: %s", model, jsonOf(t, b))
		}
	}
}

// Anthropic: at most four breakpoints, on the last tool, the last system block and the last
// block of the newest message (which rolls forward), never on thinking blocks.
func TestAnthropicBreakpointPositionsAndCount(t *testing.T) {
	c := cachingCases[3]
	_, reqs, _ := conversation(t, c, 3, "s")
	for i, r := range reqs {
		body := r.JSON
		marked := 0
		var where []string
		for ti, tl := range body["tools"].([]any) {
			if _, ok := tl.(map[string]any)["cache_control"]; ok {
				marked++
				where = append(where, fmt.Sprintf("tool %d", ti))
			}
		}
		if len(where) != 1 || where[0] != "tool 1" {
			t.Fatalf("request %d tools: %v", i+1, where)
		}
		sys := body["system"].([]any)
		if len(sys) != 1 || sys[0].(map[string]any)["cache_control"] == nil {
			t.Fatalf("request %d system: %v", i+1, sys)
		}
		marked++
		msgs := body["messages"].([]any)
		for mi, m := range msgs {
			blocks := m.(map[string]any)["content"].([]any)
			for bi, b := range blocks {
				if _, ok := b.(map[string]any)["cache_control"]; ok {
					marked++
					if mi != len(msgs)-1 || bi != len(blocks)-1 {
						t.Fatalf("request %d: a breakpoint on messages[%d].content[%d], not the newest message's last block", i+1, mi, bi)
					}
					if bt := b.(map[string]any)["type"]; bt == "thinking" || bt == "redacted_thinking" {
						t.Fatal("breakpoint on a thinking block")
					}
				}
			}
		}
		if marked != 3 || strings.Count(string(r.Body), "cache_control") != 3 {
			t.Fatalf("request %d: %d breakpoints", i+1, marked)
		}
	}
	// the assistant's thinking blocks are replayed verbatim, once
	last := reqs[2].JSON["messages"].([]any)
	if raw := last[1].(map[string]any)["content"].([]any)[0].(map[string]any); raw["type"] != "thinking" || raw["thinking"] != "t1" || raw["signature"] != "sig" {
		t.Fatalf("thinking not replayed: %v", raw)
	}
	// a newest message that ends in a thinking block gets no marker; the tail never exceeds four
	body := (&Client{}).Body(Request{Role: claudeRole, Instructions: "p", Input: []any{
		map[string]any{"role": "user", "content": "q"},
		map[string]any{"type": "message", "role": "assistant", "content": []any{}, "anthropic_message": map[string]any{"role": "assistant", "content": []any{map[string]any{"type": "thinking", "thinking": "t", "signature": "s"}}}},
	}})
	if n := strings.Count(string(mustEncode(body)), "cache_control"); n != 1 {
		t.Fatalf("breakpoints = %d", n)
	}
}

func TestRequestBytesAreDeterministic(t *testing.T) {
	for _, c := range cachingCases {
		t.Run(c.name, func(t *testing.T) {
			tools := []any{readTool("write_file"), readTool("read_file"), readTool("shell")}
			input := []any{map[string]any{"role": "user", "content": []any{map[string]any{"type": "input_text", "text": "x", "z": 1, "a": 2}}},
				map[string]any{"type": "function_call_output", "call_id": "c", "output": "o"}}
			info, _ := Lookup(c.role.Provider)
			var first []byte
			for i := 0; i < 25; i++ {
				req := Request{Role: c.role, Instructions: "policy", Input: input, Tools: tools}
				r, err := render(info, req, "conversation-fixed", false)
				if err != nil {
					t.Fatal(err)
				}
				b, err := encodeBody(info, r.body)
				if err != nil {
					t.Fatal(err)
				}
				if first == nil {
					first = b
				} else if !bytes.Equal(first, b) {
					t.Fatal("the same request rendered different bytes")
				}
			}
			// tool order is the caller's order
			s := string(first)
			w, rd, sh := strings.Index(s, "write_file"), strings.Index(s, "read_file"), strings.Index(s, "shell")
			if !(w >= 0 && w < rd && rd < sh) {
				t.Fatalf("tool order lost: %d %d %d", w, rd, sh)
			}
			// no time, request id or counter in the frozen front: another conversation's request
			// differs only by its identity, where the provider reads it (body or header)
			r1, _ := render(info, Request{Role: c.role, Instructions: "policy", Input: input, Tools: tools}, "conversation-fixed", false)
			r2, _ := render(info, Request{Role: c.role, Instructions: "policy", Input: input, Tools: tools}, "conversation-other", false)
			b1, _ := encodeBody(info, r1.body)
			b2, _ := encodeBody(info, r2.body)
			switch c.name {
			case "anthropic":
				if !bytes.Equal(b1, b2) || len(r1.headers) != 0 {
					t.Fatal("Anthropic has no routing value")
				}
			case "opencode-go":
				if !bytes.Equal(b1, b2) || r1.headers["x-opencode-session"] != "conversation-fixed" || r2.headers["x-opencode-session"] != "conversation-other" {
					t.Fatal("OpenCode Go routes by header only")
				}
			default:
				if !bytes.Equal(bytes.ReplaceAll(b1, []byte("conversation-fixed"), []byte("conversation-other")), b2) {
					t.Fatal("the bodies differ by more than the cache key")
				}
			}
		})
	}
}

// Each provider's raw cache fields end up in the usage record, the total input of Anthropic
// computed from its three counters; usage reports are built from these.
func TestUsageRecordsKeepEachProvidersRawCacheFields(t *testing.T) {
	for _, c := range cachingCases {
		t.Run(c.name, func(t *testing.T) {
			_, _, recs := conversation(t, c, 2, "s")
			want := map[string][4]int{ // input, cached, write(-1 none), output
				"chatgpt": {1000, 900, -1, 5}, "supergrok": {1000, 900, -1, 5}, "opencode-go": {1000, 900, -1, 5}, "anthropic": {100 + 900 + 0, 900, 0, 12},
			}[c.name]
			u := recs[0]["usage"].(map[string]any)
			if u["input"] != want[0] || u["cached"] != want[1] || u["output"] != want[3] {
				t.Fatalf("usage = %v, want %v", u, want)
			}
			if want[2] >= 0 && u["write"] != want[2] {
				t.Fatalf("write = %v", u["write"])
			}
			second := recs[1]["usage"].(map[string]any)
			if second["cached"] != want[1]*2 {
				t.Fatalf("second usage = %v", second)
			}
		})
	}
}

func TestCacheStatesAreSavedPerConversationAndOnlySuperGrokRemembersARefusal(t *testing.T) {
	e, _, _ := conversation(t, cachingCases[0], 1, "scope")
	for _, st := range e.c.Cache.States() {
		if st.Unsupported || st.Response != "" || st.ID == "" || len(st.ID) > MaxCacheID {
			t.Fatalf("%+v", st)
		}
	}
	// an old checkpoint's unsupported flag (from the retired ChatGPT fallback) changes nothing now
	cache := NewCache(map[string]CacheState{conversationKey(Role{Model: "gpt-6.1-sol", Effort: "high"}, "old"): {ID: "conversation-old", Unsupported: true, Response: "resp_old"}})
	body := (&Client{Cache: cache}).Body(Request{Role: Role{Model: "gpt-6.1-sol", Effort: "high"}, Instructions: "p", Input: user("x"), Scope: "old"})
	if body["prompt_cache_key"] != "conversation-old" || body["prompt_cache_options"] != nil {
		t.Fatalf("%v", body)
	}
	// a long saved identity goes out as a stable 64-character value
	long := strings.Repeat("x", 200)
	cache = NewCache(map[string]CacheState{conversationKey(Role{Model: "m"}, "long"): {ID: long}})
	k1 := (&Client{Cache: cache}).Body(Request{Role: Role{Model: "m"}, Scope: "long"})["prompt_cache_key"].(string)
	k2 := (&Client{Cache: cache}).Body(Request{Role: Role{Model: "m"}, Scope: "long"})["prompt_cache_key"].(string)
	if len(k1) != MaxCacheID || k1 != k2 {
		t.Fatalf("%q %q", k1, k2)
	}
	if got := wireID("short"); got != "short" {
		t.Fatal(got)
	}
	if id := NewCacheID(); len(id) > MaxCacheID || id == NewCacheID() {
		t.Fatal("NewCacheID")
	}
}

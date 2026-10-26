package provider

import (
	"context"
	"os"
	"slices"
	"strings"
	"testing"

	"kogen-loop/sys"
)

// KOGEN-057 (intent go-core-migration, Open model selection): any model and effort is sent
// unchanged, a model refusal is one clear error without a retry, and openai-compatible
// reaches a local host at its base_url, with or without a key.

// compatibleEnv is a world whose only route is the fake at base_url <fake>/v1; key saves one
// when set. KOGEN_PROVIDER_URL is deliberately absent: the base_url alone names the host.
func compatibleEnv(t *testing.T, key string, h ...handler) (*env, *keyFake, Role) {
	t.Helper()
	f := newKeyFake(t, h...)
	e := newEnv(t, nil)
	e.s = sys.NewWith([]string{"HOME=" + e.home, "PATH=" + os.Getenv("PATH")}, e.home)
	e.s.Stdout, e.s.Stderr = e.out, e.errs
	if key != "" {
		e.saveCreds("openai-compatible", map[string]any{"provider": "openai-compatible", "api_key": key})
	}
	return e, f, Role{Provider: "openai-compatible", Model: "qwen3-coder:30b", Effort: "default", BaseURL: f.srv.URL + "/v1"}
}

func TestOpenAICompatibleSendsTheRoleToItsBaseURLWithoutAKey(t *testing.T) {
	answer := goAnswer(map[string]any{"role": "assistant", "content": "local answer"}, "stop", "usage",
		map[string]any{"prompt_tokens": int64(2000), "completion_tokens": int64(5), "prompt_tokens_details": map[string]any{"cached_tokens": int64(1800)}})
	e, f, role := compatibleEnv(t, "", jsonAnswer(200, answer))
	resp, err := e.c.Respond(context.Background(), e.s, Request{Role: role, Instructions: "policy", Input: user("hi"), Tools: []any{goTool("read_file")}, Scope: "s"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	reqs := f.requests()
	if len(reqs) != 1 {
		t.Fatalf("%d requests", len(reqs))
	}
	r := reqs[0]
	if r.Method != "POST" || r.Path != "/v1/chat/completions" {
		t.Fatalf("%s %s", r.Method, r.Path)
	}
	if r.Header.Get("Authorization") != "" {
		t.Fatalf("no key must send no Authorization, got %q", r.Header.Get("Authorization"))
	}
	for _, h := range []string{"X-Opencode-Session", "Session-Id", "session_id", "conversation_id", "X-Grok-Conv-Id"} {
		if r.Header.Get(h) != "" {
			t.Errorf("vendor routing header %s sent to a generic host", h)
		}
	}
	if r.JSON["model"] != "qwen3-coder:30b" {
		t.Errorf("model %v", r.JSON["model"])
	}
	for _, k := range []string{"reasoning_effort", "prompt_cache_key", "prompt_cache_options"} {
		if _, ok := r.JSON[k]; ok {
			t.Errorf("%s sent with effort default to a generic host", k)
		}
	}
	if resp.Usage.Cached != 1800 || resp.Usage.Input != 2000 {
		t.Errorf("usage %+v", resp.Usage)
	}
}

func TestOpenAICompatibleSendsASavedKeyAndAnyEffort(t *testing.T) {
	e, f, role := compatibleEnv(t, testKey, jsonAnswer(200, goText("ok")))
	role.Effort = "medium"
	role.BaseURL += "/" // a trailing slash is not doubled
	if _, err := e.c.Respond(context.Background(), e.s, Request{Role: role, Instructions: "p", Input: user("x"), Scope: "s"}, nil); err != nil {
		t.Fatal(err)
	}
	r := f.requests()[0]
	if r.Path != "/v1/chat/completions" || r.Header.Get("Authorization") != "Bearer "+testKey || r.JSON["reasoning_effort"] != "medium" {
		t.Fatalf("%s %q %v", r.Path, r.Header.Get("Authorization"), r.JSON["reasoning_effort"])
	}
}

func TestOpenAICompatibleNeedsNoLoginButShowsItsKeyState(t *testing.T) {
	home := t.TempDir()
	role := Role{Provider: "openai-compatible", Model: "m", Effort: "default", BaseURL: "http://127.0.0.1:1/v1"}
	if err := RequireLogin(home, []Role{role}); err != nil {
		t.Fatalf("a keyless local host needs no login: %v", err)
	}
	if got := Status(home); len(got) != 4 {
		t.Fatalf("a keyless openai-compatible host is not listed: %q", got)
	}
	e := newEnv(t, nil)
	e.saveCreds("openai-compatible", map[string]any{"provider": "openai-compatible", "api_key": testKey})
	if got := Status(e.home)[len(Catalog())-1]; got != "openai-compatible: key saved (not verified)" {
		t.Fatalf("status %q", got)
	}
	// The other providers keep their exact lines.
	if got := Status(home); !slices.Equal(got[:4], []string{"chatgpt: not signed in", "supergrok: not signed in", "opencode-go: not signed in", "anthropic: not signed in"}) {
		t.Fatalf("%q", got)
	}
}

func TestOpenAICompatibleKeyLoginSavesPrivately(t *testing.T) {
	e := newEnv(t, nil)
	e.c.Input = &Input{Reader: strings.NewReader("local-secret\n")}
	if err := e.c.Login(context.Background(), e.s, "openai-compatible", nil); err != nil {
		t.Fatal(err)
	}
	if e.out.String() != "openai-compatible: key saved (not verified)\n" {
		t.Fatalf("%q", e.out.String())
	}
	info, err := os.Stat(e.credPath("openai-compatible"))
	if err != nil || info.Mode().Perm() != 0o600 || e.readCreds("openai-compatible")["api_key"] != "local-secret" {
		t.Fatalf("%v %v", info, err)
	}
}

// Every provider takes a model and effort no list knows, unchanged, on the wire.
func TestAnyModelAndEffortAreSentUnchanged(t *testing.T) {
	model, effort := "model-nobody-listed-1", "effort-nobody-listed"
	t.Run("opencode-go", func(t *testing.T) {
		e, f := keyEnv(t, "opencode-go", jsonAnswer(200, goText("ok")))
		if _, err := e.c.Respond(context.Background(), e.s, Request{Role: Role{Provider: "opencode-go", Model: model, Effort: effort}, Instructions: "p", Input: user("x"), Scope: "s"}, nil); err != nil {
			t.Fatal(err)
		}
		if r := f.requests()[0].JSON; r["model"] != model || r["reasoning_effort"] != effort {
			t.Fatalf("%v %v", r["model"], r["reasoning_effort"])
		}
	})
	for _, name := range []string{"chatgpt", "supergrok", "anthropic"} {
		t.Run(name, func(t *testing.T) {
			info, _ := Lookup(name)
			body, err := (&Client{Cache: NewCache(nil)}).Render(Request{Role: Role{Provider: name, Model: model, Effort: effort}, Instructions: "p", Input: user("x"), Scope: "s"})
			if err != nil {
				t.Fatal(err)
			}
			got := ""
			switch info.wire {
			case wireMessages:
				got, _ = body["output_config"].(map[string]any)["effort"].(string)
			default:
				got, _ = body["reasoning"].(map[string]any)["effort"].(string)
			}
			if body["model"] != model || got != effort {
				t.Fatalf("%v %v", body["model"], got)
			}
		})
	}
}

// A model refusal keeps its first line, adds the fix and is not retried.
func TestAModelRefusalIsClearAndNotRetried(t *testing.T) {
	cases := []struct {
		name      string
		h         handler
		first     string
		reason    string
		provider  string
		withRetry bool
	}{
		{"opencode-go model_not_found", jsonAnswer(404, map[string]any{"error": map[string]any{"code": "model_not_found", "message": "no such model"}}),
			"provider/model_unavailable: OpenCode Go refused HTTP 404; no route or model fallback", "model_unavailable", "opencode-go", false},
		{"opencode-go invalid effort 400", jsonAnswer(400, map[string]any{"error": map[string]any{"code": "invalid_request_error", "message": "bad reasoning_effort"}}),
			"provider/refused: OpenCode Go refused HTTP 400; no route or model fallback", "refused", "opencode-go", false},
		{"openai-compatible unknown model 404", jsonAnswer(404, map[string]any{"error": map[string]any{"message": "model 'kimi-k9' not found"}}),
			"provider/refused: OpenAI-compatible refused HTTP 404; no route or model fallback", "refused", "openai-compatible", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var e *env
			var f *keyFake
			role := Role{Provider: c.provider, Model: "kimi-k9", Effort: "high"}
			if c.provider == "openai-compatible" {
				var r Role
				e, f, r = compatibleEnv(t, "", c.h, jsonAnswer(200, goText("must not be reached")))
				role.BaseURL = r.BaseURL
			} else {
				e, f = keyEnv(t, c.provider, c.h, jsonAnswer(200, goText("must not be reached")))
			}
			_, err := e.c.Respond(context.Background(), e.s, Request{Role: role, Instructions: "p", Input: user("x"), Scope: "s"}, nil)
			se := mustErr(t, err)
			if se.Reason != c.reason || se.Exit != 4 || !strings.HasPrefix(se.Render(), c.first+"\n") {
				t.Fatalf("%q", se.Render())
			}
			label, _ := Lookup(c.provider)
			hint := "model kimi-k9 with effort high was sent to " + label.Label + " unchanged and not retried; if " + label.Label +
				" does not offer them, set another model or effort for this role in .kogen/project.yaml"
			if !slices.Contains(se.Lines, hint) {
				t.Fatalf("missing hint in %q", se.Lines)
			}
			if n := len(f.requests()); n != 1 {
				t.Fatalf("%d requests: a refusal must not be retried", n)
			}
		})
	}
}

// Other provider failures get no model hint.
func TestNoModelHintOnOtherFailures(t *testing.T) {
	e, _ := keyEnv(t, "opencode-go", jsonAnswer(401, map[string]any{}))
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: goRole, Instructions: "p", Input: user("x"), Scope: "s"}, nil)
	for _, l := range mustErr(t, err).Lines {
		if strings.Contains(l, "project.yaml") {
			t.Fatalf("unexpected hint %q", l)
		}
	}
}

// An OpenAI-compatible host's own refusal text is shown, made safe: one line, the key redacted,
// at most 300 bytes. OpenCode Go's body text stays hidden (TestOpenCodeGoErrorsAreClassifiedWithoutFallbackOrBodyText).
func TestOpenAICompatibleShowsTheHostsOwnRefusalSafely(t *testing.T) {
	e, _, role := compatibleEnv(t, testKey, jsonAnswer(404, map[string]any{"error": "model 'kimi-k9' not found, try pulling it first\n\x1b[31m " + testKey}))
	role.Model = "kimi-k9"
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: role, Instructions: "p", Input: user("x"), Scope: "s"}, nil)
	se := mustErr(t, err)
	want := "OpenAI-compatible said: model 'kimi-k9' not found, try pulling it first [31m [redacted]"
	if !slices.Contains(se.Lines, want) || strings.Contains(se.Render(), testKey) {
		t.Fatalf("%q", se.Lines)
	}
	if got := hostMessage(strings.Repeat("é", 400), ""); len(got) > 300+len("…") || !strings.HasSuffix(got, "…") {
		t.Fatalf("%d %q", len(got), got[len(got)-8:])
	}
	if hostMessage(" \t\n", "") != "" {
		t.Fatal("blank message kept")
	}
}

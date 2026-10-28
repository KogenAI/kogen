package provider

import (
	"context"
	"strings"
	"testing"

	"kogen-loop/sys"
)

var parallelRoles = []struct {
	name string
	role Role
	info string
}{
	{"chatgpt", Role{Model: "gpt-6.1-sol", Effort: "high"}, "chatgpt"},
	{"supergrok", grokRole, "supergrok"},
	{"anthropic", claudeRole, "anthropic"},
	{"anthropic-profile", Role{Provider: "anthropic", Model: "claude-sonnet-5-5", Effort: "high"}, "anthropic"},
	{"opencode-go", goRole, "opencode-go"},
	{"openai-compatible", Role{Provider: "openai-compatible", Model: "m", Effort: "default", BaseURL: "http://127.0.0.1:1/v1"}, "openai-compatible"},
}

func parallelBody(t *testing.T, role Role, disable bool, withTools bool) string {
	t.Helper()
	info, _ := Lookup(role.Provider)
	req := Request{Role: role, Instructions: "policy", Input: user("hi"), CacheID: "fixed-cache-id", DisableParallelToolCalls: disable}
	if withTools {
		req.Tools = []any{goTool("read_file")}
	}
	c := NewClient("")
	body, err := c.Render(req)
	if err != nil {
		t.Fatal(err)
	}
	enc, err := encodeBody(info, body)
	if err != nil {
		t.Fatal(err)
	}
	return string(enc)
}

// parallelBaseline is each route's encoded default body for fixed identities, as it was
// before DisableParallelToolCalls existed.
var parallelBaseline = map[string]string{
	"chatgpt":           `{"include":["reasoning.encrypted_content"],"instructions":"policy","model":"gpt-6.1-sol","prompt_cache_key":"fixed-cache-id","reasoning":{"effort":"high"},"store":false,"stream":true,"tool_choice":"auto","tools":[{"description":"d","name":"read_file","parameters":{"type":"object"},"type":"function"}],"input":[{"content":[{"text":"hi","type":"input_text"}],"role":"user"}]}`,
	"supergrok":         `{"include":["reasoning.encrypted_content"],"instructions":"policy","model":"grok-4.7","prompt_cache_key":"fixed-cache-id","reasoning":{"effort":"low"},"store":false,"stream":true,"tool_choice":"auto","tools":[{"description":"d","name":"read_file","parameters":{"type":"object"},"type":"function"}],"input":[{"content":[{"text":"hi","type":"input_text"}],"role":"user"}]}`,
	"anthropic":         `{"max_tokens":128000,"model":"claude-opus-5-5","output_config":{"effort":"high"},"stream":true,"system":[{"cache_control":{"type":"ephemeral"},"text":"policy","type":"text"}],"thinking":{"type":"adaptive"},"tool_choice":{"type":"auto"},"tools":[{"cache_control":{"type":"ephemeral"},"description":"d","input_schema":{"type":"object"},"name":"read_file"}],"messages":[{"content":[{"cache_control":{"type":"ephemeral"},"text":"hi","type":"text"}],"role":"user"}]}`,
	"anthropic-profile": `{"max_tokens":128000,"model":"claude-sonnet-5-5","output_config":{"effort":"high"},"stream":true,"system":[{"cache_control":{"type":"ephemeral"},"text":"policy","type":"text"}],"thinking":{"type":"adaptive"},"tool_choice":{"type":"auto"},"tools":[{"cache_control":{"type":"ephemeral"},"description":"d","input_schema":{"type":"object"},"name":"read_file"}],"messages":[{"content":[{"cache_control":{"type":"ephemeral"},"text":"hi","type":"text"}],"role":"user"}]}`,
	"opencode-go":       `{"model":"kimi-k3","reasoning_effort":"high","store":false,"stream":false,"tool_choice":"auto","tools":[{"function":{"description":"d","name":"read_file","parameters":{"type":"object"}},"type":"function"}],"messages":[{"content":"policy","role":"system"},{"content":[{"text":"hi","type":"text"}],"role":"user"}]}`,
	"openai-compatible": `{"model":"m","store":false,"stream":false,"tool_choice":"auto","tools":[{"function":{"description":"d","name":"read_file","parameters":{"type":"object"}},"type":"function"}],"messages":[{"content":"policy","role":"system"},{"content":[{"text":"hi","type":"text"}],"role":"user"}]}`,
}

func TestParallelToolCallsDefault(t *testing.T) {
	for _, c := range parallelRoles {
		got := parallelBody(t, c.role, false, true)
		if got != parallelBaseline[c.name] {
			t.Errorf("%s: default body changed\n got %s\nwant %s", c.name, got, parallelBaseline[c.name])
		}
	}
}

func parallelCall(t *testing.T, e *env, role Role, tools []any) {
	t.Helper()
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: role, Instructions: "policy", Input: user("hi"), Tools: tools, Scope: "s", DisableParallelToolCalls: true}, nil)
	if err != nil {
		t.Fatal(err)
	}
}

func TestParallelToolCallsResponses(t *testing.T) {
	for _, tools := range [][]any{{goTool("read_file")}, nil} {
		e, f := chatEnv(t, textAnswer("ok"))
		parallelCall(t, e, Role{Model: "gpt-6.1-sol", Effort: "high"}, tools)
		r := f.requests()
		if len(r) != 1 || r[0].JSON["parallel_tool_calls"] != false {
			t.Fatalf("tools=%d: parallel_tool_calls not false: %s", len(tools), r[0].Body)
		}
		if _, ok := r[0].JSON["tool_choice"]; ok != (len(tools) > 0) {
			t.Errorf("tool_choice presence %v with %d tools", ok, len(tools))
		}
		if !strings.Contains(string(r[0].Body), `"parallel_tool_calls":false`) {
			t.Errorf("literal missing: %s", r[0].Body)
		}
	}
	// A rejection of the control is returned, not retried with a weaker request.
	e, f := chatEnv(t, jsonAnswer(400, map[string]any{"error": map[string]any{"code": "unknown_parameter", "param": "parallel_tool_calls", "message": "unsupported"}}), textAnswer("must not fallback"))
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: Role{Model: "gpt-6.1-sol", Effort: "high"}, Input: user("hi"), DisableParallelToolCalls: true}, nil)
	if err == nil || len(f.requests()) != 1 || f.requests()[0].JSON["parallel_tool_calls"] != false {
		t.Fatalf("control rejection: err=%v requests=%v", err, f.requests())
	}
	// SuperGrok shares the Responses wire.
	body := parallelBody(t, grokRole, true, true)
	if !strings.Contains(body, `"parallel_tool_calls":false`) {
		t.Errorf("supergrok: %s", body)
	}
	// Off differs from default only by the one field.
	if strings.Replace(parallelBody(t, grokRole, true, true), `"parallel_tool_calls":false,`, "", 1) != parallelBaseline["supergrok"] {
		t.Error("off changed more than parallel_tool_calls")
	}
}

func TestParallelToolCallsMessages(t *testing.T) {
	for _, role := range []Role{claudeRole, {Provider: "anthropic", Model: "claude-sonnet-5-5", Effort: "high"}} {
		e, f := keyEnv(t, "anthropic", claudeText("ok"))
		parallelCall(t, e, role, []any{goTool("read_file")})
		r := f.requests()
		tc, _ := r[0].JSON["tool_choice"].(map[string]any)
		if tc["type"] != "auto" || tc["disable_parallel_tool_use"] != true || len(tc) != 2 {
			t.Fatalf("%s tool_choice = %v", role.Model, r[0].JSON["tool_choice"])
		}
		if _, ok := r[0].JSON["parallel_tool_calls"]; ok {
			t.Error("Responses field sent on Messages")
		}
		e, f = keyEnv(t, "anthropic", claudeText("ok"))
		parallelCall(t, e, role, nil)
		if _, ok := f.requests()[0].JSON["tool_choice"]; ok {
			t.Errorf("tool_choice created without tools: %s", f.requests()[0].Body)
		}
	}
}

func TestParallelToolCallsMessagesRejection(t *testing.T) {
	e, f := keyEnv(t, "anthropic", jsonAnswer(400, map[string]any{"error": map[string]any{"type": "invalid_request_error", "message": "disable_parallel_tool_use unsupported"}}), claudeText("must not fallback"))
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: claudeRole, Input: user("hi"), Tools: []any{goTool("read_file")}, DisableParallelToolCalls: true}, nil)
	if err == nil || len(f.requests()) != 1 {
		t.Fatalf("control rejection: err=%v requests=%v", err, f.requests())
	}
	tc, _ := f.requests()[0].JSON["tool_choice"].(map[string]any)
	if tc["disable_parallel_tool_use"] != true {
		t.Fatalf("control missing: %v", tc)
	}
}

func TestParallelToolCallsUnsupported(t *testing.T) {
	for _, c := range parallelRoles {
		if c.name != "opencode-go" && c.name != "openai-compatible" {
			continue
		}
		var e *env
		var f *keyFake
		role := c.role
		if c.name == "opencode-go" {
			e, f = keyEnv(t, "opencode-go", jsonAnswer(200, goText("x")))
		} else {
			e, f, role = compatibleEnv(t, "", jsonAnswer(200, goText("x")))
		}
		_, err := e.c.Respond(context.Background(), e.s, Request{Role: role, Instructions: "p", Input: user("hi"), Tools: []any{goTool("read_file")}, Scope: "s", DisableParallelToolCalls: true}, nil)
		if err == nil {
			t.Fatalf("%s: off accepted", c.name)
		}
		msg := err.Error()
		if e2, ok := sys.AsError(err); ok {
			msg = e2.Detail
		}
		if !strings.Contains(msg, "parallel tool calls") || !strings.Contains(msg, c.info) {
			t.Errorf("%s: unclear error %q", c.name, msg)
		}
		if n := len(f.requests()); n != 0 {
			t.Errorf("%s: %d requests sent", c.name, n)
		}
		// Default still works on the same route.
		if _, err := e.c.Respond(context.Background(), e.s, Request{Role: role, Instructions: "p", Input: user("hi"), Scope: "s"}, nil); err != nil {
			t.Errorf("%s default: %v", c.name, err)
		}
	}
}

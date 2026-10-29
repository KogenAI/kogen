package provider

import "testing"

var baselineRoles = []struct {
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

func baselineBody(t *testing.T, role Role) string {
	t.Helper()
	info, _ := Lookup(role.Provider)
	req := Request{Role: role, Instructions: "policy", Input: user("hi"), Tools: []any{goTool("read_file")}, CacheID: "fixed-cache-id"}
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

// baselineBodies is each route's encoded default body for fixed identities, .
var baselineBodies = map[string]string{
	"chatgpt":           `{"include":["reasoning.encrypted_content"],"instructions":"policy","model":"gpt-6.1-sol","prompt_cache_key":"fixed-cache-id","reasoning":{"effort":"high"},"store":false,"stream":true,"tool_choice":"auto","tools":[{"description":"d","name":"read_file","parameters":{"type":"object"},"type":"function"}],"input":[{"content":[{"text":"hi","type":"input_text"}],"role":"user"}]}`,
	"supergrok":         `{"include":["reasoning.encrypted_content"],"instructions":"policy","model":"grok-4.7","prompt_cache_key":"fixed-cache-id","reasoning":{"effort":"low"},"store":false,"stream":true,"tool_choice":"auto","tools":[{"description":"d","name":"read_file","parameters":{"type":"object"},"type":"function"}],"input":[{"content":[{"text":"hi","type":"input_text"}],"role":"user"}]}`,
	"anthropic":         `{"max_tokens":128000,"model":"claude-opus-5-5","output_config":{"effort":"high"},"stream":true,"system":[{"cache_control":{"type":"ephemeral"},"text":"policy","type":"text"}],"thinking":{"type":"adaptive"},"tool_choice":{"type":"auto"},"tools":[{"cache_control":{"type":"ephemeral"},"description":"d","input_schema":{"type":"object"},"name":"read_file"}],"messages":[{"content":[{"cache_control":{"type":"ephemeral"},"text":"hi","type":"text"}],"role":"user"}]}`,
	"anthropic-profile": `{"max_tokens":128000,"model":"claude-sonnet-5-5","output_config":{"effort":"high"},"stream":true,"system":[{"cache_control":{"type":"ephemeral"},"text":"policy","type":"text"}],"thinking":{"type":"adaptive"},"tool_choice":{"type":"auto"},"tools":[{"cache_control":{"type":"ephemeral"},"description":"d","input_schema":{"type":"object"},"name":"read_file"}],"messages":[{"content":[{"cache_control":{"type":"ephemeral"},"text":"hi","type":"text"}],"role":"user"}]}`,
	"opencode-go":       `{"model":"kimi-k3","reasoning_effort":"high","store":false,"stream":false,"tool_choice":"auto","tools":[{"function":{"description":"d","name":"read_file","parameters":{"type":"object"}},"type":"function"}],"messages":[{"content":"policy","role":"system"},{"content":[{"text":"hi","type":"text"}],"role":"user"}]}`,
	"openai-compatible": `{"model":"m","store":false,"stream":false,"tool_choice":"auto","tools":[{"function":{"description":"d","name":"read_file","parameters":{"type":"object"}},"type":"function"}],"messages":[{"content":"policy","role":"system"},{"content":[{"text":"hi","type":"text"}],"role":"user"}]}`,
}

func TestDefaultRequestBodies(t *testing.T) {
	for _, c := range baselineRoles {
		got := baselineBody(t, c.role)
		if got != baselineBodies[c.name] {
			t.Errorf("%s: default body changed\n got %s\nwant %s", c.name, got, baselineBodies[c.name])
		}
	}
}

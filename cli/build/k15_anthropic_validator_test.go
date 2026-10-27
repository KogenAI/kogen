package build

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"kogen/project"
)

var k15Role = project.Role{Provider: "anthropic", Model: "claude-sonnet-5-5", Effort: "high"}

// k15Validate checks a rendered Anthropic Messages body the way the real API does and returns
// an invalid_request_error message for the first violation, or "" when the body is valid.
func k15Validate(body map[string]any) string {
	raw, _ := json.Marshal(body)
	var b map[string]any
	_ = json.Unmarshal(raw, &b)
	messages, _ := b["messages"].([]any)
	if len(messages) == 0 {
		return "messages: at least one message is required"
	}
	if cacheMarks(b["tools"])+cacheMarks(b["system"])+cacheMarks(b["messages"]) > 4 {
		return "A maximum of 4 blocks with cache_control may be provided"
	}
	_, thinking := b["thinking"].(map[string]any)
	if thinking && b["thinking"].(map[string]any)["type"] == "disabled" {
		thinking = false
	}
	seen := map[string]bool{}
	for i, m := range messages {
		msg, _ := m.(map[string]any)
		role, _ := msg["role"].(string)
		if role != "user" && role != "assistant" {
			return fmt.Sprintf("messages[%d].role: must be user or assistant", i)
		}
		if i == 0 && role != "user" {
			return "messages: first message must use the user role"
		}
		blocks := k15Blocks(msg["content"])
		if len(blocks) == 0 {
			return fmt.Sprintf("messages[%d]: content must not be empty", i)
		}
		for j, bl := range blocks {
			if bl["type"] == "text" {
				if s, _ := bl["text"].(string); s == "" {
					return fmt.Sprintf("messages[%d].content[%d].text: text content blocks must be non-empty", i, j)
				}
			}
		}
		var uses []string
		for _, bl := range blocks {
			if bl["type"] == "tool_use" {
				id, _ := bl["id"].(string)
				if seen[id] {
					return "tool_use ids must be unique: " + id
				}
				seen[id] = true
				uses = append(uses, id)
			}
		}
		if role == "assistant" && len(uses) > 0 && thinking {
			// A first thinking block, when present, must be signed; its absence is valid.
			first := blocks[0]
			switch first["type"] {
			case "thinking":
				if s, _ := first["signature"].(string); s == "" {
					return fmt.Sprintf("messages[%d].content[0].thinking.signature: Field required", i)
				}
			case "redacted_thinking":
				if s, _ := first["data"].(string); s == "" {
					return fmt.Sprintf("messages[%d].content[0].redacted_thinking.data: Field required", i)
				}
			}
		}
		// tool_result blocks first, each answering a tool_use of the preceding assistant message.
		var results []string
		for j, bl := range blocks {
			if bl["type"] != "tool_result" {
				continue
			}
			if j != len(results) {
				return fmt.Sprintf("messages[%d]: tool_result blocks must come first in the user message", i)
			}
			id, _ := bl["tool_use_id"].(string)
			results = append(results, id)
		}
		var prev []string
		if i > 0 {
			pm, _ := messages[i-1].(map[string]any)
			if pm["role"] == "assistant" {
				for _, bl := range k15Blocks(pm["content"]) {
					if bl["type"] == "tool_use" {
						id, _ := bl["id"].(string)
						prev = append(prev, id)
					}
				}
			}
		}
		for _, id := range results {
			if !contains1(prev, id) {
				return fmt.Sprintf("messages[%d]: unexpected `tool_use_id` found in `tool_result` blocks: %s. Each `tool_result` block must have a corresponding `tool_use` block in the previous message", i, id)
			}
		}
		if i > 0 && len(prev) > 0 && role == "user" {
			for _, id := range prev {
				if !contains1(results, id) {
					return fmt.Sprintf("messages[%d]: `tool_use` ids were found without `tool_result` blocks immediately after: %s", i, id)
				}
			}
		}
		if len(uses) > 0 && i == len(messages)-1 {
			return "messages: `tool_use` ids were found without `tool_result` blocks immediately after: " + uses[0]
		}
		if len(uses) > 0 && i+1 < len(messages) {
			next, _ := messages[i+1].(map[string]any)
			if next["role"] != "user" {
				return fmt.Sprintf("messages[%d]: `tool_use` ids were found without `tool_result` blocks immediately after", i)
			}
		}
	}
	if last, _ := messages[len(messages)-1].(map[string]any); last["role"] != "user" {
		return "messages: the last message must use the user role"
	}
	return ""
}

func contains1(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func k15Blocks(content any) []map[string]any {
	if s, ok := content.(string); ok {
		if s == "" {
			return nil
		}
		return []map[string]any{{"type": "text", "text": s}}
	}
	var out []map[string]any
	list, _ := content.([]any)
	for _, x := range list {
		if m, ok := x.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out
}

// cacheMarks counts cache_control breakpoints anywhere below v.
func cacheMarks(v any) int {
	n := 0
	switch x := v.(type) {
	case map[string]any:
		if _, ok := x["cache_control"]; ok {
			n++
		}
		for _, c := range x {
			n += cacheMarks(c)
		}
	case []any:
		for _, c := range x {
			n += cacheMarks(c)
		}
	}
	return n
}

// k15Exchange is an Anthropic-shaped assistant turn: the provider's message item with a signed
// thinking block and tool_use blocks, the replayed function_call items and their outputs.
func k15Exchange(tag string, calls int, outputBytes int) (items []any, outputs []any) {
	blocks := []any{map[string]any{"type": "thinking", "thinking": "plan " + tag, "signature": "sig-" + tag}}
	var fcs []any
	for i := 0; i < calls; i++ {
		id := fmt.Sprintf("toolu_%s_%d", tag, i)
		blocks = append(blocks, map[string]any{"type": "tool_use", "id": id, "name": "read_file", "input": map[string]any{"path": "app.txt"}})
		fcs = append(fcs, map[string]any{"type": "function_call", "call_id": id, "name": "read_file", "arguments": `{"path":"app.txt"}`})
		outputs = append(outputs, map[string]any{"type": "function_call_output", "call_id": id, "output": strings.Repeat("o", outputBytes)})
	}
	items = append(items, map[string]any{"type": "message", "role": "assistant",
		"content":           []any{map[string]any{"type": "output_text", "text": "working " + tag}},
		"anthropic_message": map[string]any{"role": "assistant", "content": blocks}})
	items = append(items, fcs...)
	return items, outputs
}

func k15Conversation(batches [][2]int) []any {
	input := []any{map[string]any{"role": "user", "content": "exact approved authority"}}
	for i, bt := range batches {
		items, outputs := k15Exchange(fmt.Sprint(i), bt[0], bt[1])
		input = append(input, items...)
		input = append(input, outputs...)
	}
	return input
}

func TestK15ValidatorAcceptsValidAndRejectsInvalidShapes(t *testing.T) {
	b, _, _ := windowAttempt(t)
	items, outputs := k15Exchange("a", 3, 10)
	good := append(append([]any{map[string]any{"role": "user", "content": "go"}}, items...), outputs...)
	render := func(in []any) map[string]any { return b.bodyOf(k15Role, "policy", in, nil, "review") }
	if msg := k15Validate(render(good)); msg != "" {
		t.Fatalf("valid request rejected: %s", msg)
	}
	edit := func(f func(msgs []any)) map[string]any {
		body := render(good)
		raw, _ := json.Marshal(body)
		var c map[string]any
		_ = json.Unmarshal(raw, &c)
		f(c["messages"].([]any))
		return c
	}
	assistant := func(m []any) map[string]any { return m[1].(map[string]any) }
	results := func(m []any) map[string]any { return m[2].(map[string]any) }
	cases := map[string]struct {
		body map[string]any
		want string
	}{
		"orphan tool_result": {render(append([]any{good[0]}, outputs...)), "tool_result"},
		"missing tool_result": {edit(func(m []any) {
			r := results(m)
			r["content"] = r["content"].([]any)[:2]
		}), "without `tool_result`"},
		"unknown id": {edit(func(m []any) {
			results(m)["content"].([]any)[0].(map[string]any)["tool_use_id"] = "nope"
		}), "unexpected `tool_use_id`"},
		"result not first": {edit(func(m []any) {
			r := results(m)
			c := r["content"].([]any)
			r["content"] = append([]any{map[string]any{"type": "text", "text": "x"}}, c...)
		}), "must come first"},
		"assistant first": {edit(func(m []any) { m[0].(map[string]any)["role"] = "assistant" }), "first message"},
		"empty text":      {edit(func(m []any) { m[0].(map[string]any)["content"] = []any{map[string]any{"type": "text", "text": ""}} }), "non-empty"},
		"last assistant":  {edit(func(m []any) {}), ""},
		"too many breakpoints": {edit(func(m []any) {
			for _, i := range []int{1, 2} {
				blocks := m[i].(map[string]any)["content"].([]any)
				for _, bl := range blocks {
					bl.(map[string]any)["cache_control"] = map[string]any{"type": "ephemeral"}
				}
			}
		}), "cache_control"},
		"unsigned thinking": {edit(func(m []any) {
			assistant(m)["content"].([]any)[0].(map[string]any)["signature"] = ""
		}), "signature"},
		"duplicate ids": {edit(func(m []any) {
			c := assistant(m)["content"].([]any)
			c[2].(map[string]any)["id"] = c[1].(map[string]any)["id"]
		}), "unique"},
	}
	delete(cases, "last assistant")
	for name, c := range cases {
		msg := k15Validate(c.body)
		if msg == "" || !strings.Contains(msg, c.want) {
			t.Errorf("%s: message %q lacks %q", name, msg, c.want)
		}
	}
	trailing := edit(func(m []any) {})
	trailing["messages"] = trailing["messages"].([]any)[:2]
	if msg := k15Validate(trailing); !strings.Contains(msg, "tool_result") {
		t.Errorf("dangling tool_use: %q", msg)
	}
	trailing["messages"] = append(trailing["messages"].([]any)[:1], map[string]any{"role": "assistant", "content": "text"})
	if msg := k15Validate(trailing); !strings.Contains(msg, "last message") {
		t.Errorf("last assistant: %q", msg)
	}
}

// k15Reset renders the review request after prepareContext reset the working window.
func k15Reset(t *testing.T, batches [][2]int) ([]any, map[string]any) {
	t.Helper()
	b, _, _ := windowAttempt(t)
	input := k15Conversation(batches)
	got, err := b.prepareContext("review", k15Role, "policy", input, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) >= len(input) {
		t.Fatalf("no reset happened: %d >= %d", len(got), len(input))
	}
	return got, b.bodyOf(k15Role, "policy", got, nil, "review")
}

func TestK15ReviewResetThenContinueIsValidForAnthropic(t *testing.T) {
	for name, batches := range map[string][][2]int{
		"older batch of 30":  {{30, 20_000}, {2, 10_000}},
		"newest batch of 30": {{2, 300_000}, {30, 10_000}},
	} {
		t.Run(name, func(t *testing.T) {
			_, body := k15Reset(t, batches)
			if msg := k15Validate(body); msg != "" {
				t.Fatalf("post-reset request invalid: %s", msg)
			}
			// The retained newest exchange must still be sent: the last message answers all its calls.
			msgs := body["messages"].([]any)
			raw, _ := json.Marshal(msgs[len(msgs)-1])
			var last map[string]any
			_ = json.Unmarshal(raw, &last)
			want := batches[len(batches)-1][0]
			if n := strings.Count(string(raw), `"tool_result"`); n != want {
				t.Fatalf("post-reset request lost the newest exchange: %d tool_result blocks, want %d: %v", n, want, last["role"])
			}
		})
	}
}

func TestK15OldPostResetShapeIsRejected(t *testing.T) {
	got, _ := k15Reset(t, [][2]int{{2, 300_000}, {30, 10_000}})
	b, _, _ := windowAttempt(t)
	// The old window kept the newest function_call_output items and dropped the assistant message.
	var old []any
	for _, it := range got {
		if m, _ := it.(map[string]any); m["anthropic_message"] != nil || m["type"] == "function_call" {
			continue
		}
		old = append(old, it)
	}
	msg := k15Validate(b.bodyOf(k15Role, "policy", old, nil, "review"))
	if !strings.Contains(msg, "`tool_use_id`") || !strings.Contains(msg, "previous message") {
		t.Fatalf("old shape not rejected by the pairing rule: %q", msg)
	}
}

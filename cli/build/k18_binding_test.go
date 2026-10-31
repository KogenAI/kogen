package build

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"kogen/thinking"
)

// k18Canonical is the canonical JSON of v with every cache_control key removed.
func k18Canonical(v any) string {
	raw, _ := json.Marshal(v)
	var c any
	_ = json.Unmarshal(raw, &c)
	var strip func(any) any
	strip = func(x any) any {
		switch t := x.(type) {
		case map[string]any:
			delete(t, "cache_control")
			for k, c := range t {
				t[k] = strip(c)
			}
		case []any:
			for i, c := range t {
				t[i] = strip(c)
			}
		}
		return x
	}
	out, _ := json.Marshal(strip(c))
	return string(out)
}

// k18Sign is the signature issued to a message produced in the request body at message index i:
// it encodes a hash of system, tools and messages[:i].
func k18Sign(body map[string]any, i int) string {
	raw, _ := json.Marshal(body)
	var b map[string]any
	_ = json.Unmarshal(raw, &b)
	messages, _ := b["messages"].([]any)
	if i > len(messages) {
		i = len(messages)
	}
	for _, m := range messages {
		if msg, _ := m.(map[string]any); msg != nil {
			if text, ok := msg["content"].(string); ok {
				msg["content"] = []any{map[string]any{"type": "text", "text": text}}
			}
		}
	}
	sum := sha256.Sum256([]byte(k18Canonical(map[string]any{"system": b["system"], "tools": b["tools"], "messages": messages[:i]})))
	return "sig-" + hex.EncodeToString(sum[:])
}

const k18BindingMessage = "Invalid signature in thinking block. The block is bound to a different conversation. Remove the block, or set thinking.block_binding.prefix_mismatch_behavior to \"drop_block\" (needs anthropic-beta thinking-binding-controls-2026-08-01)"

// k18Validate is the K15 validator plus the prefix binding of thinking and redacted_thinking blocks.
func k18Validate(body map[string]any) string {
	if msg := k15Validate(body); msg != "" {
		return msg
	}
	raw, _ := json.Marshal(body)
	var b map[string]any
	_ = json.Unmarshal(raw, &b)
	for i, m := range b["messages"].([]any) {
		msg, _ := m.(map[string]any)
		if msg["role"] != "assistant" {
			continue
		}
		for j, bl := range k15Blocks(msg["content"]) {
			field := ""
			switch bl["type"] {
			case "thinking":
				field = "signature"
			case "redacted_thinking":
				field = "data"
			default:
				continue
			}
			if s, _ := bl[field].(string); s != "" && s != k18Sign(body, i) {
				return fmt.Sprintf("messages.%d.content.%d: %s", i, j, k18BindingMessage)
			}
		}
	}
	return ""
}

// k18Extend appends one exchange (signed assistant message with calls tool_use blocks, the
// calls and their outputs) to input; the signature is issued against the body that input renders.
func k18Extend(b *Attempt, owner string, input []any, tag string, calls, outputBytes int) []any {
	body := b.bodyOf(k15Role, "policy", input, nil, owner)
	sig := k18Sign(body, len(body["messages"].([]any)))
	items, outputs := k15Exchange(tag, calls, outputBytes)
	blocks := items[0].(map[string]any)["anthropic_message"].(map[string]any)["content"].([]any)
	blocks[0].(map[string]any)["signature"] = sig
	out := append(append([]any{}, input...), items...)
	return append(out, outputs...)
}

func k18Conversation(b *Attempt, owner string, batches [][2]int) []any {
	input := []any{map[string]any{"role": "user", "content": "exact approved authority"}}
	for i, bt := range batches {
		input = k18Extend(b, owner, input, fmt.Sprint(i), bt[0], bt[1])
	}
	return input
}

func k18Json(v any) string { raw, _ := json.Marshal(v); return string(raw) }

func TestK18BindingFakeRejectsForeignSignatures(t *testing.T) {
	t.Parallel()
	b, _, _ := windowAttempt(t)
	good := k18Conversation(b, "review", [][2]int{{2, 10}})
	if msg := k18Validate(b.bodyOf(k15Role, "policy", good, nil, "review")); msg != "" {
		t.Fatalf("own-prefix signature rejected: %s", msg)
	}
	// A different prefix (an extra opening message) makes the signature foreign.
	moved := append([]any{good[0], map[string]any{"role": "user", "content": "other prefix"}}, good[1:]...)
	want := "messages.2.content.0: " + k18BindingMessage
	if msg := k18Validate(b.bodyOf(k15Role, "policy", moved, nil, "review")); msg != want {
		t.Fatalf("got %q want %q", msg, want)
	}
	redacted := k18Conversation(b, "review", nil)
	redacted = append(redacted, good[1:]...)
	blocks := redacted[1].(map[string]any)["anthropic_message"].(map[string]any)["content"].([]any)
	blocks[0] = map[string]any{"type": "redacted_thinking", "data": "foreign"}
	if msg := k18Validate(b.bodyOf(k15Role, "policy", redacted, nil, "review")); msg != "messages.1.content.0: "+k18BindingMessage {
		t.Fatalf("redacted: %q", msg)
	}
}

func k18ResetCase(t *testing.T, owner string, batches [][2]int) {
	b, _, _ := windowAttempt(t)
	input := k18Conversation(b, owner, batches)
	if msg := k18Validate(b.bodyOf(k15Role, "policy", input[:len(input)], nil, owner)); msg != "" {
		t.Fatalf("fixture invalid: %s", msg)
	}
	got, err := b.prepareContext(owner, k15Role, "policy", input, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) >= len(input) {
		t.Fatalf("no reset: %d >= %d", len(got), len(input))
	}
	if msg := k18Validate(b.bodyOf(k15Role, "policy", got, nil, owner)); msg != "" {
		t.Fatalf("stripped window rejected: %s", msg)
	}
	newest := newestExchange(input)
	old := append(append([]any{}, got[:len(got)-len(newest)]...), newest...)
	if msg := k18Validate(b.bodyOf(k15Role, "policy", old, nil, owner)); !strings.Contains(msg, k18BindingMessage) {
		t.Fatalf("unstripped window not rejected with the binding message: %q", msg)
	}
}

func TestK18ReviewResetContinuesWithoutStaleThinking(t *testing.T) {
	t.Parallel()
	k18ResetCase(t, "review", [][2]int{{2, 300_000}, {2, 10_000}})
	k18ResetCase(t, "review", [][2]int{{2, 300_000}, {30, 10_000}})
}

func TestK18BuildResetContinuesWithoutStaleThinking(t *testing.T) {
	t.Parallel()
	k18ResetCase(t, "build", [][2]int{{2, 300_000}, {2, 10_000}})
}

func TestK18ResetStripsOnlyThinkingAndKeepsNewConversationBlocks(t *testing.T) {
	t.Parallel()
	b, _, _ := windowAttempt(t)
	input := k18Conversation(b, "review", [][2]int{{2, 300_000}, {3, 10_000}})
	before := k18Json(input)
	got, err := b.prepareContext("review", k15Role, "policy", input, nil)
	if err != nil {
		t.Fatal(err)
	}
	if k18Json(input) != before {
		t.Fatal("caller input mutated")
	}
	newest := newestExchange(input)
	kept := got[len(got)-len(newest):]
	orig := newest[0].(map[string]any)["anthropic_message"].(map[string]any)["content"].([]any)
	have := kept[0].(map[string]any)["anthropic_message"].(map[string]any)["content"].([]any)
	if k18Json(have) != k18Json(orig[1:]) {
		t.Fatalf("kept blocks differ: %s", k18Json(have))
	}
	if k18Json(kept[1:]) != k18Json(newest[1:]) {
		t.Fatal("function_call items changed")
	}
	// A message holding only thinking is sent without anthropic_message.
	only := []any{map[string]any{"type": "message", "role": "assistant", "content": "x",
		"anthropic_message": map[string]any{"role": "assistant", "content": []any{map[string]any{"type": "redacted_thinking", "data": "d"}}}}}
	if m := thinking.Strip(only)[0].(map[string]any); m["anthropic_message"] != nil || m["content"] != "x" {
		t.Fatalf("thinking-only message: %v", m)
	}
	// Messages produced after the reset keep their thinking; a later reset strips them again.
	next := k18Extend(b, "review", got, "post", 2, 250_000)
	post := next[len(got)].(map[string]any)["anthropic_message"].(map[string]any)["content"].([]any)
	if post[0].(map[string]any)["type"] != "thinking" {
		t.Fatal("post-reset message lost thinking")
	}
	if msg := k18Validate(b.bodyOf(k15Role, "policy", next, nil, "review")); msg != "" {
		t.Fatalf("post-reset request rejected: %s", msg)
	}
	again, err := b.prepareContext("review", k15Role, "policy", next, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(again) >= len(next) {
		t.Fatal("no second reset")
	}
	if strings.Contains(k18Json(again), `"thinking"`) && strings.Contains(k18Json(again[len(again)-len(newestExchange(next)):]), `"type":"thinking"`) {
		t.Fatal("second reset kept thinking")
	}
	if msg := k18Validate(b.bodyOf(k15Role, "policy", again, nil, "review")); msg != "" {
		t.Fatalf("second window rejected: %s", msg)
	}
}

func TestK18RequestWithoutResetIsByteIdentical(t *testing.T) {
	t.Parallel()
	for _, owner := range []string{"review", "build"} {
		b, _, _ := windowAttempt(t)
		input := k18Conversation(b, owner, [][2]int{{2, 10}, {2, 10}})
		want := k18Json(b.bodyOf(k15Role, "policy", input, nil, owner))
		got, err := b.prepareContext(owner, k15Role, "policy", input, nil)
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(got, input) || k18Json(b.bodyOf(k15Role, "policy", got, nil, owner)) != want {
			t.Fatalf("%s: request changed without a reset", owner)
		}
	}
}

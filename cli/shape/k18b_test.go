package shape

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"kogen-loop/provider"
)

// The binding-aware Anthropic fake of K18, for Shape and Refine requests.

func k18bCanonical(v any) string {
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

func k18bSign(body map[string]any, i int) string {
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
	sum := sha256.Sum256([]byte(k18bCanonical(map[string]any{"system": b["system"], "tools": b["tools"], "messages": messages[:i]})))
	return "sig-" + hex.EncodeToString(sum[:])
}

const k18bBindingMessage = "Invalid signature in thinking block. The block is bound to a different conversation. Remove the block, or set thinking.block_binding.prefix_mismatch_behavior to \"drop_block\" (needs anthropic-beta thinking-binding-controls-2026-08-01)"

func k18bValidate(body map[string]any) string {
	raw, _ := json.Marshal(body)
	var b map[string]any
	_ = json.Unmarshal(raw, &b)
	messages, _ := b["messages"].([]any)
	for i, m := range messages {
		msg, _ := m.(map[string]any)
		if msg["role"] != "assistant" {
			continue
		}
		blocks, _ := msg["content"].([]any)
		for j, raw := range blocks {
			bl, _ := raw.(map[string]any)
			field := ""
			switch bl["type"] {
			case "thinking":
				field = "signature"
			case "redacted_thinking":
				field = "data"
			default:
				continue
			}
			if s, _ := bl[field].(string); s != "" && s != k18bSign(body, i) {
				return fmt.Sprintf("messages.%d.content.%d: %s", i, j, k18bBindingMessage)
			}
		}
	}
	return ""
}

var k18bRole = provider.Role{Provider: "anthropic", Model: "claude-sonnet-5-5", Effort: "medium"}

func k18bRender(client *provider.Client) func([]any) map[string]any {
	return func(items []any) map[string]any {
		return client.Body(provider.Request{Role: k18bRole, Instructions: "policy", Input: items})
	}
}

// k18bExchange is one signed assistant message with calls tool_use blocks, the calls and outputs.
func k18bExchange(tag string, sig string, calls, outputBytes int) []any {
	blocks := []any{map[string]any{"type": "thinking", "thinking": "plan " + tag, "signature": sig}}
	var fcs, outs []any
	for i := 0; i < calls; i++ {
		id := fmt.Sprintf("toolu_%s_%d", tag, i)
		blocks = append(blocks, map[string]any{"type": "tool_use", "id": id, "name": "read_file", "input": map[string]any{"path": "app.txt"}})
		fcs = append(fcs, map[string]any{"type": "function_call", "call_id": id, "name": "read_file", "arguments": `{"path":"app.txt"}`})
		outs = append(outs, map[string]any{"type": "function_call_output", "call_id": id, "output": strings.Repeat("o", outputBytes)})
	}
	items := []any{map[string]any{"type": "message", "role": "assistant",
		"content":           []any{map[string]any{"type": "output_text", "text": "working " + tag}},
		"anthropic_message": map[string]any{"role": "assistant", "content": blocks}}}
	return append(append(items, fcs...), outs...)
}

func k18bConversation(render func([]any) map[string]any, batches [][2]int) []any {
	input := []any{map[string]any{"role": "user", "content": "exact request"}}
	for i, bt := range batches {
		body := render(input)
		sig := k18bSign(body, len(body["messages"].([]any)))
		input = append(append([]any{}, input...), k18bExchange(fmt.Sprint(i), sig, bt[0], bt[1])...)
	}
	return input
}

func k18bJSON(v any) string { raw, _ := json.Marshal(v); return string(raw) }

func k18bResetCase(t *testing.T, owner string) {
	t.Helper()
	root := t.TempDir()
	client := provider.NewClient("")
	render := k18bRender(client)
	input := k18bConversation(render, [][2]int{{2, 300_000}, {3, 10_000}})
	if msg := k18bValidate(render(input)); msg != "" {
		t.Fatalf("fixture invalid: %s", msg)
	}
	dir := root
	var w *window
	if owner == "refine" {
		dir = filepath.Join(root, ".kogen/local/refinements/abc")
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		w = newRefineWindow(dir, input[:1])
	} else {
		w = newShapeWindow(root, "fixture", input[:1])
	}
	ev, err := NewEvidence(dir, "fixture")
	if err != nil {
		t.Fatal(err)
	}
	before := k18bJSON(input)
	got, err := w.prepare(windowPrep{
		role: k18bRole, root: root, ev: ev, progress: func(string) {}, render: render,
		state: func(windowRef, int, map[string]any, []any) map[string]any { return map[string]any{} },
	}, input)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) >= len(input) {
		t.Fatalf("no reset: %d >= %d", len(got), len(input))
	}
	if msg := k18bValidate(render(got)); msg != "" {
		t.Fatalf("reduced request rejected: %s", msg)
	}
	newest := newestWindowExchange(input)
	if len(newest) != 1+3+3 {
		t.Fatalf("newest exchange has %d items", len(newest))
	}
	control := append(append([]any{}, got[:len(got)-len(newest)]...), newest...)
	if msg := k18bValidate(render(control)); !strings.Contains(msg, k18bBindingMessage) {
		t.Fatalf("unstripped window not rejected with the binding message: %q", msg)
	}
	if k18bJSON(input) != before {
		t.Fatal("caller input mutated")
	}
	archived := decodeFile(t, filepath.Join(w.dir, "1.json"))
	if k18bJSON(archived["input"]) != before {
		t.Fatal("archive does not hold the original unstripped input")
	}
}

func TestK18bShapeResetContinuesWithoutStaleThinking(t *testing.T) {
	parallel(t)
	k18bResetCase(t, "shape")
}

func TestK18bRefineResetContinuesWithoutStaleThinking(t *testing.T) {
	parallel(t)
	k18bResetCase(t, "refine")
}

func TestK18bShapeAndRefineRequestWithoutResetIsByteIdentical(t *testing.T) {
	parallel(t)
	for _, owner := range []string{"shape", "refine"} {
		root := t.TempDir()
		client := provider.NewClient("")
		render := k18bRender(client)
		input := k18bConversation(render, [][2]int{{2, 10}, {2, 10}})
		dir := root
		var w *window
		if owner == "refine" {
			dir = filepath.Join(root, "evidence")
			if err := os.MkdirAll(dir, 0o700); err != nil {
				t.Fatal(err)
			}
			w = newRefineWindow(dir, input[:1])
		} else {
			w = newShapeWindow(root, "fixture", input[:1])
		}
		ev, err := NewEvidence(dir, "fixture")
		if err != nil {
			t.Fatal(err)
		}
		want := k18bJSON(render(input))
		got, err := w.prepare(windowPrep{
			role: k18bRole, root: root, ev: ev, progress: func(string) {}, render: render,
			state: func(windowRef, int, map[string]any, []any) map[string]any { return map[string]any{} },
		}, input)
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(got, input) || k18bJSON(render(got)) != want {
			t.Fatalf("%s: request changed without a reset", owner)
		}
	}
}

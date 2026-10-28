package thinking

import (
	"encoding/json"
	"reflect"
	"testing"
)

func js(v any) string { raw, _ := json.Marshal(v); return string(raw) }

func TestStripThinkingKeepsOtherBlocksAndDoesNotMutate(t *testing.T) {
	text := map[string]any{"type": "text", "text": "hi"}
	use := map[string]any{"type": "tool_use", "id": "t1", "name": "read_file", "input": map[string]any{"path": "a"}}
	mixed := map[string]any{"type": "message", "role": "assistant", "content": "c",
		"anthropic_message": map[string]any{"role": "assistant", "content": []any{
			map[string]any{"type": "thinking", "thinking": "p", "signature": "s"},
			text,
			map[string]any{"type": "redacted_thinking", "data": "d"},
			use,
		}}}
	only := map[string]any{"type": "message", "role": "assistant", "content": "x",
		"anthropic_message": map[string]any{"role": "assistant", "content": []any{map[string]any{"type": "redacted_thinking", "data": "d"}}}}
	plain := map[string]any{"role": "user", "content": "u"}
	call := map[string]any{"type": "function_call", "call_id": "t1", "name": "read_file", "arguments": "{}"}
	items := []any{plain, mixed, only, call}
	before := js(items)

	got := Strip(items)
	if js(items) != before {
		t.Fatal("input mutated")
	}
	if len(got) != 4 || !reflect.DeepEqual(got[0], plain) || !reflect.DeepEqual(got[3], call) {
		t.Fatalf("untouched items changed: %s", js(got))
	}
	blocks := got[1].(map[string]any)["anthropic_message"].(map[string]any)["content"].([]any)
	if js(blocks) != js([]any{text, use}) {
		t.Fatalf("kept blocks: %s", js(blocks))
	}
	if m := got[2].(map[string]any); m["anthropic_message"] != nil || m["content"] != "x" {
		t.Fatalf("thinking-only message: %v", m)
	}
}

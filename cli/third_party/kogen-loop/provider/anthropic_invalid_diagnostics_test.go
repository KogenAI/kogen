package provider

import (
	"reflect"
	"testing"
)

func TestAnthropicInvalidDiagnostics(t *testing.T) {
	base := one(start())
	cases := []struct {
		name   string
		stream string
		want   map[string]any
	}{
		{"error", sse(ev("error", "error", map[string]any{"type": "invalid_request_error", "message": "secret"})), map[string]any{"anthropic_invalid": "sse_error", "error_type": "invalid_request_error"}},
		{"unknown", sse(ev("error", "error", map[string]any{"type": "secret"})), map[string]any{"anthropic_invalid": "sse_error", "error_type": "unknown"}},
		{"frame", sse(start()) + "data: {broken\n\n" + sse(finish("end_turn")...), map[string]any{"anthropic_invalid": "frame_json_or_shape"}},
		{"ordering", sse(ev("message_stop")), map[string]any{"anthropic_invalid": "ordering_or_shape"}},
		{"usage", sse(ev("message_start", "message", map[string]any{"usage": 42})), map[string]any{"anthropic_invalid": "invalid_usage_shape"}},
		{"stop", sse(flat(base, finish("max_tokens"))...), map[string]any{"anthropic_invalid": "non_success_stop", "stop_reason": "max_tokens"}},
		{"empty", sse(flat(base, finish("end_turn"))...), map[string]any{"anthropic_invalid": "empty_result", "stop_reason": "end_turn"}},
		{"changed", sse(flat(base, one(ev("message_delta", "delta", map[string]any{"stop_reason": "end_turn"})), finish("tool_use"))...), map[string]any{"anthropic_invalid": "changed_stop_reason", "stop_reason": "tool_use"}},
		{"after", sse(flat(base, finish("end_turn"), one(ev("message_stop")))...), map[string]any{"anthropic_invalid": "event_after_stop"}},
		{"block", sse(flat(base, block(0, map[string]any{"type": "server_tool_use"}), finish("end_turn"))...), map[string]any{"anthropic_invalid": "unsupported_block", "block_type": "server_tool_use"}},
		{"invalid block", sse(flat(base, block(0, map[string]any{"type": "thinking", "thinking": "private"}), finish("end_turn"))...), map[string]any{"anthropic_invalid": "invalid_block", "block_type": "thinking"}},
		{"duplicate", sse(flat(base, block(0, use("a")), block(1, use("a")), finish("tool_use"))...), map[string]any{"anthropic_invalid": "duplicate_tool_id"}},
		{"delta", sse(flat(base, one(ev("content_block_start", "index", int64(0), "content_block", map[string]any{"type": "text", "text": ""})), one(ev("content_block_delta", "index", int64(0), "delta", map[string]any{"type": "citations_delta"})))...), map[string]any{"anthropic_invalid": "unsupported_delta", "delta_type": "citations_delta"}},
		{"tool json", sse(flat(base, one(ev("content_block_start", "index", int64(0), "content_block", use("a"))), one(ev("content_block_delta", "index", int64(0), "delta", map[string]any{"type": "input_json_delta", "partial_json": "{"})), one(ev("content_block_stop", "index", int64(0))))...), map[string]any{"anthropic_invalid": "tool_input_json"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := parseMessages(c.stream)
			if r.kind != resInvalid || !reflect.DeepEqual(r.diag, c.want) {
				t.Fatalf("%+v", r)
			}
		})
	}
}

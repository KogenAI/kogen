package tools

import (
	"reflect"
	"strings"
	"testing"
)

func TestReplayPreservesValidSupportedFieldsWithoutManufacturingAbsentLegacyValues(t *testing.T) {
	reasoning := map[string]any{"type": "reasoning", "id": "r", "encrypted_content": "opaque", "summary": []any{}, "output_only": true}
	if got := ReplayItem(reasoning); !reflect.DeepEqual(got, map[string]any{"type": "reasoning", "id": "r", "encrypted_content": "opaque", "summary": []any{}}) {
		t.Errorf("reasoning %v", got)
	}
	if got := ReplayItem(map[string]any{"type": "reasoning", "summary": []any{}}); !reflect.DeepEqual(got, map[string]any{"type": "reasoning", "summary": []any{}}) {
		t.Errorf("sparse reasoning %v", got)
	}
	message := map[string]any{
		"type": "message", "id": "m", "role": "assistant", "phase": "commentary",
		"content": []any{map[string]any{"type": "refusal", "refusal": "no"}},
	}
	if got := ReplayItem(message); !reflect.DeepEqual(got, message) {
		t.Errorf("message %v", got)
	}
	if got := ReplayItem(map[string]any{"type": "unknown"}); got != nil {
		t.Errorf("unknown type %v", got)
	}
	if got := ReplayItem(map[string]any{"type": "message", "content": []any{map[string]any{"type": "invalid"}}}); got != nil {
		t.Errorf("message without supported content %v", got)
	}
	call := map[string]any{"type": "function_call", "call_id": "c", "name": "tool", "arguments": "{}"}
	if got := ReplayItem(call); !reflect.DeepEqual(got, call) {
		t.Errorf("function call %v", got)
	}
}

func TestReplayFiltersMessageContentAndFunctionCallFields(t *testing.T) {
	message := map[string]any{
		"type": "message", "id": "m", "role": "assistant", "status": "completed", "annotations": []any{1},
		"content": []any{
			map[string]any{"type": "output_text", "text": "hello", "annotations": []any{}, "logprobs": []any{}},
			map[string]any{"type": "output_text", "text": 5},
			map[string]any{"type": "output_text"},
			map[string]any{"type": "refusal", "refusal": "no", "extra": 1},
			map[string]any{"type": "refusal", "refusal": nil},
			"not an object",
			map[string]any{"type": "other", "text": "x"},
		},
	}
	want := map[string]any{
		"type": "message", "id": "m", "role": "assistant", "status": "completed",
		"content": []any{
			map[string]any{"type": "output_text", "text": "hello"},
			map[string]any{"type": "refusal", "refusal": "no"},
		},
	}
	if got := ReplayItem(message); !reflect.DeepEqual(got, want) {
		t.Errorf("got %v\nwant %v", got, want)
	}
	for _, content := range []any{"text", nil, map[string]any{}, []any{}} {
		if got := ReplayItem(map[string]any{"type": "message", "content": content}); got != nil {
			t.Errorf("content %v replayed as %v", content, got)
		}
	}
	if got := ReplayItem(map[string]any{"type": "message"}); got != nil {
		t.Errorf("message without content: %v", got)
	}
	call := map[string]any{"type": "function_call", "id": "fc", "call_id": "c", "name": "n", "arguments": "{}", "status": "completed", "namespace": "x"}
	if got := ReplayItem(call); got["namespace"] != nil || len(got) != 6 {
		t.Errorf("function call %v", got)
	}
	// Replaying does not change the received item.
	if _, ok := message["annotations"]; !ok {
		t.Error("the received item was modified")
	}
	// An item without a type.
	if got := ReplayItem(map[string]any{}); got != nil {
		t.Errorf("typeless item %v", got)
	}
}

func TestDecodeArgumentsIsAnObjectOrTheInvalidMarker(t *testing.T) {
	invalid := map[string]any{"__invalid__": true}
	for _, text := range []string{"", "not json", "[1]", "null", `"a"`, "5", "true", `{"a":1} trailing`, `{"a":}`, `{"a":1,}`, "{", `{"a":"\ud800"}`, `{"a":1e999}`} {
		if got := DecodeArguments(text); !reflect.DeepEqual(got, invalid) {
			t.Errorf("%q decoded as %v", text, got)
		}
	}
	got := DecodeArguments(` {"path":"a.txt","start_line":2,"end_line":2.0,"flag":true,"none":null,"list":[1,"x"],"obj":{"k":"v"}} `)
	want := map[string]any{"path": "a.txt", "start_line": int64(2), "end_line": 2.0, "flag": true, "none": nil,
		"list": []any{int64(1), "x"}, "obj": map[string]any{"k": "v"}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %#v", got)
	}
	if got := DecodeArguments("{}"); len(got) != 0 {
		t.Errorf("{} decoded as %v", got)
	}
	if got := DecodeArguments(`{"a":1,"a":2}`); got["a"] != int64(1) {
		t.Errorf("a repeated key keeps its first value, got %v", got["a"])
	}
}

func TestCallsPairWithOutputsInOrder(t *testing.T) {
	items := []map[string]any{
		{"type": "reasoning", "id": "r1", "encrypted_content": "x", "summary": []any{}},
		{"type": "function_call", "id": "fc1", "call_id": "c1", "name": "read_file", "arguments": `{"path":"a"}`, "status": "completed"},
		{"type": "message", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": "thinking"}}},
		{"type": "function_call", "id": "fc2", "call_id": "c2", "name": "shell", "arguments": "oops"},
		{"type": "web_search_call", "id": "ws"},
	}
	var c Conversation
	c.Add(map[string]any{"role": "user", "content": "go"})
	calls := c.Receive(items)
	if len(calls) != 2 || calls[0].Name != "read_file" || calls[1].Name != "shell" || calls[1].CallID() != "c2" {
		t.Fatalf("calls %+v", calls)
	}
	if got := calls[0].Args(); got["path"] != "a" {
		t.Errorf("args %v", got)
	}
	if got := calls[1].Args(); got["__invalid__"] != true {
		t.Errorf("invalid args %v", got)
	}
	if !reflect.DeepEqual(c.Unanswered(), []string{"c1", "c2"}) {
		t.Errorf("unanswered %v", c.Unanswered())
	}
	c.Answer(calls[0], "1\tline")
	if !reflect.DeepEqual(c.Unanswered(), []string{"c2"}) {
		t.Errorf("unanswered %v", c.Unanswered())
	}
	c.Answer(calls[1], Output{Text: "exit status: 0\n"})
	if len(c.Unanswered()) != 0 {
		t.Errorf("unanswered %v", c.Unanswered())
	}

	var types []string
	for _, it := range c.Input {
		m, ok := it.(map[string]any)
		if !ok {
			t.Fatalf("input item %T", it)
		}
		if typ, ok := m["type"].(string); ok {
			types = append(types, typ)
		} else {
			types = append(types, "role:"+m["role"].(string))
		}
	}
	want := []string{"role:user", "reasoning", "function_call", "message", "function_call", "function_call_output", "function_call_output"}
	if !reflect.DeepEqual(types, want) {
		t.Errorf("input order %v, want %v", types, want)
	}
	last := c.Input[len(c.Input)-1].(map[string]any)
	if last["call_id"] != "c2" || last["output"] != "exit status: 0\n" {
		t.Errorf("last output %v", last)
	}
	// The replayed call carries only the replayable fields.
	replayed := c.Input[2].(map[string]any)
	if !reflect.DeepEqual(replayed, map[string]any{"type": "function_call", "id": "fc1", "call_id": "c1", "name": "read_file", "arguments": `{"path":"a"}`, "status": "completed"}) {
		t.Errorf("replayed call %v", replayed)
	}
}

func TestOutputItemCarriesTextOrTypedParts(t *testing.T) {
	parts := []any{map[string]any{"type": "input_text", "text": "{}"}, map[string]any{"type": "input_image", "image_url": "data:"}}
	for _, c := range []struct {
		result any
		want   any
	}{
		{"text", "text"},
		{Output{Text: "text"}, "text"},
		{Output{Parts: parts}, parts},
		{parts, parts},
	} {
		got := OutputItem("id", c.result)
		if !reflect.DeepEqual(got, map[string]any{"type": "function_call_output", "call_id": "id", "output": c.want}) {
			t.Errorf("%v: %v", c.result, got)
		}
	}
	// A call without a call_id is answered with a null one, as Kogen always has.
	got := Call{Item: map[string]any{"type": "function_call"}}.Output("x")
	if v, ok := got["call_id"]; !ok || v != nil {
		t.Errorf("call_id %v (present %v)", v, ok)
	}
}

func TestCallsTakeOnlyFunctionCallsAndTolerateMissingFields(t *testing.T) {
	calls := Calls([]map[string]any{
		{"type": "function_call"},
		{"type": "function_call", "name": 5, "arguments": 7},
		{"type": "message"},
	})
	if len(calls) != 2 || calls[0].Name != "" || calls[0].Arguments != "" || calls[1].Name != "" || calls[1].Arguments != "" {
		t.Errorf("calls %+v", calls)
	}
	if got := calls[0].Args(); got["__invalid__"] != true {
		t.Errorf("args of a call without arguments: %v", got)
	}
	if got := Calls(nil); got != nil {
		t.Errorf("no items: %v", got)
	}
}

func TestUnansweredMatchesByCallID(t *testing.T) {
	input := []any{
		"a plain string",
		map[string]any{"type": "function_call", "call_id": "a"},
		map[string]any{"type": "function_call_output", "call_id": "a", "output": "x"},
		map[string]any{"type": "function_call", "call_id": "b"},
		map[string]any{"type": "function_call_output", "call_id": "other", "output": "x"},
		map[string]any{"type": "function_call", "call_id": "c"},
	}
	if got := Unanswered(input); !reflect.DeepEqual(got, []string{"b", "c"}) {
		t.Errorf("unanswered %v", got)
	}
	if got := Unanswered(nil); got != nil {
		t.Errorf("empty input: %v", got)
	}
	_ = strings.TrimSpace
}

package build

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"kogen-loop/tools"
)

// A request body compared or hashed by these tests is first reduced to what Kogen owns: the
// instructions, roles, model, effort and input messages it builds, its own tool definitions and
// the tools it offers, in which order and with which tool choice. The pinned loop owns the
// definitions of the generic tools and the rest of the request envelope, so a stored golden
// holds neither: each generic definition becomes a placeholder naming the tool (its text is
// checked against tools.Definition when the test runs) and the fields the loop renders and
// Kogen does not set are dropped. The reduced request is encoded with sorted keys, so the key
// order of the wire is not pinned either.

// loopEnvelopeFields are the top-level request fields the loop renders and Kogen does not set.
var loopEnvelopeFields = []string{"include", "store", "stream", "max_tokens", "thinking"}

// loopToolDefinition is the name of the generic tool that x defines, when x is the definition
// of a tool the pinned loop supplies as any provider wire renders it.
func loopToolDefinition(x map[string]any) (string, bool) {
	name, _ := x["name"].(string)
	if x["parameters"] == nil && x["input_schema"] == nil {
		return "", false
	}
	_, loop := tools.Definition(name)
	return name, loop
}

// withoutLoopDefinitions replaces every generic tool definition in v with a placeholder and
// reports one that is not the pinned loop's.
func withoutLoopDefinitions(t *testing.T, v any) any {
	t.Helper()
	switch x := v.(type) {
	case map[string]any:
		if name, loop := loopToolDefinition(x); loop {
			pinned, _ := tools.Definition(name)
			if x["description"] != pinned["description"] {
				t.Errorf("the %s definition differs from the pinned loop's", name)
			}
			return map[string]any{"loop_tool_definition": name}
		}
		for k, e := range x {
			x[k] = withoutLoopDefinitions(t, e)
		}
	case []any:
		for i, e := range x {
			x[i] = withoutLoopDefinitions(t, e)
		}
	}
	return v
}

// kogenOwnedRequest is the request body wire reduced to what Kogen owns, as compact JSON with
// sorted keys.
func kogenOwnedRequest(t *testing.T, wire string) string {
	t.Helper()
	var v any
	dec := json.NewDecoder(strings.NewReader(wire))
	dec.UseNumber()
	if err := dec.Decode(&v); err != nil {
		t.Fatalf("request JSON: %v", err)
	}
	if body, ok := v.(map[string]any); ok {
		for _, k := range loopEnvelopeFields {
			delete(body, k)
		}
	}
	var out bytes.Buffer
	enc := json.NewEncoder(&out)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(withoutLoopDefinitions(t, v)); err != nil {
		t.Fatal(err)
	}
	return strings.TrimSuffix(out.String(), "\n")
}

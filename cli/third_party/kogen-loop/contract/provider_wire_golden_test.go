package contract_test

import (
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"sort"
	"testing"

	"github.com/KogenAI/kogen-loop/provider"
)

// Kogen's cli/research_removal_test.go and cli/testdata/loop_knobs_golden.json
// motivate owning these consumer request pins in loop. The inputs and recorded
// bodies come from loop's baseline_bodies_test.go and tool_choice_empty_golden.json;
// neither the Kogen checkout nor fixture generation is needed to run this test.
func TestProviderWireGoldens(t *testing.T) {
	data, err := os.ReadFile("testdata/loop_knobs_golden.json")
	if err != nil {
		t.Fatal(err)
	}
	var golden map[string]json.RawMessage
	if err := json.Unmarshal(data, &golden); err != nil {
		t.Fatal(err)
	}
	routes := []struct {
		name string
		role provider.Role
	}{
		{"chatgpt", provider.Role{Provider: "chatgpt", Model: "gpt-6.1-sol", Effort: "high"}},
		{"supergrok", provider.Role{Provider: "supergrok", Model: "grok-4.7", Effort: "low"}},
		{"anthropic", provider.Role{Provider: "anthropic", Model: "claude-opus-5-5", Effort: "high"}},
		{"anthropic-profile", provider.Role{Provider: "anthropic", Model: "claude-sonnet-5-5", Effort: "high"}},
		{"opencode-go", provider.Role{Provider: "opencode-go", Model: "kimi-k3", Effort: "high"}},
		{"openai-compatible", provider.Role{Provider: "openai-compatible", Model: "m", Effort: "default", BaseURL: "http://127.0.0.1:1/v1"}},
	}
	tool := func(name string) any {
		return map[string]any{"type": "function", "name": name, "description": "d", "parameters": map[string]any{"type": "object"}}
	}
	visited := map[string]bool{}
	for _, route := range routes {
		for _, variant := range []string{"baseline", "tools=false", "tools=true"} {
			key := "baseline/" + route.name
			role := route.role
			tools := []any{tool("read_file")}
			if variant != "baseline" {
				key = fmt.Sprintf("tools/%s/%s", route.name, variant)
				if route.name == "openai-compatible" {
					role.Model = "qwen3-coder:30b"
				}
				if variant == "tools=false" {
					tools = nil
				} else {
					tools = append(tools, tool("submit"))
				}
			}
			visited[key] = true
			t.Run(key, func(t *testing.T) {
				req := provider.Request{Role: role, Instructions: "policy", Input: []any{map[string]any{"role": "user", "content": []any{map[string]any{"type": "input_text", "text": "hi"}}}}, Tools: tools, CacheID: "fixed-cache-id"}
				body, err := provider.NewClient("").Render(req)
				if err != nil {
					t.Fatalf("render %s: %v", key, err)
				}
				gotBytes, err := json.Marshal(body)
				if err != nil {
					t.Fatalf("marshal %s: %v", key, err)
				}
				raw, ok := golden[key]
				if !ok {
					t.Fatalf("missing golden %s", key)
				}
				var got, want map[string]any
				if err := json.Unmarshal(gotBytes, &got); err != nil {
					t.Fatalf("decode actual %s: %v", key, err)
				}
				if err := json.Unmarshal(raw, &want); err != nil || want == nil {
					t.Fatalf("decode golden %s: %v", key, err)
				}
				if path, g, w, differs := firstDiff("$", got, want); differs {
					t.Errorf("%s body differs at %s: got %s, want %s", key, path, g, w)
				}
			})
		}
	}
	var stale []string
	for key := range golden {
		if !visited[key] {
			stale = append(stale, key)
		}
	}
	sort.Strings(stale)
	for _, key := range stale {
		t.Errorf("stale golden key %s is not visited by any route or variant", key)
	}
}

// firstDiff walks two decoded JSON values depth-first and returns the path of
// the first difference with both sides rendered compactly; a side that lacks
// the member or element renders as <missing>.
func firstDiff(path string, got, want any) (string, string, string, bool) {
	switch g := got.(type) {
	case map[string]any:
		if w, ok := want.(map[string]any); ok {
			names := make([]string, 0, len(g)+len(w))
			for name := range g {
				names = append(names, name)
			}
			for name := range w {
				if _, ok := g[name]; !ok {
					names = append(names, name)
				}
			}
			sort.Strings(names)
			for _, name := range names {
				gv, gok := g[name]
				wv, wok := w[name]
				if p, gs, ws, differs := firstDiffSides(path+"."+name, gv, gok, wv, wok); differs {
					return p, gs, ws, true
				}
			}
			return "", "", "", false
		}
	case []any:
		if w, ok := want.([]any); ok {
			for i := 0; i < max(len(g), len(w)); i++ {
				var gv, wv any
				if i < len(g) {
					gv = g[i]
				}
				if i < len(w) {
					wv = w[i]
				}
				if p, gs, ws, differs := firstDiffSides(fmt.Sprintf("%s[%d]", path, i), gv, i < len(g), wv, i < len(w)); differs {
					return p, gs, ws, true
				}
			}
			return "", "", "", false
		}
	}
	if reflect.DeepEqual(got, want) {
		return "", "", "", false
	}
	return path, renderJSON(got), renderJSON(want), true
}

func firstDiffSides(path string, got any, gotOK bool, want any, wantOK bool) (string, string, string, bool) {
	if gotOK && wantOK {
		return firstDiff(path, got, want)
	}
	g, w := "<missing>", "<missing>"
	if gotOK {
		g = renderJSON(got)
	}
	if wantOK {
		w = renderJSON(want)
	}
	return path, g, w, true
}

func renderJSON(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprintf("%v", v)
	}
	return string(b)
}

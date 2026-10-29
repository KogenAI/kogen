package conformance

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"kogen-loop/api"
	"kogen-loop/loop"
	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
)

// The climb levers are deleted, not deprecated: no field, method, constant or option-only
// file is left, while the measurement fields, the fixed constants and ToolChoice stay.
func TestClimbLeversRemoved(t *testing.T) {
	for _, c := range []struct {
		typ   reflect.Type
		field string
	}{
		{reflect.TypeOf(provider.Request{}), "DisableParallelToolCalls"},
		{reflect.TypeOf(loop.Request{}), "DisableParallelToolCalls"},
		{reflect.TypeOf(loop.Round{}), "DisableParallelToolCalls"},
		{reflect.TypeOf(provider.Request{}), "AuthorityBoundary"},
		{reflect.TypeOf(loop.Direct{}), "InputBudgetBytes"},
		{reflect.TypeOf(loop.FailOverBudget{}), "InputBudgetBytes"},
		{reflect.TypeOf(tools.Tools{}), "ResultBound"},
		{reflect.TypeOf(tools.Tools{}), "ResultHead"},
		{reflect.TypeOf(tools.Documentation{}), "ResultBound"},
		{reflect.TypeOf(tools.Documentation{}), "BodyBound"},
	} {
		if _, ok := c.typ.FieldByName(c.field); ok {
			t.Errorf("%s.%s still exists", c.typ, c.field)
		}
	}
	for _, c := range []struct {
		typ    reflect.Type
		method string
	}{
		{reflect.TypeOf(&tools.Tools{}), "Cut"},
		{reflect.TypeOf(&tools.Tools{}), "Validate"},
		{reflect.TypeOf(tools.Documentation{}), "Validate"},
	} {
		if _, ok := c.typ.MethodByName(c.method); ok {
			t.Errorf("%s.%s still exists", c.typ, c.method)
		}
	}

	// Declared names, constants and unused helpers of the removed branches.
	for dir, removed := range map[string][]string{
		"../loop":     {"MinInputBudgetBytes"},
		"../provider": {"markAuthority", "countBreakpoints", "maxBreakpoints"},
		"../tools":    {"New", "budgets", "bounds", "docFitMetadata", "docMinBound", "minResultBound", "minResultTail", "BodyBound", "ResultBound", "ResultHead"},
	} {
		names := declaredNames(t, dir)
		for _, name := range removed {
			if names[name] {
				t.Errorf("%s still declares %s", dir, name)
			}
		}
	}

	root, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}
	for _, gone := range []string{
		"provider/parallel_tool_calls_test.go", "provider/authority_breakpoint_test.go",
		"loop/input_budget_test.go", "loop/l_cut_test.go", "tools/l_cut_test.go",
		"tools/l_docbound_test.go", "features/steps/l_window_driver.go",
	} {
		if _, err := os.Stat(filepath.Join(root, gone)); !os.IsNotExist(err) {
			t.Errorf("%s must not exist (stat error %v)", gone, err)
		}
	}
	for _, kept := range []string{"tools/testdata/cut_golden.json", "provider/tool_choice_helpers_test.go", "loop/parallel_tool_calls_test.go"} {
		if _, err := os.Stat(filepath.Join(root, kept)); err != nil {
			t.Errorf("%s must remain: %v", kept, err)
		}
	}

	// What the levers sat beside stays: fixed budgets, measurement and ToolChoice.
	for _, c := range []struct {
		typ   reflect.Type
		field string
	}{
		{reflect.TypeOf(provider.Request{}), "ToolChoice"},
		{reflect.TypeOf(tools.Measurement{}), "RenderedBytes"},
		{reflect.TypeOf(tools.Measurement{}), "InputBudgetBytes"},
		{reflect.TypeOf(tools.Measurement{}), "OutputReserveTokens"},
		{reflect.TypeOf(tools.Measurement{}), "Fits"},
		{reflect.TypeOf(tools.Documentation{}), "Timeout"},
		{reflect.TypeOf(tools.Tools{}), "ShellTimeout"},
	} {
		if _, ok := c.typ.FieldByName(c.field); !ok {
			t.Errorf("%s.%s must remain", c.typ, c.field)
		}
	}
	if provider.InputBudgetBytes != 524288 || tools.InputBudgetBytes != 524288 {
		t.Errorf("input budget constants %d and %d", provider.InputBudgetBytes, tools.InputBudgetBytes)
	}
}

// markerCount counts the cache_control members anywhere in a request body.
func markerCount(v any) int {
	n := 0
	switch x := v.(type) {
	case map[string]any:
		for k, child := range x {
			if k == "cache_control" {
				n++
			}
			n += markerCount(child)
		}
	case []any:
		for _, child := range x {
			n += markerCount(child)
		}
	}
	return n
}

// The fixed policy: 524288-byte window, 16384/4096 text cut, 16384/8388608 documentation
// limits, provider-default parallel calls and three default cache breakpoints.
func TestClimbLeverConstants(t *testing.T) {
	t.Run("window", func(t *testing.T) {
		// A smaller documented bound of a model family is retained; the maximum is fixed.
		small := 100000
		if got := provider.UsableInputBytes(provider.Limits{Input: &small}); got != small {
			t.Errorf("smaller family bound = %d, want %d", got, small)
		}
		role := provider.Role{Provider: "chatgpt", Model: "m", Effort: "e"}
		client := provider.NewClient("")
		measure := func(instructions string) (tools.Measurement, loop.Request) {
			r := loop.Request{Role: role, Instructions: instructions, Input: []any{}, Tools: []any{}}
			m, err := tools.Measure(client.Body(provider.Request{Role: r.Role, Instructions: r.Instructions, Input: r.Input, Tools: r.Tools}), r.Role)
			if err != nil {
				t.Fatal(err)
			}
			return m, r
		}
		base, _ := measure("")
		if base.InputBudgetBytes != 524288 || base.OutputReserveTokens != provider.OutputReserveTokens {
			t.Fatalf("measurement %+v", base)
		}
		pad := strings.Repeat("a", base.InputBudgetBytes-base.RenderedBytes)
		at, r := measure(pad)
		if !at.Fits || at.RenderedBytes != 524288 {
			t.Fatalf("at the ceiling: %+v", at)
		}
		if _, err := (loop.FailOverBudget{Client: client}).Prepare(context.Background(), r); err != nil {
			t.Errorf("524288 bytes refused: %v", err)
		}
		r.Instructions += "a"
		over, _ := measure(r.Instructions)
		if over.Fits || over.RenderedBytes != 524289 {
			t.Fatalf("over the ceiling: %+v", over)
		}
		_, err := (loop.FailOverBudget{Client: client}).Prepare(context.Background(), r)
		se, ok := sys.AsError(err)
		if !ok || se.Reason != api.ErrContextBudget || !strings.Contains(se.Detail, "524289 bytes exceeds 524288") {
			t.Errorf("524289 bytes: %v", err)
		}
	})

	t.Run("cut", func(t *testing.T) {
		text := strings.Repeat("0123456789", 4000)
		got := tools.Cut(text)
		if len(got) > 16384 || !strings.HasPrefix(got, text[:4096]+"\n[... ") || !strings.Contains(got, "bytes omitted") || tools.Cut(got) != got {
			t.Fatalf("cut is %d bytes", len(got))
		}
		if tools.Cut(text[:16384]) != text[:16384] || len(tools.Cut(text[:16385])) > 16384 || tools.Cut(text[:16385]) == text[:16385] {
			t.Error("the 16384-byte boundary moved")
		}
		if tools.Cut(text[:16385])[:4096] != text[:4096] {
			t.Error("the 4096-byte head moved")
		}
		if out := (tools.Output{Text: text}).Cut().Text; out != got {
			t.Error("Output.Cut differs from Cut")
		}
	})

	t.Run("loop_round", func(t *testing.T) {
		// A real round over the fake Responses provider: a long read_file result reaches the
		// model cut, and the requests carry no parallel-call field and the automatic choice.
		w := newWorld(t).signIn().seed(map[string]string{"big.txt": strings.Repeat("0123456789abcdef\n", 3000)})
		f := newFakeProvider(t, []exchange{
			{Items: []map[string]any{call("c1", "read_file", map[string]any{"path": "big.txt"})}},
			{Items: []map[string]any{call("c2", "finish", map[string]any{"summary": "s"})}},
		})
		d := direct(t, w, f)
		rd := roundWith(t, w)
		rd.Definitions = tools.AsAny(tools.Defs("read_file"), []map[string]any{loop.TerminalDefinition("finish")})
		var delivered string
		res, err := loop.Run(context.Background(), rd, []any{userMessage("go")}, d, loop.Hooks{
			AfterCall: func(_ context.Context, c tools.Call, out tools.Output, _ bool, _ []any) error {
				if c.Name == "read_file" {
					delivered = out.Text
				}
				return nil
			},
		})
		if err != nil || res.Ending != loop.EndTerminal || res.Requests != 2 {
			t.Fatalf("%+v %v", res, err)
		}
		raw, err := rd.Tools.Run("read_file", map[string]any{"path": "big.txt"})
		if err != nil || len(raw.Text) <= 16384 {
			t.Fatalf("raw read %d bytes, err %v", len(raw.Text), err)
		}
		if delivered != tools.Cut(raw.Text) || len(delivered) > 16384 || !strings.HasPrefix(delivered, raw.Text[:4096]+"\n[... ") {
			t.Errorf("delivered %d bytes, want the default cut", len(delivered))
		}
		reqs := f.requests()
		if len(reqs) != 2 {
			t.Fatalf("%d requests", len(reqs))
		}
		for i, r := range reqs {
			if _, has := r["parallel_tool_calls"]; has {
				t.Errorf("request %d carries parallel_tool_calls", i+1)
			}
			if r["tool_choice"] != "auto" {
				t.Errorf("request %d tool_choice = %v", i+1, r["tool_choice"])
			}
		}
		input, _ := reqs[1]["input"].([]any)
		var sent string
		for _, it := range input {
			if m, ok := it.(map[string]any); ok && m["type"] == "function_call_output" {
				sent, _ = m["output"].(string)
			}
		}
		if sent != delivered {
			t.Errorf("the model saw %d bytes, the loop delivered %d", len(sent), len(delivered))
		}
	})

	t.Run("documentation", func(t *testing.T) {
		const body = 8388608
		origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch r.URL.Path {
			case "/huge":
				io.WriteString(w, strings.Repeat("a", body+4096))
			case "/long":
				io.WriteString(w, strings.Repeat("b", 20000))
			default:
				io.WriteString(w, "short\n")
			}
		}))
		defer origin.Close()
		fetch := func(path string) (map[string]any, string) {
			text := tools.Documentation{}.Lookup(map[string]any{"operation": "fetch", "url": origin.URL + path, "base": origin.URL})
			var out map[string]any
			if err := json.Unmarshal([]byte(text), &out); err != nil {
				t.Fatalf("%s: %v\n%.200s", path, err, text)
			}
			return out, text
		}
		out, text := fetch("/huge")
		if out["body_total"] != float64(body) || out["status"] != "retrieved" || len(text) > 16384 || out["truncated"] != true {
			t.Errorf("huge page: body_total %v status %v, %d result bytes", out["body_total"], out["status"], len(text))
		}
		out, text = fetch("/long")
		if out["body_total"] != float64(20000) || len(text) > 16384 || out["truncated"] != true {
			t.Errorf("long page: body_total %v, %d result bytes, truncated %v", out["body_total"], len(text), out["truncated"])
		}
		if out, _ = fetch("/short"); out["truncated"] != false || out["body"] != "short\n" {
			t.Errorf("short page: %v", out)
		}
	})

	t.Run("provider_defaults", func(t *testing.T) {
		client := provider.NewClient("")
		toolDefs := []any{map[string]any{"type": "function", "name": "probe", "description": "d", "parameters": map[string]any{"type": "object"}}}
		input := []any{
			map[string]any{"role": "user", "content": "one"},
			map[string]any{"role": "assistant", "content": "two"},
			map[string]any{"role": "user", "content": "three"},
		}
		for _, c := range []struct {
			name      string
			role      provider.Role
			markers   int
			parallel  string // the wire field that would limit parallel calls
			choiceKey string
		}{
			{"anthropic", provider.Role{Provider: "anthropic", Model: "claude-opus-5-5", Effort: "high"}, 3, "disable_parallel_tool_use", "tool_choice"},
			{"anthropic-profile", provider.Role{Provider: "anthropic", Model: "claude-sonnet-5-5", Effort: "high"}, 3, "disable_parallel_tool_use", "tool_choice"},
			{"chatgpt", provider.Role{Provider: "chatgpt", Model: "gpt-6.1-sol", Effort: "high"}, 0, "parallel_tool_calls", "tool_choice"},
			{"openai-compatible", provider.Role{Provider: "openai-compatible", Model: "m", Effort: "default", BaseURL: "http://127.0.0.1:1/v1"}, 0, "parallel_tool_calls", "tool_choice"},
		} {
			body, err := client.Render(provider.Request{Role: c.role, Instructions: "policy", Input: input, Tools: toolDefs, CacheID: "fixed-cache-id"})
			if err != nil {
				t.Fatalf("%s: %v", c.name, err)
			}
			if n := markerCount(body); n != c.markers {
				t.Errorf("%s: %d cache breakpoints, want %d", c.name, n, c.markers)
			}
			enc, _ := json.Marshal(body)
			if strings.Contains(string(enc), c.parallel) || strings.Contains(string(enc), `"ttl"`) {
				t.Errorf("%s: parallel-call control or ttl on the wire: %s", c.name, enc)
			}
			if fmt.Sprint(body[c.choiceKey]) != "auto" && fmt.Sprint(body[c.choiceKey]) != "map[type:auto]" {
				t.Errorf("%s: tool_choice = %v", c.name, body[c.choiceKey])
			}
		}
		// ToolChoice keeps naming the one tool where the route can force it.
		chat := provider.Role{Provider: "chatgpt", Model: "gpt-6.1-sol", Effort: "high"}
		body, err := client.Render(provider.Request{Role: chat, Instructions: "policy", Input: input, Tools: toolDefs, ToolChoice: "probe", CacheID: "fixed-cache-id"})
		if err != nil || !reflect.DeepEqual(body["tool_choice"], map[string]any{"type": "function", "name": "probe"}) {
			t.Errorf("forced tool choice: %v %v", body["tool_choice"], err)
		}
	})
}

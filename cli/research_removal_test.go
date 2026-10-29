package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
	"kogen/agent"
)

// testdata/loop_knobs_golden.json holds knobFixtureRequests and the cuts of knobFixtureRaw as the
// previous pin (c7e8331f) rendered them, through knobNormalize: provider.Client.Body of the
// request as built here and tools.Cut of each raw result. TestResearchRemovalDefaults renders
// the same with plain construction and compares.

// knobFixtureRoles are one role per wire, as the request fixtures render them.
var knobFixtureRoles = []provider.Role{
	{Provider: "chatgpt", Model: "gpt-6.1-sol", Effort: "high"},
	{Provider: "supergrok", Model: "grok-4.7", Effort: "high"},
	{Provider: "opencode-go", Model: "kimi-k3", Effort: "high"},
	{Provider: "anthropic", Model: "claude-opus-5-5", Effort: "high"},
	{Provider: "openai-compatible", Model: "local-model", Effort: "medium", BaseURL: "http://localhost:11434/v1"},
}

// knobFixtureEveryTool is every tool definition a Shape, Refine, Build or Review request offers.
var knobFixtureEveryTool = []string{tools.ShellTool, tools.ViewImageTool, tools.ReadFileTool, tools.WriteFileTool, agent.ReportBlockerTool, agent.FinishTool,
	tools.ListFilesTool, tools.SearchTextTool, agent.ProbeTool, tools.DocumentationTool, agent.SubmitTool, agent.SubmitReviewTool,
	agent.SubmitRefinementTool, agent.SubmitConfigurationTool, agent.ShapeBatchTool, agent.WorkerResultTool}

// knobFixtureRaw are tool results as a tool returns them: just inside, just over and far over
// the 16384-byte bound, the last with multibyte text.
func knobFixtureRaw() []string {
	return []string{
		strings.Repeat("a", 16384),
		strings.Repeat("b", 16385),
		strings.Repeat("héllo 🙂 wörld\n", 3000),
	}
}

// knobFixtureInput is a conversation with tool calls and their results, each result delivered
// by tools.Cut.
func knobFixtureInput() []any {
	input := []any{
		map[string]any{"role": "user", "content": "Authority: the approved Intent and its protected files."},
		map[string]any{"role": "user", "content": "Cumulative proposal manifest: []"},
	}
	for i, raw := range knobFixtureRaw() {
		id := fmt.Sprintf("call-%d", i)
		args, _ := json.Marshal(map[string]any{"path": fmt.Sprintf("file-%d.txt", i)})
		input = append(input,
			map[string]any{"type": "function_call", "call_id": id, "name": "read_file", "arguments": string(args)},
			map[string]any{"type": "function_call_output", "call_id": id, "output": tools.Cut(raw)},
		)
	}
	return append(input, map[string]any{"role": "user", "content": "Continue."})
}

// knobFixtureRequests are the requests of every wire with the full tool set and a
// conversation, as the Client renders them.
func knobFixtureRequests(body func(provider.Request) map[string]any) []map[string]any {
	var out []map[string]any
	for _, role := range knobFixtureRoles {
		req := provider.Request{
			Role: role, Instructions: "Policy of the fixture.", Input: knobFixtureInput(),
			Tools: agent.AsAny(agent.Defs(knobFixtureEveryTool...)), CacheID: "knob-fixture-cache",
		}
		out = append(out, map[string]any{"provider": role.Provider, "body": body(req)})
	}
	return out
}

// knobNormalize is a request body as the golden keeps it: decoded JSON in which the
// documentation tool definition (the one text the new pin changes) is a placeholder and every
// string over 256 bytes is its length and SHA-256, so the golden stays small and a difference
// of one byte still shows.
func knobNormalize(v any) any {
	raw, _ := json.Marshal(v)
	var decoded any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		panic(err)
	}
	var walk func(v any) any
	walk = func(v any) any {
		switch x := v.(type) {
		case map[string]any:
			if x["name"] == tools.DocumentationTool && (x["parameters"] != nil || x["input_schema"] != nil) {
				return "<documentation tool definition>"
			}
			for k, e := range x {
				x[k] = walk(e)
			}
			return x
		case []any:
			for i, e := range x {
				x[i] = walk(e)
			}
			return x
		case string:
			if len(x) > 256 {
				sum := sha256.Sum256([]byte(x))
				return fmt.Sprintf("sha256:%s:%d", hex.EncodeToString(sum[:]), len(x))
			}
		}
		return v
	}
	return walk(decoded)
}

// knobServer is a local provider that counts its requests and refuses each one, keeping the
// raw bodies.
type knobServer struct {
	srv    *httptest.Server
	count  atomic.Int64
	bodies [][]byte
}

func newKnobServer(t *testing.T) *knobServer {
	t.Helper()
	k := &knobServer{}
	k.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		k.bodies = append(k.bodies, body)
		k.count.Add(1)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(400)
		io.WriteString(w, `{"error":{"code":"invalid_request_error","message":"scripted refusal","type":"invalid_request_error"}}`)
	}))
	t.Cleanup(k.srv.Close)
	return k
}

// knobSession is a session whose home has a saved Anthropic key and whose provider is k.
func knobSession(t *testing.T, k *knobServer) *sys.Session {
	t.Helper()
	home := t.TempDir()
	dir := filepath.Join(home, ".kogen", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	key, _ := json.Marshal(map[string]any{"provider": "anthropic", "api_key": "sk-ant-FIXTURE-KEY"})
	if err := os.WriteFile(filepath.Join(dir, "anthropic.json"), key, 0o600); err != nil {
		t.Fatal(err)
	}
	env := []string{"PATH=" + os.Getenv("PATH"), "HOME=" + home, "KOGEN_PROVIDER_URL=" + k.srv.URL, "KOGEN_AUTH_URL=" + k.srv.URL}
	return sys.NewWith(env, t.TempDir())
}

// TestResearchRemovalDefaults holds the fixed defaults that replaced Kogen's research settings,
// through the real default construction: the 524288-byte working window, tool results of 16384
// bytes with a 4096-byte head, documentation at its pinned defaults and no authority boundary.
// The requests and cuts equal the previous pin's.
func TestResearchRemovalDefaults(t *testing.T) {
	t.Run("the working window is 524288 bytes, inclusive", func(t *testing.T) {
		if tools.InputBudgetBytes != 524288 {
			t.Fatalf("input budget %d", tools.InputBudgetBytes)
		}
		// {"x":"<n a's>"} is n+8 bytes.
		fit, err := tools.Measure(map[string]any{"x": strings.Repeat("a", 524288-8)})
		if err != nil || fit.RenderedBytes != 524288 || fit.InputBudgetBytes != 524288 || !fit.Fits || fit.OutputReserveTokens != 131072 {
			t.Fatalf("at the ceiling: %+v (%v)", fit, err)
		}
		over, err := tools.Measure(map[string]any{"x": strings.Repeat("a", 524288-7)})
		if err != nil || over.RenderedBytes != 524289 || over.Fits {
			t.Fatalf("one byte over: %+v (%v)", over, err)
		}
	})

	t.Run("a tool result is cut at 16384 bytes with a 4096-byte head", func(t *testing.T) {
		root := t.TempDir()
		s := sys.NewWith([]string{"PATH=" + os.Getenv("PATH"), "HOME=" + t.TempDir()}, root)
		tl := &tools.Tools{Root: root, Session: s, Enabled: []string{tools.ShellTool}}
		out, err := tl.Run(tools.ShellTool, map[string]any{"command": "head -c 30000 /dev/zero | tr '\\000' a"})
		if err != nil {
			t.Fatal(err)
		}
		cut := out.Cut().Text
		loc := strings.Index(cut, "\n[... ")
		if len(cut) != 16384 || loc < 4090 || loc > 4096 || !strings.Contains(cut, "bytes omitted ...]") {
			t.Fatalf("%d bytes, marker at %d: %.120q", len(cut), loc, cut[max(0, loc-10):])
		}
		for i, text := range knobFixtureRaw() {
			if got, want := (tools.Output{Text: text}).Cut().Text, tools.Cut(text); got != want {
				t.Errorf("cut %d: %d bytes, default %d", i, len(got), len(want))
			}
		}
		typed := tools.Output{Parts: []any{map[string]any{"type": "input_text", "text": strings.Repeat("x", 20000)}}}
		if got := typed.Cut(); !reflect.DeepEqual(got, typed) {
			t.Error("typed parts changed")
		}
	})

	t.Run("documentation keeps its pinned defaults", func(t *testing.T) {
		origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			for i := 0; i < 4000; i++ {
				fmt.Fprintf(w, "line %05d\n", i)
			}
		}))
		defer origin.Close()
		out := (tools.Documentation{}).Lookup(map[string]any{"operation": "fetch", "url": origin.URL + "/big", "base": origin.URL})
		if !strings.Contains(out, `"body_total":44000`) || !strings.Contains(out, `"truncated":true`) || len(out) > 16384 || len(out) < 8192 {
			t.Fatalf("%d bytes: %.200q", len(out), out)
		}
	})

	t.Run("a plain request has no authority boundary and equals the previous pin's", func(t *testing.T) {
		raw, err := os.ReadFile("testdata/loop_knobs_golden.json")
		if err != nil {
			t.Fatal(err)
		}
		var golden struct {
			Requests []any
			Cuts     []any
		}
		if err := json.Unmarshal(raw, &golden); err != nil {
			t.Fatal(err)
		}
		client := provider.NewClient("kogen dev+12345678 (test)")
		got := knobNormalize(knobFixtureRequests(func(r provider.Request) map[string]any { return client.Body(r) }))
		if !reflect.DeepEqual(got, any(golden.Requests)) {
			gotJSON, _ := json.Marshal(got)
			wantJSON, _ := json.Marshal(golden.Requests)
			t.Fatalf("requests differ from the previous pin's (%d and %d bytes)", len(gotJSON), len(wantJSON))
		}
		for i, text := range knobFixtureRaw() {
			if got := knobNormalize(tools.Cut(text)); got != golden.Cuts[i] {
				t.Errorf("cut %d = %v, want %v", i, got, golden.Cuts[i])
			}
		}
		if _, ok := knobNormalize(map[string]any{"name": "documentation", "parameters": map[string]any{}}).(string); !ok {
			t.Fatal("the normalization does not set the documentation definition apart")
		}
	})

	t.Run("the request sent is the plain request's body, measured as sent", func(t *testing.T) {
		role := provider.Role{Provider: "anthropic", Model: "claude-sonnet-5-5", Effort: "high"}
		k := newKnobServer(t)
		client := provider.NewClient("kogen dev+12345678 (test)")
		req := provider.Request{Role: role, Instructions: "policy", Input: knobFixtureInput(),
			Tools: agent.AsAny(agent.Defs(knobFixtureEveryTool...)), CacheID: "knob-fixture-cache"}
		client.Respond(context.Background(), knobSession(t, k), req, nil)
		if len(k.bodies) == 0 {
			t.Fatal("nothing was sent")
		}
		measured, err := tools.Measure(client.Body(req), role)
		if err != nil || len(k.bodies[0]) != measured.RenderedBytes || !measured.Fits {
			t.Fatalf("sent %d bytes, measured %+v (%v)", len(k.bodies[0]), measured, err)
		}
		if bytes.Contains(k.bodies[0], []byte(`"authority_boundary"`)) {
			t.Fatal("the request carries an authority boundary")
		}
	})
}

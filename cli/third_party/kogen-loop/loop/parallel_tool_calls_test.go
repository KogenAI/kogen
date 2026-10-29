package loop

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
)

// parallelServer is a local Messages endpoint: it records bodies and answers each request
// with the next scripted batch of tool_use blocks.
type parallelServer struct {
	srv    *httptest.Server
	mu     sync.Mutex
	bodies []map[string]any
	script [][]string // tool names per answer
}

func newParallelServer(t *testing.T, script ...[]string) *parallelServer {
	p := &parallelServer{script: script}
	p.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		var body map[string]any
		json.Unmarshal(raw, &body)
		p.mu.Lock()
		n := len(p.bodies)
		p.bodies = append(p.bodies, body)
		p.mu.Unlock()
		if n >= len(p.script) {
			http.Error(w, `{"error":{"message":"script exhausted"}}`, 400)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		ev := func(typ string, kv map[string]any) {
			kv["type"] = typ
			b, _ := json.Marshal(kv)
			io.WriteString(w, "event: "+typ+"\ndata: "+string(b)+"\n\n")
		}
		ev("message_start", map[string]any{"message": map[string]any{"id": "msg", "model": "claude-opus-5-5", "usage": map[string]any{"input_tokens": 1, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}}})
		for i, name := range p.script[n] {
			ev("content_block_start", map[string]any{"index": i, "content_block": map[string]any{"type": "tool_use", "id": name + string(rune('a'+i)) + string(rune('0'+n)), "name": name, "input": map[string]any{}}})
			ev("content_block_stop", map[string]any{"index": i})
		}
		ev("message_delta", map[string]any{"delta": map[string]any{"stop_reason": "tool_use"}, "usage": map[string]any{"output_tokens": 1}})
		ev("message_stop", map[string]any{})
	}))
	t.Cleanup(p.srv.Close)
	return p
}

func (p *parallelServer) requests() []map[string]any {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]map[string]any(nil), p.bodies...)
}

func parallelClient(t *testing.T, url string) (*provider.Client, *sys.Session) {
	home := t.TempDir()
	dir := filepath.Join(home, ".kogen", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "anthropic.json"), []byte(`{"provider":"anthropic","api_key":"SYNTHETIC_API_KEY_0001"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	s := sys.NewWith([]string{"HOME=" + home, "PATH=" + os.Getenv("PATH"), "KOGEN_PROVIDER_URL=" + url}, t.TempDir())
	return provider.NewClient(""), s
}

var parallelRole = provider.Role{Provider: "anthropic", Model: "claude-opus-5-5", Effort: "high"}

func parallelDefs() []any {
	return []any{
		map[string]any{"type": "function", "name": "probe", "description": "d", "parameters": map[string]any{"type": "object"}},
		map[string]any{"type": "function", "name": "finish", "description": "d", "parameters": map[string]any{"type": "object"}},
	}
}

func disabled(t *testing.T, body map[string]any) bool {
	t.Helper()
	tc, _ := body["tool_choice"].(map[string]any)
	_, present := tc["disable_parallel_tool_use"]
	return present
}

// Through the real loop and Direct the provider's own parallel-call behavior is preserved:
// no request carries a parallel-call control and the automatic tool_choice stays.
func TestParallelToolCallsLoop(t *testing.T) {
	srv := newParallelServer(t, []string{"probe"}, []string{"finish"})
	client, session := parallelClient(t, srv.srv.URL)
	d := &Direct{Client: client, Session: session}
	rd := Round{Role: parallelRole, Instructions: "p", Definitions: parallelDefs(), Tools: &tools.Tools{Session: session}}
	h := Hooks{HandleCall: func(_ context.Context, c tools.Call) (Handled, error) {
		return Handled{Handled: true, Output: tools.Output{Text: "ok"}}, nil
	}}
	res, err := Run(context.Background(), rd, []any{map[string]any{"role": "user", "content": []any{map[string]any{"type": "input_text", "text": "go"}}}}, d, h)
	if err != nil || res.Requests != 2 || res.Ending != EndTerminal {
		t.Fatalf("%+v %v", res, err)
	}
	reqs := srv.requests()
	if len(reqs) != 2 {
		t.Fatalf("%d requests", len(reqs))
	}
	for i, r := range reqs {
		if disabled(t, r) {
			t.Errorf("request %d carried the control: %v", i+1, r["tool_choice"])
		}
		if tc, _ := r["tool_choice"].(map[string]any); tc["type"] != "auto" {
			t.Errorf("request %d tool_choice %v, want auto", i+1, r["tool_choice"])
		}
	}
}

func TestParallelToolCallsBatch(t *testing.T) {
	srv := newParallelServer(t, []string{"probe", "finish", "probe"})
	client, session := parallelClient(t, srv.srv.URL)
	var ran, after []string
	h := Hooks{
		HandleCall: func(_ context.Context, c tools.Call) (Handled, error) {
			ran = append(ran, c.CallID().(string))
			return Handled{Handled: true, Output: tools.Output{Text: "out " + c.CallID().(string)}}, nil
		},
		AfterCall: func(_ context.Context, c tools.Call, _ tools.Output, terminal bool, _ []any) error {
			after = append(after, c.CallID().(string)+map[bool]string{true: ":terminal", false: ""}[terminal])
			return nil
		},
	}
	rd := Round{Role: parallelRole, Instructions: "p", Definitions: parallelDefs(), Tools: &tools.Tools{Session: session}}
	res, err := Run(context.Background(), rd, []any{}, &Direct{Client: client, Session: session}, h)
	if err != nil || res.Ending != EndTerminal || res.Requests != 1 {
		t.Fatalf("%+v %v", res, err)
	}
	if disabled(t, srv.requests()[0]) {
		t.Fatal("parallel-call control sent")
	}
	if strings.Join(ran, ",") != "probea0,probec0" {
		t.Errorf("executed %v", ran)
	}
	if strings.Join(after, ",") != "probea0,finishb0:terminal,probec0" {
		t.Errorf("after %v", after)
	}
	// Replay: both executed calls have outputs; the terminal call has none.
	outs := map[string]bool{}
	for _, it := range res.Input {
		if m, ok := it.(map[string]any); ok && m["type"] == "function_call_output" {
			outs[m["call_id"].(string)] = true
		}
	}
	if len(outs) != 2 || !outs["probea0"] || !outs["probec0"] || outs["finishb0"] {
		t.Errorf("outputs %v", outs)
	}
	if res.Terminal == nil || res.Terminal.CallID() != any("finishb0") {
		t.Errorf("terminal %+v", res.Terminal)
	}
}

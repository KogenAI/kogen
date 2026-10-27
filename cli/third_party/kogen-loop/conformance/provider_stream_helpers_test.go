package conformance

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

type streamRequest struct {
	Header       http.Header
	Body         map[string]any
	Method, Path string
}
type streamReply struct {
	Refusal map[string]any
	Events  []map[string]any
	Items   []map[string]any
}
type streamFake struct {
	mu       sync.Mutex
	requests []streamRequest
	replies  []streamReply
	bad      bool
	srv      *httptest.Server
}

func newStreamFake(t *testing.T, path string, replies ...streamReply) *streamFake {
	f := &streamFake{replies: replies}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		err := json.NewDecoder(r.Body).Decode(&body)
		f.mu.Lock()
		i := len(f.requests)
		f.requests = append(f.requests, streamRequest{r.Header.Clone(), body, r.Method, r.URL.Path})
		bad := err != nil || r.Method != "POST" || r.URL.Path != path || i >= len(replies)
		if bad {
			f.bad = true
		}
		f.mu.Unlock()
		if bad {
			http.Error(w, `{"error":{"message":"wrong or exhausted local route"}}`, 400)
			return
		}
		rep := replies[i]
		if rep.Refusal != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(400)
			json.NewEncoder(w).Encode(map[string]any{"error": rep.Refusal})
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		frame := func(e map[string]any) {
			b, _ := json.Marshal(e)
			if path == "/v1/messages" {
				fmt.Fprintf(w, "event: %s\n", e["type"])
			}
			fmt.Fprintf(w, "data: %s\n\n", b)
		}
		if path == "/v1/messages" {
			for _, e := range rep.Events {
				frame(e)
			}
		} else {
			for n, item := range rep.Items {
				frame(map[string]any{"type": "response.output_item.done", "output_index": n, "item": item})
			}
			frame(map[string]any{"type": "response.completed", "response": map[string]any{"status": "completed"}})
		}
	}))
	t.Cleanup(f.srv.Close)
	return f
}
func (f *streamFake) captured(t *testing.T) []streamRequest {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.bad || len(f.requests) != len(f.replies) {
		t.Fatalf("fake bad=%v requests=%d script=%d", f.bad, len(f.requests), len(f.replies))
	}
	return append([]streamRequest(nil), f.requests...)
}
func streamEnv(w *world, f *streamFake) []string {
	return append(w.env(nil), "KOGEN_PROVIDER_URL="+f.srv.URL, "KOGEN_AUTH_URL="+f.srv.URL)
}
func streamWorld(t *testing.T, anthropic bool) *world {
	w := newWorld(t)
	for _, d := range []string{w.home, w.root, w.tmp, filepath.Join(w.home, ".kogen"), filepath.Join(w.home, ".kogen", "credentials")} {
		if err := os.MkdirAll(d, 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(d, 0700); err != nil {
			t.Fatal(err)
		}
	}
	if !anthropic {
		return w.signIn()
	}
	if err := os.WriteFile(filepath.Join(w.home, ".kogen", "credentials", "anthropic.json"), []byte(`{"provider":"anthropic","api_key":"SYNTHETIC_API_KEY_0001"}`), 0600); err != nil {
		t.Fatal(err)
	}
	return w
}
func streamCLI(t *testing.T, w *world, f *streamFake, task map[string]any) result {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, cliBinary(t), "run", "--task", "-")
	cmd.Env = streamEnv(w, f)
	cmd.Dir = w.root
	cmd.Stdin = bytes.NewReader(mustJSON(t, task))
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if ctx.Err() != nil {
		t.Fatal(ctx.Err())
	}
	code := 0
	if err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatal(err)
		}
		code = ee.ExitCode()
	}
	r := result{exit: code, stderr: stderr.String()}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		var e map[string]any
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			t.Fatalf("non JSONL: %q", line)
		}
		r.events = append(r.events, e)
		r.lines = append(r.lines, line)
	}
	checkInvariants(t, r)
	streamRedacted(t, append(out, stderr.Bytes()...))
	return r
}
func streamRedacted(t *testing.T, v any) {
	t.Helper()
	s := fmt.Sprint(v)
	if b, ok := v.([]byte); ok {
		s = string(b)
	}
	for _, secret := range []string{"SYNTHETIC_API_KEY_0001", "fake-access-token", "fake-refresh-token"} {
		if strings.Contains(s, secret) {
			t.Fatal("credential leaked")
		}
	}
}
func streamClone[T any](v T) T {
	b, _ := json.Marshal(v)
	var c T
	if err := json.Unmarshal(b, &c); err != nil {
		panic(err)
	}
	return c
}
func streamNoKey(m map[string]any) map[string]any {
	c := streamClone(m)
	delete(c, "prompt_cache_key")
	return c
}
func checkStreamHeaders(reqs []streamRequest, keys []bool, id string) error {
	if len(reqs) != len(keys) || id == "" {
		return fmt.Errorf("request count/identity")
	}
	for i, r := range reqs {
		if r.Method != "POST" || r.Path != "/v1/responses" {
			return fmt.Errorf("route")
		}
		if r.Header.Get("session_id") != id || r.Header.Get("conversation_id") != id {
			return fmt.Errorf("identity at %d", i)
		}
		k, p := r.Body["prompt_cache_key"]
		if p != keys[i] || p && k != id {
			return fmt.Errorf("key at %d", i)
		}
	}
	return nil
}
func checkStreamRetry(a, b map[string]any) error {
	if !reflect.DeepEqual(streamNoKey(a), b) {
		return fmt.Errorf("retry changed body")
	}
	return nil
}

// These native blocks are synthetic local fixtures, assembled using the adopted
// Messages fragment/replay schema, not newly recorded provider responses.
func streamBlocks() []any {
	return []any{
		map[string]any{"type": "thinking", "thinking": "opaque", "signature": "signature"},
		map[string]any{"type": "redacted_thinking", "data": "redacted"},
		map[string]any{"type": "text", "text": "checking"},
		map[string]any{"type": "tool_use", "id": "b", "name": "shell", "input": map[string]any{"command": "printf b >> b.log"}},
		map[string]any{"type": "tool_use", "id": "a", "name": "shell", "input": map[string]any{"command": "printf a >> a.log"}},
	}
}
func streamMessages(reason string, invalid, final bool) streamReply {
	ev := func(typ string, kv ...any) map[string]any {
		m := map[string]any{"type": typ}
		for i := 0; i < len(kv); i += 2 {
			m[kv[i].(string)] = kv[i+1]
		}
		return m
	}
	events := []map[string]any{ev("message_start", "message", map[string]any{"id": "msg_fixture", "model": "claude-opus-5-5", "usage": map[string]any{"input_tokens": 10}})}
	blocks := streamBlocks()
	if final {
		blocks = []any{map[string]any{"type": "text", "text": "done"}}
	}
	if invalid {
		blocks = append(blocks, map[string]any{"type": "thinking", "thinking": "bad", "signature": ""})
	}
	for i, raw := range blocks {
		b := streamClone(raw.(map[string]any))
		var deltas []map[string]any
		switch b["type"] {
		case "thinking":
			if b["signature"] != "" {
				b["thinking"] = ""
				delete(b, "signature")
				deltas = []map[string]any{{"type": "thinking_delta", "thinking": "opaque"}, {"type": "signature_delta", "signature": "signature"}}
			}
		case "text":
			text := b["text"]
			b["text"] = ""
			deltas = []map[string]any{{"type": "text_delta", "text": text}}
		case "tool_use":
			js, _ := json.Marshal(b["input"])
			b["input"] = map[string]any{}
			mid := len(js) / 2
			deltas = []map[string]any{{"type": "input_json_delta", "partial_json": string(js[:mid])}, {"type": "input_json_delta", "partial_json": string(js[mid:])}}
		}
		events = append(events, ev("content_block_start", "index", i, "content_block", b))
		for _, d := range deltas {
			events = append(events, ev("content_block_delta", "index", i, "delta", d))
		}
		events = append(events, ev("content_block_stop", "index", i))
	}
	events = append(events, ev("message_delta", "delta", map[string]any{"stop_reason": reason}, "usage", map[string]any{"output_tokens": 12}), ev("message_stop"))
	return streamReply{Events: events}
}
func checkStreamReplay(body map[string]any) error {
	msgs, ok := body["messages"].([]any)
	if !ok || len(msgs) != 3 {
		return fmt.Errorf("message grouping")
	}
	opening, ok := msgs[0].(map[string]any)
	if !ok || opening["role"] != "user" {
		return fmt.Errorf("opening user message")
	}
	if text, ok := opening["content"].(string); !ok || text == "" {
		return fmt.Errorf("opening text replaced by extra replay blocks")
	}
	if !reflect.DeepEqual(msgs[1], map[string]any{"role": "assistant", "content": streamBlocks()}) {
		return fmt.Errorf("native replay")
	}
	results := []any{map[string]any{"type": "tool_result", "tool_use_id": "b", "content": "exit status: 0\n"}, map[string]any{"type": "tool_result", "tool_use_id": "a", "content": "exit status: 0\n", "cache_control": map[string]any{"type": "ephemeral"}}}
	if !reflect.DeepEqual(msgs[2], map[string]any{"role": "user", "content": results}) {
		return fmt.Errorf("tool results")
	}
	return nil
}
func checkStreamMarker(rec map[string]any, reason any, handled bool) error {
	s, p := rec["anthropic_stop_reason"]
	m, q := rec["anthropic_end_turn_tool_use"]
	b, ok := m.(bool)
	if !p || !q || !ok || b != handled || s != reason {
		return fmt.Errorf("stop reason/handled marker")
	}
	return nil
}

type streamEffects struct {
	Files                                        []string
	Hooks, Calls, Results, Events                []string
	Requests, Attempts, Logical, Rounds, Exposed int
}

func checkStreamEffects(o streamEffects, invalid, direct bool) error {
	n := 2
	if invalid {
		n = 1
	}
	if o.Requests != n || o.Attempts != n || o.Logical != n {
		return fmt.Errorf("counts")
	}
	if invalid {
		if len(o.Hooks)+len(o.Calls)+len(o.Results)+len(o.Events)+o.Rounds+o.Exposed != 0 || !reflect.DeepEqual(o.Files, []string{"", ""}) {
			return fmt.Errorf("invalid batch escaped")
		}
		return nil
	}
	if !reflect.DeepEqual(o.Files, []string{"b", "a"}) || o.Rounds != 1 {
		return fmt.Errorf("execution effects")
	}
	if direct {
		if !reflect.DeepEqual(o.Hooks, []string{"before:b", "handle:b", "after:b", "before:a", "handle:a", "after:a"}) {
			return fmt.Errorf("hooks")
		}
	} else if !reflect.DeepEqual(o.Calls, []string{"b", "a"}) || !reflect.DeepEqual(o.Results, []string{"b", "a"}) || !reflect.DeepEqual(o.Events, []string{"call:b", "result:b", "call:a", "result:a"}) {
		return fmt.Errorf("tool events")
	}
	return nil
}

// Transcript restoration preserves identity, not the provider's unsupported-key
// cache. Check process events and wire identity together rather than accepting
// two matching-but-changed headers.
type streamResumeObservation struct {
	Requests     []streamRequest
	TranscriptID string
	Starts       []map[string]any
	Stored       []any
}

func checkStreamResume(o streamResumeObservation) error {
	if len(o.Requests) != 5 {
		return fmt.Errorf("resume request count")
	}
	id, _ := o.Requests[0].Body["prompt_cache_key"].(string)
	if o.TranscriptID != id || len(o.Starts) != 2 {
		return fmt.Errorf("transcript identity")
	}
	for _, s := range o.Starts {
		if s["session_id"] != id {
			return fmt.Errorf("process identity")
		}
	}
	if o.Starts[1]["resumed"] != true {
		return fmt.Errorf("resume flag")
	}
	// Anchor persistence to the known first round, not just to whatever the
	// transcript happens to contain. A truncated transcript must not become its
	// own expected replay.
	prior := []any{
		userMessage("start"),
		call("c", "write_file", map[string]any{"path": "x.txt", "content": "observed"}),
		map[string]any{"type": "function_call_output", "call_id": "c", "output": "ok"},
		map[string]any{"type": "message", "id": "msg-fixture", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": "done"}}},
	}
	if !reflect.DeepEqual(o.Stored, prior) {
		return fmt.Errorf("persisted first-round conversation")
	}
	want := append(prior, userMessage("feedback: check again"))
	if !reflect.DeepEqual(o.Requests[3].Body["input"], want) {
		return fmt.Errorf("resumed conversation/feedback")
	}
	for _, pair := range [][2]int{{0, 1}, {3, 4}} {
		if err := checkStreamRetry(o.Requests[pair[0]].Body, o.Requests[pair[1]].Body); err != nil {
			return err
		}
	}
	return checkStreamHeaders(o.Requests, []bool{true, false, false, true, false}, id)
}

func streamRefusal(code, param, message string) streamReply {
	return streamReply{Refusal: map[string]any{"code": code, "param": param, "message": message}}
}

func checkStreamChatTool(body map[string]any) error {
	input, ok := body["input"].([]any)
	if !ok {
		return fmt.Errorf("missing replay input")
	}
	found := 0
	for _, raw := range input {
		m, ok := raw.(map[string]any)
		if !ok {
			return fmt.Errorf("input item")
		}
		if m["type"] == "function_call_output" {
			found++
			if m["call_id"] != "c" || m["output"] != "ok" {
				return fmt.Errorf("observable write_file result")
			}
		}
	}
	if found != 1 {
		return fmt.Errorf("tool result count")
	}
	return nil
}

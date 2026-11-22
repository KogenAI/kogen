package provider

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/KogenAI/kogen-loop/sys"
)

// Model-free tests of the Chat Completions response-header wait. Each runs Respond against a local
// httptest server on the injected Client.Now: the clock moves only while the client is blocked on
// the server, and nothing sleeps. The bounded real-time guard only fails a test that would hang.

const hdtGuard = 10 * time.Second

// hdtPlan is how the server answers one request: headers held until hold closes (nil: at once),
// then body chunks until body closes, or full when body is nil.
type hdtPlan struct {
	ctype string
	hold  chan struct{}
	body  chan string
	full  string
}

type hdtServer struct {
	srv    *httptest.Server
	plans  []*hdtPlan
	opened []chan struct{}
	gone   []chan struct{}
	mu     sync.Mutex
	n      int
	bodies []string
}

func newHdtServer(t *testing.T, plans ...*hdtPlan) *hdtServer {
	t.Helper()
	s := &hdtServer{plans: plans}
	for range plans {
		s.opened = append(s.opened, make(chan struct{}))
		s.gone = append(s.gone, make(chan struct{}))
	}
	s.srv = httptest.NewServer(http.HandlerFunc(s.serve))
	t.Cleanup(s.srv.Close)
	return s
}

func (s *hdtServer) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.n
}

func (s *hdtServer) serve(w http.ResponseWriter, r *http.Request) {
	b, _ := io.ReadAll(r.Body)
	s.mu.Lock()
	i := s.n
	s.n++
	s.bodies = append(s.bodies, string(b))
	s.mu.Unlock()
	if i >= len(s.plans) {
		http.Error(w, "unexpected extra request", 500)
		return
	}
	p := s.plans[i]
	defer close(s.gone[i])
	close(s.opened[i])
	if p.hold != nil {
		select {
		case <-p.hold:
		case <-r.Context().Done():
			return
		case <-time.After(2 * hdtGuard):
			return
		}
	}
	w.Header().Set("Content-Type", p.ctype)
	w.WriteHeader(200)
	w.(http.Flusher).Flush()
	if p.body == nil {
		io.WriteString(w, p.full)
		return
	}
	for {
		select {
		case chunk, ok := <-p.body:
			if !ok {
				return
			}
			io.WriteString(w, chunk)
			w.(http.Flusher).Flush()
		case <-r.Context().Done():
			return
		case <-time.After(2 * hdtGuard):
			return
		}
	}
}

// hdtCall is one Respond in flight against the server.
type hdtCall struct {
	t        *testing.T
	e        *env
	reads    chan readSignal
	guard    <-chan time.Time
	finished chan struct{}
	resp     *Response
	err      error
}

func hdtStart(t *testing.T, srv *hdtServer, mod func(*Request)) *hdtCall {
	t.Helper()
	old := idlePoll
	idlePoll = 5 * time.Millisecond
	t.Cleanup(func() { idlePoll = old })
	e, _, req := obsEnv(t, "opencode-go")
	st := &signalTransport{rt: &http.Transport{}, reads: make(chan readSignal, 1024)}
	t.Cleanup(func() { st.rt.(*http.Transport).CloseIdleConnections() })
	e.c.HTTP = &http.Client{Transport: st}
	e.s = sys.NewWith([]string{"HOME=" + e.home, "PATH=" + os.Getenv("PATH"), "KOGEN_PROVIDER_URL=" + srv.srv.URL}, e.home)
	c := &hdtCall{t: t, e: e, reads: st.reads, guard: time.After(hdtGuard)}
	if mod != nil {
		mod(&req)
	}
	c.run(req)
	return c
}

func (c *hdtCall) run(req Request) {
	c.finished = make(chan struct{})
	go func() {
		defer close(c.finished)
		c.resp, c.err = c.e.c.Respond(context.Background(), c.e.s, req, nil)
	}()
}

func (c *hdtCall) waitOpen(srv *hdtServer, i int) {
	c.t.Helper()
	select {
	case <-srv.opened[i]:
	case <-c.guard:
		c.t.Fatalf("request %d never reached the server", i+1)
	}
}

// waitRead returns once the client has handled the first bytes of the attempt's body.
func (c *hdtCall) waitRead(attempt, bytes int) {
	c.t.Helper()
	for {
		select {
		case sig := <-c.reads:
			if sig.attempt == attempt && sig.bytes >= bytes {
				return
			}
		case <-c.guard:
			c.t.Fatalf("attempt %d: the client never handled %d bytes of the answer", attempt, bytes)
		}
	}
}

func (c *hdtCall) wait() {
	c.t.Helper()
	select {
	case <-c.finished:
	case <-c.guard:
		c.t.Fatal("Respond did not return")
	}
}

func hdtChunk(delta map[string]any, finish any, extra map[string]any) string {
	choice := map[string]any{"index": int64(0), "delta": delta}
	if finish != nil {
		choice["finish_reason"] = finish
	}
	ch := map[string]any{"id": "chatcmpl-stream", "object": "chat.completion.chunk", "model": "kimi-k3", "choices": []any{choice}}
	for k, v := range extra {
		ch[k] = v
	}
	return "data: " + string(mustEncode(ch)) + "\n\n"
}

const hdtDone = "data: [DONE]\n\n"

var hdtUsage = map[string]any{"usage": map[string]any{"prompt_tokens": int64(100), "completion_tokens": int64(20)}}

func hdtTextAnswer(text string) (first, rest string) {
	return hdtChunk(map[string]any{"role": "assistant", "content": text}, nil, nil),
		hdtChunk(map[string]any{}, "stop", hdtUsage) + hdtDone
}

func hdtMessageText(t *testing.T, items []map[string]any) string {
	t.Helper()
	if len(items) == 0 || items[0]["type"] != "message" {
		t.Fatalf("items = %s, want an assistant message first", jsonOf(t, items))
	}
	list, _ := asList(items[0]["content"])
	if len(list) != 1 {
		t.Fatalf("message content = %v", items[0]["content"])
	}
	b, _ := asMap(list[0])
	s, _ := b["text"].(string)
	return s
}

// hdtWantAnswer wants one request, no retry and the given answer text.
func hdtWantAnswer(t *testing.T, c *hdtCall, srv *hdtServer, text string) {
	t.Helper()
	if c.err != nil || c.resp == nil {
		t.Fatalf("the call failed: %v", idleText(c.err))
	}
	if got := hdtMessageText(t, c.resp.Items); got != text {
		t.Fatalf("text = %q, want %q", got, text)
	}
	if n := srv.count(); n != 1 {
		t.Fatalf("%d requests reached the server, want 1 (an attempt was cut and retried)", n)
	}
	if len(c.e.clk.slept()) != 0 {
		t.Fatalf("slept %v: an attempt was retried", c.e.clk.slept())
	}
}

// Serial: idlePoll is a package global.
// The headers come after 60 s of silence (beyond the old 45 s first-byte limit), then a normal answer.
func TestStreamDelayedHeaders60s(t *testing.T) {
	first, rest := hdtTextAnswer("late but whole")
	p := &hdtPlan{ctype: "text/event-stream", hold: make(chan struct{}), body: make(chan string, 4)}
	srv := newHdtServer(t, p)
	c := hdtStart(t, srv, nil)
	c.waitOpen(srv, 0)
	c.e.clk.advance(60 * time.Second)
	close(p.hold)
	c.waitRead(1, 0)
	p.body <- first
	p.body <- rest
	close(p.body)
	c.wait()
	hdtWantAnswer(t, c, srv, "late but whole")
}

// Serial: idlePoll is a package global.
// No headers within the header timeout: the transient failure names the header wait, never idle.
func TestStreamHeaderTimeoutNamesHeaders(t *testing.T) {
	srv := newHdtServer(t,
		&hdtPlan{ctype: "text/event-stream", hold: make(chan struct{})},
		&hdtPlan{ctype: "text/event-stream", hold: make(chan struct{})},
		&hdtPlan{ctype: "text/event-stream", hold: make(chan struct{})})
	c := hdtStart(t, srv, nil)
	for i := range srv.plans {
		c.waitOpen(srv, i)
		c.e.clk.advance(DefaultHeaderTimeout)
		select {
		case <-srv.gone[i]:
		case <-c.guard:
			t.Fatalf("request %d: %v without headers and the client still waited", i+1, DefaultHeaderTimeout)
		}
	}
	c.wait()
	if c.err == nil {
		t.Fatal("the call succeeded although the server never sent headers")
	}
	text := strings.ToLower(idleText(c.err))
	if !strings.Contains(text, "response headers") || !strings.Contains(text, "did not answer after 3 attempts") {
		t.Errorf("error %q does not say three attempts ended waiting for response headers", text)
	}
	if strings.Contains(text, "idle") || strings.Contains(text, "first byte") {
		t.Errorf("error %q uses the stream idle wording", text)
	}
	if srv.count() != 3 {
		t.Errorf("%d requests, want 3", srv.count())
	}
}

// Serial: idlePoll is a package global.
// Headers at 100 s and the first chunk 150 s after them: 250 s in all, no cut at the 120 s header
// timeout because the idle clock starts at the headers.
func TestIdleClockStartsAfterHeaders(t *testing.T) {
	first, rest := hdtTextAnswer("slow first chunk")
	p := &hdtPlan{ctype: "text/event-stream", hold: make(chan struct{}), body: make(chan string, 4)}
	srv := newHdtServer(t, p)
	c := hdtStart(t, srv, nil)
	c.waitOpen(srv, 0)
	c.e.clk.advance(100 * time.Second)
	close(p.hold)
	c.waitRead(1, 0)
	c.e.clk.advance(150 * time.Second)
	p.body <- first
	c.waitRead(1, len(first))
	p.body <- rest
	close(p.body)
	c.wait()
	hdtWantAnswer(t, c, srv, "slow first chunk")
}

// A stream: true request answered with a plain JSON body is read as a complete answer.
func TestStreamRequestPlainJSONAnswer(t *testing.T) {
	srv := newHdtServer(t, &hdtPlan{ctype: "application/json", full: string(mustEncode(goText("plain answer")))})
	c := hdtStart(t, srv, nil)
	c.wait()
	hdtWantAnswer(t, c, srv, "plain answer")
	if !strings.Contains(srv.bodies[0], `"stream":true`) {
		t.Fatalf("request body %q does not ask for a stream", srv.bodies[0])
	}
}

// A streamed tool call, then a second request that carries the tool result.
func TestStreamToolCallRoundTrip(t *testing.T) {
	const args = `{"path":"a.go","n":1}`
	frag := func(s string, first bool) string {
		call := map[string]any{"index": int64(0), "function": map[string]any{"arguments": s}}
		if first {
			call["id"], call["type"] = "call_rt", "function"
			call["function"].(map[string]any)["name"] = "read_file"
		}
		return hdtChunk(map[string]any{"tool_calls": []any{call}}, nil, nil)
	}
	first := hdtChunk(map[string]any{"role": "assistant"}, nil, nil) + frag(`{"path"`, true) + frag(`:"a.go"`, false) +
		frag(`,"n":`, false) + frag(`1}`, false) + hdtChunk(map[string]any{}, "tool_calls", hdtUsage) + hdtDone
	second, secondRest := hdtTextAnswer("the file says hi")
	srv := newHdtServer(t,
		&hdtPlan{ctype: "text/event-stream", full: first},
		&hdtPlan{ctype: "text/event-stream", full: second + secondRest})
	c := hdtStart(t, srv, func(r *Request) { r.Tools = []any{goTool("read_file")} })
	c.wait()
	if c.err != nil || c.resp == nil {
		t.Fatalf("the first call failed: %v", idleText(c.err))
	}
	items := c.resp.Items
	last := items[len(items)-1]
	if last["type"] != "function_call" || last["call_id"] != "call_rt" || last["name"] != "read_file" || last["arguments"] != args {
		t.Fatalf("items = %s, want a function_call call_rt read_file %s", jsonOf(t, items), args)
	}
	input := user("x")
	for _, it := range items {
		input = append(input, it)
	}
	input = append(input, map[string]any{"type": "function_call_output", "call_id": "call_rt", "output": "hi from the tool"})
	c.run(Request{Role: goRole, Instructions: "p", Input: input, CacheID: "streamobs-cache", Tools: []any{goTool("read_file")}})
	c.wait()
	if c.err != nil || c.resp == nil {
		t.Fatalf("the second call failed: %v", idleText(c.err))
	}
	if got := hdtMessageText(t, c.resp.Items); got != "the file says hi" {
		t.Fatalf("second answer = %q", got)
	}
	if srv.count() != 2 {
		t.Fatalf("%d requests, want 2", srv.count())
	}
	for _, want := range []string{`"tool_call_id":"call_rt"`, "hi from the tool", `"arguments":"{\"path\":\"a.go\",\"n\":1}"`} {
		if !strings.Contains(srv.bodies[1], want) {
			t.Errorf("second request body lacks %s: %s", want, srv.bodies[1])
		}
	}
}

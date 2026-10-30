package provider

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"kogen-loop/sys"
)

// These tests drive Client.Respond against a real local HTTP server. The server sends only what
// the test commands, the client's clock is the injected Client.Now, and the test advances it only
// after the client has read what was sent: it waits on channels, never on a sleep. The bounded
// real-time guard only fails a test that would otherwise hang.

const idleGuard = 20 * time.Second

// readSignal is one body read about to start; bytes is what the attempt's body has returned so far.
type readSignal struct{ attempt, bytes int }

// signalTransport reports every body Read of every response. A Read starts only after the client
// has handled the previous one, so a report carrying n bytes means the client has processed
// (timestamped, classified) all of the first n bytes.
type signalTransport struct {
	rt    http.RoundTripper
	reads chan readSignal
	mu    sync.Mutex
	n     int
}

func (s *signalTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	resp, err := s.rt.RoundTrip(req)
	if err != nil {
		return resp, err
	}
	s.mu.Lock()
	s.n++
	attempt := s.n
	s.mu.Unlock()
	resp.Body = &signalBody{ReadCloser: resp.Body, st: s, attempt: attempt}
	return resp, nil
}

type signalBody struct {
	io.ReadCloser
	st      *signalTransport
	attempt int
	n       int
}

func (b *signalBody) Read(p []byte) (int, error) {
	select {
	case b.st.reads <- readSignal{b.attempt, b.n}:
	default:
	}
	n, err := b.ReadCloser.Read(p)
	b.n += n
	return n, err
}

// idleStall is one attempt the server holds open: it answers 200, flushes the headers, then writes
// what the test sends until the client leaves.
type idleStall struct {
	cmds chan string
	open chan struct{} // the request arrived
	gone chan struct{} // the request's context ended: the client closed the connection
}

type idleServer struct {
	srv    *httptest.Server
	stalls []*idleStall
	answer string
	ctype  string
	mu     sync.Mutex
	n      int
}

func newIdleServer(t *testing.T, wire string, stalls int) *idleServer {
	t.Helper()
	s := &idleServer{ctype: "text/event-stream"}
	head, tail := idleAnswer(wire)
	s.answer = head + tail
	if wire == "opencode-go" {
		s.ctype = "application/json"
	}
	for i := 0; i < stalls; i++ {
		s.stalls = append(s.stalls, &idleStall{cmds: make(chan string, 16), open: make(chan struct{}), gone: make(chan struct{})})
	}
	s.srv = httptest.NewServer(http.HandlerFunc(s.serve))
	t.Cleanup(s.srv.Close)
	return s
}

func (s *idleServer) serve(w http.ResponseWriter, r *http.Request) {
	io.Copy(io.Discard, r.Body)
	s.mu.Lock()
	i := s.n
	s.n++
	s.mu.Unlock()
	w.Header().Set("Content-Type", s.ctype)
	if i >= len(s.stalls) {
		io.WriteString(w, s.answer)
		return
	}
	st := s.stalls[i]
	w.WriteHeader(200)
	w.(http.Flusher).Flush()
	close(st.open)
	for {
		select {
		case chunk := <-st.cmds:
			io.WriteString(w, chunk)
			w.(http.Flusher).Flush()
		case <-r.Context().Done():
			close(st.gone)
			return
		case <-time.After(2 * idleGuard): // frees the handler of a test that already failed
			return
		}
	}
}

// idleStep advances the clock, then has the server send chunk (when not empty).
type idleStep struct {
	advance time.Duration
	send    string
}

// idleRun is what a stalled-attempt scenario observed.
type idleRun struct {
	e    *env
	obs  *observer
	resp *Response
	err  error
}

// driveIdle runs one Respond against a server that stalls its first `stalls` attempts. Every stalled
// attempt gets the same steps and, after them, endAfter more simulated time, at which the client
// must give up and close the connection.
func driveIdle(t *testing.T, wire string, stalls int, steps []idleStep, endAfter time.Duration) idleRun {
	t.Helper()
	old := idlePoll
	idlePoll = 5 * time.Millisecond
	defer func() { idlePoll = old }()
	srv := newIdleServer(t, wire, stalls)
	e, _, req := obsEnv(t, wire)
	st := &signalTransport{rt: &http.Transport{}, reads: make(chan readSignal, 1024)}
	t.Cleanup(func() { st.rt.(*http.Transport).CloseIdleConnections() })
	e.c.HTTP = &http.Client{Transport: st}
	e.s = sys.NewWith([]string{"HOME=" + e.home, "PATH=" + os.Getenv("PATH"), "KOGEN_PROVIDER_URL=" + srv.srv.URL}, e.home)

	run := idleRun{e: e, obs: &observer{}}
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		run.resp, run.err = e.c.Respond(context.Background(), e.s, req, run.obs)
	}()
	guard := time.After(idleGuard)
	waitRead := func(attempt, bytes int) {
		t.Helper()
		for {
			select {
			case sig := <-st.reads:
				if sig.attempt == attempt && sig.bytes >= bytes {
					return
				}
			case <-guard:
				t.Fatalf("attempt %d: the client never read %d bytes", attempt, bytes)
			}
		}
	}
	for i, stall := range srv.stalls {
		select {
		case <-stall.open:
		case <-guard:
			t.Fatalf("attempt %d never reached the server", i+1)
		}
		waitRead(i+1, 0) // the headers are handled
		sent := 0
		for _, s := range steps {
			e.clk.advance(s.advance)
			if s.send != "" {
				stall.cmds <- s.send
				sent += len(s.send)
				waitRead(i+1, sent)
			}
		}
		e.clk.advance(endAfter)
		select {
		case <-stall.gone:
		case <-guard:
			t.Fatalf("attempt %d: the limit passed and the connection stayed open", i+1)
		}
	}
	select {
	case <-finished:
	case <-guard:
		t.Fatal("Respond did not return")
	}
	return run
}

// idleCase is a stalled attempt and the record it must leave.
type idleCase struct {
	name       string
	wire       string
	steps      []idleStep
	endAfter   time.Duration
	byteMS     any // last_byte_ms
	progressMS any // last_progress_ms
	detail     string
}

func checkStalled(t *testing.T, c idleCase) {
	t.Helper()
	t.Run("retried", func(t *testing.T) {
		r := driveIdle(t, c.wire, 1, c.steps, c.endAfter)
		if r.err != nil || r.resp == nil {
			t.Fatalf("the retry did not answer: %v", r.err)
		}
		recs := attemptRecords(t, r.obs, 2)
		wantFields(t, "stalled", recs[0], map[string]any{
			"outcome": "failed", "end_reason": "idle", "error": "provider_failure",
			"last_byte_ms": c.byteMS, "last_progress_ms": c.progressMS,
		})
		wantFields(t, "retry", recs[1], map[string]any{"outcome": "completed", "error": nil})
		if !reflect.DeepEqual(r.e.clk.slept(), []time.Duration{2 * time.Second}) {
			t.Errorf("slept %v, want one 2 s backoff", r.e.clk.slept())
		}
		if n := liveWatches.Load(); n != 0 {
			t.Errorf("%d attempt timers still running", n)
		}
	})
	t.Run("three attempts", func(t *testing.T) {
		r := driveIdle(t, c.wire, 3, c.steps, c.endAfter)
		text := idleText(r.err)
		if r.err == nil || !strings.Contains(text, "did not answer after 3 attempts") || !strings.Contains(text, c.detail) {
			t.Fatalf("error %q, want %q after 3 attempts", text, c.detail)
		}
		for i, rec := range attemptRecords(t, r.obs, 3) {
			wantFields(t, "attempt "+string(rune('1'+i)), rec, map[string]any{"outcome": "failed", "end_reason": "idle", "last_byte_ms": c.byteMS, "last_progress_ms": c.progressMS})
		}
		if !reflect.DeepEqual(r.e.clk.slept(), []time.Duration{2 * time.Second, 8 * time.Second}) {
			t.Errorf("slept %v, want 2 s then 8 s", r.e.clk.slept())
		}
	})
}

func TestIdleStreamSilentServer(t *testing.T) {
	good := string(mustEncode(goText("hello")))
	chatHead, _ := idleAnswer("chatgpt")
	msgHead, _ := idleAnswer("anthropic")
	cases := []idleCase{
		{name: "chatgpt headers then nothing", wire: "chatgpt", endAfter: 90 * time.Second, byteMS: nil, progressMS: nil, detail: "no first byte within 90 s"},
		{name: "anthropic headers then nothing", wire: "anthropic", endAfter: 45 * time.Second, byteMS: nil, progressMS: nil, detail: "no first byte within 45 s"},
		{name: "chatgpt progress then nothing", wire: "chatgpt", steps: []idleStep{{time.Second, chatHead}}, endAfter: 180 * time.Second,
			byteMS: int64(1000), progressMS: int64(1000), detail: "stream idle for 180 s"},
		{name: "anthropic progress then nothing", wire: "anthropic", steps: []idleStep{{time.Second, msgHead}}, endAfter: 180 * time.Second,
			byteMS: int64(1000), progressMS: int64(1000), detail: "stream idle for 180 s"},
		// the headers are the first byte of a body read whole
		{name: "chat completions headers then nothing", wire: "opencode-go", endAfter: 180 * time.Second,
			byteMS: nil, progressMS: int64(0), detail: "stream idle for 180 s"},
		{name: "chat completions body stops after 10 bytes", wire: "opencode-go", steps: []idleStep{{time.Second, good[:10]}}, endAfter: 180 * time.Second,
			byteMS: int64(1000), progressMS: int64(1000), detail: "stream idle for 180 s"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { checkStalled(t, c) })
	}
}

func TestIdleStreamKeepAlive(t *testing.T) {
	good := string(mustEncode(goText("hello")))
	chatHead, _ := idleAnswer("chatgpt")
	msgHead, _ := idleAnswer("anthropic")
	const idle = "stream idle for 180 s"
	cases := []idleCase{
		// after one progress read, keep-alives 80 s later do not move the 180 s clock
		{name: "responses comment after progress", wire: "chatgpt",
			steps:    []idleStep{{time.Second, chatHead}, {80 * time.Second, ": keepalive\n\n"}},
			endAfter: 100 * time.Second, byteMS: int64(81000), progressMS: int64(1000), detail: idle},
		{name: "messages comment and ping event after progress", wire: "anthropic",
			steps:    []idleStep{{time.Second, msgHead}, {40 * time.Second, ": ping\n\n"}, {40 * time.Second, "event: ping\ndata: {\"type\":\"ping\"}\n\n"}},
			endAfter: 100 * time.Second, byteMS: int64(81000), progressMS: int64(1000), detail: idle},
		{name: "chat completions whitespace after 10 bytes", wire: "opencode-go",
			steps:    []idleStep{{time.Second, good[:10]}, {40 * time.Second, "\n"}, {40 * time.Second, "   "}},
			endAfter: 100 * time.Second, byteMS: int64(81000), progressMS: int64(1000), detail: idle},
		{name: "chat completions whitespace before the value", wire: "opencode-go",
			steps:    []idleStep{{80 * time.Second, " \n\t\r"}},
			endAfter: 100 * time.Second, byteMS: int64(80000), progressMS: int64(0), detail: idle},
		// keep-alives never meet the first-byte limit
		{name: "responses keep-alives only", wire: "chatgpt",
			steps:    []idleStep{{40 * time.Second, ": keepalive\n\n"}, {40 * time.Second, ": keepalive\n\n"}},
			endAfter: 10 * time.Second, byteMS: int64(80000), progressMS: nil, detail: "no first byte within 90 s"},
		{name: "messages keep-alives only", wire: "anthropic",
			steps:    []idleStep{{20 * time.Second, ": ping\n\n"}, {20 * time.Second, "event: ping\ndata: {\"type\":\"ping\"}\n\n"}},
			endAfter: 5 * time.Second, byteMS: int64(40000), progressMS: nil, detail: "no first byte within 45 s"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { checkStalled(t, c) })
	}
}

// ---- progress at the boundaries, with the scripted transport ----

func TestIdleStreamProgress(t *testing.T) {
	// answered runs one script and wants a completed answer in one request; stalled wants an idle
	// first attempt retried to a completed one.
	answered := func(t *testing.T, wire string, steps []obsStep, hdr time.Duration) map[string]any {
		t.Helper()
		e, tr, req := idleEnv(t, wire, obsAttempt{headersAdvance: hdr, steps: steps})
		obs := &observer{}
		if _, err := respondIdle(t, e, req, obs); err != nil {
			t.Fatal(err)
		}
		if tr.next != 1 || len(e.clk.slept()) != 0 {
			t.Fatalf("%d requests, slept %v", tr.next, e.clk.slept())
		}
		rec := attemptRecords(t, obs, 1)[0]
		wantFields(t, "answered", rec, map[string]any{"outcome": "completed"})
		return rec
	}
	stalled := func(t *testing.T, wire string, steps []obsStep, hdr time.Duration) map[string]any {
		t.Helper()
		head, tail := idleAnswer(wire)
		e, tr, req := idleEnv(t, wire, obsAttempt{headersAdvance: hdr, steps: steps}, obsAttempt{steps: []obsStep{{advance: ms1, data: head + tail}}})
		obs := &observer{}
		if _, err := respondIdle(t, e, req, obs); err != nil {
			t.Fatal(err)
		}
		recs := attemptRecords(t, obs, 2)
		wantFields(t, "stalled", recs[0], map[string]any{"outcome": "failed", "end_reason": "idle", "error": "provider_failure"})
		wantFields(t, "retry", recs[1], map[string]any{"outcome": "completed"})
		if tr.next != 2 || !reflect.DeepEqual(e.clk.slept(), []time.Duration{2 * time.Second}) {
			t.Fatalf("%d requests, slept %v", tr.next, e.clk.slept())
		}
		return recs[0]
	}

	for _, wire := range []string{"chatgpt", "anthropic"} {
		head, tail := idleAnswer(wire)
		prog := idleProgress(wire)
		t.Run(wire+"/boundary", func(t *testing.T) {
			// progress 1 ms before the limit renews the clock; at the limit it is too late
			rec := answered(t, wire, []obsStep{{advance: ms1, data: head}, {advance: idleLimit - ms1, data: tail}}, 0)
			wantFields(t, "in time", rec, map[string]any{"last_progress_ms": int64(180000), "last_byte_ms": int64(180000)})
			rec = stalled(t, wire, []obsStep{{advance: ms1, data: head}, {advance: idleLimit, data: tail}}, 0)
			// the late read is a byte, never progress
			wantFields(t, "late", rec, map[string]any{"last_progress_ms": int64(1), "last_byte_ms": int64(180001)})
		})
		t.Run(wire+"/first progress boundary", func(t *testing.T) {
			first := idleFirst(wire)
			answered(t, wire, []obsStep{{advance: first - ms1, data: head}, {advance: ms1, data: tail}}, 0)
			rec := stalled(t, wire, []obsStep{{advance: first, data: head}}, 0)
			wantFields(t, "late first", rec, map[string]any{"last_progress_ms": nil})
		})
		t.Run(wire+"/partial event", func(t *testing.T) {
			// the unfinished event renews the clock in the read that carries its blank line
			p1, p2 := prog[:5], prog[5:]
			rec := answered(t, wire, []obsStep{{advance: ms1, data: head}, {advance: 100 * time.Second, data: p1}, {advance: 79999 * ms1, data: p2}, {advance: 179999 * ms1, data: tail}}, 0)
			wantFields(t, "renewed at its end", rec, map[string]any{"last_progress_ms": int64(1 + 100000 + 79999 + 179999)})
			// had the unfinished part renewed it, this tail would be on time
			stalled(t, wire, []obsStep{{advance: ms1, data: head}, {advance: 100 * time.Second, data: p1}, {advance: 79999 * ms1, data: p2}, {advance: idleLimit, data: tail}}, 0)
			rec = stalled(t, wire, []obsStep{{advance: ms1, data: head}, {advance: 100 * time.Second, data: p1}, {advance: 80 * time.Second, data: p2}}, 0)
			wantFields(t, "unfinished at the limit", rec, map[string]any{"last_progress_ms": int64(1)})
		})
		t.Run(wire+"/crlf framing", func(t *testing.T) {
			crlf := strings.ReplaceAll(prog, "\n", "\r\n")
			cut := len(crlf) - 3 // between the \r and \n of the blank line
			answered(t, wire, []obsStep{{advance: ms1, data: head}, {advance: 100 * time.Second, data: crlf[:cut]}, {advance: 79999 * ms1, data: crlf[cut:]}, {advance: 179999 * ms1, data: tail}}, 0)
			stalled(t, wire, []obsStep{{advance: ms1, data: head}, {advance: 100 * time.Second, data: strings.ReplaceAll(": keepalive\n\n", "\n", "\r\n")}, {advance: 80 * time.Second, data: tail}}, 0)
		})
		t.Run(wire+"/long stream", func(t *testing.T) {
			// 800+ simulated seconds with progress gaps under 180 s and keep-alives between
			steps := []obsStep{{advance: 20 * time.Second, data: idleBeat(wire)}, {advance: 20 * time.Second, data: head}}
			for i := 0; i < 5; i++ {
				steps = append(steps, obsStep{advance: 85 * time.Second, data: idleBeat(wire)}, obsStep{advance: 85 * time.Second, data: prog})
			}
			steps = append(steps, obsStep{advance: 100 * time.Second, data: tail})
			rec := answered(t, wire, steps, 0)
			wantFields(t, "long", rec, map[string]any{"end_reason": "complete"})
			if rec["wall_ms"].(int64) < 800000 {
				t.Errorf("wall %v ms, want over 800000", rec["wall_ms"])
			}
		})
	}

	t.Run("responses ping-typed data is progress", func(t *testing.T) {
		// only Messages treats a ping as a keep-alive
		head, tail := idleAnswer("chatgpt")
		ping := "event: ping\ndata: {\"type\":\"ping\"}\n\n"
		answered(t, "chatgpt", []obsStep{{advance: ms1, data: head}, {advance: 100 * time.Second, data: ping}, {advance: 179999 * ms1, data: tail}}, 0)
	})

	t.Run("messages events other than a ping are progress", func(t *testing.T) {
		head, tail := idleAnswer("anthropic")
		note := "data: {\"type\":\"message_note\"}\n\n" // a data object that is not a ping
		answered(t, "anthropic", []obsStep{{advance: ms1, data: head}, {advance: 100 * time.Second, data: note}, {advance: 179999 * ms1, data: tail}}, 0)
		// a comment line before a data line does not make the block a keep-alive
		mixed := ": c\n" + sse(ev("message_note"))
		answered(t, "anthropic", []obsStep{{advance: ms1, data: head}, {advance: 100 * time.Second, data: mixed}, {advance: 179999 * ms1, data: tail}}, 0)
		// an event without a data field is not progress
		stalled(t, "anthropic", []obsStep{{advance: ms1, data: head}, {advance: 100 * time.Second, data: "event: message_note\n\n"}, {advance: 80 * time.Second, data: tail}}, 0)
	})

	t.Run("chat completions body", func(t *testing.T) {
		good := string(mustEncode(goText("hello")))
		hdr := 20 * ms1
		// non-whitespace bytes within the limit complete; the record's progress is the last body read
		rec := answered(t, "opencode-go", []obsStep{{advance: idleLimit - ms1, data: good[:10]}, {advance: idleLimit - ms1, data: good[10:]}}, hdr)
		last := int64(20 + 2*179999)
		wantFields(t, "healthy", rec, map[string]any{"last_progress_ms": last, "last_byte_ms": last, "headers_ms": int64(20)})
		// whitespace between does not renew, a read at the limit is too late
		answered(t, "opencode-go", []obsStep{{advance: ms1, data: good[:10]}, {advance: 100 * time.Second, data: "\n"}, {advance: 79999 * ms1, data: good[10:]}}, hdr)
		rec = stalled(t, "opencode-go", []obsStep{{advance: ms1, data: good[:10]}, {advance: 100 * time.Second, data: "\n"}, {advance: 80 * time.Second, data: good[10:]}}, hdr)
		wantFields(t, "whitespace", rec, map[string]any{"last_progress_ms": int64(21)})
		// whitespace with a content byte in the same read is progress
		answered(t, "opencode-go", []obsStep{{advance: ms1, data: good[:10]}, {advance: 100 * time.Second, data: good[10:11] + " "}, {advance: 179999 * ms1, data: good[11:]}}, hdr)
	})

	t.Run("http error bodies", func(t *testing.T) {
		for _, wire := range []string{"chatgpt", "anthropic", "opencode-go"} {
			// the headers are the first byte and start the idle clock; a whitespace-only read does not renew it
			e, tr, req := idleEnv(t, wire, obsAttempt{status: 400, steps: []obsStep{{advance: 100 * time.Second, data: " \n"}, {advance: 80 * time.Second, data: `{}`}}},
				obsAttempt{steps: []obsStep{{advance: ms1, data: idleFull(wire)}}})
			obs := &observer{}
			if _, err := respondIdle(t, e, req, obs); err != nil {
				t.Fatalf("%s: %v", wire, err)
			}
			recs := attemptRecords(t, obs, 2)
			// the read at the limit is a byte, not progress
			wantFields(t, wire, recs[0], map[string]any{"end_reason": "idle", "outcome": "failed", "last_byte_ms": int64(180000), "last_progress_ms": int64(0)})
			if tr.next != 2 {
				t.Errorf("%s: %d requests", wire, tr.next)
			}
			// content within the limit is read whole and refused normally
			e, _, req = idleEnv(t, wire, obsAttempt{status: 400, steps: []obsStep{{advance: 100 * time.Second, data: " \n"}, {advance: 79999 * ms1, data: `{}`}}})
			obs = &observer{}
			if _, err := respondIdle(t, e, req, obs); err == nil {
				t.Fatalf("%s: a refusal was accepted", wire)
			}
			rec := attemptRecords(t, obs, 1)[0]
			if rec["end_reason"] == "idle" {
				t.Errorf("%s: end_reason idle", wire)
			}
			wantFields(t, wire, rec, map[string]any{"last_progress_ms": int64(179999)})
		}
	})
}

func idleFull(wire string) string {
	head, tail := idleAnswer(wire)
	return head + tail
}

package provider

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// These tests drive Client.Respond with scripted local transports and the real parsers. Reads
// advance the simulated Client.Now, so a silent 90 s costs no real time.

const idleLimit = 180 * time.Second

// idleWires lists the routes with their first-byte limits; stream says whether the body is a stream.
var idleWires = []struct {
	name   string
	first  time.Duration
	stream bool
}{
	{"chatgpt", 90 * time.Second, true},
	{"supergrok", 45 * time.Second, true},
	{"anthropic", 45 * time.Second, true},
	{"opencode-go", 45 * time.Second, false},
}

func idleEnv(t *testing.T, wire string, attempts ...obsAttempt) (*env, *obsTransport, Request) {
	t.Helper()
	if wire != "supergrok" {
		return obsEnv(t, wire, attempts...)
	}
	e := newEnv(t, nil)
	tr := &obsTransport{clk: e.clk, attempts: attempts}
	e.c.HTTP = &http.Client{Transport: tr}
	e.saveCreds("supergrok", e.supergrokCreds())
	return e, tr, Request{Role: grokRole, Instructions: "p", Input: user("x"), CacheID: "streamidle-cache"}
}

// idleAnswer is a complete answer of the wire, split into the stream's head and tail.
func idleAnswer(wire string) (head, tail string) {
	switch wire {
	case "opencode-go":
		good := string(mustEncode(goText("hello")))
		return good[:10], good[10:]
	case "anthropic":
		return wireStream(wire)
	}
	return wireStream("chatgpt")
}

func idleBeat(wire string) string {
	if wire == "anthropic" {
		return ": ping\n\n"
	}
	return ": keepalive\n\n"
}

// idleProgress is a data event that is response progress but no answer: it renews the idle clock.
func idleProgress(wire string) string {
	if wire == "anthropic" {
		return sse(ev("message_note"))
	}
	return frame(map[string]any{"type": "response.in_progress"})
}

func idleText(err error) string {
	if err == nil {
		return ""
	}
	return err.Error() + " " + jsonOfErr(err)
}

func idleSecs(d time.Duration) string { return strconv.Itoa(int(d/time.Second)) + " s" }

func respondIdle(t *testing.T, e *env, req Request, obs Observer) (*Response, error) {
	t.Helper()
	return e.c.Respond(context.Background(), e.s, req, obs)
}

func TestStreamIdleFirstByte(t *testing.T) {
	for _, w := range idleWires {
		first := w.first
		head, tail := idleAnswer(w.name)
		full := head + tail
		want := "no first byte within " + idleSecs(first)

		// stalls is every way the first byte can be late, as attempt scripts of a late and an in-time try
		type stall struct {
			name         string
			late, onTime obsAttempt
			streamOnly   bool
		}
		stalls := []stall{
			{name: "headers late", late: obsAttempt{headersAdvance: first, steps: []obsStep{{advance: ms1, data: full}}},
				onTime: obsAttempt{headersAdvance: first - ms1, steps: []obsStep{{data: full}}}},
			{name: "body late", streamOnly: true, late: obsAttempt{headersAdvance: 10 * ms1, steps: []obsStep{{advance: first - 10*ms1, data: full}}},
				onTime: obsAttempt{headersAdvance: 10 * ms1, steps: []obsStep{{advance: first - 11*ms1, data: full}}}},
			// the headers are not the first stream byte: silence after them still expires at the limit
			{name: "headers then silence", streamOnly: true, late: obsAttempt{headersAdvance: first - ms1, steps: []obsStep{{advance: ms1}, {data: full}}},
				onTime: obsAttempt{headersAdvance: first - ms1, steps: []obsStep{{data: full}}}},
		}
		for _, st := range stalls {
			if st.streamOnly && !w.stream {
				continue
			}
			t.Run(w.name+"/"+st.name, func(t *testing.T) {
				ok := obsAttempt{steps: []obsStep{{advance: ms1, data: full}}}
				// just before the limit: the first attempt answers
				e, tr, req := idleEnv(t, w.name, st.onTime)
				obs := &observer{}
				if _, err := respondIdle(t, e, req, obs); err != nil {
					t.Fatal(err)
				}
				wantFields(t, "in time", attemptRecords(t, obs, 1)[0], map[string]any{"outcome": "completed"})
				if tr.next != 1 {
					t.Fatalf("%d requests, want 1", tr.next)
				}

				// at the limit: a failed idle attempt, retried and answered
				e, tr, req = idleEnv(t, w.name, st.late, ok)
				obs = &observer{}
				if _, err := respondIdle(t, e, req, obs); err != nil {
					t.Fatal(err)
				}
				recs := attemptRecords(t, obs, 2)
				wantFields(t, "late", recs[0], map[string]any{"outcome": "failed", "end_reason": "idle", "error": "provider_failure"})
				wantFields(t, "retry", recs[1], map[string]any{"outcome": "completed", "error": nil})
				if !reflect.DeepEqual(e.clk.slept(), []time.Duration{2 * time.Second}) || tr.next != 2 {
					t.Fatalf("slept %v after %d requests", e.clk.slept(), tr.next)
				}

				// silence on every attempt: the usual three attempts, with the timeout in the detail
				e, tr, req = idleEnv(t, w.name, st.late, st.late, st.late, st.late)
				_, err := respondIdle(t, e, req, nil)
				if err == nil || !strings.Contains(idleText(err), "did not answer after 3 attempts") || !strings.Contains(idleText(err), want) {
					t.Fatalf("error %v, want the detail %q", err, want)
				}
				if tr.next != 3 || !reflect.DeepEqual(e.clk.slept(), []time.Duration{2 * time.Second, 8 * time.Second}) {
					t.Fatalf("%d requests, slept %v", tr.next, e.clk.slept())
				}
			})
		}
	}

	t.Run("single", func(t *testing.T) {
		head, tail := idleAnswer("chatgpt")
		late := obsAttempt{headersAdvance: 90 * time.Second, steps: []obsStep{{data: head + tail}}}
		e, tr, req := idleEnv(t, "chatgpt", late, obsAttempt{steps: []obsStep{{data: head + tail}}})
		req.Single = true
		obs := &observer{}
		_, err := respondIdle(t, e, req, obs)
		if err == nil || !strings.Contains(idleText(err), "no first byte within 90 s") || tr.next != 1 || len(e.clk.slept()) != 0 {
			t.Fatalf("%v after %d requests, slept %v", err, tr.next, e.clk.slept())
		}
		wantFields(t, "single", attemptRecords(t, obs, 1)[0], map[string]any{"outcome": "failed", "end_reason": "idle"})
	})
}

func TestStreamIdleGap(t *testing.T) {
	for _, w := range idleWires {
		head, tail := idleAnswer(w.name)
		beat := idleBeat(w.name)
		full := head + tail
		stalled := "stream idle for 180 s"
		// each case is a script whose idle attempt must fail and a script that must not
		type gap struct {
			name     string
			ok, late []obsStep
		}
		var cases []gap
		if w.stream {
			cases = []gap{
				{"bytes before the limit", []obsStep{{advance: ms1, data: head}, {advance: idleLimit - ms1, data: tail}}, []obsStep{{advance: ms1, data: head}, {advance: idleLimit, data: tail}}},
				// keep-alives between progress neither renew the clock nor meet the limit
				{"keep-alives", []obsStep{{advance: ms1, data: head}, {advance: 100 * time.Second, data: beat}, {advance: 79 * time.Second, data: tail}},
					[]obsStep{{advance: ms1, data: head}, {advance: 100 * time.Second, data: beat}, {advance: 80 * time.Second, data: tail}}},
				// an unfinished event renews the clock in the read that completes it
				{"partial frames", []obsStep{{advance: ms1, data: head}, {advance: 100 * time.Second, data: tail[:5]}, {advance: 79 * time.Second, data: tail[5:]}},
					[]obsStep{{advance: ms1, data: head}, {advance: 100 * time.Second, data: tail[:5]}, {advance: 80 * time.Second, data: tail[5:]}}},
				{"progress renews", []obsStep{{advance: ms1, data: head}, {advance: idleLimit - ms1, data: idleProgress(w.name)}, {advance: idleLimit - ms1, data: tail}},
					[]obsStep{{advance: ms1, data: head}, {advance: idleLimit - ms1, data: idleProgress(w.name)}, {advance: idleLimit, data: tail}}},
				// a read of no bytes is neither progress nor a reset
				{"zero reads", []obsStep{{advance: ms1, data: head}, {advance: 100 * time.Second}, {advance: 79 * time.Second, data: tail}},
					[]obsStep{{advance: ms1, data: head}, {advance: 100 * time.Second}, {advance: 80 * time.Second, data: tail}}},
			}
		} else {
			// the headers are the first byte and the start of idle: body bytes follow within the idle limit, not the first-byte limit
			cases = []gap{
				{"bytes before the limit", []obsStep{{advance: idleLimit - ms1, data: head}, {advance: idleLimit - ms1, data: tail}}, []obsStep{{advance: ms1, data: head}, {advance: idleLimit, data: tail}}},
				{"zero reads", []obsStep{{advance: ms1, data: head}, {advance: 100 * time.Second}, {advance: 79 * time.Second, data: tail}},
					[]obsStep{{advance: ms1, data: head}, {advance: 100 * time.Second}, {advance: 80 * time.Second, data: tail}}},
			}
		}
		for _, c := range cases {
			t.Run(w.name+"/"+c.name, func(t *testing.T) {
				hdr := time.Duration(0)
				if !w.stream {
					hdr = w.first - ms1
				}
				okA := obsAttempt{headersAdvance: hdr, steps: c.ok}
				lateA := obsAttempt{headersAdvance: hdr, steps: c.late}
				e, _, req := idleEnv(t, w.name, okA)
				obs := &observer{}
				if _, err := respondIdle(t, e, req, obs); err != nil {
					t.Fatal(err)
				}
				wantFields(t, "in time", attemptRecords(t, obs, 1)[0], map[string]any{"outcome": "completed"})

				e, tr, req := idleEnv(t, w.name, lateA, obsAttempt{steps: []obsStep{{advance: ms1, data: full}}})
				obs = &observer{}
				if _, err := respondIdle(t, e, req, obs); err != nil {
					t.Fatal(err)
				}
				recs := attemptRecords(t, obs, 2)
				wantFields(t, "idle", recs[0], map[string]any{"outcome": "failed", "end_reason": "idle"})
				wantFields(t, "retry", recs[1], map[string]any{"outcome": "completed"})
				if tr.next != 2 || !reflect.DeepEqual(e.clk.slept(), []time.Duration{2 * time.Second}) {
					t.Fatalf("%d requests, slept %v", tr.next, e.clk.slept())
				}

				e, tr, req = idleEnv(t, w.name, lateA, lateA, lateA, lateA)
				_, err := respondIdle(t, e, req, nil)
				if err == nil || !strings.Contains(idleText(err), stalled) || tr.next != 3 {
					t.Fatalf("error %v after %d requests, want %q after 3", err, tr.next, stalled)
				}
			})
		}
	}
}

func TestStreamIdleLongStream(t *testing.T) {
	for _, wire := range []string{"chatgpt", "anthropic"} {
		t.Run(wire, func(t *testing.T) {
			head, tail := idleAnswer(wire)
			beat := idleBeat(wire)
			// progress events with keep-alives between them, through 880 simulated seconds
			var steps []obsStep
			steps = append(steps, obsStep{advance: 20 * time.Second, data: beat}, obsStep{advance: 20 * time.Second, data: idleProgress(wire)})
			steps = append(steps, obsStep{advance: ms1, data: head})
			for i := 0; i < 4; i++ {
				steps = append(steps, obsStep{advance: 85 * time.Second, data: beat}, obsStep{advance: 85 * time.Second, data: idleProgress(wire)})
			}
			steps = append(steps, obsStep{advance: 170 * time.Second, data: tail})
			e, tr, req := idleEnv(t, wire, obsAttempt{steps: steps})
			obs := &observer{}
			if _, err := respondIdle(t, e, req, obs); err != nil {
				t.Fatal(err)
			}
			rec := attemptRecords(t, obs, 1)[0]
			wantFields(t, "long", rec, map[string]any{"outcome": "completed", "end_reason": "complete"})
			if rec["wall_ms"].(int64) < 800000 || rec["max_gap_ms"].(int64) >= 180000 || tr.next != 1 || len(e.clk.slept()) != 0 {
				t.Fatalf("wall %v max gap %v, %d requests, slept %v", rec["wall_ms"], rec["max_gap_ms"], tr.next, e.clk.slept())
			}
		})
	}
}

func TestStreamIdleAbsoluteBudget(t *testing.T) {
	// streamingFor is an answer that keeps sending progress every 100 s and never completes
	streamingFor := func(wire string, n int) []obsStep {
		head, _ := idleAnswer(wire)
		steps := []obsStep{{advance: ms1, data: head}}
		for i := 0; i < n; i++ {
			steps = append(steps, obsStep{advance: 100 * time.Second, data: idleProgress(wire)})
		}
		return steps
	}
	for _, wire := range []string{"chatgpt", "anthropic"} {
		t.Run(wire+"/progress cannot renew", func(t *testing.T) {
			e, tr, req := idleEnv(t, wire, obsAttempt{steps: streamingFor(wire, 20)}, obsAttempt{steps: streamingFor(wire, 20)})
			obs := &observer{}
			_, err := respondIdle(t, e, req, obs)
			if err == nil || !strings.Contains(idleText(err), "response wait exceeded 30 minutes") || tr.next != 1 || len(e.clk.slept()) != 0 {
				t.Fatalf("%v after %d requests, slept %v", err, tr.next, e.clk.slept())
			}
			rec := attemptRecords(t, obs, 1)[0]
			wantFields(t, "budget", rec, map[string]any{"end_reason": "budget", "outcome": "failed"})

			// the client's lower budget keeps its own text
			e, tr, req = idleEnv(t, wire, obsAttempt{steps: streamingFor(wire, 20)})
			e.c.ResponseBudget = 5 * time.Minute
			_, err = respondIdle(t, e, req, nil)
			if err == nil || !strings.Contains(idleText(err), "response wait exceeded 5m0s") || tr.next != 1 {
				t.Fatalf("%v after %d requests", err, tr.next)
			}
		})

		t.Run(wire+"/shared across retry and backoff", func(t *testing.T) {
			first := idleWires[0].first
			if wire == "anthropic" {
				first = 45 * time.Second
			}
			silent := obsAttempt{steps: []obsStep{{advance: first, data: "x"}}}
			e, tr, req := idleEnv(t, wire, silent, obsAttempt{steps: streamingFor(wire, 20)}, obsAttempt{steps: streamingFor(wire, 20)})
			e.c.ResponseBudget = 5 * time.Minute
			obs := &observer{}
			_, err := respondIdle(t, e, req, obs)
			if err == nil || !strings.Contains(idleText(err), "response wait exceeded") || tr.next != 2 || !reflect.DeepEqual(e.clk.slept(), []time.Duration{2 * time.Second}) {
				t.Fatalf("%v after %d requests, slept %v", err, tr.next, e.clk.slept())
			}
			recs := attemptRecords(t, obs, 2)
			wantFields(t, "first", recs[0], map[string]any{"end_reason": "idle", "outcome": "failed"})
			wantFields(t, "second", recs[1], map[string]any{"end_reason": "budget", "outcome": "failed"})
			// the retry has what is left of the budget, not a fresh 5 minutes: it ends at the
			// read that crosses the deadline, the fourth
			if ms := recs[1]["wall_ms"].(int64); ms != 300001 {
				t.Errorf("second attempt ran %d ms, want 300001", ms)
			}
		})

		t.Run(wire+"/budget wins an overlapping timeout", func(t *testing.T) {
			for _, c := range []struct {
				name string
				a    obsAttempt
			}{
				{"body", obsAttempt{steps: []obsStep{{advance: idleFirst(wire), data: "x"}}}},
				{"headers", obsAttempt{headersAdvance: idleFirst(wire), steps: []obsStep{{data: "x"}}}},
			} {
				e, tr, req := idleEnv(t, wire, c.a, c.a)
				e.c.ResponseBudget = idleFirst(wire)
				obs := &observer{}
				_, err := respondIdle(t, e, req, obs)
				if err == nil || !strings.Contains(idleText(err), "response wait exceeded") || strings.Contains(idleText(err), "no first byte") || tr.next != 1 {
					t.Fatalf("%s: %v after %d requests", c.name, err, tr.next)
				}
				if rec := attemptRecords(t, obs, 1)[0]; rec["end_reason"] == "idle" {
					t.Errorf("%s: end_reason idle", c.name)
				}
			}
		})
	}
}

func idleFirst(wire string) time.Duration {
	if wire == "chatgpt" {
		return 90 * time.Second
	}
	return 45 * time.Second
}

func TestStreamIdleCompatibility(t *testing.T) {
	for _, w := range idleWires {
		t.Run(w.name, func(t *testing.T) {
			head, tail := idleAnswer(w.name)
			late := obsAttempt{headersAdvance: w.first, steps: []obsStep{{data: head + tail}}}
			ok := obsAttempt{steps: []obsStep{{advance: ms1, data: head + tail}}}
			e, tr, req := idleEnv(t, w.name, late, ok)
			if _, err := respondIdle(t, e, req, nil); err != nil { // no observer
				t.Fatal(err)
			}
			info, _ := Lookup(req.Role.Provider)
			want, err := encodeBody(info, e.c.Body(req))
			if err != nil || len(tr.bodies) != 2 || !bytes.Equal(tr.bodies[0], want) || !bytes.Equal(tr.bodies[1], want) {
				t.Fatalf("request bytes differ after a timeout: %v\n got %s\nwant %s", err, tr.bodies, want)
			}

			// three exhausted attempts and the unchanged 2 s then 8 s backoff
			e, tr, req = idleEnv(t, w.name, late, late, late, late)
			obs := &observer{}
			if _, err := respondIdle(t, e, req, obs); err == nil || tr.next != 3 || !reflect.DeepEqual(e.clk.slept(), []time.Duration{2 * time.Second, 8 * time.Second}) {
				t.Fatalf("%v after %d requests, slept %v", err, tr.next, e.clk.slept())
			}
			for _, rec := range attemptRecords(t, obs, 3) {
				wantFields(t, "exhausted", rec, map[string]any{"end_reason": "idle", "outcome": "failed"})
			}

			// Request.Single is single-shot on ChatGPT only
			e, tr, req = idleEnv(t, w.name, late, late, late)
			req.Single = true
			_, err = respondIdle(t, e, req, nil)
			wantRequests := 3
			if w.name == "chatgpt" {
				wantRequests = 1
			}
			if err == nil || tr.next != wantRequests {
				t.Fatalf("single: %v after %d requests, want %d", err, tr.next, wantRequests)
			}
		})
	}

	t.Run("a healthy answer keeps its record", func(t *testing.T) {
		good := string(mustEncode(goText("hello")))
		e, _, req := idleEnv(t, "opencode-go", obsAttempt{headersAdvance: 20 * ms1, steps: []obsStep{{advance: 30 * ms1, data: good}}})
		obs := &observer{}
		if _, err := respondIdle(t, e, req, obs); err != nil {
			t.Fatal(err)
		}
		wantFields(t, "chat", attemptRecords(t, obs, 1)[0], map[string]any{"outcome": "completed", "end_reason": nil, "first_byte_ms": nil, "stream_bytes": nil, "headers_ms": int64(20), "last_byte_ms": int64(50), "last_progress_ms": int64(50)})
	})

	t.Run("budget ceiling and public options are unchanged", func(t *testing.T) {
		if ResponseBudget != 30*time.Minute {
			t.Fatalf("ResponseBudget = %v", ResponseBudget)
		}
		exported := func(v any) []string {
			var names []string
			rt := reflect.TypeOf(v)
			for i := 0; i < rt.NumField(); i++ {
				if rt.Field(i).IsExported() {
					names = append(names, rt.Field(i).Name)
				}
			}
			return names
		}
		wantClient := []string{"HTTP", "Now", "Sleep", "Cache", "Locker", "Input", "Version", "ResponseBudget"}
		wantRequest := []string{"Role", "Instructions", "Input", "Tools", "ToolChoice", "Single", "CacheID", "Scope", "Cache", "Context"}
		if got := exported(Client{}); !reflect.DeepEqual(got, wantClient) {
			t.Errorf("Client options = %v, want %v", got, wantClient)
		}
		if got := exported(Request{}); !reflect.DeepEqual(got, wantRequest) {
			t.Errorf("Request options = %v, want %v", got, wantRequest)
		}
	})
}

// ---- blocked I/O: nothing arrives until the watchdog cancels ----

type blockAttempt struct {
	headers   bool     // the request itself never answers
	chunks    []string // delivered before the body blocks
	hold      bool     // the body blocks after its chunks (else it ends)
	ignoreCtx bool     // the blocked body ends only when closed, as a transport that ignores the context
}

type blockBody struct {
	ctx       context.Context
	chunks    []string
	hold      bool
	ignoreCtx bool
	blocked   chan<- string
	closed    chan struct{}
	once      sync.Once
	mu        sync.Mutex
	late      bool // a byte was asked for after the block ended
}

func (b *blockBody) Read(p []byte) (int, error) {
	if len(b.chunks) > 0 {
		n := copy(p, b.chunks[0])
		b.chunks = b.chunks[1:]
		return n, nil
	}
	if !b.hold {
		return 0, io.EOF
	}
	b.blocked <- "body"
	var done <-chan struct{}
	if !b.ignoreCtx {
		done = b.ctx.Done()
	}
	select {
	case <-done:
		return 0, b.ctx.Err()
	case <-b.closed:
		return 0, errors.New("body closed")
	}
}

func (b *blockBody) Close() error {
	b.once.Do(func() { close(b.closed) })
	return nil
}

func (b *blockBody) isClosed() bool {
	select {
	case <-b.closed:
		return true
	default:
		return false
	}
}

type blockTransport struct {
	mu       sync.Mutex
	attempts []blockAttempt
	next     int
	blocked  chan string
	bodies   []*blockBody
}

func (tr *blockTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	io.Copy(io.Discard, req.Body)
	tr.mu.Lock()
	if tr.next >= len(tr.attempts) {
		tr.mu.Unlock()
		return nil, errors.New("script exhausted")
	}
	a := tr.attempts[tr.next]
	tr.next++
	tr.mu.Unlock()
	if a.headers {
		tr.blocked <- "headers"
		<-req.Context().Done()
		return nil, req.Context().Err()
	}
	b := &blockBody{ctx: req.Context(), chunks: a.chunks, hold: a.hold, ignoreCtx: a.ignoreCtx, blocked: tr.blocked, closed: make(chan struct{})}
	tr.mu.Lock()
	tr.bodies = append(tr.bodies, b)
	tr.mu.Unlock()
	return &http.Response{StatusCode: 200, Header: http.Header{}, Body: b, Request: req}, nil
}

func TestStreamIdleBlocked(t *testing.T) {
	old := idlePoll
	idlePoll = 5 * time.Millisecond
	defer func() { idlePoll = old }()

	type block struct {
		name   string
		wire   string
		stall  blockAttempt
		expire time.Duration // simulated silence that ends the attempt
	}
	var blocks []block
	for _, w := range idleWires {
		head, _ := idleAnswer(w.name)
		blocks = append(blocks, block{w.name + "/before headers", w.name, blockAttempt{headers: true}, w.first})
		if w.stream {
			blocks = append(blocks, block{w.name + "/headers then silence", w.name, blockAttempt{hold: true}, w.first})
			blocks = append(blocks, block{w.name + "/after a byte", w.name, blockAttempt{chunks: []string{head}, hold: true}, idleLimit})
			blocks = append(blocks, block{w.name + "/transport ignoring cancellation", w.name, blockAttempt{chunks: []string{head}, hold: true, ignoreCtx: true}, idleLimit})
		} else {
			blocks = append(blocks, block{w.name + "/after a byte", w.name, blockAttempt{chunks: []string{head}, hold: true}, idleLimit})
		}
	}
	for _, b := range blocks {
		t.Run(b.name, func(t *testing.T) {
			head, tail := idleAnswer(b.wire)
			e, _, req := idleEnv(t, b.wire)
			tr := &blockTransport{attempts: []blockAttempt{b.stall, {chunks: []string{head + tail}}}, blocked: make(chan string, 4)}
			e.c.HTTP = &http.Client{Transport: tr}
			obs := &observer{}
			type outcome struct {
				resp *Response
				err  error
			}
			done := make(chan outcome, 1)
			go func() {
				resp, err := e.c.Respond(context.Background(), e.s, req, obs)
				done <- outcome{resp, err}
			}()
			guard := time.After(15 * time.Second)
			select {
			case <-tr.blocked:
			case <-guard:
				t.Fatal("the attempt never blocked")
			}
			// shy of the limit the attempt keeps waiting
			e.clk.advance(b.expire - time.Second)
			select {
			case o := <-done:
				t.Fatalf("ended a second early: %v", o.err)
			case <-time.After(100 * time.Millisecond):
			}
			e.clk.advance(time.Second)
			select {
			case o := <-done:
				if o.err != nil || o.resp == nil {
					t.Fatalf("retry after the timeout: %v", o.err)
				}
			case <-guard:
				t.Fatal("blocked attempt was not cancelled")
			}
			recs := attemptRecords(t, obs, 2)
			wantFields(t, "blocked", recs[0], map[string]any{"outcome": "failed", "end_reason": "idle"})
			wantFields(t, "retry", recs[1], map[string]any{"outcome": "completed"})
			// no byte arrived late: the stalled attempt saw only what it delivered
			delivered := int64(0)
			for _, c := range b.stall.chunks {
				delivered += int64(len(c))
			}
			if b.wire != "opencode-go" && recs[0]["stream_bytes"] != nil && recs[0]["stream_bytes"].(int64) != delivered {
				t.Errorf("stream_bytes = %v, want %d", recs[0]["stream_bytes"], delivered)
			}
			if !reflect.DeepEqual(e.clk.slept(), []time.Duration{2 * time.Second}) {
				t.Errorf("slept %v", e.clk.slept())
			}
			tr.mu.Lock()
			defer tr.mu.Unlock()
			for i, body := range tr.bodies {
				if !body.isClosed() {
					t.Errorf("attempt %d body left open", i+1)
				}
			}
			if liveWatches.Load() != 0 {
				t.Errorf("%d attempt timers still running", liveWatches.Load())
			}
		})
	}

	t.Run("timers stop after success and failure", func(t *testing.T) {
		head, tail := idleAnswer("anthropic")
		e, _, req := idleEnv(t, "anthropic", obsAttempt{steps: []obsStep{{advance: ms1, data: head + tail}}})
		if _, err := respondIdle(t, e, req, nil); err != nil {
			t.Fatal(err)
		}
		bad := obsAttempt{status: 400, steps: []obsStep{{advance: ms1, data: `{}`}}}
		e, _, req = idleEnv(t, "anthropic", bad)
		if _, err := respondIdle(t, e, req, nil); err == nil {
			t.Fatal("refusal accepted")
		}
		if n := liveWatches.Load(); n != 0 {
			t.Fatalf("%d attempt timers still running", n)
		}
	})
}

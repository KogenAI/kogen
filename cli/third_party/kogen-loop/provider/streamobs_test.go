package provider

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"
)

// ---- scripted transport: reads advance the test clock, so every timing is exact ----

type obsStep struct {
	advance time.Duration
	data    string
	err     error
	do      func()
}

type obsAttempt struct {
	status         int
	headersAdvance time.Duration
	steps          []obsStep
	doErr          error
}

type scriptBody struct {
	clk   *clock
	steps []obsStep
	i     int
}

func (b *scriptBody) Read(p []byte) (int, error) {
	if b.i >= len(b.steps) {
		return 0, io.EOF
	}
	s := b.steps[b.i]
	b.i++
	b.clk.advance(s.advance)
	if s.do != nil {
		s.do()
	}
	return copy(p, s.data), s.err
}

func (b *scriptBody) Close() error { return nil }

func (c *clock) advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

type obsTransport struct {
	clk      *clock
	attempts []obsAttempt
	next     int
	bodies   [][]byte
}

func (tr *obsTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	body, _ := io.ReadAll(req.Body)
	tr.bodies = append(tr.bodies, body)
	if tr.next >= len(tr.attempts) {
		return nil, errors.New("script exhausted")
	}
	a := tr.attempts[tr.next]
	tr.next++
	tr.clk.advance(a.headersAdvance)
	if a.doErr != nil {
		return nil, a.doErr
	}
	status := a.status
	if status == 0 {
		status = 200
	}
	h := http.Header{"X-Request-Id": []string{"req-fixture"}}
	return &http.Response{StatusCode: status, Header: h, Body: &scriptBody{clk: tr.clk, steps: a.steps}, Request: req}, nil
}

// obsEnv is a client whose HTTP answers come from the script; wire is chatgpt (Responses),
// anthropic (Messages) or opencode-go (Chat Completions).
func obsEnv(t *testing.T, wire string, attempts ...obsAttempt) (*env, *obsTransport, Request) {
	t.Helper()
	e := newEnv(t, nil)
	tr := &obsTransport{clk: e.clk, attempts: attempts}
	e.c.HTTP = &http.Client{Transport: tr}
	req := Request{Instructions: "p", Input: user("x"), CacheID: "streamobs-cache"}
	switch wire {
	case "chatgpt":
		e.saveCreds("chatgpt", e.chatgptCreds())
		req.Role = Role{Model: "gpt-6.1-sol", Effort: "high"}
	case "anthropic":
		e.saveCreds("anthropic", map[string]any{"provider": "anthropic", "api_key": testKey})
		req.Role = claudeRole
	default:
		e.saveCreds("opencode-go", map[string]any{"provider": "opencode-go", "api_key": testKey})
		req.Role = goRole
	}
	return e, tr, req
}

func msgItem() map[string]any {
	return map[string]any{"type": "message", "id": "message", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": "ok", "annotations": []any{}}}}
}

func respDelta() string {
	return frame(map[string]any{"type": "response.output_text.delta", "output_index": int64(0), "delta": "hi"})
}

func respTail() string {
	return frame(itemDone(0, msgItem())) + frame(done(map[string]any{"usage": map[string]any{
		"input_tokens": int64(1), "input_tokens_details": map[string]any{"cached_tokens": int64(0)},
		"output_tokens": int64(1), "output_tokens_details": map[string]any{"reasoning_tokens": int64(0)}}}))
}

func msgStart() string {
	return sse(start("input_tokens", int64(10), "cache_read_input_tokens", int64(0), "cache_creation_input_tokens", int64(0)))
}

func msgBlockStart() string {
	return sse(ev("content_block_start", "index", int64(0), "content_block", map[string]any{"type": "text", "text": ""}))
}

func msgDelta() string {
	return sse(ev("content_block_delta", "index", int64(0), "delta", map[string]any{"type": "text_delta", "text": "hi"}))
}

func msgTail() string {
	return sse(ev("content_block_stop", "index", int64(0))) + sse(finish("end_turn")...)
}

// wireStream is a complete answer split after its first delta.
func wireStream(wire string) (head, tail string) {
	if wire == "anthropic" {
		return msgStart() + msgBlockStart() + msgDelta(), msgTail()
	}
	return respDelta(), respTail()
}

func attemptRecords(t *testing.T, obs *observer, n int) []map[string]any {
	t.Helper()
	recs := obs.records()
	if len(recs) != n {
		t.Fatalf("%d attempt records, want %d: %s", len(recs), n, jsonOf(t, recs))
	}
	return recs
}

func wantFields(t *testing.T, label string, rec map[string]any, want map[string]any) {
	t.Helper()
	for k, v := range want {
		if !reflect.DeepEqual(rec[k], v) {
			t.Errorf("%s: %s = %#v, want %#v", label, k, rec[k], v)
		}
	}
}

func hist(a, b, c, d, e, f int64) []any { return []any{a, b, c, d, e, f} }

const ms1 = time.Millisecond

func TestStreamObsTiming(t *testing.T) {
	t.Run("responses", func(t *testing.T) {
		d := respDelta()
		fail := frame(map[string]any{"type": "error", "error": map[string]any{"code": "server_error", "message": "x"}})
		first := ": keepalive\n\n"
		half1, half2 := d[:10], d[10:]+fail
		e, _, req := obsEnv(t, "chatgpt",
			obsAttempt{headersAdvance: 40 * ms1, steps: []obsStep{
				{advance: 100 * ms1, data: first},
				{advance: 50 * ms1}, // a zero-byte read counts as neither a byte nor a gap boundary
				{advance: 150 * ms1, data: half1},
				{advance: 300 * ms1, data: half2},
			}},
			obsAttempt{headersAdvance: 10 * ms1, steps: []obsStep{
				{advance: 20 * ms1, data: ": keepalive\n\n"},
				{advance: 1500 * ms1, data: d + respTail()},
			}},
		)
		obs := &observer{}
		if _, err := e.c.Respond(context.Background(), e.s, req, obs); err != nil {
			t.Fatal(err)
		}
		recs := attemptRecords(t, obs, 2)
		wantFields(t, "attempt 1", recs[0], map[string]any{
			"headers_ms": int64(40), "first_byte_ms": int64(140), "ttft_ms": int64(640), "last_byte_ms": int64(640),
			"max_gap_ms": int64(300), "gap_hist": hist(2, 0, 0, 0, 0, 0), "stream_bytes": int64(len(first) + len(half1) + len(half2)),
			"end_reason": "complete", "outcome": "failed",
		})
		// the retry is a new attempt: its times restart at its own start
		wantFields(t, "attempt 2", recs[1], map[string]any{
			"headers_ms": int64(10), "first_byte_ms": int64(30), "ttft_ms": int64(1530), "last_byte_ms": int64(1530),
			"max_gap_ms": int64(1500), "gap_hist": hist(0, 1, 0, 0, 0, 0), "stream_bytes": int64(len(": keepalive\n\n") + len(d+respTail())),
			"end_reason": "complete", "outcome": "completed",
		})
	})

	t.Run("messages", func(t *testing.T) {
		delta := msgDelta()
		cut := obsAttempt{headersAdvance: 30 * ms1, steps: []obsStep{
			{advance: 200 * ms1, data: ": ping\n\n" + msgStart()},
			{advance: 61 * time.Second, data: msgBlockStart() + delta[:15]},
			{advance: time.Second, data: delta[15:]},
		}}
		full := msgStart() + msgBlockStart() + msgDelta() + msgTail()
		e, _, req := obsEnv(t, "anthropic", cut, obsAttempt{headersAdvance: 5 * ms1, steps: []obsStep{{advance: 40 * time.Second, data: full}}})
		obs := &observer{}
		if _, err := e.c.Respond(context.Background(), e.s, req, obs); err != nil {
			t.Fatal(err)
		}
		recs := attemptRecords(t, obs, 2)
		wantFields(t, "attempt 1", recs[0], map[string]any{
			"headers_ms": int64(30), "first_byte_ms": int64(230), "ttft_ms": int64(62230), "last_byte_ms": int64(62230),
			"max_gap_ms": int64(61000), "gap_hist": hist(1, 0, 0, 0, 1, 0),
			"stream_bytes": int64(len(": ping\n\n"+msgStart()) + len(msgBlockStart()+delta)), "end_reason": "transport", "outcome": "failed",
		})
		wantFields(t, "attempt 2", recs[1], map[string]any{
			"headers_ms": int64(5), "first_byte_ms": int64(40005), "ttft_ms": int64(40005), "last_byte_ms": int64(40005),
			"max_gap_ms": int64(0), "gap_hist": hist(0, 0, 0, 0, 0, 0), "stream_bytes": int64(len(full)), "end_reason": "complete", "outcome": "completed",
		})
	})

	t.Run("deltas of every kind and only deltas", func(t *testing.T) {
		for _, c := range []struct {
			name, wire string
			chunks     []string
			ttft       any
		}{
			{"reasoning delta", "chatgpt", []string{frame(map[string]any{"type": "response.created", "response": map[string]any{}}), frame(map[string]any{"type": "response.reasoning_summary_text.delta", "delta": "t"}), respTail()}, int64(20)},
			{"tool delta", "chatgpt", []string{frame(map[string]any{"type": "response.output_item.added", "output_index": int64(0)}), frame(map[string]any{"type": "response.function_call_arguments.delta", "delta": "{"}), respTail()}, int64(20)},
			{"no delta", "chatgpt", []string{frame(map[string]any{"type": "response.created", "response": map[string]any{}}), respTail()}, nil},
			{"message_delta", "anthropic", []string{msgStart(), sse(ev("message_delta", "delta", map[string]any{"stop_reason": "end_turn"}, "usage", map[string]any{"output_tokens": int64(1)})), sse(ev("message_stop"))}, int64(20)},
			{"no delta before stop", "anthropic", []string{msgStart(), msgBlockStart(), sse(ev("content_block_stop", "index", int64(0)))}, nil},
		} {
			var steps []obsStep
			for _, ch := range c.chunks {
				steps = append(steps, obsStep{advance: 10 * ms1, data: ch})
			}
			e, _, req := obsEnv(t, c.wire, obsAttempt{steps: steps})
			obs := &observer{}
			e.c.Respond(context.Background(), e.s, req, obs)
			recs := obs.records()
			if len(recs) == 0 {
				t.Fatalf("%s: no record", c.name)
			}
			if got := recs[0]["ttft_ms"]; !reflect.DeepEqual(got, c.ttft) {
				t.Errorf("%s: ttft_ms = %#v, want %#v", c.name, got, c.ttft)
			}
		}
	})

	t.Run("a stream without bytes", func(t *testing.T) {
		for _, wire := range []string{"chatgpt", "anthropic"} {
			e, _, req := obsEnv(t, wire, obsAttempt{headersAdvance: 7 * ms1, steps: []obsStep{{advance: 3 * ms1}}})
			obs := &observer{}
			e.c.Respond(context.Background(), e.s, req, obs)
			wantFields(t, wire, obs.records()[0], map[string]any{
				"headers_ms": int64(7), "first_byte_ms": nil, "last_byte_ms": nil, "ttft_ms": nil, "max_gap_ms": int64(0),
				"gap_hist": hist(0, 0, 0, 0, 0, 0), "stream_bytes": int64(0), "end_reason": "transport",
			})
		}
	})
}

func TestStreamObsGaps(t *testing.T) {
	base := time.Unix(1000, 0)
	s := time.Second
	for _, c := range []struct {
		gap    time.Duration
		bucket int
	}{
		{0, 0}, {999 * ms1, 0}, {s, 0}, {s + 1, 1}, {s + ms1, 1},
		{10*s - 1, 1}, {10 * s, 1}, {10*s + 1, 2},
		{30 * s, 2}, {30*s + 1, 3},
		{60 * s, 3}, {60*s + 1, 4},
		{120 * s, 4}, {120*s + 1, 5}, {3600 * s, 5},
	} {
		o := newStreamObs(base)
		o.beginStream()
		o.read(base.Add(5*s), 1)
		o.read(base.Add(5*s+c.gap), 1)
		var want [6]int64
		want[c.bucket] = 1
		f := o.fields()
		if !reflect.DeepEqual(f["gap_hist"], hist(want[0], want[1], want[2], want[3], want[4], want[5])) || f["max_gap_ms"] != c.gap.Milliseconds() {
			t.Errorf("gap %v: hist %v max %v, want bucket %d max %d", c.gap, f["gap_hist"], f["max_gap_ms"], c.bucket, c.gap.Milliseconds())
		}
	}

	t.Run("no reads", func(t *testing.T) {
		o := newStreamObs(base)
		o.gotHeaders(base.Add(900 * s))
		o.beginStream()
		o.read(base.Add(901*s), 0) // a zero-byte read is nothing
		wantFields(t, "none", o.fields(), map[string]any{
			"headers_ms": int64(900000), "first_byte_ms": nil, "last_byte_ms": nil, "max_gap_ms": int64(0),
			"gap_hist": hist(0, 0, 0, 0, 0, 0), "stream_bytes": int64(0), "ttft_ms": nil,
		})
	})

	t.Run("one read", func(t *testing.T) {
		o := newStreamObs(base)
		o.gotHeaders(base.Add(ms1))
		o.beginStream()
		o.read(base.Add(500*s), 7) // headers to first byte is not a gap
		wantFields(t, "one", o.fields(), map[string]any{
			"first_byte_ms": int64(500000), "last_byte_ms": int64(500000), "max_gap_ms": int64(0),
			"gap_hist": hist(0, 0, 0, 0, 0, 0), "stream_bytes": int64(7),
		})
	})

	t.Run("many reads in order", func(t *testing.T) {
		o := newStreamObs(base)
		o.beginStream()
		at := base
		for _, g := range []time.Duration{500 * ms1, 2 * s, 15 * s, 45 * s, 90 * s, 200 * s, 1500 * ms1 / 3} {
			at = at.Add(g)
			o.read(at, 3)
			o.read(at.Add(time.Hour), 0) // terminal zero-byte reads are excluded
		}
		// the first read starts the series: 6 gaps from 7 reads
		wantFields(t, "many", o.fields(), map[string]any{
			"gap_hist": hist(1, 1, 1, 1, 1, 1), "max_gap_ms": int64(200000), "stream_bytes": int64(21),
			"first_byte_ms": int64(500), "last_byte_ms": (500*ms1 + 2*s + 15*s + 45*s + 90*s + 200*s + 500*ms1).Milliseconds(),
		})
	})
}

func TestStreamObsEndReasons(t *testing.T) {
	var interrupt func(e *env) func()
	interrupt = func(e *env) func() { return func() { e.s.Interrupt("SIGINT") } }
	reset := errors.New("connection reset by peer")

	type scenario struct {
		name     string
		budget   time.Duration
		steps    func(e *env, cancel context.CancelFunc, head, tail string) []obsStep
		extra    []obsAttempt // later attempts
		records  int
		reasons  []string
		outcomes []string
		err      string // substring of the error; empty for success
	}
	scenarios := []scenario{
		{name: "clean", steps: func(e *env, _ context.CancelFunc, head, tail string) []obsStep {
			return []obsStep{{advance: ms1, data: head}, {advance: ms1, data: tail}}
		}, records: 1, reasons: []string{"complete"}, outcomes: []string{"completed"}},
		{name: "ended early without completion", steps: func(e *env, _ context.CancelFunc, head, tail string) []obsStep {
			return []obsStep{{advance: ms1, data: head}}
		}, records: 2, reasons: []string{"transport", "complete"}, outcomes: []string{"failed", "completed"}},
		{name: "unexpected EOF", steps: func(e *env, _ context.CancelFunc, head, tail string) []obsStep {
			return []obsStep{{advance: ms1, data: head, err: io.ErrUnexpectedEOF}}
		}, records: 2, reasons: []string{"transport", "complete"}, outcomes: []string{"failed", "completed"}},
		{name: "reset", steps: func(e *env, _ context.CancelFunc, head, tail string) []obsStep {
			return []obsStep{{advance: ms1, data: head}, {advance: ms1, err: reset}}
		}, records: 2, reasons: []string{"transport", "complete"}, outcomes: []string{"failed", "completed"}},
		{name: "cancel after bytes", steps: func(e *env, _ context.CancelFunc, head, tail string) []obsStep {
			return []obsStep{{advance: ms1, data: head, do: interrupt(e)}}
		}, records: 1, reasons: []string{"cancel"}, outcomes: []string{"cancelled"}, err: "SIGINT"},
		{name: "cancel seen at the next read", steps: func(e *env, _ context.CancelFunc, head, tail string) []obsStep {
			return []obsStep{{advance: ms1, data: head}, {advance: ms1, do: interrupt(e)}, {advance: ms1, data: tail}}
		}, records: 1, reasons: []string{"cancel"}, outcomes: []string{"cancelled"}, err: "SIGINT"},
		{name: "cancel with a read error", steps: func(e *env, _ context.CancelFunc, head, tail string) []obsStep {
			return []obsStep{{advance: ms1, data: head}, {advance: ms1, do: interrupt(e), err: reset}}
		}, records: 1, reasons: []string{"cancel"}, outcomes: []string{"cancelled"}, err: "SIGINT"},
		{name: "cancel at EOF", steps: func(e *env, _ context.CancelFunc, head, tail string) []obsStep {
			return []obsStep{{advance: ms1, data: head}, {advance: ms1, do: interrupt(e), err: io.EOF}}
		}, records: 1, reasons: []string{"cancel"}, outcomes: []string{"cancelled"}, err: "SIGINT"},
		{name: "caller context cancelled", steps: func(e *env, cancel context.CancelFunc, head, tail string) []obsStep {
			return []obsStep{{advance: ms1, data: head}, {advance: ms1, do: cancel, err: context.Canceled}}
		}, records: 1, reasons: []string{"cancel"}, outcomes: []string{"failed"}, err: "context canceled"},
		{name: "caller cancellation wins budget check", budget: 10 * time.Second, steps: func(e *env, cancel context.CancelFunc, head, tail string) []obsStep {
			return []obsStep{{advance: ms1, data: head}, {advance: 11 * time.Second, data: tail, do: cancel}}
		}, records: 1, reasons: []string{"cancel"}, outcomes: []string{"failed"}, err: "response wait exceeded"},
		{name: "budget with bytes", budget: 10 * time.Second, steps: func(e *env, _ context.CancelFunc, head, tail string) []obsStep {
			return []obsStep{{advance: ms1, data: head}, {advance: 11 * time.Second, data: tail}}
		}, records: 1, reasons: []string{"budget"}, outcomes: []string{"failed"}, err: "response wait exceeded"},
		{name: "budget seen at the next read", budget: 10 * time.Second, steps: func(e *env, _ context.CancelFunc, head, tail string) []obsStep {
			return []obsStep{{advance: ms1, data: head}, {advance: 11 * time.Second}, {advance: ms1, data: tail}}
		}, records: 1, reasons: []string{"budget"}, outcomes: []string{"failed"}, err: "response wait exceeded"},
		{name: "budget with a read error", budget: 10 * time.Second, steps: func(e *env, _ context.CancelFunc, head, tail string) []obsStep {
			return []obsStep{{advance: ms1, data: head}, {advance: 11 * time.Second, err: reset}}
		}, records: 1, reasons: []string{"budget"}, outcomes: []string{"failed"}, err: "response wait exceeded"},
		{name: "budget at EOF", budget: 10 * time.Second, steps: func(e *env, _ context.CancelFunc, head, tail string) []obsStep {
			return []obsStep{{advance: ms1, data: head}, {advance: 11 * time.Second, err: io.EOF}}
		}, records: 1, reasons: []string{"budget"}, outcomes: []string{"failed"}, err: "response wait exceeded"},
	}
	var seen []string
	for _, wire := range []string{"chatgpt", "anthropic"} {
		for _, sc := range scenarios {
			t.Run(wire+"/"+sc.name, func(t *testing.T) {
				head, tail := wireStream(wire)
				e, tr, req := obsEnv(t, wire)
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				attempts := []obsAttempt{{steps: sc.steps(e, cancel, head, tail)}}
				if sc.records == 2 {
					attempts = append(attempts, obsAttempt{steps: []obsStep{{advance: ms1, data: head + tail}}})
				}
				tr.attempts = attempts
				e.c.ResponseBudget = sc.budget
				obs := &observer{}
				_, err := e.c.Respond(ctx, e.s, req, obs)
				if sc.err == "" && err != nil || sc.err != "" && (err == nil || !strings.Contains(err.Error()+" "+jsonOfErr(err), sc.err)) {
					t.Fatalf("error = %v, want %q", err, sc.err)
				}
				recs := attemptRecords(t, obs, sc.records)
				for i, rec := range recs {
					if rec["end_reason"] != sc.reasons[i] || rec["outcome"] != sc.outcomes[i] {
						t.Errorf("attempt %d: end_reason %v outcome %v, want %s %s", i+1, rec["end_reason"], rec["outcome"], sc.reasons[i], sc.outcomes[i])
					}
					seen = append(seen, rec["end_reason"].(string))
				}
				// the partial stream is still observed, whatever ended it
				if recs[0]["first_byte_ms"] == nil || recs[0]["stream_bytes"].(int64) == 0 || recs[0]["ttft_ms"] == nil {
					t.Errorf("partial observations lost: %s", jsonOf(t, recs[0]))
				}
				if sc.records == 2 && tr.next != 2 {
					t.Errorf("%d requests, want the unchanged single retry", tr.next)
				}
			})
		}
	}
	sort.Strings(seen)
	for _, r := range seen {
		if r != "complete" && r != "transport" && r != "cancel" && r != "budget" {
			t.Errorf("end_reason %q is not one of the four", r)
		}
	}

	t.Run("a dropped stream keeps the parser's result", func(t *testing.T) {
		for _, wire := range []string{"chatgpt", "anthropic"} {
			head, _ := wireStream(wire)
			drop := obsAttempt{steps: []obsStep{{advance: ms1, data: head}}}
			e, tr, req := obsEnv(t, wire, drop, drop, drop, drop)
			obs := &observer{}
			_, err := e.c.Respond(context.Background(), e.s, req, obs)
			if err == nil || !strings.Contains(err.Error()+jsonOfErr(err), "did not answer after 3 attempts") || tr.next != 3 || !reflect.DeepEqual(e.clk.slept(), []time.Duration{2 * time.Second, 8 * time.Second}) {
				t.Fatalf("%s: %v after %d requests, slept %v", wire, err, tr.next, e.clk.slept())
			}
			for _, rec := range attemptRecords(t, obs, 3) {
				if rec["end_reason"] != "transport" || rec["outcome"] != "failed" {
					t.Errorf("%s: %s", wire, jsonOf(t, rec))
				}
			}
		}
	})

	t.Run("unfinished message stop is a dropped stream", func(t *testing.T) {
		head, _ := wireStream("anthropic")
		cut := head + strings.TrimSuffix(sse(ev("message_stop")), "\n\n")
		e, _, req := obsEnv(t, "anthropic", obsAttempt{steps: []obsStep{{data: cut}}})
		obs := &observer{}
		e.c.Respond(context.Background(), e.s, req, obs)
		if got := obs.records()[0]["end_reason"]; got != "transport" {
			t.Fatalf("unfinished terminal frame: end_reason = %v", got)
		}
	})

	t.Run("a received refusal is not a transport break", func(t *testing.T) {
		e, _, req := obsEnv(t, "chatgpt", obsAttempt{status: 400, steps: []obsStep{{advance: ms1, data: `{"error":{"message":"no"}}`}}})
		obs := &observer{}
		if _, err := e.c.Respond(context.Background(), e.s, req, obs); err == nil {
			t.Fatal("refusal accepted")
		}
		if rec := attemptRecords(t, obs, 1)[0]; rec["end_reason"] != nil || rec["outcome"] != "failed" {
			t.Errorf("%s", jsonOf(t, rec))
		}
	})

	t.Run("a failed connection", func(t *testing.T) {
		e, _, req := obsEnv(t, "anthropic", obsAttempt{doErr: reset}, obsAttempt{steps: []obsStep{{advance: ms1, data: func() string { h, tl := wireStream("anthropic"); return h + tl }()}}})
		obs := &observer{}
		if _, err := e.c.Respond(context.Background(), e.s, req, obs); err != nil {
			t.Fatal(err)
		}
		recs := attemptRecords(t, obs, 2)
		wantFields(t, "no headers", recs[0], map[string]any{"headers_ms": nil, "first_byte_ms": nil, "stream_bytes": nil, "end_reason": "transport"})
		wantFields(t, "retry", recs[1], map[string]any{"end_reason": "complete"})
	})
}

func jsonOfErr(err error) string {
	if e, ok := err.(interface{ Render() string }); ok {
		return e.Render()
	}
	return ""
}

func TestStreamObsNonStreaming(t *testing.T) {
	nulls := map[string]any{"first_byte_ms": nil, "ttft_ms": nil, "max_gap_ms": nil, "gap_hist": nil, "stream_bytes": nil, "end_reason": nil}
	check := func(t *testing.T, label string, rec map[string]any, headers, last any) {
		t.Helper()
		wantFields(t, label, rec, nulls)
		wantFields(t, label, rec, map[string]any{"headers_ms": headers, "last_byte_ms": last})
	}
	good := string(mustEncode(goText("hello")))

	t.Run("chat completions body", func(t *testing.T) {
		e, _, req := obsEnv(t, "opencode-go", obsAttempt{headersAdvance: 20 * ms1, steps: []obsStep{
			{advance: 100 * ms1, data: good[:10]},
			{advance: 40 * ms1},
			{advance: 60 * ms1, data: good[10:]},
			{advance: 500 * ms1}, // the end of the body is not a byte
		}})
		obs := &observer{}
		if _, err := e.c.Respond(context.Background(), e.s, req, obs); err != nil {
			t.Fatal(err)
		}
		check(t, "chat", attemptRecords(t, obs, 1)[0], int64(20), int64(220))
	})

	t.Run("chat completions error and empty bodies", func(t *testing.T) {
		e, _, req := obsEnv(t, "opencode-go", obsAttempt{status: 400, headersAdvance: 5 * ms1, steps: []obsStep{{advance: 30 * ms1, data: `{"error":{"code":"x"}}`}}})
		obs := &observer{}
		e.c.Respond(context.Background(), e.s, req, obs)
		check(t, "chat error", attemptRecords(t, obs, 1)[0], int64(5), int64(35))
		e, _, req = obsEnv(t, "opencode-go", obsAttempt{status: 400, headersAdvance: 5 * ms1, steps: []obsStep{{advance: 30 * ms1}}})
		obs = &observer{}
		e.c.Respond(context.Background(), e.s, req, obs)
		check(t, "chat empty", attemptRecords(t, obs, 1)[0], int64(5), nil)
	})

	t.Run("chat completions partial body", func(t *testing.T) {
		e, _, req := obsEnv(t, "opencode-go",
			obsAttempt{headersAdvance: 5 * ms1, steps: []obsStep{{advance: 30 * ms1, data: good[:7]}, {advance: 70 * ms1, err: errors.New("reset")}}},
			obsAttempt{steps: []obsStep{{advance: ms1, data: good}}})
		obs := &observer{}
		if _, err := e.c.Respond(context.Background(), e.s, req, obs); err != nil {
			t.Fatal(err)
		}
		recs := attemptRecords(t, obs, 2)
		check(t, "partial", recs[0], int64(5), int64(35))
		check(t, "retry", recs[1], int64(0), int64(1))
	})

	for _, wire := range []string{"chatgpt", "anthropic"} {
		t.Run(wire+" http error bodies", func(t *testing.T) {
			body := `{"error":{"message":"refused","type":"invalid_request_error"}}`
			e, _, req := obsEnv(t, wire, obsAttempt{status: 400, headersAdvance: 12 * ms1, steps: []obsStep{
				{advance: 8 * ms1, data: body[:20]}, {advance: 25 * ms1, data: body[20:]}, {advance: 900 * ms1},
			}})
			obs := &observer{}
			if _, err := e.c.Respond(context.Background(), e.s, req, obs); err == nil {
				t.Fatal("refusal accepted")
			}
			check(t, "error body", attemptRecords(t, obs, 1)[0], int64(12), int64(45))

			e, _, req = obsEnv(t, wire, obsAttempt{status: 400, headersAdvance: 12 * ms1})
			obs = &observer{}
			e.c.Respond(context.Background(), e.s, req, obs)
			check(t, "empty body", attemptRecords(t, obs, 1)[0], int64(12), nil)

			// a body cut by a transport error keeps what was read; the retry starts afresh
			head, tail := wireStream(wire)
			e, _, req = obsEnv(t, wire,
				obsAttempt{status: 503, headersAdvance: 12 * ms1, steps: []obsStep{{advance: 8 * ms1, data: "partial"}, {advance: 50 * ms1, err: errors.New("reset")}}},
				obsAttempt{steps: []obsStep{{advance: ms1, data: head + tail}}})
			obs = &observer{}
			if _, err := e.c.Respond(context.Background(), e.s, req, obs); err != nil {
				t.Fatal(err)
			}
			recs := attemptRecords(t, obs, 2)
			check(t, "partial error body", recs[0], int64(12), int64(20))
			wantFields(t, "retry is a stream", recs[1], map[string]any{"end_reason": "complete"})
		})
	}
}

func TestStreamObsCompatibility(t *testing.T) {
	// the record's fields before this change, plus the new ones
	old := []string{"provider", "compatibility", "operation_id", "attempt_id", "timestamp", "provider_response_id", "provider_request_id",
		"configured_model", "configured_effort", "effective_model", "effective_effort", "requested_service_tier", "effective_service_tier",
		"requested_reasoning_context", "effective_reasoning_context", "cache", "usage", "usage_state", "wall_ms", "ttft_ms", "outcome", "error"}
	added := []string{"headers_ms", "first_byte_ms", "last_byte_ms", "max_gap_ms", "gap_hist", "stream_bytes", "end_reason"}
	for _, wire := range []string{"chatgpt", "anthropic", "opencode-go"} {
		t.Run(wire, func(t *testing.T) {
			var steps []obsStep
			if wire == "opencode-go" {
				steps = []obsStep{{advance: 30 * ms1, data: string(mustEncode(goText("hello")))}}
			} else {
				head, tail := wireStream(wire)
				steps = []obsStep{{advance: 10 * ms1, data: head}, {advance: 20 * ms1, data: tail}}
			}
			e, tr, req := obsEnv(t, wire, obsAttempt{headersAdvance: 4 * ms1, steps: steps})
			obs := &observer{}
			resp, err := e.c.Respond(context.Background(), e.s, req, obs)
			if err != nil || resp == nil {
				t.Fatal(err)
			}
			info, _ := Lookup(req.Role.Provider)
			want, err := encodeBody(info, e.c.Body(req))
			if err != nil || len(tr.bodies) != 1 || !bytes.Equal(tr.bodies[0], want) {
				t.Fatalf("request bytes differ: %v\n got %s\nwant %s", err, tr.bodies, want)
			}
			rec := attemptRecords(t, obs, 1)[0]
			// every old field is still there and the new ones are present, null or not
			for _, k := range append(append([]string(nil), old...), added...) {
				if _, ok := rec[k]; !ok {
					t.Errorf("field %s missing", k)
				}
			}
			var keys []string
			for k := range rec {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			wantKeys := append(append(append([]string(nil), old...), added...), "conversation_id", "fingerprints")
			if wire == "anthropic" {
				wantKeys = append(wantKeys, "anthropic_stop_reason", "anthropic_end_turn_tool_use")
			}
			sort.Strings(wantKeys)
			if !reflect.DeepEqual(keys, wantKeys) {
				t.Errorf("record fields = %v, want %v", keys, wantKeys)
			}
			wantFields(t, wire, rec, map[string]any{"provider": Name(req.Role), "outcome": "completed", "error": nil, "wall_ms": int64(34), "provider_request_id": rec["provider_request_id"]})
			if wire == "opencode-go" {
				check := map[string]any{"first_byte_ms": nil, "ttft_ms": nil, "end_reason": nil, "stream_bytes": nil}
				wantFields(t, wire, rec, check)
			}
		})
	}

	t.Run("retries budgets and observers keep their behavior", func(t *testing.T) {
		busy := obsAttempt{status: 503, steps: []obsStep{{advance: ms1, data: `{}`}}}
		e, tr, req := obsEnv(t, "chatgpt", busy, busy, busy, busy)
		obs := &observer{}
		_, err := e.c.Respond(context.Background(), e.s, req, obs)
		if err == nil || tr.next != 3 || len(obs.records()) != 3 || !reflect.DeepEqual(e.clk.slept(), []time.Duration{2 * time.Second, 8 * time.Second}) {
			t.Fatalf("%v: %d requests, %d records, slept %v", err, tr.next, len(obs.records()), e.clk.slept())
		}
		// no observer, same request, same answer
		head, tail := wireStream("chatgpt")
		e, _, req = obsEnv(t, "chatgpt", obsAttempt{steps: []obsStep{{advance: ms1, data: head + tail}}})
		if _, err := e.c.Respond(context.Background(), e.s, req, nil); err != nil {
			t.Fatal(err)
		}
		// an out-of-range budget is still refused before any transport
		e, tr, req = obsEnv(t, "chatgpt")
		e.c.ResponseBudget = time.Millisecond
		if _, err := e.c.Respond(context.Background(), e.s, req, nil); err == nil || len(tr.bodies) != 0 {
			t.Fatalf("budget accepted: %v", err)
		}
	})
}

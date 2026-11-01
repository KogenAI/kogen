package provider

import (
	"context"
	"io"
	"net/http"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// These tests cover the visible output limit of one streaming attempt: 131072 bytes of visible
// deltas are allowed, one more ends the attempt as a transient failure.

const outLimit = 131072

// outDelta is one delta frame of the wire: kind is text, refusal, args, reasoning or summary
// (Responses), or text, json, thinking or signature (Messages).
func outDelta(wire, kind, s string) string { return outDeltaAt(wire, 0, kind, s) }

func outDeltaAt(wire string, index int64, kind, s string) string {
	if wire == "anthropic" {
		d := map[string]any{"type": kind + "_delta"}
		switch kind {
		case "text":
			d["text"] = s
		case "json":
			d["type"], d["partial_json"] = "input_json_delta", s
		case "thinking":
			d["thinking"] = s
		case "signature":
			d["signature"] = s
		}
		return sse(ev("content_block_delta", "index", index, "delta", d))
	}
	typ := map[string]string{"text": "response.output_text.delta", "refusal": "response.refusal.delta", "args": "response.function_call_arguments.delta",
		"reasoning": "response.reasoning_text.delta", "summary": "response.reasoning_summary_text.delta"}[kind]
	return frame(map[string]any{"type": typ, "output_index": int64(0), "delta": s})
}

// outHead and outTail open and complete a short answer of the wire.
func outHead(wire string) string {
	if wire == "anthropic" {
		return msgStart() + msgBlockStart()
	}
	return ""
}

func outTail(wire string) string {
	if wire == "anthropic" {
		return msgTail()
	}
	return respTail()
}

// outSplit cuts s into reads of at most the client's read buffer.
func outSplit(s string) []string {
	var out []string
	for len(s) > memRead {
		out, s = append(out, s[:memRead]), s[memRead:]
	}
	return append(out, s)
}

// outAnswer is the attempt of the wire with the given opening, frames and terminal events:
// every read is at most the client's buffer, and the last frame and the terminal events end
// together in the final reads.
func outAnswer(wire, head, tail string, frames ...string) obsAttempt {
	last := len(frames) - 1
	steps := []obsStep{}
	for _, c := range outSplit(head + strings.Join(frames[:last], "")) {
		steps = append(steps, obsStep{data: c})
	}
	for _, c := range outSplit(frames[last] + tail) {
		steps = append(steps, obsStep{data: c})
	}
	return obsAttempt{steps: steps}
}

func outStd(wire string, frames ...string) obsAttempt {
	return outAnswer(wire, outHead(wire), outTail(wire), frames...)
}

// outText is the text deltas of n bytes of unit, in deltas of at most 1024 bytes.
func outText(wire, kind, unit string, n int) []string {
	var out []string
	for n > 0 {
		k := min(n, 1024-1024%len(unit))
		out = append(out, outDelta(wire, kind, strings.Repeat(unit, k/len(unit))))
		n -= k
	}
	return out
}

func TestOutputLimitThinkingIsNotVisible(t *testing.T) {
	t.Parallel()
	const w = "anthropic"
	start := func(i int64, b map[string]any) string {
		return sse(ev("content_block_start", "index", i, "content_block", b))
	}
	stop := func(i int64) string { return sse(ev("content_block_stop", "index", i)) }
	attempt := outAnswer(w, msgStart(), sse(finish("end_turn")...),
		start(0, map[string]any{"type": "thinking", "thinking": "", "signature": ""}),
		outDeltaAt(w, 0, "thinking", strings.Repeat("a", 150000)),
		outDeltaAt(w, 0, "signature", strings.Repeat("a", 150000)),
		stop(0),
		start(1, map[string]any{"type": "text", "text": ""}),
		outDeltaAt(w, 1, "text", strings.Repeat("a", 4096)),
		stop(1))
	resp, err, obs, _ := outRespond(t, w, attempt)
	if err != nil || resp == nil {
		t.Fatalf("response %v, error %v", resp, err)
	}
	wantFields(t, "attempt", attemptRecords(t, obs, 1)[0], map[string]any{"outcome": "completed", "end_reason": "complete"})
}

func outRespond(t *testing.T, wire string, attempts ...obsAttempt) (*Response, error, *observer, *env) {
	t.Helper()
	e, _, req := idleEnv(t, wire, attempts...)
	obs := &observer{}
	resp, err := e.c.Respond(context.Background(), e.s, req, obs)
	return resp, err, obs, e
}

func TestOutputLimitCount(t *testing.T) {
	t.Parallel()
	all := []string{"chatgpt", "supergrok", "anthropic"}
	responses := []string{"chatgpt", "supergrok"}
	// a mixed case: the first kind's bytes, then the second's
	mix := func(wire string, parts ...[]string) []string {
		var out []string
		for _, p := range parts {
			out = append(out, p...)
		}
		return out
	}
	bigItem := map[string]any{"type": "message", "id": "message", "role": "assistant",
		"content": []any{map[string]any{"type": "output_text", "text": strings.Repeat("x", 200000), "annotations": []any{}}}}
	cases := []struct {
		name   string
		wires  []string
		frames func(wire string) []string
		cut    bool
	}{
		{"exactly the limit", all, func(w string) []string { return outText(w, "text", "a", outLimit) }, false},
		{"one byte over", all, func(w string) []string { return outText(w, "text", "a", outLimit+1) }, true},
		{"multibyte exactly", all, func(w string) []string { return outText(w, "text", "é", outLimit) }, false},
		{"multibyte over", all, func(w string) []string { return outText(w, "text", "é", outLimit+2) }, true},
		{"one large delta over", all, func(w string) []string { return []string{outDelta(w, "text", strings.Repeat("a", outLimit+1))} }, true},
		{"one large delta exactly", all, func(w string) []string { return []string{outDelta(w, "text", strings.Repeat("a", outLimit))} }, false},
		{"refusal and text deltas", responses, func(w string) []string {
			return mix(w, outText(w, "text", "a", 65536), outText(w, "refusal", "a", 65537))
		}, true},
		{"function call argument deltas", responses, func(w string) []string { return outText(w, "args", "a", outLimit+1) }, true},
		{"function call argument deltas exactly", responses, func(w string) []string { return outText(w, "args", "a", outLimit) }, false},
		{"tool input json deltas", []string{"anthropic"}, func(w string) []string {
			return mix(w, outText(w, "text", "a", 100000), outText(w, "json", "a", 31073))
		}, true},
		{"reasoning is not visible", responses, func(w string) []string {
			return mix(w, outText(w, "reasoning", "a", 150000), outText(w, "summary", "a", 150000), outText(w, "text", "a", 4096))
		}, false},
		{"comments and keep-alives are not visible", all, func(w string) []string {
			return mix(w, []string{": " + strings.Repeat("x", 200000) + "\n\n"}, outText(w, "text", "a", 4096))
		}, false},
		{"missing and non-string deltas count 0", responses, func(w string) []string {
			return []string{frame(map[string]any{"type": "response.output_text.delta"}), frame(map[string]any{"type": "response.output_text.delta", "delta": []any{strings.Repeat("a", outLimit+1)}})}
		}, false},
		{"done events and items are not counted", responses, func(w string) []string {
			return []string{
				frame(map[string]any{"type": "response.output_text.done", "text": strings.Repeat("x", 200000)}),
				frame(map[string]any{"type": "response.refusal.done", "refusal": strings.Repeat("x", 200000)}),
				frame(map[string]any{"type": "response.function_call_arguments.done", "arguments": strings.Repeat("x", 200000)}),
				frame(itemDone(0, bigItem)),
				frame(done(map[string]any{"output": []any{bigItem}, "usage": map[string]any{
					"input_tokens": int64(1), "input_tokens_details": map[string]any{"cached_tokens": int64(0)},
					"output_tokens": int64(1), "output_tokens_details": map[string]any{"reasoning_tokens": int64(0)}}})),
			}
		}, false},
	}
	for _, c := range cases {
		for _, wire := range c.wires {
			t.Run(c.name+"/"+wire, func(t *testing.T) {
				t.Parallel()
				frames := c.frames(wire)
				second := outStd(wire, outText(wire, "text", "a", outLimit)...)
				first := outStd(wire, frames...)
				if !c.cut {
					first = obsAttempt{steps: first.steps}
					resp, err, obs, e := outRespond(t, wire, first)
					if err != nil || resp == nil {
						t.Fatalf("response %v, error %v", resp, err)
					}
					recs := attemptRecords(t, obs, 1)
					wantFields(t, "attempt", recs[0], map[string]any{"outcome": "completed", "end_reason": "complete"})
					if len(e.clk.slept()) != 0 {
						t.Fatalf("slept %v", e.clk.slept())
					}
					return
				}
				resp, err, obs, e := outRespond(t, wire, first, second)
				if err != nil || resp == nil {
					t.Fatalf("response %v, error %v (the retry's full limit must complete: the count restarts)", resp, err)
				}
				recs := attemptRecords(t, obs, 2)
				wantFields(t, "attempt 1", recs[0], map[string]any{"outcome": "failed", "error": "provider_failure", "end_reason": "output_limit"})
				wantFields(t, "attempt 2", recs[1], map[string]any{"outcome": "completed", "end_reason": "complete"})
				if _, has := recs[0]["provider_failure"]; has {
					t.Errorf("attempt 1 has provider_failure %v", recs[0]["provider_failure"])
				}
				if recs[0]["usage_state"] != nil && recs[0]["usage_state"] != UsageUnknown {
					t.Errorf("attempt 1 usage state %v", recs[0]["usage_state"])
				}
				// the crossing event wins over the terminal events of its own read
				var total int64
				for _, s := range first.steps {
					total += int64(len(s.data))
				}
				if got := recs[0]["stream_bytes"]; got != total {
					t.Errorf("stream_bytes = %v, want %d", got, total)
				}
				if !reflect.DeepEqual(e.clk.slept(), []time.Duration{2 * time.Second}) {
					t.Errorf("slept %v", e.clk.slept())
				}
			})
		}
	}
}

// outFake streams 1 KiB text deltas until the client goes away (or 4 MiB, so a test never hangs),
// counting the requests and the streams that ended by the client's disconnect.
type outFake struct {
	requests, ended atomic.Int64
}

func (f *outFake) runaway(wire string) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		f.requests.Add(1)
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("X-Request-Id", "req-fixture")
		piece := outDelta(wire, "text", strings.Repeat("a", 1024))
		io.WriteString(w, outHead(wire))
		for sent := 0; sent < 4<<20; sent += len(piece) {
			if _, err := io.WriteString(w, piece); err != nil {
				break
			}
			w.(http.Flusher).Flush()
			if r.Context().Err() != nil {
				break
			}
		}
		select {
		case <-r.Context().Done():
			f.ended.Add(1)
		case <-time.After(5 * time.Second):
		}
	}
}

func (f *outFake) answer(wire string) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		f.requests.Add(1)
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("X-Request-Id", "req-fixture")
		io.WriteString(w, outHead(wire)+outDelta(wire, "text", "done")+outTail(wire))
	}
}

// outServer is a test world whose provider streams the scripted handlers in order.
func outServer(t *testing.T, wire string, h ...handler) (*env, Request) {
	t.Helper()
	if wire == "anthropic" {
		e, _ := keyEnv(t, "anthropic", h...)
		return e, Request{Role: claudeRole, Instructions: "p", Input: user("x"), CacheID: "outlimit-cache"}
	}
	f := newFake(t, h...)
	e := newEnv(t, f)
	if wire == "supergrok" {
		e.saveCreds("supergrok", e.supergrokCreds())
		return e, Request{Role: grokRole, Instructions: "p", Input: user("x"), CacheID: "outlimit-cache"}
	}
	e.saveCreds("chatgpt", e.chatgptCreds())
	return e, Request{Role: Role{Model: "gpt-6.1-sol", Effort: "high"}, Instructions: "p", Input: user("x"), CacheID: "outlimit-cache"}
}

func TestOutputLimitRunaway(t *testing.T) {
	t.Parallel()
	labels := map[string]string{"chatgpt": "ChatGPT", "supergrok": "SuperGrok", "anthropic": "Anthropic"}
	for _, wire := range []string{"chatgpt", "supergrok", "anthropic"} {
		t.Run(wire+"/the retry answers", func(t *testing.T) {
			t.Parallel()
			var f outFake
			e, req := outServer(t, wire, f.runaway(wire), f.answer(wire))
			obs := &observer{}
			resp, err := e.c.Respond(context.Background(), e.s, req, obs)
			if err != nil || resp == nil {
				t.Fatalf("response %v, error %v", resp, err)
			}
			recs := attemptRecords(t, obs, 2)
			wantFields(t, "attempt 1", recs[0], map[string]any{"outcome": "failed", "error": "provider_failure", "end_reason": "output_limit"})
			wantFields(t, "attempt 2", recs[1], map[string]any{"outcome": "completed"})
			if n, _ := recs[0]["stream_bytes"].(int64); n <= outLimit || n >= 262144 {
				t.Errorf("attempt 1 read %v bytes, want more than %d and fewer than 262144", recs[0]["stream_bytes"], outLimit)
			}
			if !reflect.DeepEqual(e.clk.slept(), []time.Duration{2 * time.Second}) {
				t.Errorf("slept %v, want one 2 s backoff", e.clk.slept())
			}
			deadline := time.Now().Add(3 * time.Second)
			for f.ended.Load() < 1 && time.Now().Before(deadline) {
				time.Sleep(10 * time.Millisecond)
			}
			if f.ended.Load() != 1 || f.requests.Load() != 2 {
				t.Errorf("%d streams ended by the client, %d requests", f.ended.Load(), f.requests.Load())
			}
		})
		t.Run(wire+"/three runaways", func(t *testing.T) {
			t.Parallel()
			var f outFake
			e, req := outServer(t, wire, f.runaway(wire), f.runaway(wire), f.runaway(wire))
			obs := &observer{}
			_, err := e.c.Respond(context.Background(), e.s, req, obs)
			se := mustErr(t, err)
			want := labels[wire] + " did not answer after 3 attempts: visible output exceeded 131072 bytes"
			if se.Class != "provider" || se.Reason != "unavailable" || se.Detail != want || se.Exit != 4 {
				t.Fatalf("error %v (exit %d), want provider/unavailable %q", se, se.Exit, want)
			}
			for i, rec := range attemptRecords(t, obs, 3) {
				wantFields(t, "attempt", rec, map[string]any{"outcome": "failed", "end_reason": "output_limit"})
				if n, _ := rec["stream_bytes"].(int64); n <= outLimit || n >= 262144 {
					t.Errorf("attempt %d read %v bytes", i+1, rec["stream_bytes"])
				}
			}
			if !reflect.DeepEqual(e.clk.slept(), []time.Duration{2 * time.Second, 8 * time.Second}) {
				t.Errorf("slept %v", e.clk.slept())
			}
		})
	}
	t.Run("chatgpt single attempt", func(t *testing.T) {
		t.Parallel()
		var f outFake
		e, req := outServer(t, "chatgpt", f.runaway("chatgpt"), f.answer("chatgpt"))
		req.Single = true
		_, err := e.c.Respond(context.Background(), e.s, req, nil)
		se := mustErr(t, err)
		if se.Reason != "unavailable" || se.Detail != "visible output exceeded 131072 bytes" || f.requests.Load() != 1 || len(e.clk.slept()) != 0 {
			t.Fatalf("error %v, %d requests, slept %v", se, f.requests.Load(), e.clk.slept())
		}
	})
}

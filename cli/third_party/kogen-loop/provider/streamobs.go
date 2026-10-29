package provider

import (
	"io"
	"time"
)

// streamObs holds one transport attempt's stream observations: headers, byte and gap timings,
// the first parsed delta and how the stream ended. It only observes; nothing reads it back
// except record. Times are relative to the attempt's start. A nil *streamObs ignores every call.
type streamObs struct {
	start time.Time

	hasHeaders bool
	headers    time.Duration

	hasRead     bool
	first, last time.Duration
	prev        time.Time

	stream  bool // the streaming read loop ran: the stream-only fields are reported
	bytes   int64
	reads   int
	maxGap  time.Duration
	hist    [6]int64
	hasTTFT bool
	ttft    time.Duration

	endTracked bool // the attempt is on a streaming route and has not turned to an HTTP error body
	end        string
}

func newStreamObs(start time.Time) *streamObs { return &streamObs{start: start} }

// rel is at relative to the attempt start, never negative.
func (o *streamObs) rel(at time.Time) time.Duration {
	if d := at.Sub(o.start); d > 0 {
		return d
	}
	return 0
}

// gapBucket classifies a full duration into [0,1s], (1s,10s], (10s,30s], (30s,60s], (60s,120s]
// and (120s,infinity).
func gapBucket(d time.Duration) int {
	switch {
	case d <= time.Second:
		return 0
	case d <= 10*time.Second:
		return 1
	case d <= 30*time.Second:
		return 2
	case d <= 60*time.Second:
		return 3
	case d <= 120*time.Second:
		return 4
	}
	return 5
}

// gotHeaders records the completion of a successful client Do.
func (o *streamObs) gotHeaders(at time.Time) {
	if o == nil {
		return
	}
	o.hasHeaders, o.headers = true, o.rel(at)
}

// beginStream marks the response body as a stream read in chunks.
func (o *streamObs) beginStream() {
	if o != nil {
		o.stream = true
	}
}

// read records one completed body read of n bytes; a read without bytes changes nothing.
func (o *streamObs) read(at time.Time, n int) {
	if o == nil || n <= 0 {
		return
	}
	d := o.rel(at)
	if !o.hasRead {
		o.hasRead, o.first = true, d
	}
	o.last = d
	if o.stream {
		o.bytes += int64(n)
		if o.reads > 0 {
			gap := at.Sub(o.prev)
			if gap < 0 {
				gap = 0
			}
			if gap > o.maxGap {
				o.maxGap = gap
			}
			o.hist[gapBucket(gap)]++
		}
		o.reads++
	}
	o.prev = at
}

// firstDelta records the read completion that carried the first parsed delta event.
func (o *streamObs) firstDelta(at time.Time) {
	if o == nil || o.hasTTFT {
		return
	}
	o.hasTTFT, o.ttft = true, o.rel(at)
}

// finish sets the stream's end reason once; only streaming-route attempts keep one.
func (o *streamObs) finish(reason string) {
	if o == nil || !o.endTracked || o.end != "" {
		return
	}
	o.end = reason
}

// finishIdle records an attempt ended by the first-byte or idle timeout, on any route.
func (o *streamObs) finishIdle() {
	if o == nil || o.end != "" {
		return
	}
	o.end = "idle"
}

// finishCheck records the end of a stream stopped by the call's check: a caller interrupt
// or the spent budget.
func (o *streamObs) finishCheck(k *call) {
	if k.interrupted() != nil || k.ctx.Err() != nil {
		o.finish("cancel")
		return
	}
	o.finish("budget")
}

// finishFailure records a transport failure with transportFailure's precedence: the caller's
// stop, then the budget, then the network.
func (o *streamObs) finishFailure(k *call, reqCtxErr error) {
	if k.interrupted() != nil || k.ctx.Err() != nil {
		o.finish("cancel")
		return
	}
	if (!k.deadline.IsZero() && !k.c.now().Before(k.deadline)) || reqCtxErr != nil {
		o.finish("budget")
		return
	}
	o.finish("transport")
}

func ms(d time.Duration) int64 { return d.Milliseconds() }

// fields are the observations as record fields; missing ones are explicit null.
func (o *streamObs) fields() map[string]any {
	f := map[string]any{
		"headers_ms": nil, "first_byte_ms": nil, "last_byte_ms": nil, "ttft_ms": nil,
		"max_gap_ms": nil, "gap_hist": nil, "stream_bytes": nil, "end_reason": nil,
	}
	if o == nil {
		return f
	}
	if o.hasHeaders {
		f["headers_ms"] = ms(o.headers)
	}
	if o.hasRead {
		f["last_byte_ms"] = ms(o.last)
	}
	if o.end != "" {
		f["end_reason"] = o.end
	}
	if !o.stream {
		return f
	}
	if o.hasRead {
		f["first_byte_ms"] = ms(o.first)
	}
	if o.hasTTFT {
		f["ttft_ms"] = ms(o.ttft)
	}
	f["max_gap_ms"] = ms(o.maxGap)
	hist := make([]any, len(o.hist))
	for i, n := range o.hist {
		hist[i] = n
	}
	f["gap_hist"] = hist
	f["stream_bytes"] = o.bytes
	return f
}

// obsBody notes the completion time of every positive read of a body read whole.
type obsBody struct {
	r   io.Reader
	o   *streamObs
	w   *idleWatch
	now func() time.Time
}

// Read fails with errIdle once the attempt's silence limit has passed.
func (b obsBody) Read(p []byte) (int, error) {
	n, err := b.r.Read(p)
	at := b.now()
	if n > 0 {
		b.o.read(at, n)
	}
	if b.w.observe(at, n) {
		return n, errIdle
	}
	return n, err
}

// whole is a body whose reads are observed for io.ReadAll.
func (r *run) whole(body io.Reader) io.Reader {
	return obsBody{r: body, o: r.so, w: r.watch, now: r.k.c.now}
}

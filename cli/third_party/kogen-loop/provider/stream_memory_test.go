package provider

import (
	"context"
	"io"
	"net/http"
	"reflect"
	"strings"
	"sync"
	"testing"
)

// These tests drive Client.Respond with lazily generated finite bodies, so an unbounded stream
// costs a bounded fake and the unfixed tree fails instead of exhausting memory.

const (
	memLimit = 64 << 20 // the documented ceiling of one streaming attempt
	memRead  = 32 << 10 // Respond's read buffer
)

// genBody serves generated pieces, never more than one piece per read and never more than the
// caller's buffer, so a piece such as a terminal event arrives in a read of its own.
type genBody struct {
	next   func() string // the next piece, "" at the end
	cur    string
	read   int
	closed bool
	mu     sync.Mutex
}

func (b *genBody) Read(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.cur == "" {
		b.cur = b.next()
	}
	if b.cur == "" {
		return 0, io.EOF
	}
	n := copy(p, b.cur)
	b.cur = b.cur[n:]
	b.read += n
	return n, nil
}

func (b *genBody) Close() error {
	b.mu.Lock()
	b.closed = true
	b.mu.Unlock()
	return nil
}

// memTransport answers every attempt with a fresh body.
type memTransport struct {
	mk     func() *genBody
	bodies []*genBody
}

func (tr *memTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	b := tr.mk()
	tr.bodies = append(tr.bodies, b)
	h := http.Header{"X-Request-Id": []string{"req-fixture"}}
	return &http.Response{StatusCode: 200, Header: h, Body: b, Request: req}, nil
}

// repeat is size bytes of unit, cyclic, in pieces of at most memRead bytes; unit divides memRead.
func repeat(unit string, size int) func() string {
	block := strings.Repeat(unit, memRead/len(unit))
	pos := 0
	return func() string {
		n := min(memRead, size-pos)
		if n <= 0 {
			return ""
		}
		pos += n
		return block[:n]
	}
}

// pieces serves the given generators one after the other.
func pieces(parts ...func() string) func() string {
	return func() string {
		for len(parts) > 0 {
			if s := parts[0](); s != "" {
				return s
			}
			parts = parts[1:]
		}
		return ""
	}
}

func once(s string) func() string {
	return func() string {
		r := s
		s = ""
		return r
	}
}

// upTo ends next once it has served size bytes.
func upTo(next func() string, size int) func() string {
	sent := 0
	return func() string {
		if sent >= size {
			return ""
		}
		s := next()
		sent += len(s)
		return s
	}
}

func comment(n int) string { return ":" + strings.Repeat("x", n-3) + "\n\n" } // n >= 3 bytes

// padded is a complete answer made exactly size bytes long with ignored SSE comments between its
// head and its terminal tail, which is the final read.
func padded(wire string, size int) func() *genBody {
	head, tail := wireStream(wire)
	pad := size - len(head) - len(tail)
	const unit = 4096
	k, r := pad/unit, pad%unit
	if r < 3 {
		k, r = k-1, r+unit
	}
	return func() *genBody {
		return &genBody{next: pieces(once(head), repeat(comment(unit), k*unit), once(comment(r)), once(tail))}
	}
}

// fresh is a body factory whose every body has its own generator.
func fresh(gen func() func() string) func() *genBody {
	return func() *genBody { return &genBody{next: gen()} }
}

// itemEvents are valid output-item events of distinct indexes, 8 KiB of text each.
func itemEvents() func() string {
	text := strings.Repeat("x", 8<<10)
	i := 0
	return func() string {
		var b strings.Builder
		for j := 0; j < 4; j++ {
			item := map[string]any{"type": "message", "id": "message", "role": "assistant",
				"content": []any{map[string]any{"type": "output_text", "text": text, "annotations": []any{}}}}
			b.WriteString(frame(itemDone(i, item)))
			i++
		}
		return b.String()
	}
}

func memRespond(t *testing.T, wire string, mk func() *genBody) (*Response, error, *memTransport) {
	t.Helper()
	e, _, req := idleEnv(t, wire)
	tr := &memTransport{mk: mk}
	e.c.HTTP = &http.Client{Transport: tr}
	resp, err := e.c.Respond(context.Background(), e.s, req, nil)
	return resp, err, tr
}

func TestLStreamMemory(t *testing.T) {
	wires := []string{"chatgpt", "supergrok", "anthropic"}

	t.Run("answers at and below the ceiling are kept", func(t *testing.T) {
		for _, wire := range wires {
			for _, size := range []int{memLimit - 1, memLimit} {
				resp, err, tr := memRespond(t, wire, padded(wire, size))
				want := []map[string]any{msgItem()}
				if wire == "anthropic" {
					want = []map[string]any{{"type": "message", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": "hi"}}, "anthropic_message": map[string]any{"role": "assistant", "content": []any{map[string]any{"type": "text", "text": "hi"}}}}}
				}
				if err != nil || resp == nil || !reflect.DeepEqual(resp.Items, want) {
					t.Fatalf("%s at %d bytes: %v, %v", wire, size, resp, err)
				}
				if len(tr.bodies) != 1 || tr.bodies[0].read != size {
					t.Fatalf("%s at %d bytes: %d attempts, read %d", wire, size, len(tr.bodies), tr.bodies[0].read)
				}
			}
		}
	})

	over := []struct {
		name  string
		wires []string
		mk    func(wire string) func() *genBody
	}{
		{"complete answer one byte over", wires, func(wire string) func() *genBody { return padded(wire, memLimit+1) }},
		{"pings", []string{"anthropic"}, func(string) func() *genBody {
			return fresh(func() func() string {
				frame := "event: ping\ndata: {\"type\":\"ping\"}\n"
				frame += ":" + strings.Repeat("x", 64-len(frame)-3) + "\n\n"
				return repeat(frame, memLimit+2*memRead)
			})
		}},
		{"unfinished frame", []string{"chatgpt", "supergrok"}, func(string) func() *genBody {
			return fresh(func() func() string {
				return pieces(once(`data: {"type":"response.output_text.delta","delta":"`), repeat("x", memLimit+2*memRead))
			})
		}},
		{"output items", []string{"chatgpt"}, func(string) func() *genBody {
			return fresh(func() func() string { return upTo(itemEvents(), memLimit+2*memRead) })
		}},
	}
	for _, c := range over {
		for _, wire := range c.wires {
			t.Run(c.name+"/"+wire, func(t *testing.T) {
				resp, err, tr := memRespond(t, wire, c.mk(wire))
				if resp != nil || err == nil {
					t.Fatalf("response %v, error %v; want a failure", resp, err)
				}
				se := mustErr(t, err)
				if se.Class != "provider" || se.Reason != "invalid_response" {
					t.Fatalf("error %v, want provider/invalid_response", err)
				}
				if len(tr.bodies) < 1 || len(tr.bodies) > 3 {
					t.Fatalf("%d attempts", len(tr.bodies))
				}
				for i, b := range tr.bodies {
					if !b.closed {
						t.Errorf("attempt %d body not closed", i+1)
					}
					if b.read <= memLimit || b.read > memLimit+memRead {
						t.Errorf("attempt %d read %d bytes, want more than %d and at most %d", i+1, b.read, memLimit, memLimit+memRead)
					}
				}
			})
		}
	}
}

// A frame break split across reads, in any line-ending style, is found as in one read.
func TestLStreamMemoryFrameBreaks(t *testing.T) {
	head, tail := wireStream("chatgpt")
	for _, nl := range []string{"\n", "\r\n"} {
		stream := strings.ReplaceAll(head+": c"+"\n\n"+tail, "\n", nl)
		whole := newAccumulator()
		if d := whole.feed(stream); d != "" || !whole.done {
			t.Fatalf("%q: whole stream: %q done=%v", nl, d, whole.done)
		}
		want := jsonOf(t, whole.finish(false).items)
		for _, size := range []int{1, 2, 3, 5} {
			a := newAccumulator()
			for i := 0; i < len(stream); i += size {
				if d := a.feed(stream[i:min(i+size, len(stream))]); d != "" {
					t.Fatalf("%q in %d: %q", nl, size, d)
				}
			}
			if got := jsonOf(t, a.finish(false).items); !a.done || got != want {
				t.Fatalf("%q in %d: done=%v items %s, want %s", nl, size, a.done, got, want)
			}
		}
	}
}

package shape

import (
	"context"
	"io"
	"net/http"
	"sync"
	"testing"
	"time"
)

// pacedStream is the response body of one long productive stream. The client reads one valid
// incremental event per Read, and the simulated clock moves by gap just before each is delivered,
// so every event arrives inside the client's silence limits while the logical response grows by
// gap per event. The provider fixture's own completion follows the events. No real-time wait.
type pacedStream struct {
	clock  *budgetClock
	gap    time.Duration
	events [][]byte
	rest   io.ReadCloser

	mu       sync.Mutex
	finished time.Time
}

func (b *pacedStream) Read(p []byte) (int, error) {
	if len(b.events) > 0 {
		b.clock.Advance(b.gap)
		n := copy(p, b.events[0])
		b.events = b.events[1:]
		return n, nil
	}
	n, err := b.rest.Read(p)
	if err == io.EOF {
		b.mu.Lock()
		b.finished = b.clock.Now()
		b.mu.Unlock()
	}
	return n, err
}

func (b *pacedStream) Close() error { return b.rest.Close() }

// pacedTransport paces the first response only; later exchanges pass through.
type pacedTransport struct {
	clock *budgetClock
	once  sync.Once

	mu      sync.Mutex
	started time.Time
	stream  *pacedStream
}

func (t *pacedTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	resp, err := http.DefaultTransport.RoundTrip(r)
	if err != nil {
		return resp, err
	}
	t.once.Do(func() {
		// 16 events 50 seconds apart: the first lands inside ChatGPT's 90-second first-byte
		// limit and each later one inside the idle limit, for 800 seconds in all.
		var events [][]byte
		for i := 0; i < 16; i++ {
			events = append(events, []byte(`data: {"type":"response.reasoning_summary_text.delta","output_index":0,"delta":"thinking"}`+"\n\n"))
		}
		s := &pacedStream{clock: t.clock, gap: 50 * time.Second, events: events, rest: resp.Body}
		t.mu.Lock()
		t.started, t.stream = t.clock.Now(), s
		t.mu.Unlock()
		resp.Body = s
	})
	return resp, nil
}

// TestShapeBudgetStreaming800Seconds is the reproducer of the research evidence: a productive
// Shape response that streams steadily for 800 simulated seconds, longer than Build's ten
// minutes and inside the loop's thirty, is not cut. Valid incremental events arrive through one
// logical Respond call, then a valid completion; Shape finishes with the production settings.
func TestShapeBudgetStreaming800Seconds(t *testing.T) {
	serialTmp(t)
	clock := newBudgetClock()
	f := newShpFx(t, shpSubmit("c1", shpFiles()), shpAck("c2"))
	tr := &pacedTransport{clock: clock}
	f.Client.HTTP = &http.Client{Transport: tr}
	f.Client.Now = clock.Now
	f.newSession()
	exit, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: "Add calc.is_even(n).", Client: f.Client})
	if err != nil || exit != 0 {
		t.Fatalf("exit %d err %v\n%s", exit, err, f.Stdout)
	}
	tr.mu.Lock()
	started, stream := tr.started, tr.stream
	tr.mu.Unlock()
	if stream == nil || len(stream.events) != 0 {
		t.Fatal("the long response was not streamed")
	}
	stream.mu.Lock()
	finished := stream.finished
	stream.mu.Unlock()
	if got := finished.Sub(started); got != 800*time.Second {
		t.Fatalf("the response streamed for %s of simulated time, want 800s", got)
	}
	shpEq(t, "requests", len(f.Prov.requests()), 2)
	shpEq(t, "response budget", f.Client.ResponseBudget, time.Duration(0))
	wantBudgetRecord(t, f.events())
}

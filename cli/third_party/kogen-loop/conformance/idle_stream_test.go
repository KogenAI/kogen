package conformance

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sync"
	"testing"
	"time"

	"kogen-loop/api"
	"kogen-loop/loop"
	"kogen-loop/provider"
	"kogen-loop/sys"
)

// idleClock is the injected Client.Now/Sleep: a sleep advances it without waiting.
type idleClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *idleClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *idleClock) advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

func (c *idleClock) Sleep(ctx context.Context, d time.Duration) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	c.advance(d)
	return nil
}

// idleReads reports the bytes a response body has returned each time the client starts a read,
// so a report of n means the client has handled the first n bytes.
type idleReads struct {
	rt    http.RoundTripper
	reads chan int
}

func (r *idleReads) RoundTrip(req *http.Request) (*http.Response, error) {
	resp, err := r.rt.RoundTrip(req)
	if err == nil {
		resp.Body = &idleReadBody{ReadCloser: resp.Body, reads: r.reads}
	}
	return resp, err
}

type idleReadBody struct {
	io.ReadCloser
	reads chan int
	n     int
}

func (b *idleReadBody) Read(p []byte) (int, error) {
	select {
	case b.reads <- b.n:
	default:
	}
	n, err := b.ReadCloser.Read(p)
	b.n += n
	return n, err
}

// TestIdleStreamRunLog: a stream that sends progress and then only keep-alives while the connection
// stays open ends its attempt as idle, and the run log's request.attempt event shows the last byte
// beside the last progress; the retry answers and the round ends.
func TestIdleStreamRunLog(t *testing.T) {
	w := newWorld(t).signIn()
	cmds := make(chan string, 8)
	open := make(chan struct{})
	gone := make(chan struct{})
	var mu sync.Mutex
	attempts := 0
	srv := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		mu.Lock()
		attempts++
		n := attempts
		mu.Unlock()
		rw.Header().Set("Content-Type", "text/event-stream")
		if n > 1 {
			item, _ := json.Marshal(map[string]any{"type": "response.output_item.done", "output_index": 0, "item": message("answered")})
			done, _ := json.Marshal(map[string]any{"type": "response.completed", "response": map[string]any{"status": "completed"}})
			fmt.Fprintf(rw, "data: %s\n\ndata: %s\n\n", item, done)
			return
		}
		rw.WriteHeader(200)
		rw.(http.Flusher).Flush()
		close(open)
		for {
			select {
			case chunk := <-cmds:
				io.WriteString(rw, chunk)
				rw.(http.Flusher).Flush()
			case <-r.Context().Done():
				close(gone)
				return
			case <-time.After(30 * time.Second):
				return
			}
		}
	}))
	t.Cleanup(srv.Close)

	clk := &idleClock{t: time.Now()}
	tr := &idleReads{rt: &http.Transport{}, reads: make(chan int, 64)}
	t.Cleanup(tr.rt.(*http.Transport).CloseIdleConnections)
	client := provider.NewClient("kogen-loop test")
	client.Now, client.Sleep, client.HTTP = clk.Now, clk.Sleep, &http.Client{Transport: tr}

	var events []api.Event
	cfg := sessionConfig(w, nil, &events)
	cfg.Client = client
	cfg.Session = sys.NewWith(append(w.env(nil), "KOGEN_PROVIDER_URL="+srv.URL), w.root)
	s, err := loop.NewSession(cfg)
	if err != nil {
		t.Fatal(err)
	}
	type outcome struct {
		res loop.Result
		err error
	}
	finished := make(chan outcome, 1)
	go func() {
		res, err := s.Round(context.Background(), "open")
		finished <- outcome{res, err}
	}()

	guard := time.After(30 * time.Second)
	waitRead := func(bytes int) {
		t.Helper()
		for {
			select {
			case n := <-tr.reads:
				if n >= bytes {
					return
				}
			case <-guard:
				t.Fatalf("the client never read %d bytes", bytes)
			}
		}
	}
	send := func(after time.Duration, chunk string, sent *int) {
		t.Helper()
		clk.advance(after)
		cmds <- chunk
		*sent += len(chunk)
		waitRead(*sent)
	}
	select {
	case <-open:
	case <-guard:
		t.Fatal("the first request never reached the server")
	}
	waitRead(0)
	sent := 0
	send(time.Second, "data: {\"type\":\"response.in_progress\"}\n\n", &sent)
	send(80*time.Second, ": keepalive\n\n", &sent)
	clk.advance(100 * time.Second) // 180 s after the progress, with the connection still open
	select {
	case <-gone:
	case <-guard:
		t.Fatal("the idle attempt stayed open")
	}
	var o outcome
	select {
	case o = <-finished:
	case <-guard:
		t.Fatal("the round did not end")
	}
	if o.err != nil || o.res.Ending != loop.EndNoCall {
		t.Fatalf("round: %+v, %v", o.res, o.err)
	}

	var attemptEvents []api.Event
	for _, e := range events {
		if e.Type == "request.attempt" {
			attemptEvents = append(attemptEvents, e)
		}
	}
	if len(attemptEvents) != 2 {
		t.Fatalf("%d request.attempt events in %v", len(attemptEvents), eventTypes(events))
	}
	first, _ := attemptEvents[0].Fields["record"].(map[string]any)
	want := map[string]any{
		"outcome": "failed", "end_reason": "idle", "error": "provider_failure",
		"last_progress_ms": int64(1000), "last_byte_ms": int64(81000),
	}
	for k, v := range want {
		if !reflect.DeepEqual(first[k], v) {
			t.Errorf("first attempt %s = %#v, want %#v", k, first[k], v)
		}
	}
	if attemptEvents[0].Fields["n"] != 1 {
		t.Errorf("first attempt n = %v", attemptEvents[0].Fields["n"])
	}
	second, _ := attemptEvents[1].Fields["record"].(map[string]any)
	if second["outcome"] != "completed" {
		t.Errorf("retry outcome = %v", second["outcome"])
	}
	if _, ok := second["last_progress_ms"]; !ok {
		t.Errorf("retry record has no last_progress_ms: %v", second)
	}
	types := eventTypes(events)
	if types[len(types)-1] != "round.ended" {
		t.Errorf("events %v do not end with round.ended", types)
	}
	pos := func(e api.Event) int {
		for i := range events {
			if events[i].Seq == e.Seq {
				return i
			}
		}
		return -1
	}
	if pos(attemptEvents[0]) > pos(attemptEvents[1]) {
		t.Errorf("attempt events out of order in %v", types)
	}
}

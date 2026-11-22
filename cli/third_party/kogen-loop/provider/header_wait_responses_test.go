package provider

import (
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/KogenAI/kogen-loop/sys"
)

// Model-free tests of the response-header wait on the Responses (ChatGPT) and Messages
// (Anthropic) routes. They reuse the fixture server of header_timeout_test.go and run on the
// injected Client.Now: the clock moves only while the client is blocked on the server, and
// nothing sleeps for the simulated durations. The real-time guard only fails a hung test.

// rhwStart starts Respond against a fixture server answering with plans, in the background, on
// the wire with the Client's HeaderTimeout (zero: the default).
func rhwStart(t *testing.T, wire string, headerTimeout time.Duration, plans ...*hdtPlan) (*hdtCall, *hdtServer) {
	t.Helper()
	srv := newHdtServer(t, plans...)
	old := idlePoll
	idlePoll = 5 * time.Millisecond
	t.Cleanup(func() { idlePoll = old })
	e, _, req := obsEnv(t, wire)
	e.c.HeaderTimeout = headerTimeout
	st := &signalTransport{rt: &http.Transport{}, reads: make(chan readSignal, 1024)}
	t.Cleanup(func() { st.rt.(*http.Transport).CloseIdleConnections() })
	e.c.HTTP = &http.Client{Transport: st}
	e.s = sys.NewWith([]string{"HOME=" + e.home, "PATH=" + os.Getenv("PATH"), "KOGEN_PROVIDER_URL=" + srv.srv.URL}, e.home)
	c := &hdtCall{t: t, e: e, reads: st.reads, guard: time.After(3 * time.Second)}
	// Release every held handler so the server closes at once when a test fails.
	t.Cleanup(func() {
		for _, p := range srv.plans {
			if p.hold != nil {
				select {
				case <-p.hold:
				default:
					close(p.hold)
				}
			}
		}
	})
	c.run(req)
	return c, srv
}

// rhwStaysUntil fails when the client already left request i.
func rhwStaysUntil(t *testing.T, srv *hdtServer, i int, why string) {
	t.Helper()
	time.Sleep(150 * time.Millisecond)
	select {
	case <-srv.gone[i]:
		t.Fatalf("request %d: the client gave up too early: %s", i+1, why)
	default:
	}
}

func rhwWantFirstAttempt(t *testing.T, c *hdtCall, srv *hdtServer) {
	t.Helper()
	if c.err != nil || c.resp == nil {
		t.Fatalf("the call failed: %v", idleText(c.err))
	}
	if n := srv.count(); n != 1 || len(c.e.clk.slept()) != 0 {
		t.Fatalf("%d requests, slept %v: an attempt was cut and retried", n, c.e.clk.slept())
	}
}

func rhwDelayedHeaders(t *testing.T, wire string, delay time.Duration) {
	head, tail := wireStream(wire)
	p := &hdtPlan{ctype: "text/event-stream", hold: make(chan struct{}), body: make(chan string, 4)}
	c, srv := rhwStart(t, wire, 0, p)
	c.waitOpen(srv, 0)
	c.e.clk.advance(delay)
	close(p.hold)
	c.waitRead(1, 0)
	p.body <- head
	p.body <- tail
	close(p.body)
	c.wait()
	rhwWantFirstAttempt(t, c, srv)
}

func TestMessagesHeadersHeldSixtySeconds(t *testing.T) {
	rhwDelayedHeaders(t, "anthropic", 60*time.Second)
}

func TestResponsesHeadersHeldHundredSeconds(t *testing.T) {
	rhwDelayedHeaders(t, "chatgpt", 100*time.Second)
}

func TestStreamHeadersNeverSentEndAtHeaderTimeout(t *testing.T) {
	for _, tc := range []struct {
		name    string
		timeout time.Duration
		limit   time.Duration
		want    string
	}{
		{"default", 0, DefaultHeaderTimeout, "no response headers within 120 s"},
		{"configured", 30 * time.Second, 30 * time.Second, "no response headers within 30 s"},
	} {
		{
			wire := "anthropic"
			t.Run(tc.name, func(t *testing.T) {
				c, srv := rhwStart(t, wire, tc.timeout,
					&hdtPlan{ctype: "text/event-stream", hold: make(chan struct{})},
					&hdtPlan{ctype: "text/event-stream", hold: make(chan struct{})},
					&hdtPlan{ctype: "text/event-stream", hold: make(chan struct{})})
				for i := range srv.plans {
					c.waitOpen(srv, i)
					c.e.clk.advance(tc.limit - time.Second)
					rhwStaysUntil(t, srv, i, "the header wait lasts the full "+tc.want)
					c.e.clk.advance(time.Second)
					select {
					case <-srv.gone[i]:
					case <-c.guard:
						t.Fatalf("request %d: %v without headers and the client still waited", i+1, tc.limit)
					}
				}
				c.wait()
				if c.err == nil {
					t.Fatal("the call succeeded although the server never sent headers")
				}
				text := idleText(c.err)
				if !strings.Contains(text, tc.want) || !strings.Contains(text, "did not answer after 3 attempts") {
					t.Errorf("error %q does not say three attempts ended with %q", text, tc.want)
				}
				if low := strings.ToLower(text); strings.Contains(low, "first byte") || strings.Contains(low, "idle") {
					t.Errorf("error %q names the first-byte or idle limit", text)
				}
				if srv.count() != 3 {
					t.Errorf("%d requests, want 3", srv.count())
				}
			})
		}
	}
}

func TestStreamFirstProgressCountsFromHeaders(t *testing.T) {
	t.Run("first event 40 s after late headers is in time", func(t *testing.T) {
		head, tail := wireStream("anthropic")
		p := &hdtPlan{ctype: "text/event-stream", hold: make(chan struct{}), body: make(chan string, 4)}
		c, srv := rhwStart(t, "anthropic", 0, p)
		c.waitOpen(srv, 0)
		c.e.clk.advance(100 * time.Second)
		close(p.hold)
		c.waitRead(1, 0)
		c.e.clk.advance(40 * time.Second)
		p.body <- head
		c.waitRead(1, len(head))
		p.body <- tail
		close(p.body)
		c.wait()
		rhwWantFirstAttempt(t, c, srv)
	})

	t.Run("silence after late headers ends 45 s after the headers", func(t *testing.T) {
		plan := func() *hdtPlan {
			return &hdtPlan{ctype: "text/event-stream", hold: make(chan struct{}), body: make(chan string)}
		}
		c, srv := rhwStart(t, "anthropic", 0, plan(), plan(), plan())
		for i, p := range srv.plans {
			c.waitOpen(srv, i)
			c.e.clk.advance(100 * time.Second)
			close(p.hold)
			c.waitRead(i+1, 0)
			c.e.clk.advance(44 * time.Second)
			rhwStaysUntil(t, srv, i, "44 s after the headers is within the 45 s first-progress limit")
			c.e.clk.advance(time.Second)
			select {
			case <-srv.gone[i]:
			case <-c.guard:
				t.Fatalf("request %d: 45 s of silence after the headers and the client still waited", i+1)
			}
		}
		c.wait()
		if c.err == nil || !strings.Contains(idleText(c.err), "no first byte within 45 s") {
			t.Fatalf("error %q does not name the 45 s first-byte limit", idleText(c.err))
		}
		if srv.count() != 3 {
			t.Errorf("%d requests, want 3", srv.count())
		}
	})
}

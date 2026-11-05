package provider

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/KogenAI/kogen-loop/sys"
)

// outage is a fake origin whose loopback port starts closed (connection refused) and can be
// reopened on the same port.
type outage struct {
	t    *testing.T
	srv  *httptest.Server
	addr string
	url  string
	mu   sync.Mutex
	n    int
}

func newOutage(t *testing.T, h ...handler) *outage {
	t.Helper()
	o := &outage{t: t}
	next := 0
	o.srv = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		o.mu.Lock()
		var hh handler
		if next < len(h) {
			hh = h[next]
		}
		next++
		o.n++
		o.mu.Unlock()
		if hh == nil {
			jsonAnswer(400, map[string]any{"error": map[string]any{"message": "scripted provider refusal"}})(w, r)
			return
		}
		hh(w, r)
	}))
	o.addr = o.srv.Listener.Addr().String()
	o.srv.Listener.Close()
	o.url = "http://" + o.addr
	t.Cleanup(o.srv.Close)
	return o
}

// open starts listening again on the port the origin had.
func (o *outage) open() {
	var l net.Listener
	var err error
	for i := 0; i < 50; i++ {
		if l, err = net.Listen("tcp", o.addr); err == nil {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err != nil {
		o.t.Fatal(err)
	}
	o.srv.Listener = l
	o.srv.Start()
}

func (o *outage) requests() int {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.n
}

// reopenAfter makes the client's Sleep open the origin once it has paused for 1 s n times.
func (o *outage) reopenAfter(e *env, n int) {
	probes := 0
	clk := e.clk
	e.c.Sleep = func(ctx context.Context, d time.Duration) error {
		err := clk.Sleep(ctx, d)
		if d == time.Second {
			probes++
			if probes == n {
				o.open()
			}
		}
		return err
	}
}

type outageRoute struct {
	name, label string
	env         func(t *testing.T, origin string) *env
	req         Request
	ok          handler
}

func outageRoutes() []outageRoute {
	keyed := func(name string) func(t *testing.T, origin string) *env {
		return func(t *testing.T, origin string) *env {
			e := newEnvWithURL(t, origin)
			e.saveCreds(name, map[string]any{"provider": name, "api_key": testKey})
			return e
		}
	}
	return []outageRoute{
		{"chatgpt", "ChatGPT", func(t *testing.T, origin string) *env {
			e := newEnvWithURL(t, origin)
			e.saveCreds("chatgpt", e.chatgptCreds())
			return e
		}, Request{Role: fixtureRole, Instructions: "fixture", Input: user("x")}, textAnswer("done")},
		{"opencode-go", "OpenCode Go", keyed("opencode-go"), Request{Role: goRole, Instructions: "p", Input: user("x")}, textHandlerGo("done")},
		{"anthropic", "Anthropic", keyed("anthropic"), Request{Role: claudeRole, Instructions: "p", Input: user("x")}, claudeText("done")},
	}
}

// transportThenCompleted checks the failed attempt's record (Chat Completions has no stream
// observation, so its end_reason stays null as before) and the completed one.
func transportThenCompleted(t *testing.T, rt outageRoute, obs *observer) {
	t.Helper()
	recs := obs.records()
	if len(recs) != 2 {
		t.Fatalf("%d attempt records", len(recs))
	}
	var end any = "transport"
	if rt.name == "opencode-go" {
		end = nil
	}
	if recs[0]["outcome"] != "failed" || recs[0]["error"] != "provider_failure" || recs[0]["end_reason"] != end || recs[1]["outcome"] != "completed" {
		t.Fatalf("records %v / %v", recs[0], recs[1])
	}
}

// dialTimeout is a transport whose first dial fails like the default dialer's i/o timeout.
type timeoutErr struct{}

func (timeoutErr) Error() string   { return "i/o timeout" }
func (timeoutErr) Timeout() bool   { return true }
func (timeoutErr) Temporary() bool { return true }

func failingDial(first int32, err error) *http.Client {
	var calls atomic.Int32
	return &http.Client{Transport: &http.Transport{
		DisableCompression: true,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			if calls.Add(1) <= first {
				return nil, err
			}
			return (&net.Dialer{}).DialContext(ctx, network, addr)
		},
	}}
}

func TestConnectionFailureWaitsForOrigin(t *testing.T) {
	t.Parallel()
	for _, rt := range outageRoutes() {
		t.Run(rt.name+"/refused", func(t *testing.T) {
			t.Parallel()
			o := newOutage(t, rt.ok)
			e := rt.env(t, o.url)
			o.reopenAfter(e, 3)
			obs := &observer{}
			resp, err := e.c.Respond(context.Background(), e.s, rt.req, obs)
			if err != nil || resp == nil {
				t.Fatal(err)
			}
			if o.requests() != 1 || !reflect.DeepEqual(e.clk.slept(), secs(2, 1, 1, 1)) {
				t.Fatalf("%d requests, slept %v", o.requests(), e.clk.slept())
			}
			transportThenCompleted(t, rt, obs)
		})
		t.Run(rt.name+"/dial timeout", func(t *testing.T) {
			t.Parallel()
			o := newOutage(t, rt.ok)
			e := rt.env(t, o.url)
			e.c.HTTP = failingDial(1, &net.OpError{Op: "dial", Net: "tcp", Err: timeoutErr{}})
			o.reopenAfter(e, 3)
			obs := &observer{}
			if _, err := e.c.Respond(context.Background(), e.s, rt.req, obs); err != nil {
				t.Fatal(err)
			}
			if o.requests() != 1 || !reflect.DeepEqual(e.clk.slept(), secs(2, 1, 1, 1)) {
				t.Fatalf("%d requests, slept %v", o.requests(), e.clk.slept())
			}
			transportThenCompleted(t, rt, obs)
		})
	}
}

func TestConnectionFailureKeepsThreeAttempts(t *testing.T) {
	t.Parallel()
	t.Run("origin comes back failing", func(t *testing.T) {
		t.Parallel()
		o := newOutage(t, limited(503, "0"), limited(503, "0"), limited(503, "0"))
		rt := outageRoutes()[0]
		e := rt.env(t, o.url)
		o.reopenAfter(e, 2)
		obs := &observer{}
		_, err := e.c.Respond(context.Background(), e.s, rt.req, obs)
		se := mustErr(t, err)
		if !strings.HasPrefix(se.Detail, "ChatGPT did not answer after 3 attempts: HTTP 503 ") || o.requests() != 2 || len(obs.records()) != 3 {
			t.Fatalf("%v, %d requests, %d records", se, o.requests(), len(obs.records()))
		}
	})
	t.Run("origin accepts probes but refuses attempts", func(t *testing.T) {
		t.Parallel()
		o := newOutage(t, textAnswer("never"))
		o.open()
		rt := outageRoutes()[0]
		e := rt.env(t, o.url)
		refused := &net.OpError{Op: "dial", Net: "tcp", Err: os.NewSyscallError("connect", syscall.ECONNREFUSED)}
		e.c.HTTP = failingDial(100, refused)
		obs := &observer{}
		_, err := e.c.Respond(context.Background(), e.s, rt.req, obs)
		se := mustErr(t, err)
		if !strings.HasPrefix(se.Detail, "ChatGPT did not answer after 3 attempts: network error: ") || !strings.HasSuffix(se.Detail, "connection refused") ||
			len(obs.records()) != 3 || o.requests() != 0 || !reflect.DeepEqual(e.clk.slept(), secs(2, 8)) {
			t.Fatalf("%v, %d records, %d requests, slept %v", se, len(obs.records()), o.requests(), e.clk.slept())
		}
	})
}

func TestFailureAfterConnectionKeepsTodaysHandling(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, _, err := w.(http.Hijacker).Hijack()
		if err == nil {
			c.Close()
		}
	}))
	defer srv.Close()
	e := newEnvWithURL(t, srv.URL)
	e.saveCreds("chatgpt", e.chatgptCreds())
	obs := &observer{}
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: fixtureRole, Instructions: "fixture"}, obs)
	se := mustErr(t, err)
	if !strings.HasPrefix(se.Detail, "ChatGPT did not answer after 3 attempts: network error: ") || len(obs.records()) != 3 || !reflect.DeepEqual(e.clk.slept(), secs(2, 8)) {
		t.Fatalf("%v, %d records, slept %v", se, len(obs.records()), e.clk.slept())
	}
}

func TestSingleConnectionFailureDoesNotWait(t *testing.T) {
	t.Parallel()
	o := newOutage(t)
	e := outageRoutes()[0].env(t, o.url)
	obs := &observer{}
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: fixtureRole, Instructions: "fixture", Single: true}, obs)
	se := mustErr(t, err)
	if !strings.HasPrefix(se.Detail, "network error: ") || len(obs.records()) != 1 || len(e.clk.slept()) != 0 {
		t.Fatalf("%v, %d records, slept %v", se, len(obs.records()), e.clk.slept())
	}
}

func TestClosedOriginIsWaitedForUntilTheBudget(t *testing.T) {
	t.Parallel()
	for _, rt := range outageRoutes() {
		t.Run(rt.name, func(t *testing.T) {
			t.Parallel()
			o := newOutage(t, rt.ok)
			e := rt.env(t, o.url)
			e.c.ResponseBudget = 10 * time.Second
			obs := &observer{}
			_, err := e.c.Respond(context.Background(), e.s, rt.req, obs)
			se := mustErr(t, err)
			if se.Reason != "unavailable" || se.Detail != rt.label+" response wait exceeded 10s" || len(obs.records()) != 1 || o.requests() != 0 ||
				strings.Contains(se.Detail, testKey) || strings.Contains(se.Detail, "fake-access-token") || strings.Contains(se.Detail, o.addr) {
				t.Fatalf("%v, %d records, %d requests", se, len(obs.records()), o.requests())
			}
		})
	}
}

func TestCancellationEndsTheWaitForOrigin(t *testing.T) {
	t.Parallel()
	t.Run("context", func(t *testing.T) {
		t.Parallel()
		o := newOutage(t, textAnswer("never"))
		e := outageRoutes()[0].env(t, o.url)
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		clk := e.clk
		probes := 0
		e.c.Sleep = func(ctx context.Context, d time.Duration) error {
			if d == time.Second {
				if probes++; probes == 2 {
					cancel()
				}
			}
			return clk.Sleep(ctx, d)
		}
		obs := &observer{}
		_, err := e.c.Respond(ctx, e.s, Request{Role: fixtureRole, Instructions: "fixture"}, obs)
		if err != context.Canceled || len(obs.records()) != 1 || o.requests() != 0 {
			t.Fatalf("%v, %d records, %d requests", err, len(obs.records()), o.requests())
		}
	})
	t.Run("interrupt", func(t *testing.T) {
		t.Parallel()
		o := newOutage(t, textAnswer("never"))
		e := outageRoutes()[0].env(t, o.url)
		clk := e.clk
		probes := 0
		e.c.Sleep = func(ctx context.Context, d time.Duration) error {
			if d == time.Second {
				if probes++; probes == 2 {
					e.s.Interrupt("SIGINT")
				}
			}
			return clk.Sleep(ctx, d)
		}
		obs := &observer{}
		_, err := e.c.Respond(context.Background(), e.s, Request{Role: fixtureRole, Instructions: "fixture"}, obs)
		if in, ok := err.(*sys.Interrupted); !ok || in.Signal != "SIGINT" || len(obs.records()) != 1 || o.requests() != 0 {
			t.Fatalf("%v, %d records, %d requests", err, len(obs.records()), o.requests())
		}
	})
}

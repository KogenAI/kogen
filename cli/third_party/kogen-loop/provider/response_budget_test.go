package provider

import (
	"context"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type budgetTransport struct {
	base      http.RoundTripper
	remaining time.Duration
}

func (b *budgetTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	deadline, ok := r.Context().Deadline()
	if ok {
		b.remaining = time.Until(deadline)
	}
	return b.base.RoundTrip(r)
}

// assertBudgetDeadline observes the actual transport deadline rather than inferring
// the selected budget from the diagnostic text.
func assertBudgetDeadline(t *testing.T, client, request, want time.Duration) {
	t.Helper()
	e, _ := chatEnv(t, textAnswer("ok"))
	e.c.ResponseBudget = client
	transport := &budgetTransport{base: http.DefaultTransport}
	e.c.HTTP = &http.Client{Transport: transport}
	if _, err := e.respond(Request{Budget: request}); err != nil {
		t.Fatal(err)
	}
	if transport.remaining <= want-50*time.Millisecond || transport.remaining > want {
		t.Fatalf("client %v request %v: deadline remaining %v, want %v", client, request, transport.remaining, want)
	}
}

// expiryDetail expires a call on the fake clock (a held credential lock; each wait advances
// the clock 100x) and returns its error detail.
func expiryDetail(t *testing.T, client, request time.Duration) string {
	t.Helper()
	f := newFake(t, textAnswer("never"))
	e := newEnv(t, f)
	e.saveCreds("chatgpt", e.chatgptCreds())
	p, _ := Lookup("chatgpt")
	held, err := (Locker{}).Acquire(lockPath(e.home, p))
	if err != nil {
		t.Fatal(err)
	}
	defer held.Release()
	e.saveCreds("chatgpt", e.chatgptCreds("expires_at", e.clk.Now().Unix()+10))
	e.c.Sleep = func(ctx context.Context, d time.Duration) error { return e.clk.Sleep(ctx, d*100) }
	e.c.ResponseBudget = client
	_, err = e.respond(Request{Budget: request})
	se := mustErr(t, err)
	if se.Class != "provider" || se.Reason != "unavailable" || se.Exit != 4 || len(f.requests()) != 0 {
		t.Fatalf("%v", se)
	}
	return se.Detail
}

func TestClientResponseBudgetDefault(t *testing.T) {
	for _, b := range []time.Duration{0, 30 * time.Minute} {
		assertBudgetDeadline(t, b, 0, 30*time.Minute)
	}
	if ResponseBudget != 30*time.Minute {
		t.Fatal(ResponseBudget)
	}
	want := "ChatGPT response wait exceeded 30 minutes"
	if got := expiryDetail(t, 0, 0); got != want {
		t.Fatal(got)
	}
	if got := NewClient("v"); got.ResponseBudget != 0 {
		t.Fatal(got.ResponseBudget)
	}
	if got := expiryDetail(t, 30*time.Minute, 0); got != "ChatGPT response wait exceeded 30m0s" {
		t.Fatal(got)
	}
	// request bytes and the transport deadline are the same for zero and explicit 30m
	var bodies [2]string
	for i, b := range []time.Duration{0, 30 * time.Minute} {
		e, _ := chatEnv(t, textAnswer("ok"))
		f := e.f
		e.realClock()
		e.c.ResponseBudget = b
		if _, err := e.respond(Request{}); err != nil {
			t.Fatal(err)
		}
		reqs := f.requests()
		if len(reqs) != 1 {
			t.Fatal(len(reqs))
		}
		bodies[i] = string(reqs[0].Body)
		for _, h := range []string{"Conversation_id", "Session_id"} {
			bodies[i] = strings.ReplaceAll(bodies[i], reqs[0].Header.Get(h), "ID")
		}
	}
	if bodies[0] != bodies[1] {
		t.Fatalf("bytes differ:\n%s\n%s", bodies[0], bodies[1])
	}
}

func TestClientResponseBudgetValidation(t *testing.T) {
	bad := []time.Duration{-time.Second, time.Second - 1, 30*time.Minute + 1}
	for _, d := range bad {
		e, f := chatEnv(t, textAnswer("ok"))
		e.c.ResponseBudget = d
		_, err := e.respond(Request{})
		se := mustErr(t, err)
		if se.Class != "provider" || se.Reason != "refused" || se.Exit != 4 || se.Detail != "response budget must be zero or between 1s and 30m0s" || len(f.requests()) != 0 || len(e.clk.slept()) != 0 {
			t.Fatalf("%v: %v", d, se)
		}
	}
	for _, d := range []time.Duration{0, time.Second, time.Second + 1, 10 * time.Minute, 30*time.Minute - 1, 30 * time.Minute} {
		e, f := chatEnv(t, textAnswer("ok"))
		e.c.ResponseBudget = d
		if _, err := e.respond(Request{}); err != nil || len(f.requests()) != 1 {
			t.Fatalf("%v: %v", d, err)
		}
	}
}

func TestClientResponseBudgetPrecedence(t *testing.T) {
	cases := []struct {
		client, req time.Duration
		want        string
	}{
		{10 * time.Minute, 0, "10m0s"},
		{10 * time.Minute, 2 * time.Second, "2s"},
		{10 * time.Minute, 10 * time.Minute, "10m0s"},
		{10 * time.Minute, time.Hour, "10m0s"},
		{10 * time.Minute, 150 * time.Millisecond, "150ms"},
		{2 * time.Second, 2 * time.Second, "2s"},
		{2 * time.Second, 5 * time.Second, "2s"},
	}
	for _, c := range cases {
		want, err := time.ParseDuration(c.want)
		if err != nil {
			t.Fatal(err)
		}
		assertBudgetDeadline(t, c.client, c.req, want)
		if got := expiryDetail(t, c.client, c.req); got != "ChatGPT response wait exceeded "+c.want {
			t.Fatalf("%v/%v: %s", c.client, c.req, got)
		}
	}
	// invalid client value is not bypassed by a valid request override
	e, f := chatEnv(t, textAnswer("ok"))
	e.c.ResponseBudget = 31 * time.Minute
	_, err := e.respond(Request{Budget: time.Second})
	if se := mustErr(t, err); se.Reason != "refused" || len(f.requests()) != 0 {
		t.Fatalf("%v", err)
	}
}

func TestClientResponseBudgetStall(t *testing.T) {
	release := make(chan struct{})
	var attempts atomic.Int32
	closed := make(chan struct{})
	e, _ := chatEnv(t, func(w http.ResponseWriter, r *http.Request) {
		attempts.Add(1)
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(200)
		w.(http.Flusher).Flush()
		select {
		case <-r.Context().Done():
		case <-release:
		case <-time.After(10 * time.Second):
		}
		close(closed)
	})
	defer close(release)
	e.realClock()
	e.c.ResponseBudget = 2 * time.Second
	start := time.Now()
	_, err := e.respond(Request{})
	el := time.Since(start)
	se := mustErr(t, err)
	if el < 1800*time.Millisecond || el > 4*time.Second || se.Reason != "unavailable" || se.Exit != 4 || se.Detail != "ChatGPT response wait exceeded 2s" || attempts.Load() != 1 {
		t.Fatalf("%v after %v, %d attempts", se, el, attempts.Load())
	}
	select {
	case <-closed:
	case <-time.After(2 * time.Second):
		t.Fatal("response not cleaned up")
	}
}

func TestClientResponseBudgetAbsolute(t *testing.T) {
	// retries and their backoff spend one budget: expiry adds no attempt
	e, f := chatEnv(t, jsonAnswer(500, map[string]any{}), jsonAnswer(500, map[string]any{}), jsonAnswer(500, map[string]any{}))
	e.c.ResponseBudget = 5 * time.Second
	start := e.clk.Now()
	_, err := e.respond(Request{})
	if se := mustErr(t, err); se.Detail != "ChatGPT response wait exceeded 5s" {
		t.Fatal(se)
	}
	if el := e.clk.Now().Sub(start); el != 5*time.Second || len(f.requests()) != 2 {
		t.Fatalf("spent %v over %d attempts", el, len(f.requests()))
	}
	// stream progress does not renew it
	opened, closed := make(chan struct{}), make(chan struct{})
	busy := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		close(opened)
		tick := time.NewTicker(5 * time.Millisecond)
		defer tick.Stop()
		for {
			select {
			case <-r.Context().Done():
				close(closed)
				return
			case <-tick.C:
				if _, err := w.Write([]byte(": heartbeat\n\n")); err != nil {
					close(closed)
					return
				}
				w.(http.Flusher).Flush()
			}
		}
	}
	e2, f2 := chatEnv(t, busy)
	e2.realClock()
	e2.c.ResponseBudget = time.Second
	begin := time.Now()
	_, err = e2.c.Respond(context.Background(), e2.s, Request{Role: fixtureRole, Instructions: "fixture"}, nil)
	if se := mustErr(t, err); !strings.HasSuffix(se.Detail, "response wait exceeded 1s") || time.Since(begin) > 3*time.Second || len(f2.requests()) != 1 {
		t.Fatalf("%v after %v", err, time.Since(begin))
	}
	<-closed
}

func TestClientResponseBudgetDiagnostic(t *testing.T) {
	cases := []struct {
		client, req time.Duration
		want        string
	}{
		{0, 0, "30 minutes"},
		{0, 150 * time.Millisecond, "30 minutes"},
		{10 * time.Minute, 0, "10m0s"},
		{30 * time.Minute, 0, "30m0s"},
		{10 * time.Minute, 2 * time.Second, "2s"},
		{10 * time.Minute, 150 * time.Millisecond, "150ms"},
		{2 * time.Second, 2 * time.Second, "2s"},
		{2 * time.Second, time.Minute, "2s"},
	}
	for _, c := range cases {
		if got := expiryDetail(t, c.client, c.req); got != "ChatGPT response wait exceeded "+c.want {
			t.Fatalf("%v/%v: %s", c.client, c.req, got)
		}
	}
}

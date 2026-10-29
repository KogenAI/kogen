package build

import (
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"kogen-loop/provider"
)

// These tests run the native builder and the independent reviewer with the production research
// settings, never replacing the default: the budget each request is sent under is observed on
// the real client's transport deadline, and the run log and the expiry diagnostic are read as a
// user sees them. They are serial because other tests change the process-wide settings.

type deadlineObserver struct {
	mu        sync.Mutex
	remaining []time.Duration
	missing   int
}

func (o *deadlineObserver) RoundTrip(r *http.Request) (*http.Response, error) {
	o.mu.Lock()
	if d, ok := r.Context().Deadline(); ok {
		o.remaining = append(o.remaining, time.Until(d))
	} else {
		o.missing++
	}
	o.mu.Unlock()
	return http.DefaultTransport.RoundTrip(r)
}

func observeDeadlines(c *provider.Client) *deadlineObserver {
	o := &deadlineObserver{}
	c.HTTP = &http.Client{Transport: o}
	return o
}

// wantTenMinutes holds that all n exchanges were sent under the ten-minute budget: not the
// library's thirty minutes, not a lower setting and not unbounded.
func (o *deadlineObserver) wantTenMinutes(t *testing.T, n int) {
	t.Helper()
	o.mu.Lock()
	defer o.mu.Unlock()
	if len(o.remaining) != n || o.missing != 0 {
		t.Fatalf("observed %d exchanges (%d without a deadline), want %d", len(o.remaining), o.missing, n)
	}
	for i, d := range o.remaining {
		if d > 10*time.Minute || d < 10*time.Minute-time.Minute {
			t.Fatalf("exchange %d had %s left, want about ten minutes", i, d)
		}
	}
}

// budgetClock is the client's controllable clock.
type budgetClock struct {
	mu  sync.Mutex
	now time.Time
}

func newBudgetClock() *budgetClock { return &budgetClock{now: time.Now()} }

func (c *budgetClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *budgetClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

// stalledPastTen is a provider that takes a request, says nothing, and loses the connection
// once more than ten minutes have passed on the clock: no wall-clock wait.
func stalledPastTen(c *budgetClock) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		c.Advance(10*time.Minute + time.Second)
		panic(http.ErrAbortHandler)
	}
}

// wantBudgetRecord holds that a run log has exactly one response_budget event, naming ten minutes.
func wantBudgetRecord(t *testing.T, events []map[string]any) {
	t.Helper()
	got := eventsNamed(events, "response_budget")
	if len(got) != 1 {
		t.Fatalf("%d response_budget events, want exactly one: %v", len(got), got)
	}
	eq(t, "budget", got[0]["budget"], any("10 minutes"))
	eq(t, "budget_ms", got[0]["budget_ms"], any(float64(600000)))
}

// wantTenMinuteExpiry holds that what the user saw reports the unavailable provider failure of a
// stalled wait naming ten minutes, never the library's Go duration form.
func wantTenMinuteExpiry(t *testing.T, a *attempt) {
	t.Helper()
	text := a.shown()
	contains(t, "output", text, "provider/unavailable: ChatGPT response wait exceeded 10 minutes\n")
	lacks(t, "output", text, "10m0s")
	if a.exit != 4 {
		t.Fatalf("exit %d: %s", a.exit, text)
	}
}

func TestResponseBudgetDefaultBuild(t *testing.T) {
	t.Run("the builder and the independent reviewer send under ten minutes and the run records it once", func(t *testing.T) {
		e := newEnv(t)
		f := e.prov
		f.then(landScript(f)...)
		f.then(submit(f, "approve"))
		var obs *deadlineObserver
		a := e.reviewed(func(in *Input) { obs = observeDeadlines(in.Deps.Client) })
		if a.exit != 0 || a.err != nil {
			t.Fatalf("exit %d err %v\n%s", a.exit, a.err, a.shown())
		}
		eq(t, "review requests", len(f.reviewRequests()), 1)
		eq(t, "builder requests", f.count()-1, 1)
		obs.wantTenMinutes(t, f.count())
		wantBudgetRecord(t, e.events(e.onlyRun()))
	})

	t.Run("a stalled builder expires unavailable naming ten minutes and its resume lands under a new budget", func(t *testing.T) {
		e := newEnv(t)
		f := e.prov
		clock := newBudgetClock()
		f.then(stalledPastTen(clock))
		a := e.build(func(in *Input) { in.Deps.Client.Now = clock.Now })
		wantTenMinuteExpiry(t, a)
		eq(t, "requests", f.count(), 1)
		id := e.onlyRun()
		eq(t, "outcome", e.result(id)["outcome"], any("unavailable"))
		wantBudgetRecord(t, e.events(id))

		f.then(landScript(f)...)
		var obs *deadlineObserver
		r := e.resume(id, func(in *ResumeInput) { obs = observeDeadlines(in.Deps.Client) })
		if r.exit != 0 || r.err != nil {
			t.Fatalf("exit %d err %v\n%s", r.exit, r.err, r.shown())
		}
		obs.wantTenMinutes(t, 1)
		ids := e.runIDs()
		eq(t, "runs", len(ids), 2)
		for _, run := range ids {
			wantBudgetRecord(t, e.events(run))
		}
	})

	t.Run("a stalled review expires unavailable naming ten minutes and its resume answers it", func(t *testing.T) {
		e := newEnv(t)
		f := e.prov
		clock := newBudgetClock()
		f.then(landScript(f)...)
		f.then(stalledPastTen(clock))
		a := e.reviewed(func(in *Input) { in.Deps.Client.Now = clock.Now })
		wantTenMinuteExpiry(t, a)
		eq(t, "review requests", len(f.reviewRequests()), 1)
		id := e.onlyRun()
		wantBudgetRecord(t, e.events(id))

		f.then(submit(f, "approve"))
		var obs *deadlineObserver
		r := e.resume(id, useRealReviewerOnResume, func(in *ResumeInput) { obs = observeDeadlines(in.Deps.Client) })
		if r.exit != 0 || r.err != nil {
			t.Fatalf("exit %d err %v\n%s", r.exit, r.err, r.shown())
		}
		obs.wantTenMinutes(t, 1)
		eq(t, "review requests", len(f.reviewRequests()), 2)
		for _, run := range e.runIDs() {
			wantBudgetRecord(t, e.events(run))
		}
		if !strings.Contains(r.shown(), "review: approved") {
			t.Fatalf("resume: %s", r.shown())
		}
	})
}

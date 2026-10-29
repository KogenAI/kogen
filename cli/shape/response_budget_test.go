package shape

import (
	"context"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
)

// These tests run the entries with the production research settings, never replacing the
// default: the response budget each provider-backed entry sends with is observed on the real
// client's transport deadline, and the run log and the expiry diagnostic are read as a user
// sees them. They are serial because other tests change the process-wide settings.

// deadlineObserver records the time the client's transport had left for each exchange.
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
	if n < 2 || len(o.remaining) != n || o.missing != 0 {
		t.Fatalf("observed %d exchanges (%d without a deadline), want %d (at least 2)", len(o.remaining), o.missing, n)
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
func stalledPastTen(c *budgetClock) shpStep {
	return shpStep{handler: func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		c.Advance(10*time.Minute + time.Second)
		panic(http.ErrAbortHandler)
	}}
}

// budgetEvents are the response_budget events of a run log.
func budgetEvents(events []map[string]any) []map[string]any {
	return shpNamed(events, "response_budget")
}

func wantBudgetRecord(t *testing.T, events []map[string]any) {
	t.Helper()
	got := budgetEvents(events)
	if len(got) != 1 {
		t.Fatalf("%d response_budget events, want exactly one: %v", len(got), got)
	}
	shpEq(t, "budget", got[0]["budget"], any("10 minutes"))
	shpEq(t, "budget_ms", got[0]["budget_ms"], any(float64(600000)))
}

// wantTenMinuteText holds that what the user saw reports the provider's unavailable failure of
// a stalled wait, naming ten minutes in the library's Go duration form nowhere.
func wantTenMinuteText(t *testing.T, text string) {
	t.Helper()
	if !strings.Contains(text, "provider/unavailable: ChatGPT response wait exceeded 10 minutes\n") || strings.Contains(text, "10m0s") {
		t.Fatalf("the user saw %q", text)
	}
}

func TestResponseBudgetDefaultShape(t *testing.T) {
	t.Run("shape sends every request under ten minutes and records it once", func(t *testing.T) {
		serialTmp(t)
		f := newShpFx(t, shpSubmit("c1", shpFiles()), shpAck("c2"))
		obs := observeDeadlines(f.Client)
		f.newSession()
		if _, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: "Add calc.is_even(n).", Client: f.Client}); err != nil {
			t.Fatalf("%v\n%s", err, f.Stdout)
		}
		obs.wantTenMinutes(t, len(f.Prov.requests()))
		wantBudgetRecord(t, f.events())
	})

	t.Run("a stalled shape expires unavailable naming ten minutes, is not retried and records once", func(t *testing.T) {
		serialTmp(t)
		clock := newBudgetClock()
		f := newShpFx(t, stalledPastTen(clock), shpSubmit("c1", shpFiles()), shpAck("c2"))
		f.Client.Now = clock.Now
		f.newSession()
		exit, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: "Add calc.is_even(n).", Client: f.Client})
		e, ok := sys.AsError(err)
		if !ok || e.Class != "shape" || e.Reason != "provider_failed" || e.Exit != 4 || exit != 4 {
			t.Fatalf("exit %d err %v", exit, err)
		}
		wantTenMinuteText(t, knobText(f, err))
		shpEq(t, "requests", len(f.Prov.requests()), 1)
		wantBudgetRecord(t, f.events())

		// The retry Shape names is the rerun: it is a new run with its own single record.
		f.newSession()
		if _, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: "Add calc.is_even(n).", Client: f.Client}); err != nil {
			t.Fatalf("%v\n%s", err, f.Stdout)
		}
		shpEq(t, "requests after the rerun", len(f.Prov.requests()) > 1, true)
		shpEq(t, "records after the rerun", len(budgetEvents(f.events())), 2)
	})

	t.Run("refine sends every request under ten minutes and records it once", func(t *testing.T) {
		serialTmp(t)
		f := newRefFx(t, refOpts{red: true}, shpAnswer(shpCall("p1", "probe", map[string]any{"command": "true"})), refSubmit("c1", refIntentPath, shpIntentMD))
		f.remove(".kogen/local/readiness/is-even.json")
		obs := observeDeadlines(f.Client)
		f.newSession()
		if _, err := Refine(context.Background(), f.S, RefineInput{Project: f.Root, Slug: shpSlug, Hash: f.hash0, Request: "Clarify the draft.", Client: f.Client}); err != nil {
			t.Fatal(err)
		}
		obs.wantTenMinutes(t, len(f.Prov.requests()))
		wantBudgetRecord(t, f.evidenceEvents())
	})

	t.Run("a stalled refine expires unavailable naming ten minutes and records once", func(t *testing.T) {
		serialTmp(t)
		clock := newBudgetClock()
		f := newRefFx(t, refOpts{red: true}, stalledPastTen(clock), refSubmit("c1", refIntentPath, shpIntentMD))
		f.remove(".kogen/local/readiness/is-even.json")
		f.Client.Now = clock.Now
		f.newSession()
		_, err := Refine(context.Background(), f.S, RefineInput{Project: f.Root, Slug: shpSlug, Hash: f.hash0, Request: "Clarify the draft.", Client: f.Client})
		if e, ok := sys.AsError(err); !ok || e.Class != "provider" || e.Reason != "unavailable" || e.Exit != 4 {
			t.Fatalf("err %v, want provider/unavailable (exit 4)", err)
		}
		wantTenMinuteText(t, knobText(f.shpFx, err))
		shpEq(t, "requests", len(f.Prov.requests()), 1)
		wantBudgetRecord(t, f.evidenceEvents())
	})

	t.Run("shape workers send under the same ten minutes within the one record", func(t *testing.T) {
		serialTmp(t)
		f := newShpFx(t)
		f.withWorkers()
		obs := observeDeadlines(f.Client)
		brief := f.brief("features/steps/draft.js")
		jobs := []any{shpJob("inspect", "probe", []any{"app.txt"}), shpJob("draft", "draft", []any{}, "features/steps/draft.js")}
		draft := map[string]any{"path": "features/steps/draft.js", "content": "// drafted\n"}
		f.Prov.route = func(req map[string]any) *shpStep {
			switch workerJobID(req) {
			case "inspect":
				st := shpWorkerResult("w3", "inspected the fixture")
				return &st
			case "draft":
				st := shpWorkerResult("d1", "drafted the step", draft)
				return &st
			}
			return nil
		}
		f.Prov.seq = []shpStep{
			shpAnswer(shpCall("b1", "shape_batch", map[string]any{"brief": brief, "jobs": jobs})),
			shpSubmit("q", map[string]any{"questions": []any{shpQuestion("Q?")}}),
		}
		f.newSession()
		exit, err := f.shape("Add calc.is_even(n).")
		if err != nil || exit != 5 {
			t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
		}
		workers := 0
		for _, r := range f.Prov.requests() {
			if workerJobID(r) != "" {
				workers++
			}
		}
		shpEq(t, "worker requests", workers, 2)
		obs.wantTenMinutes(t, len(f.Prov.requests()))
		wantBudgetRecord(t, f.events())
	})

	t.Run("the setup conversation of init sends under ten minutes", func(t *testing.T) {
		serialTmp(t)
		f := initNewFx(t, true, initNothing())
		f.write("README.md", "x\n")
		f.commitAll("a")
		client := provider.NewClient("dev+12345678")
		obs := observeDeadlines(client)
		s := sys.NewWith(f.env, f.repo)
		s.Stdout, s.Stderr = f.out, f.err
		exit, err := Init(context.Background(), s, InitInput{Client: client, Tools: f.tools, Home: f.home})
		if exit != 0 || err != nil {
			t.Fatalf("exit %d err %v", exit, err)
		}
		shpEq(t, "requests", len(f.requests()), 1)
		obs.mu.Lock()
		defer obs.mu.Unlock()
		if len(obs.remaining) != 1 || obs.missing != 0 || obs.remaining[0] > 10*time.Minute || obs.remaining[0] < 9*time.Minute {
			t.Fatalf("setup exchange deadlines %v (%d without one)", obs.remaining, obs.missing)
		}
	})
}

package conformance

import (
	"context"
	"encoding/json"
	"math"
	"net/http"
	"runtime"
	"sync"
	"testing"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
)

// gapClock is a scripted client clock: it moves only when a request is sent or a wait sleeps.
type gapClock struct {
	mu     sync.Mutex
	t      time.Time
	waited time.Duration
}

func (c *gapClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *gapClock) advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

func (c *gapClock) Sleep(ctx context.Context, d time.Duration) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	c.advance(d)
	c.mu.Lock()
	c.waited += d
	c.mu.Unlock()
	return nil
}

// gapTransport spends 30 ms of the scripted clock in every exchange.
type gapTransport struct{ clk *gapClock }

func (g gapTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	g.clk.advance(30 * time.Millisecond)
	return http.DefaultTransport.RoundTrip(r)
}

type gapRecords struct{ recs []map[string]any }

func (o *gapRecords) Attempt(rec map[string]any) { o.recs = append(o.recs, rec) }

func TestAttemptRecordsCarryRequestOffsetAndLoad(t *testing.T) {
	w := newWorld(t).signIn()
	f := newFakeProvider(t, []exchange{{Status: 503}, {Items: []map[string]any{message("ok")}}})
	clk := &gapClock{t: time.Now()}
	client := provider.NewClient("kogen-loop test")
	client.Now, client.Sleep, client.HTTP = clk.Now, clk.Sleep, &http.Client{Transport: gapTransport{clk}}
	s := sys.NewWith(w.env(f), w.root)
	obs := &gapRecords{}
	req := provider.Request{Role: provider.Role{Provider: "chatgpt", Model: "fixture-model", Effort: "medium"}, Instructions: "i"}
	if _, err := client.Respond(context.Background(), s, req, obs); err != nil {
		t.Fatal(err)
	}
	if len(obs.recs) != 2 || clk.waited == 0 {
		t.Fatalf("%d attempt records and %s waited, want 2 attempts and a wait", len(obs.recs), clk.waited)
	}
	wall := func(rec map[string]any) int64 { n, _ := rec["wall_ms"].(int64); return n }
	want := []int64{0, wall(obs.recs[0]) + clk.waited.Milliseconds()}
	for i, rec := range obs.recs {
		if got, ok := rec["request_offset_ms"].(int64); !ok || got != want[i] {
			t.Errorf("attempt %d request_offset_ms = %#v, want %d", i+1, rec["request_offset_ms"], want[i])
		}
		raw, err := json.Marshal(rec["load_average"])
		if err != nil {
			t.Fatal(err)
		}
		if runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
			if string(raw) != "null" {
				t.Errorf("attempt %d load_average = %s, want null", i+1, raw)
			}
			continue
		}
		var load []float64
		if err := json.Unmarshal(raw, &load); err != nil || len(load) != 3 {
			t.Fatalf("attempt %d load_average = %s, want three numbers", i+1, raw)
		}
		for _, v := range load {
			if v < 0 || math.Abs(v*100-math.Round(v*100)) > 1e-9 {
				t.Errorf("attempt %d load_average = %s", i+1, raw)
			}
		}
	}
}

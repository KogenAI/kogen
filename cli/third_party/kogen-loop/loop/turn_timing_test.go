package loop

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/KogenAI/kogen-loop/api"
	"github.com/KogenAI/kogen-loop/provider"
	"github.com/KogenAI/kogen-loop/sys"
	"github.com/KogenAI/kogen-loop/tools"
)

// timingTurn is one scripted provider turn: an optional first attempt that fails with a 503
// after failAfter (with retryAfter as its Retry-After header), the provider time of the
// answering attempt and the probe calls (milliseconds each) it asks for; no probes: finish.
type timingTurn struct {
	failAfter  time.Duration
	retryAfter string
	provider   time.Duration
	probes     []int
	status     int // the answering attempt's status when not 200 (a failed turn)
}

type timingRun struct {
	events  []api.Event
	session *Session
	err     error
}

// runTiming plays the turns through a Session on one injected clock shared by Client.Now,
// Client.Sleep (which advances it) and Tools.Now, against a local openai-compatible server.
func runTiming(t *testing.T, turns []timingTurn) timingRun {
	t.Helper()
	clock := &modelMSClock{t: time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC)}
	var mu sync.Mutex
	n, failed := 0, map[int]bool{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		mu.Lock()
		defer mu.Unlock()
		tt := turns[n]
		if tt.failAfter > 0 && !failed[n] {
			failed[n] = true
			clock.advance(int(tt.failAfter.Milliseconds()))
			if tt.retryAfter != "" {
				w.Header().Set("Retry-After", tt.retryAfter)
			}
			w.WriteHeader(503)
			fmt.Fprint(w, `{"error":"busy"}`)
			return
		}
		i := n
		n++
		clock.advance(int(tt.provider.Milliseconds()))
		if tt.status != 0 {
			w.WriteHeader(tt.status)
			fmt.Fprint(w, `{"error":"no"}`)
			return
		}
		call := fmt.Sprintf(`{"id":"t%dfin","type":"function","function":{"name":"finish","arguments":"{\"summary\":\"done\"}"}}`, i)
		if len(tt.probes) > 0 {
			call = ""
			for j, ms := range tt.probes {
				if call != "" {
					call += ","
				}
				call += fmt.Sprintf(`{"id":"t%dc%d","type":"function","function":{"name":"probe","arguments":"{\"command\":\"%d\"}"}}`, i, j, ms)
			}
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[%s]},"finish_reason":"tool_calls"}]}`, call)
	}))
	defer srv.Close()
	client := provider.NewClient("timing test")
	client.Now = clock.now
	client.Sleep = func(ctx context.Context, d time.Duration) error { clock.advance(int(d.Milliseconds())); return nil }
	root := t.TempDir()
	var run timingRun
	s, err := NewSession(SessionConfig{
		Root: root, Role: provider.Role{Provider: "openai-compatible", Model: "local", BaseURL: srv.URL},
		Client: client, Session: sys.NewWith([]string{"HOME=" + t.TempDir(), "PATH=" + os.Getenv("PATH")}, root),
		Emit: func(e api.Event) { run.events = append(run.events, e) },
	})
	if err != nil {
		t.Fatal(err)
	}
	s.tools.Now = clock.now
	s.tools.Enabled = append(s.tools.Enabled, tools.ProbeTool)
	s.tools.Probe = func(command string, _ any) (string, error) {
		var ms int
		fmt.Sscan(command, &ms)
		clock.advance(ms)
		return "probe ran", nil
	}
	run.session = s
	_, run.err = s.Round(context.Background(), "go")
	return run
}

func timingEvents(events []api.Event) []api.Event {
	var out []api.Event
	for _, e := range events {
		if e.Type == api.EventTurnTiming {
			out = append(out, e)
		}
	}
	return out
}

func wantTiming(t *testing.T, label string, e api.Event, want map[string]int64, tool map[string]int64) {
	t.Helper()
	for k, v := range want {
		if got, ok := e.Fields[k].(int64); !ok || got != v {
			t.Errorf("%s: %s = %#v, want %d (%v)", label, k, e.Fields[k], v, e.Fields)
		}
	}
	got, ok := e.Fields["tool_ms"].(map[string]int64)
	if !ok || fmt.Sprint(got) != fmt.Sprint(tool) {
		t.Errorf("%s: tool_ms = %#v, want %v", label, e.Fields["tool_ms"], tool)
	}
}

// Every turn ends with one turn.timing event placed before the next request.started and, after
// the last turn, before round.ended; the time is split into provider, tools and overhead; and
// Session.Timing sums the turns.
func TestTurnTimingSplitPlacementAndSummary(t *testing.T) {
	t.Parallel()
	run := runTiming(t, []timingTurn{
		{provider: 300 * time.Millisecond, probes: []int{200}},
		{provider: 100 * time.Millisecond, probes: []int{150, 50}},
		{provider: 100 * time.Millisecond},
	})
	if run.err != nil {
		t.Fatal(run.err)
	}
	for i, e := range run.events {
		if e.Type != api.EventTurnTiming {
			continue
		}
		if next := run.events[i+1].Type; next != api.EventRequestStarted && next != api.EventRoundEnded {
			t.Errorf("turn.timing is followed by %s", next)
		}
	}
	tm := timingEvents(run.events)
	if len(tm) != 3 {
		t.Fatalf("%d turn.timing events, want 3", len(tm))
	}
	wantTiming(t, "turn 1", tm[0], map[string]int64{"n": 1, "wall_ms": 500, "provider_wait_ms": 300, "backoff_ms": 0, "tool_wall_ms": 200, "overhead_ms": 0}, map[string]int64{"probe": 200})
	wantTiming(t, "turn 2", tm[1], map[string]int64{"n": 2, "wall_ms": 300, "provider_wait_ms": 100, "tool_wall_ms": 200, "overhead_ms": 0}, map[string]int64{"probe": 200})
	wantTiming(t, "turn 3", tm[2], map[string]int64{"n": 3, "wall_ms": 100, "provider_wait_ms": 100, "tool_wall_ms": 0, "overhead_ms": 0}, map[string]int64{})
	sum := run.session.Timing()
	for k, v := range map[string]int64{"wall_ms": 900, "provider_wait_ms": 500, "backoff_ms": 0, "tool_wall_ms": 400, "overhead_ms": 0} {
		if sum[k] != v {
			t.Errorf("Timing %s = %v, want %d", k, sum[k], v)
		}
	}
	if got := sum["tool_ms"]; fmt.Sprint(got) != "map[probe:400]" {
		t.Errorf("Timing tool_ms = %v", got)
	}
}

// A retried request counts the time between its attempts as backoff and the attempts' own time
// as provider wait; an advertised Retry-After is the backoff.
func TestTurnTimingBackoff(t *testing.T) {
	t.Parallel()
	for _, c := range []struct {
		retryAfter string
		backoff    int64
	}{{"", 2000}, {"3", 3000}} {
		run := runTiming(t, []timingTurn{{failAfter: 50 * time.Millisecond, retryAfter: c.retryAfter, provider: 300 * time.Millisecond}})
		tm := timingEvents(run.events)
		if run.err != nil || len(tm) != 1 {
			t.Fatalf("retry-after %q: %v, %d events", c.retryAfter, run.err, len(tm))
		}
		wantTiming(t, "retry-after "+c.retryAfter, tm[0], map[string]int64{
			"backoff_ms": c.backoff, "provider_wait_ms": 350, "wall_ms": c.backoff + 350, "overhead_ms": 0}, map[string]int64{})
	}
}

// A turn that fails after its request started still ends with a turn.timing event, and the
// summary counts it.
func TestTurnTimingOfAFailedTurn(t *testing.T) {
	t.Parallel()
	run := runTiming(t, []timingTurn{{provider: 40 * time.Millisecond, status: 400}})
	if run.err == nil {
		t.Fatal("the round did not fail")
	}
	tm := timingEvents(run.events)
	if len(tm) != 1 || run.events[len(run.events)-1].Type != api.EventTurnTiming {
		t.Fatalf("turn.timing events %d, last event %s", len(tm), run.events[len(run.events)-1].Type)
	}
	wantTiming(t, "failed turn", tm[0], map[string]int64{"n": 1, "provider_wait_ms": 40, "wall_ms": 40}, map[string]int64{})
	if run.session.Timing()["provider_wait_ms"] != int64(40) {
		t.Errorf("Timing %v", run.session.Timing())
	}
}

// A session that ran no turn, and a nil one, have all-zero timing with an empty tool_ms.
func TestTimingOfASessionWithoutTurns(t *testing.T) {
	t.Parallel()
	for _, s := range []*Session{nil, {}} {
		sum := s.Timing()
		if sum["wall_ms"] != int64(0) || fmt.Sprint(sum["tool_ms"]) != "map[]" || len(sum) != 6 {
			t.Errorf("Timing of %v = %v", s, sum)
		}
	}
}

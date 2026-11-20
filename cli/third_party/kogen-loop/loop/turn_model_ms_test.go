package loop

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/KogenAI/kogen-loop/api"
	"github.com/KogenAI/kogen-loop/provider"
	"github.com/KogenAI/kogen-loop/sys"
	"github.com/KogenAI/kogen-loop/tools"
)

type modelMSClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *modelMSClock) now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *modelMSClock) advance(ms int) {
	c.mu.Lock()
	c.t = c.t.Add(time.Duration(ms) * time.Millisecond)
	c.mu.Unlock()
}

// modelMSRound runs one session round against a local openai-compatible server. Each turn is
// the provider's time and the probe calls it answers with; no calls means the finish call.
func modelMSRound(t *testing.T, clock *modelMSClock, turns []struct {
	provider int
	calls    []int
}) []api.Event {
	t.Helper()
	var n atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		i := int(n.Add(1)) - 1
		if i >= len(turns) {
			i = len(turns) - 1
		}
		if clock != nil {
			clock.advance(turns[i].provider)
		}
		var parts []string
		for j, ms := range turns[i].calls {
			parts = append(parts, fmt.Sprintf(`{"id":"t%dc%d","type":"function","function":{"name":"probe","arguments":"{\"command\":\"%d\"}"}}`, i, j, ms))
		}
		if len(turns[i].calls) == 0 {
			parts = append(parts, fmt.Sprintf(`{"id":"t%dfin","type":"function","function":{"name":"finish","arguments":"{\"summary\":\"done\"}"}}`, i))
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[%s]},"finish_reason":"tool_calls"}]}`, strings.Join(parts, ","))
	}))
	defer srv.Close()
	root := t.TempDir()
	var events []api.Event
	s, err := NewSession(SessionConfig{
		Root: root, Role: provider.Role{Provider: "openai-compatible", Model: "local", BaseURL: srv.URL},
		Session: sys.NewWith([]string{"HOME=" + t.TempDir(), "PATH=" + os.Getenv("PATH")}, root),
		Emit:    func(e api.Event) { events = append(events, e) },
	})
	if err != nil {
		t.Fatal(err)
	}
	if clock != nil {
		s.tools.Now = clock.now
	}
	s.tools.Enabled = append(s.tools.Enabled, tools.ProbeTool)
	s.tools.Probe = func(command string, _ any) (string, error) {
		var ms int
		fmt.Sscan(command, &ms)
		if clock != nil {
			clock.advance(ms)
		}
		return "probe ran " + command + " ms", nil
	}
	res, err := s.Round(context.Background(), "go")
	if err != nil || res.Ending != EndTerminal {
		t.Fatalf("%+v %v", res, err)
	}
	return events
}

// Every response event carries the wall time of its own turn on the tools clock, separate from
// the tool.result elapsed_ms, and the two together stay within the run's wall time.
func TestSessionResponseModelMSUsesTheToolsClock(t *testing.T) {
	t.Parallel()
	clock := &modelMSClock{t: time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC)}
	before := clock.now()
	events := modelMSRound(t, clock, []struct {
		provider int
		calls    []int
	}{{300, []int{200}}, {100, []int{150, 50}}, {100, nil}})
	wall := clock.now().Sub(before).Milliseconds()
	var model, elapsed []int64
	for _, e := range events {
		switch e.Type {
		case api.EventResponse:
			ms, ok := e.Fields["model_ms"].(int64)
			if !ok {
				t.Fatalf("model_ms %T %v in %v", e.Fields["model_ms"], e.Fields["model_ms"], e.Fields)
			}
			model = append(model, ms)
		case api.EventToolResult:
			elapsed = append(elapsed, e.Fields["elapsed_ms"].(int64))
		default:
			if _, ok := e.Fields["model_ms"]; ok {
				t.Errorf("%s event has model_ms", e.Type)
			}
		}
	}
	if fmt.Sprint(model) != "[300 100 100]" {
		t.Errorf("model_ms %v, want [300 100 100]", model)
	}
	if fmt.Sprint(elapsed) != "[200 150 50]" {
		t.Errorf("elapsed_ms %v, want [200 150 50]", elapsed)
	}
	var sum int64
	for _, v := range append(model, elapsed...) {
		sum += v
	}
	if wall != 900 || sum > wall {
		t.Errorf("wall %d ms, sum %d ms", wall, sum)
	}
}

// With the tools clock nil, model_ms is read from the real time and is a non-negative int64.
func TestSessionResponseModelMSRealClock(t *testing.T) {
	t.Parallel()
	events := modelMSRound(t, nil, []struct {
		provider int
		calls    []int
	}{{0, nil}})
	found := false
	for _, e := range events {
		if e.Type != api.EventResponse {
			continue
		}
		found = true
		ms, ok := e.Fields["model_ms"].(int64)
		if !ok || ms < 0 {
			t.Errorf("model_ms %T %v", e.Fields["model_ms"], e.Fields["model_ms"])
		}
	}
	if !found {
		t.Error("no response event")
	}
}

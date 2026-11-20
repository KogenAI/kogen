package loop

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/KogenAI/kogen-loop/api"
	"github.com/KogenAI/kogen-loop/provider"
	"github.com/KogenAI/kogen-loop/sys"
	"github.com/KogenAI/kogen-loop/tools"
)

// modelMSRulesRound runs one session round against a local openai-compatible server on one
// injected clock. answer receives the number of the request among the non-summarization
// requests and whether this one is the condensation summary; it advances the clock and returns
// the status and body. The client's Sleep seam does not wait.
func modelMSRulesRound(t *testing.T, answer func(clock *modelMSClock, n int, summary bool) (int, string)) []api.Event {
	t.Helper()
	clock := &modelMSClock{t: time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC)}
	var n atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		summary := strings.Contains(string(body), summaryInstructions[:30])
		i := 0
		if !summary {
			i = int(n.Add(1))
		}
		status, text := answer(clock, i, summary)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		io.WriteString(w, text)
	}))
	defer srv.Close()
	client := provider.NewClient("test")
	client.Sleep = func(ctx context.Context, _ time.Duration) error { return ctx.Err() }
	root := t.TempDir()
	var events []api.Event
	s, err := NewSession(SessionConfig{
		Root: root, Role: provider.Role{Provider: "openai-compatible", Model: "local", BaseURL: srv.URL},
		Session: sys.NewWith([]string{"HOME=" + t.TempDir(), "PATH=" + os.Getenv("PATH")}, root),
		Client:  client,
		Emit:    func(e api.Event) { events = append(events, e) },
	})
	if err != nil {
		t.Fatal(err)
	}
	s.tools.Now = clock.now
	s.tools.Enabled = append(s.tools.Enabled, tools.ProbeTool)
	s.tools.Probe = func(string, any) (string, error) { return strings.Repeat("a", 20000), nil }
	res, err := s.Round(context.Background(), "go")
	if err != nil || res.Ending != EndTerminal {
		t.Fatalf("%+v %v", res, err)
	}
	return events
}

// modelMSRulesCalls answers with one tool call per name; "finish" ends the round.
func modelMSRulesCalls(names ...string) string {
	var parts []string
	for i, name := range names {
		args := `{\"command\":\"x\"}`
		if name == "finish" {
			args = `{\"summary\":\"done\"}`
		}
		parts = append(parts, fmt.Sprintf(`{"id":"c%d","type":"function","function":{"name":"%s","arguments":"%s"}}`, i, name, args))
	}
	return fmt.Sprintf(`{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[%s]},"finish_reason":"tool_calls"}]}`, strings.Join(parts, ","))
}

// A request the provider call retries is one turn: the failed attempt and the answering attempt
// are both inside the one response event's model_ms.
func TestSessionRetriedRequestIsOneTurnModelMS(t *testing.T) {
	t.Parallel()
	events := modelMSRulesRound(t, func(clock *modelMSClock, n int, _ bool) (int, string) {
		if n == 1 {
			clock.advance(100)
			return http.StatusInternalServerError, `{"error":{"message":"temporary"}}`
		}
		clock.advance(200)
		return http.StatusOK, modelMSRulesCalls("finish")
	})
	var responses int
	for _, e := range events {
		if e.Type != api.EventResponse {
			continue
		}
		responses++
		if ms, ok := e.Fields["model_ms"].(int64); !ok || ms != 300 {
			t.Errorf("model_ms %T %v, want int64 300", e.Fields["model_ms"], e.Fields["model_ms"])
		}
	}
	if responses != 1 {
		t.Errorf("%d response events, want 1", responses)
	}
}

// Only response events carry model_ms, over a round that condenses its history once.
func TestSessionOnlyResponseEventsCarryModelMS(t *testing.T) {
	t.Parallel()
	probes := make([]string, 20)
	for i := range probes {
		probes[i] = "probe"
	}
	events := modelMSRulesRound(t, func(clock *modelMSClock, n int, summary bool) (int, string) {
		clock.advance(10)
		if summary {
			return http.StatusOK, `{"choices":[{"message":{"role":"assistant","content":"summary of earlier work"},"finish_reason":"stop"}]}`
		}
		if n <= 2 {
			return http.StatusOK, modelMSRulesCalls(probes...)
		}
		return http.StatusOK, modelMSRulesCalls("finish")
	})
	var condensed, responses int
	for _, e := range events {
		_, has := e.Fields["model_ms"]
		switch e.Type {
		case api.EventResponse:
			responses++
			if _, ok := e.Fields["model_ms"].(int64); !ok {
				t.Errorf("response model_ms %T %v", e.Fields["model_ms"], e.Fields["model_ms"])
			}
		case api.EventContextCondensed:
			condensed++
			if has {
				t.Errorf("%s event has model_ms", e.Type)
			}
		default:
			if has {
				t.Errorf("%s event has model_ms", e.Type)
			}
		}
	}
	if condensed != 1 {
		t.Errorf("%d context.condensed events, want 1", condensed)
	}
	if responses != 3 {
		t.Errorf("%d response events, want 3", responses)
	}
}

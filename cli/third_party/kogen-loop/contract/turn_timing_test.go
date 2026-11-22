package contract_test

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	"github.com/KogenAI/kogen-loop/api"
	"github.com/KogenAI/kogen-loop/loop"
	"github.com/KogenAI/kogen-loop/provider"
)

// TestSessionEmitsTurnTiming pins what a consumer of loop.Session sees: api.EventTurnTiming
// is the last event of the turn, right before round.ended, with the contract's keys, and
// Session.Timing is those keys (except n) summed over the turns the session ran.
func TestSessionEmitsTurnTiming(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"finish","arguments":"{\"summary\":\"done\"}"}}]},"finish_reason":"tool_calls"}]}`)
	}))
	defer srv.Close()
	sess, root, _ := newSession(t)
	var events []api.Event
	s, err := loop.NewSession(loop.SessionConfig{
		Root: root, Role: provider.Role{Provider: "openai-compatible", Model: "local", BaseURL: srv.URL},
		Session: sess, Emit: func(e api.Event) { events = append(events, e) },
	})
	if err != nil {
		t.Fatal(err)
	}
	if api.EventTurnTiming != "turn.timing" {
		t.Fatalf("api.EventTurnTiming = %q", api.EventTurnTiming)
	}
	if _, err := s.Round(context.Background(), "go"); err != nil {
		t.Fatal(err)
	}
	var timing map[string]any
	for i, e := range events {
		if e.Type != api.EventTurnTiming {
			continue
		}
		if timing != nil || events[i+1].Type != api.EventRoundEnded {
			t.Fatalf("turn.timing at %d of %d events", i, len(events))
		}
		timing = e.Fields
	}
	if timing == nil {
		t.Fatal("no turn.timing event")
	}
	if timing["n"] != int64(1) {
		t.Errorf("n = %v", timing["n"])
	}
	delete(timing, "n")
	if sum := s.Timing(); !reflect.DeepEqual(sum, timing) {
		t.Errorf("Session.Timing %v, want the turn's %v", sum, timing)
	}
	for _, k := range []string{"wall_ms", "provider_wait_ms", "backoff_ms", "tool_ms", "tool_wall_ms", "overhead_ms"} {
		if _, ok := timing[k]; !ok {
			t.Errorf("turn.timing lacks %s", k)
		}
	}
	if len(timing) != 6 {
		t.Errorf("turn.timing keys %v", timing)
	}
}

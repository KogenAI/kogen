package loop

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"sync/atomic"
	"testing"

	"kogen-loop/api"
	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
)

type scriptRequester struct {
	script   [][]map[string]any
	requests [][]any
}

func (s *scriptRequester) Request(ctx context.Context, r Request) (*provider.Response, []any, error) {
	s.requests = append(s.requests, append([]any(nil), r.Input...))
	if len(s.requests) > len(s.script) {
		return nil, nil, errors.New("script exhausted")
	}
	return &provider.Response{Items: s.script[len(s.requests)-1]}, r.Input, nil
}

func prose(text string) []map[string]any {
	return []map[string]any{{"type": "message", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": text}}}}
}

func call(name string) []map[string]any {
	return []map[string]any{{"type": "function_call", "call_id": "c-" + name, "name": name, "arguments": `{"summary":"x"}`}}
}

func userMsg(text string) any { return map[string]any{"role": "user", "content": text} }

func marshal(t *testing.T, v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestNoCallEndsRound(t *testing.T) {
	ctx := context.Background()
	start := []any{userMsg("go")}

	t.Run("no_call", func(t *testing.T) {
		rq := &scriptRequester{script: [][]map[string]any{prose("done"), prose("never sent")}}
		res, err := Run(ctx, Round{Terminal: []string{"submit"}}, start, rq, Hooks{})
		if err != nil {
			t.Fatal(err)
		}
		if res.Ending != EndNoCall || res.Terminal != nil || res.Requests != 1 || len(rq.requests) != 1 {
			t.Fatalf("result %+v", res)
		}
		if got, want := marshal(t, res.Input), marshal(t, []any{userMsg("go"), prose("done")[0]}); got != want {
			t.Fatalf("input %s", got)
		}
	})

	t.Run("terminal_first", func(t *testing.T) {
		for _, name := range []string{"submit", "finish"} {
			rq := &scriptRequester{script: [][]map[string]any{call(name)}}
			res, err := Run(ctx, Round{Terminal: []string{"submit", "finish"}}, start, rq, Hooks{})
			if err != nil || res.Ending != EndTerminal || res.Requests != 1 {
				t.Fatalf("%s: %+v %v", name, res, err)
			}
		}
		rq := &scriptRequester{script: [][]map[string]any{call("custom")}}
		h := Hooks{HandleCall: func(_ context.Context, _ tools.Call) (Handled, error) {
			return Handled{Handled: true, Terminal: true}, nil
		}}
		res, err := Run(ctx, Round{}, start, rq, h)
		if err != nil || res.Ending != EndTerminal || res.Requests != 1 {
			t.Fatalf("intercepted: %+v %v", res, err)
		}
	})

	t.Run("session_events", func(t *testing.T) {
		var n atomic.Int32
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{"choices":[{"message":{"role":"assistant","content":"prose %d"},"finish_reason":"stop"}]}`, n.Add(1))
		}))
		defer srv.Close()
		var events []api.Event
		s, err := NewSession(SessionConfig{
			Root: t.TempDir(), Role: provider.Role{Provider: "openai-compatible", Model: "local", BaseURL: srv.URL},
			Session:  sys.NewWith([]string{"HOME=" + t.TempDir(), "PATH=" + os.Getenv("PATH")}, t.TempDir()),
			Terminal: []string{"submit", "finish"},
			Emit:     func(e api.Event) { events = append(events, e) },
		})
		if err != nil {
			t.Fatal(err)
		}
		for turn := 0; turn < 2; turn++ {
			events = nil
			res, err := s.Round(ctx, "go")
			if err != nil || res.Ending != EndNoCall || res.Requests != 1 {
				t.Fatalf("turn %d: %+v %v", turn, res, err)
			}
			var types []string
			for _, e := range events {
				if e.Type != api.EventRequestAttempt {
					types = append(types, e.Type)
				}
			}
			want := []string{api.EventRequestStarted, api.EventResponse, api.EventRoundEnded}
			if !reflect.DeepEqual(types, want) {
				t.Fatalf("turn %d events %v", turn, types)
			}
			for i := 1; i < len(events); i++ {
				if events[i].Seq != events[i-1].Seq+1 {
					t.Fatalf("seq %d then %d", events[i-1].Seq, events[i].Seq)
				}
			}
			if end := events[len(events)-1].Fields; end["requests"] != 1 {
				t.Fatalf("round.ended %v", end)
			}
		}
	})
}

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
	"strings"
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

func reminderText(names ...string) string {
	return "Call one of these terminal tools to end this round: " + strings.Join(names, ", ") + "."
}

func userMsg(text string) any { return map[string]any{"role": "user", "content": text} }

func marshal(t *testing.T, v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

type reminderNote struct {
	n     int
	names []string
}

func TestTerminalReminders(t *testing.T) {
	ctx := context.Background()
	start := []any{userMsg("go")}
	var notes []reminderNote
	hooks := func() Hooks {
		notes = nil
		return Hooks{TerminalReminder: func(_ context.Context, n int, names []string) error {
			notes = append(notes, reminderNote{n, append([]string(nil), names...)})
			return nil
		}}
	}

	t.Run("prose_terminal", func(t *testing.T) {
		rq := &scriptRequester{script: [][]map[string]any{prose("thinking"), call("submit")}}
		res, err := Run(ctx, Round{Terminal: []string{"submit"}, TerminalReminders: 1}, start, rq, hooks())
		if err != nil {
			t.Fatal(err)
		}
		if res.Ending != EndTerminal || res.Terminal == nil || res.Terminal.Name != "submit" || res.Requests != 2 {
			t.Fatalf("result %+v", res)
		}
		want := []any{userMsg("go"), prose("thinking")[0], userMsg(reminderText("submit"))}
		if len(rq.requests) != 2 || marshal(t, rq.requests[1]) != marshal(t, want) {
			t.Fatalf("second request %s", marshal(t, rq.requests))
		}
		if !reflect.DeepEqual(notes, []reminderNote{{1, []string{"submit"}}}) {
			t.Fatalf("notes %v", notes)
		}
	})

	t.Run("zero_bytes", func(t *testing.T) {
		for _, script := range [][][]map[string]any{{prose("done")}, {call("finish")}} {
			var outs []string
			for _, n := range []int{0, -3} {
				rq := &scriptRequester{script: script}
				h := Hooks{TerminalReminder: func(context.Context, int, []string) error { t.Fatal("reminder"); return nil }}
				res, err := Run(ctx, Round{TerminalReminders: n}, start, rq, h)
				if err != nil {
					t.Fatal(err)
				}
				outs = append(outs, marshal(t, rq.requests)+marshal(t, res))
			}
			ref := &scriptRequester{script: script}
			res, err := Run(ctx, Round{}, start, ref, Hooks{})
			if err != nil {
				t.Fatal(err)
			}
			want := marshal(t, ref.requests) + marshal(t, res)
			if outs[0] != want || outs[1] != want || len(ref.requests) != 1 {
				t.Fatalf("zero differs:\n%s\n%s", outs[0], want)
			}
		}
	})

	t.Run("exhausted", func(t *testing.T) {
		rq := &scriptRequester{script: [][]map[string]any{prose("a"), prose("b")}}
		res, err := Run(ctx, Round{TerminalReminders: 1}, start, rq, hooks())
		if err != nil {
			t.Fatal(err)
		}
		if res.Ending != EndNoCall || res.Requests != 2 || len(rq.requests) != 2 || len(notes) != 1 {
			t.Fatalf("result %+v notes %v", res, notes)
		}
		if marshal(t, res.Response.Items) != marshal(t, prose("b")) {
			t.Fatal("final response not retained")
		}
	})

	t.Run("budget_two", func(t *testing.T) {
		rq := &scriptRequester{script: [][]map[string]any{prose("a"), prose("b"), prose("c")}}
		res, err := Run(ctx, Round{TerminalReminders: 2}, start, rq, hooks())
		if err != nil {
			t.Fatal(err)
		}
		if res.Ending != EndNoCall || res.Requests != 3 || len(rq.requests) != 3 {
			t.Fatalf("result %+v", res)
		}
		if !reflect.DeepEqual(notes, []reminderNote{{1, []string{"finish"}}, {2, []string{"finish"}}}) {
			t.Fatalf("notes %v", notes)
		}
	})

	t.Run("reset", func(t *testing.T) {
		for i := 0; i < 3; i++ {
			rq := &scriptRequester{script: [][]map[string]any{prose("a"), prose("b")}}
			res, err := Run(ctx, Round{TerminalReminders: 1}, start, rq, hooks())
			if err != nil || res.Requests != 2 || len(notes) != 1 || notes[0].n != 1 {
				t.Fatalf("run %d: %+v %v %v", i, res, err, notes)
			}
		}
	})

	t.Run("terminal_first", func(t *testing.T) {
		for _, name := range []string{"submit", "finish"} {
			rq := &scriptRequester{script: [][]map[string]any{call(name)}}
			terminal := []string{"submit", "finish"}
			res, err := Run(ctx, Round{Terminal: terminal, TerminalReminders: 3}, start, rq, hooks())
			if err != nil || res.Ending != EndTerminal || res.Requests != 1 || len(notes) != 0 {
				t.Fatalf("%s: %+v %v %v", name, res, err, notes)
			}
		}
		rq := &scriptRequester{script: [][]map[string]any{call("custom")}}
		h := hooks()
		h.HandleCall = func(_ context.Context, _ tools.Call) (Handled, error) {
			return Handled{Handled: true, Terminal: true}, nil
		}
		res, err := Run(ctx, Round{TerminalReminders: 3}, start, rq, h)
		if err != nil || res.Ending != EndTerminal || res.Requests != 1 || len(notes) != 0 {
			t.Fatalf("intercepted: %+v %v %v", res, err, notes)
		}
	})

	t.Run("names", func(t *testing.T) {
		for _, terminal := range [][]string{{"submit", "finish", "finish"}, nil} {
			rq := &scriptRequester{script: [][]map[string]any{prose("a"), call("finish")}}
			if _, err := Run(ctx, Round{Terminal: terminal, TerminalReminders: 1}, start, rq, hooks()); err != nil {
				t.Fatal(err)
			}
			effective := terminal
			if effective == nil {
				effective = DefaultTerminal
			}
			last := rq.requests[1][len(rq.requests[1])-1]
			if marshal(t, last) != marshal(t, userMsg(reminderText(effective...))) {
				t.Fatalf("message %s", marshal(t, last))
			}
			if !reflect.DeepEqual(notes[0].names, effective) {
				t.Fatalf("names %v", notes[0].names)
			}
		}
		if got := reminderText("submit", "finish", "finish"); got != "Call one of these terminal tools to end this round: submit, finish, finish." {
			t.Fatal(got)
		}
	})

	t.Run("stops", func(t *testing.T) {
		rq := &scriptRequester{script: [][]map[string]any{prose("a"), prose("b")}}
		_, err := Run(ctx, Round{MaxRounds: 1, TerminalReminders: 1}, start, rq, hooks())
		var rl *RoundLimitError
		if !errors.As(err, &rl) || len(rq.requests) != 1 || len(notes) != 0 {
			t.Fatalf("limit: %v %d %v", err, len(rq.requests), notes)
		}

		rq = &scriptRequester{script: [][]map[string]any{prose("a"), prose("b"), prose("c")}}
		h := hooks()
		h.Progress = func(context.Context, int) (string, error) { return "same", nil }
		_, err = Run(ctx, Round{TerminalReminders: 5}, start, rq, h)
		var np *NoProgressError
		if !errors.As(err, &np) || len(rq.requests) != 3 || len(notes) != 2 {
			t.Fatalf("progress: %v %d %v", err, len(rq.requests), notes)
		}

		cprogress, cancelProgress := context.WithCancel(ctx)
		rq = &scriptRequester{script: [][]map[string]any{prose("a"), prose("b")}}
		h = hooks()
		h.Progress = func(context.Context, int) (string, error) { cancelProgress(); return "ok", nil }
		if _, err = Run(cprogress, Round{TerminalReminders: 1}, start, rq, h); err != context.Canceled || len(notes) != 0 || len(rq.requests) != 1 {
			t.Fatalf("progress cancellation: %v %v", err, notes)
		}

		rq = &scriptRequester{script: [][]map[string]any{prose("a"), call("submit")}}
		h = Hooks{TerminalReminder: func(_ context.Context, _ int, names []string) error { names[0] = "other"; return nil }}
		res, err := Run(ctx, Round{Terminal: []string{"submit"}, TerminalReminders: 1}, start, rq, h)
		if err != nil || res.Ending != EndTerminal || marshal(t, rq.requests[1][len(rq.requests[1])-1]) != marshal(t, userMsg(reminderText("submit"))) {
			t.Fatalf("mutated notification names: %+v %v", res, err)
		}

		boom := errors.New("boom")
		rq = &scriptRequester{script: [][]map[string]any{prose("a"), prose("b")}}
		h = Hooks{TerminalReminder: func(context.Context, int, []string) error { return boom }}
		if _, err = Run(ctx, Round{TerminalReminders: 1}, start, rq, h); err != boom || len(rq.requests) != 1 {
			t.Fatalf("hook: %v", err)
		}

		cctx, cancel := context.WithCancel(ctx)
		rq = &scriptRequester{script: [][]map[string]any{prose("a"), prose("b")}}
		h = Hooks{TerminalReminder: func(context.Context, int, []string) error { cancel(); return nil }}
		if _, err = Run(cctx, Round{TerminalReminders: 1}, start, rq, h); err != context.Canceled || len(rq.requests) != 1 {
			t.Fatalf("cancel: %v", err)
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
			Session:           sys.NewWith([]string{"HOME=" + t.TempDir(), "PATH=" + os.Getenv("PATH")}, t.TempDir()),
			Terminal:          []string{"submit", "finish"},
			TerminalReminders: 1,
			Emit:              func(e api.Event) { events = append(events, e) },
		})
		if err != nil {
			t.Fatal(err)
		}
		for turn := 0; turn < 2; turn++ {
			events = nil
			res, err := s.Round(ctx, "go")
			if err != nil || res.Ending != EndNoCall || res.Requests != 2 {
				t.Fatalf("turn %d: %+v %v", turn, res, err)
			}
			var types []string
			for _, e := range events {
				if e.Type != api.EventRequestAttempt {
					types = append(types, e.Type)
				}
			}
			want := []string{api.EventRequestStarted, api.EventResponse, api.EventTerminalReminder, api.EventRequestStarted, api.EventResponse, api.EventRoundEnded}
			if !reflect.DeepEqual(types, want) {
				t.Fatalf("turn %d events %v", turn, types)
			}
			for i := 1; i < len(events); i++ {
				if events[i].Seq != events[i-1].Seq+1 {
					t.Fatalf("seq %d then %d", events[i-1].Seq, events[i].Seq)
				}
			}
			var f map[string]any
			for _, e := range events {
				if e.Type == api.EventTerminalReminder {
					f = e.Fields
				}
			}
			if f["reminder"] != 1 || !reflect.DeepEqual(f["terminal_tools"], []string{"submit", "finish"}) {
				t.Fatalf("fields %v", f)
			}
			if end := events[len(events)-1].Fields; end["requests"] != 2 {
				t.Fatalf("round.ended %v", end)
			}
		}
		if api.EventTerminalReminder != "round.terminal_reminder" {
			t.Fatal(api.EventTerminalReminder)
		}
	})

	t.Run("contract", func(t *testing.T) {
		doc, err := os.ReadFile("../docs/contract/loop-v1.md")
		if err != nil {
			t.Fatal(err)
		}
		for _, want := range []string{"Round.TerminalReminders", "SessionConfig.TerminalReminders", "Hooks.TerminalReminder", "round.terminal_reminder", "Call one of these terminal tools to end this round: ", "no task JSON field or CLI flag"} {
			if !strings.Contains(string(doc), want) {
				t.Errorf("contract lacks %q", want)
			}
		}
		for _, p := range []string{"../api/api.go", "../cmd/kogen-loop/main.go"} {
			src, _ := os.ReadFile(p)
			if strings.Contains(string(src), "TerminalReminders") {
				t.Errorf("%s exposes TerminalReminders", p)
			}
		}
	})
}

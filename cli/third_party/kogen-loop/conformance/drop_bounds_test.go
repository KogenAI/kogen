package conformance

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"kogen-loop/loop"
	"kogen-loop/provider"
	"kogen-loop/tools"
)

// The optional loop stopping bounds are deleted, not deprecated or replaced: no option, typed
// stop or constant is left in the loop package.
func TestDropBoundsRemoved(t *testing.T) {
	for _, c := range []struct {
		typ   reflect.Type
		field string
	}{
		{reflect.TypeOf(loop.Round{}), "MaxRounds"},
		{reflect.TypeOf(loop.Hooks{}), "Progress"},
	} {
		if _, ok := c.typ.FieldByName(c.field); ok {
			t.Errorf("%s.%s still exists", c.typ, c.field)
		}
	}
	names := declaredNames(t, "../loop")
	for _, name := range []string{"MaxRounds", "Progress", "RoundLimitError", "NoProgressRounds", "NoProgressError"} {
		if names[name] {
			t.Errorf("package loop still declares %s", name)
		}
	}
	// What stays: the request count of a result and the round's other settings.
	if _, ok := reflect.TypeOf(loop.Result{}).FieldByName("Requests"); !ok {
		t.Error("loop.Result.Requests must remain")
	}
	if _, ok := reflect.TypeOf(loop.Round{}).FieldByName("Terminal"); !ok {
		t.Error("loop.Round.Terminal must remain")
	}
}

// A run that keeps getting handled nonterminal calls has no round-count or progress stop; it
// ends only by a terminal call, a response without a call or an error.
func TestDropBoundsDefaultBehavior(t *testing.T) {
	const repeated = 6
	handled := loop.Hooks{HandleCall: func(_ context.Context, _ tools.Call) (loop.Handled, error) {
		return loop.Handled{Handled: true, Output: tools.Output{Text: "handled"}}, nil
	}}
	var script []*provider.Response
	var want []string
	for i := 1; i <= repeated; i++ {
		id := string(rune('a' + i - 1))
		script = append(script, respond("r"+id, fakeCall(id, "custom", `{"same":true}`)))
		want = append(want, "call:"+id, "out:"+id)
	}
	start := []any{userMessage("go")}
	wantIDs := append([]string{"user"}, want...)
	checkReplay := func(t *testing.T, asked []loop.Request) {
		t.Helper()
		for i, request := range asked {
			if got := ids(request.Input); !reflect.DeepEqual(got, wantIDs[:1+2*i]) {
				t.Fatalf("request %d input %v, want %v", i+1, got, wantIDs[:1+2*i])
			}
			for j := 0; j < i; j++ {
				output := request.Input[2+2*j].(map[string]any)["output"]
				if output != "handled" {
					t.Fatalf("request %d replayed output %d = %v, want handled", i+1, j+1, output)
				}
			}
		}
	}

	t.Run("terminal", func(t *testing.T) {
		rq := &scripted{responses: append(append([]*provider.Response(nil), script...), respond("end", fakeCall("z", "finish", `{"summary":"s"}`)))}
		res, err := loop.Run(context.Background(), loop.Round{}, start, rq, handled)
		if err != nil {
			t.Fatal(err)
		}
		if res.Ending != loop.EndTerminal || res.Terminal == nil || res.Terminal.CallID() != "z" || res.Requests != repeated+1 || len(rq.asked) != repeated+1 {
			t.Fatalf("result %+v asked %d", res, len(rq.asked))
		}
		checkReplay(t, rq.asked)
		if got, wantTerminal := ids(res.Input), append(append([]string(nil), wantIDs...), "call:z"); !reflect.DeepEqual(got, wantTerminal) {
			t.Fatalf("input %v, want %v", got, wantTerminal)
		}
	})

	t.Run("no_call", func(t *testing.T) {
		rq := &scripted{responses: append(append([]*provider.Response(nil), script...), respond("end", message("done")))}
		res, err := loop.Run(context.Background(), loop.Round{}, start, rq, handled)
		if err != nil {
			t.Fatal(err)
		}
		if res.Ending != loop.EndNoCall || res.Terminal != nil || res.Requests != repeated+1 || len(rq.asked) != repeated+1 {
			t.Fatalf("result %+v asked %d", res, len(rq.asked))
		}
		checkReplay(t, rq.asked)
		if got, wantNoCall := ids(res.Input), append(append([]string(nil), wantIDs...), "assistant"); !reflect.DeepEqual(got, wantNoCall) {
			t.Fatalf("input %v, want %v", got, wantNoCall)
		}
	})

	t.Run("requester_error", func(t *testing.T) {
		sentinel := errors.New("requester failed")
		rq := &failingAfter{scripted: scripted{responses: script}, err: sentinel}
		res, err := loop.Run(context.Background(), loop.Round{}, start, rq, handled)
		if err != sentinel {
			t.Fatalf("error %v, want the sentinel unchanged", err)
		}
		if res.Ending != "" || res.Requests != 0 || len(rq.asked) != repeated+1 {
			t.Fatalf("result %+v asked %d", res, len(rq.asked))
		}
		checkReplay(t, rq.asked)
	})
}

// failingAfter answers its scripted responses and then fails with err.
type failingAfter struct {
	scripted
	err error
}

func (f *failingAfter) Request(ctx context.Context, r loop.Request) (*provider.Response, []any, error) {
	if len(f.asked) >= len(f.responses) {
		f.asked = append(f.asked, r)
		return nil, nil, f.err
	}
	return f.scripted.Request(ctx, r)
}

// The bound-only acceptance and the maintained documentation of the removed options are gone;
// the changelog records the removal.
func TestDropBoundsDocumentation(t *testing.T) {
	for _, gone := range []string{
		".kogen/intents/l3-round-limit/acceptance.feature",
		"features/steps/round_limit.js",
		"features/steps/round_limit_test.go.txt",
	} {
		if _, err := os.Stat(filepath.Join("..", gone)); !os.IsNotExist(err) {
			t.Errorf("%s must be removed (stat error %v)", gone, err)
		}
	}
	read := func(rel string) string {
		b, err := os.ReadFile(filepath.Join("..", rel))
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	removed := []string{"MaxRounds", "RoundLimitError", "NoProgressRounds", "NoProgressError", "Hooks.Progress", "no-progress", "round-limit", "Round limit"}
	for _, rel := range []string{"README.md", "docs/contract/loop-v1.md"} {
		text := read(rel)
		for _, name := range removed {
			if strings.Contains(text, name) {
				t.Errorf("%s still documents %s", rel, name)
			}
		}
	}
	changelog := read("CHANGELOG.md")
	if strings.Contains(changelog, "Add a round limit and no-progress stop") {
		t.Error("CHANGELOG still advertises the round limit and no-progress stop")
	}
	var entry string
	for _, line := range strings.Split(changelog, "\n") {
		if strings.HasPrefix(line, "- Remove") && strings.Contains(line, "MaxRounds") {
			entry = line
		}
	}
	for _, name := range []string{"loop.Round.MaxRounds", "loop.RoundLimitError", "loop.Hooks.Progress", "loop.NoProgressRounds", "loop.NoProgressError"} {
		if !strings.Contains(entry, name) {
			t.Errorf("CHANGELOG removal entry %q lacks %s", entry, name)
		}
	}
	// Useful coverage stays beside the deleted round-limit case.
	if !strings.Contains(read("loop/terminal_reminders_test.go"), "session_events") {
		t.Error("loop/terminal_reminders_test.go lost its session_events test")
	}
}

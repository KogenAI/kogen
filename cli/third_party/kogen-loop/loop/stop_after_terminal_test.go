package loop

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"kogen-loop/tools"
)

const skipText = "skipped: earlier terminal call ended the round"

func fcall(id, name, args string) map[string]any {
	return map[string]any{"type": "function_call", "call_id": id, "name": name, "arguments": args}
}

func fout(id, text string) map[string]any {
	return map[string]any{"type": "function_call_output", "call_id": id, "output": text}
}

type termObs struct {
	before, after []string
	skippedAfter  []bool
	handled       []string
}

func (o *termObs) hooks(handle func(tools.Call) Handled) Hooks {
	return Hooks{
		BeforeCall: func(_ context.Context, c tools.Call, _ []any) error {
			o.before = append(o.before, c.Name)
			return nil
		},
		HandleCall: func(_ context.Context, c tools.Call) (Handled, error) {
			o.handled = append(o.handled, c.Name)
			if handle == nil {
				return Handled{}, nil
			}
			return handle(c), nil
		},
		AfterCall: func(_ context.Context, c tools.Call, out tools.Output, terminal bool, _ []any) error {
			o.after = append(o.after, c.Name)
			o.skippedAfter = append(o.skippedAfter, out.Text == skipText && !terminal)
			return nil
		},
	}
}

func TestStopAfterTerminal(t *testing.T) {
	ctx := context.Background()
	start := []any{userMsg("go")}
	setup := func(t *testing.T) (*tools.Tools, string) {
		root := t.TempDir()
		if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("hello\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		tl, err := tools.New(tools.Tools{Root: root, Enabled: []string{tools.ReadFileTool, tools.WriteFileTool}})
		if err != nil {
			t.Fatal(err)
		}
		return tl, root
	}
	readArgs := `{"path":"a.txt"}`
	writeArgs := `{"path":"b.txt","content":"x"}`

	t.Run("read_terminal_write", func(t *testing.T) {
		tl, root := setup(t)
		items := []map[string]any{fcall("r", "read_file", readArgs), fcall("t", "finish", `{"summary":"x"}`), fcall("w", "write_file", writeArgs)}
		rq := &scriptRequester{script: [][]map[string]any{items}}
		res, err := Run(ctx, Round{Tools: tl, StopAfterTerminal: true}, start, rq, Hooks{})
		if err != nil {
			t.Fatal(err)
		}
		if res.Ending != EndTerminal || res.Terminal == nil || res.Terminal.CallID() != "t" || res.Requests != 1 {
			t.Fatalf("result %+v", res)
		}
		if _, err := os.Stat(filepath.Join(root, "b.txt")); !os.IsNotExist(err) {
			t.Fatalf("write ran: %v", err)
		}
		if n := len(res.Input); n < 2 {
			t.Fatalf("input %s", marshal(t, res.Input))
		}
		if last := res.Input[len(res.Input)-1]; !reflect.DeepEqual(last, fout("w", skipText)) {
			t.Fatalf("last %s", marshal(t, last))
		}
		var outs []string
		for _, it := range res.Input {
			if m, ok := it.(map[string]any); ok && m["type"] == "function_call_output" {
				outs = append(outs, m["call_id"].(string))
			}
		}
		if !reflect.DeepEqual(res.Input[len(res.Input)-2], fout("r", "1\thello")) {
			t.Fatalf("read output %s", marshal(t, res.Input))
		}
		if !reflect.DeepEqual(outs, []string{"r", "w"}) {
			t.Fatalf("outputs %v", outs)
		}
	})

	t.Run("first_terminal", func(t *testing.T) {
		items := []map[string]any{fcall("a", "finish", "{}"), fcall("b", "finish", "{}"), fcall("c", "submit", "{}")}
		rq := &scriptRequester{script: [][]map[string]any{items}}
		res, err := Run(ctx, Round{Terminal: []string{"finish", "submit"}, StopAfterTerminal: true}, start, rq, Hooks{})
		if err != nil {
			t.Fatal(err)
		}
		if res.Terminal == nil || res.Terminal.CallID() != "a" {
			t.Fatalf("terminal %+v", res.Terminal)
		}
		tail := res.Input[len(res.Input)-2:]
		if marshal(t, tail) != marshal(t, []any{fout("b", skipText), fout("c", skipText)}) {
			t.Fatalf("tail %s", marshal(t, tail))
		}
	})

	t.Run("off_compatibility", func(t *testing.T) {
		for _, rd := range []Round{{}, {StopAfterTerminal: false}} {
			tl, root := setup(t)
			rd.Tools = tl
			items := []map[string]any{fcall("r", "read_file", readArgs), fcall("t1", "finish", "{}"), fcall("w", "write_file", writeArgs), fcall("t2", "finish", "{}")}
			rq := &scriptRequester{script: [][]map[string]any{items}}
			var obs termObs
			res, err := Run(ctx, rd, start, rq, obs.hooks(nil))
			if err != nil {
				t.Fatal(err)
			}
			if res.Terminal == nil || res.Terminal.CallID() != "t2" {
				t.Fatalf("terminal %+v", res.Terminal)
			}
			if b, err := os.ReadFile(filepath.Join(root, "b.txt")); err != nil || string(b) != "x" {
				t.Fatalf("write did not run: %q %v", b, err)
			}
			if len(obs.after) != 4 || !reflect.DeepEqual(obs.handled, []string{"read_file", "write_file"}) {
				t.Fatalf("obs %+v", obs)
			}
			for _, s := range obs.skippedAfter {
				if s {
					t.Fatalf("unexpected skip %+v", obs)
				}
			}
			if len(res.Input) != 7 {
				t.Fatalf("input %s", marshal(t, res.Input))
			}
			readOut := res.Input[5].(map[string]any)
			if readOut["type"] != "function_call_output" || readOut["call_id"] != "r" || !strings.Contains(readOut["output"].(string), "hello") {
				t.Fatalf("read output %s", marshal(t, readOut))
			}
			// Independently constructed bytes: sent input + replay items + outputs of non-terminal calls.
			want := marshal(t, []any{userMsg("go"), items[0], items[1], items[2], items[3], fout("r", "1\thello"), fout("w", "ok")})
			if got := marshal(t, res.Input); got != want {
				t.Fatalf("transcript\n got %s\nwant %s", got, want)
			}
			if w := res.Input[6].(map[string]any); w["call_id"] != "w" || strings.Contains(w["output"].(string), "skipped") {
				t.Fatalf("write output %s", marshal(t, w))
			}
		}
	})

	t.Run("hook_terminal_events", func(t *testing.T) {
		items := []map[string]any{fcall("a", "x", "{}"), fcall("h", "hook_end", "{}"), fcall("b", "x", "{}"), fcall("c", "finish", "{}")}
		rq := &scriptRequester{script: [][]map[string]any{items}}
		var obs termObs
		var events []string
		h := obs.hooks(func(c tools.Call) Handled {
			if c.Name == "hook_end" {
				return Handled{Handled: true, Terminal: true}
			}
			return Handled{Handled: true, Output: tools.Output{Text: "ok"}}
		})
		before, after := h.BeforeCall, h.AfterCall
		h.BeforeCall = func(ctx context.Context, c tools.Call, input []any) error {
			events = append(events, "call:"+c.CallID().(string))
			return before(ctx, c, input)
		}
		h.AfterCall = func(ctx context.Context, c tools.Call, out tools.Output, terminal bool, input []any) error {
			if !terminal {
				events = append(events, "result:"+c.CallID().(string)+":"+out.Text)
			}
			return after(ctx, c, out, terminal, input)
		}
		res, err := Run(ctx, Round{StopAfterTerminal: true}, start, rq, h)
		if err != nil {
			t.Fatal(err)
		}
		if res.Terminal == nil || res.Terminal.CallID() != "h" {
			t.Fatalf("terminal %+v", res.Terminal)
		}
		if !reflect.DeepEqual(events, []string{"call:a", "result:a:ok", "call:h", "call:b", "result:b:" + skipText, "call:c", "result:c:" + skipText}) {
			t.Fatalf("events %v", events)
		}
		if !reflect.DeepEqual(obs.handled, []string{"x", "hook_end"}) {
			t.Fatalf("handled %v", obs.handled)
		}
		if !reflect.DeepEqual(obs.before, []string{"x", "hook_end", "x", "finish"}) || !reflect.DeepEqual(obs.after, obs.before) {
			t.Fatalf("events %+v", obs)
		}
		if !reflect.DeepEqual(obs.skippedAfter, []bool{false, false, true, true}) {
			t.Fatalf("skips %v", obs.skippedAfter)
		}
		tail := res.Input[len(res.Input)-3:]
		if marshal(t, tail) != marshal(t, []any{fout("a", "ok"), fout("b", skipText), fout("c", skipText)}) {
			t.Fatalf("tail %s", marshal(t, tail))
		}
	})

	t.Run("no_terminal", func(t *testing.T) {
		tl, root := setup(t)
		items := []map[string]any{fcall("r", "read_file", readArgs), fcall("w", "write_file", writeArgs)}
		rq := &scriptRequester{script: [][]map[string]any{items, call("finish")}}
		res, err := Run(ctx, Round{Tools: tl, StopAfterTerminal: true}, start, rq, Hooks{})
		if err != nil {
			t.Fatal(err)
		}
		if res.Requests != 2 || res.Terminal == nil || res.Terminal.Name != "finish" {
			t.Fatalf("result %+v", res)
		}
		if _, err := os.Stat(filepath.Join(root, "b.txt")); err != nil {
			t.Fatal(err)
		}
		if strings.Contains(marshal(t, rq.requests[1]), "skipped") || len(rq.requests[1]) != 5 {
			t.Fatalf("second request %s", marshal(t, rq.requests[1]))
		}
	})
}

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

func fcall(id, name, args string) map[string]any {
	return map[string]any{"type": "function_call", "call_id": id, "name": name, "arguments": args}
}

func fout(id, text string) map[string]any {
	return map[string]any{"type": "function_call_output", "call_id": id, "output": text}
}

// A batch always runs completely: calls after a terminal call still execute and the last
// terminal call is the Result.Terminal; terminal calls themselves are not executed and
// append no output.
func TestCompleteBatchRunsAfterTerminalAndLastTerminalWins(t *testing.T) {
	ctx := context.Background()
	start := []any{userMsg("go")}
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("hello\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	tl := &tools.Tools{Root: root, Enabled: []string{tools.ReadFileTool, tools.WriteFileTool}}
	items := []map[string]any{
		fcall("r", "read_file", `{"path":"a.txt"}`), fcall("t1", "finish", "{}"),
		fcall("w", "write_file", `{"path":"b.txt","content":"x"}`), fcall("t2", "finish", "{}"),
	}
	rq := &scriptRequester{script: [][]map[string]any{items}}
	var before, after, handled []string
	var terminals []bool
	h := Hooks{
		BeforeCall: func(_ context.Context, c tools.Call, _ []any) error {
			before = append(before, c.Name)
			return nil
		},
		HandleCall: func(_ context.Context, c tools.Call) (Handled, error) {
			handled = append(handled, c.Name)
			return Handled{}, nil
		},
		AfterCall: func(_ context.Context, c tools.Call, out tools.Output, terminal bool, _ []any) error {
			after = append(after, c.Name)
			terminals = append(terminals, terminal)
			return nil
		},
	}
	res, err := Run(ctx, Round{Tools: tl}, start, rq, h)
	if err != nil {
		t.Fatal(err)
	}
	if res.Ending != EndTerminal || res.Terminal == nil || res.Terminal.CallID() != "t2" || res.Requests != 1 {
		t.Fatalf("result %+v", res)
	}
	if b, err := os.ReadFile(filepath.Join(root, "b.txt")); err != nil || string(b) != "x" {
		t.Fatalf("write after the first terminal did not run: %q %v", b, err)
	}
	if !reflect.DeepEqual(before, []string{"read_file", "finish", "write_file", "finish"}) || !reflect.DeepEqual(after, before) {
		t.Fatalf("hooks before %v after %v", before, after)
	}
	if !reflect.DeepEqual(handled, []string{"read_file", "write_file"}) {
		t.Fatalf("terminal calls must not reach HandleCall: %v", handled)
	}
	if !reflect.DeepEqual(terminals, []bool{false, true, false, true}) {
		t.Fatalf("terminal flags %v", terminals)
	}
	// Independently constructed bytes: sent input + replay items + outputs of non-terminal calls.
	want := marshal(t, []any{userMsg("go"), items[0], items[1], items[2], items[3], fout("r", "1\thello"), fout("w", "ok")})
	if got := marshal(t, res.Input); got != want {
		t.Fatalf("transcript\n got %s\nwant %s", got, want)
	}
	if strings.Contains(marshal(t, res.Input), "skipped") {
		t.Fatalf("a call was skipped: %s", marshal(t, res.Input))
	}
}

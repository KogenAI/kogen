package conformance

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"

	"kogen-loop/loop"
	"kogen-loop/provider"
)

type utf8Requester struct {
	scripted
	t       *testing.T
	outputs map[string]string
}

func (s *utf8Requester) Request(ctx context.Context, r loop.Request) (*provider.Response, []any, error) {
	if len(s.asked) == 1 {
		s.outputs = map[string]string{}
		for _, item := range r.Input {
			m, ok := item.(map[string]any)
			if !ok || m["type"] != "function_call_output" {
				continue
			}
			text, ok := m["output"].(string)
			if !ok {
				s.t.Fatal("non-text output")
			}
			if !utf8.ValidString(text) {
				s.t.Fatalf("invalid pre-serialization output %q", text)
			}
			s.outputs[m["call_id"].(string)] = text
		}
		wire, err := json.Marshal(r.Input)
		if err != nil {
			s.t.Fatal(err)
		}
		var decoded []map[string]any
		if err = json.Unmarshal(wire, &decoded); err != nil {
			s.t.Fatal(err)
		}
		for _, m := range decoded {
			if m["type"] == "function_call_output" && m["output"] != s.outputs[m["call_id"].(string)] {
				s.t.Fatal("wire text differs")
			}
		}
	}
	return s.scripted.Request(ctx, r)
}
func runUTF8Shell(t *testing.T, commands ...string) (*utf8Requester, string) {
	t.Helper()
	w := newWorld(t)
	var calls []map[string]any
	for i, cmd := range commands {
		args, _ := json.Marshal(map[string]string{"command": cmd})
		calls = append(calls, fakeCall(fmt.Sprint(i), "shell", string(args)))
	}
	r := &utf8Requester{t: t, scripted: scripted{responses: []*provider.Response{respond("r1", calls...), respond("r2")}}}
	if _, err := loop.Run(context.Background(), roundWith(t, w), []any{userMessage("go")}, r, loop.Hooks{}); err != nil {
		t.Fatal(err)
	}
	if len(r.outputs) != len(commands) {
		t.Fatalf("outputs: %v", r.outputs)
	}
	return r, w.root
}
func TestLShellUTF8BinaryRequest(t *testing.T) {
	r, root := runUTF8Shell(t, "dd if=/dev/urandom of=random.bin bs=3000 count=1 2>/dev/null; cat random.bin", `printf 'Δ\377🙂\376'`)
	raw, err := os.ReadFile(filepath.Join(root, "random.bin"))
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) != 3000 || utf8.Valid(raw) {
		t.Fatal("random capture not invalid UTF-8")
	}
	if want := "exit status: 0\n" + string([]rune(string(raw))); r.outputs["0"] != want {
		t.Fatal("random output differs from normalized capture")
	}
	if r.outputs["1"] != "exit status: 0\nΔ�🙂�" {
		t.Fatalf("deterministic output %q", r.outputs["1"])
	}
}
func TestLShellUTF8ValidAndCutRequest(t *testing.T) {
	r, _ := runUTF8Shell(t, `printf 'Δ🙂'`, `i=0; while [ "$i" -lt 4000 ]; do printf 'Δ🙂'; i=$((i+1)); done`)
	if r.outputs["0"] != "exit status: 0\nΔ🙂" {
		t.Fatalf("fitting output %q", r.outputs["0"])
	}
	text := "exit status: 0\n" + strings.Repeat("Δ🙂", 4000)
	head := text[:4096]
	for !utf8.ValidString(head) {
		head = head[:len(head)-1]
	}
	markerWidth := len(fmt.Sprintf("\n[... %d bytes omitted ...]\n", len(text)))
	tail := text[len(text)-(16384-4096-markerWidth):]
	for !utf8.ValidString(tail) {
		tail = tail[1:]
	}
	want := head + fmt.Sprintf("\n[... %d bytes omitted ...]\n", len(text)-len(head)-len(tail)) + tail
	if r.outputs["1"] != want {
		t.Fatalf("oversized output mismatch: got %d want %d", len(r.outputs["1"]), len(want))
	}
}

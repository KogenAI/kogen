package conformance

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"kogen-loop/loop"
	"kogen-loop/provider"
)

func shellResult(t *testing.T, r loop.Request, id string) string {
	t.Helper()
	for _, item := range r.Input {
		m, ok := item.(map[string]any)
		if ok && m["type"] == "function_call_output" && m["call_id"] == id {
			s, ok := m["output"].(string)
			if !ok {
				t.Fatalf("invalid output: %v", m)
			}
			return s
		}
	}
	t.Fatalf("missing result for %s in %v", id, r.Input)
	return ""
}

func runShellArgs(t *testing.T, args map[string]any) string {
	t.Helper()
	l := newLifecycleRun(t)
	rq := &scripted{responses: []*provider.Response{respond("r1", call("c1", "shell", args)), respond("r2", message("done"))}}
	if _, err := loop.Run(context.Background(), l.rd, []any{userMessage("go")}, rq, loop.Hooks{}); err != nil {
		t.Fatal(err)
	}
	if len(rq.asked) != 2 {
		t.Fatalf("requests: %d", len(rq.asked))
	}
	return shellResult(t, rq.asked[1], "c1")
}

func TestShellLifecycleEmptyHandleCommand(t *testing.T) {
	got := runShellArgs(t, map[string]any{"command": "printf 'empty-handle-ok\\n'; exit 7", "handle": ""})
	if got != "exit status: 7\nempty-handle-ok\n" {
		t.Fatalf("output: %q", got)
	}
}

func TestShellLifecycleAmbiguousHandle(t *testing.T) {
	l := newLifecycleRun(t)
	marker := filepath.Join(l.w.root, "marker")
	rq := &scripted{responses: []*provider.Response{respond("r1", call("c1", "shell", map[string]any{"command": "touch " + shq(marker), "handle": "nonempty"})), respond("r2", message("done"))}}
	if _, err := loop.Run(context.Background(), l.rd, []any{userMessage("go")}, rq, loop.Hooks{}); err != nil {
		t.Fatal(err)
	}
	if len(rq.asked) != 2 {
		t.Fatalf("requests: %d", len(rq.asked))
	}
	if got := shellResult(t, rq.asked[1], "c1"); got != "error: supply exactly one of command or handle" {
		t.Fatalf("output: %q", got)
	}
	if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("marker exists or cannot be checked: %v", err)
	}
}

func TestShellLifecycleNeitherArgument(t *testing.T) {
	got := runShellArgs(t, map[string]any{})
	if got != "error: supply exactly one of command or handle" {
		t.Fatalf("output: %q", got)
	}
}

func TestShellLifecycleEmptyHandleOnly(t *testing.T) {
	got := runShellArgs(t, map[string]any{"handle": ""})
	if !strings.HasPrefix(got, "error:") {
		t.Fatalf("output: %q", got)
	}
}

type retrievalScript struct {
	scripted
	t    *testing.T
	root string
}

func (s *retrievalScript) Request(ctx context.Context, r loop.Request) (*provider.Response, []any, error) {
	if len(s.asked) == 1 {
		text := shellResult(s.t, r, "c1")
		var result struct {
			Status string `json:"status"`
			Handle string `json:"handle"`
			Output string `json:"output"`
		}
		if err := json.Unmarshal([]byte(text), &result); err != nil || result.Status != "running" || result.Handle == "" || result.Output != "partial\n" {
			s.t.Fatalf("initial result: %q (%v)", text, err)
		}
		if err := os.WriteFile(filepath.Join(s.root, "release"), nil, 0600); err != nil {
			s.t.Fatal(err)
		}
		s.responses[1] = respond("r2", call("c2", "shell", map[string]any{"handle": result.Handle}))
	}
	return s.scripted.Request(ctx, r)
}

func TestShellLifecycleHandleRetrieval(t *testing.T) {
	t.Parallel()
	l := newLifecycleRun(t)
	// A new command's wait elapses once the command has printed; a retrieval's never does.
	l.rd.Tools.ShellAfter = func(wait time.Duration) <-chan time.Time {
		if wait != 45*time.Second {
			return nil
		}
		fire := make(chan time.Time, 1)
		go func() {
			end := time.Now().Add(10 * time.Second)
			for time.Now().Before(end) {
				if _, err := os.Stat(filepath.Join(l.w.root, "ready")); err == nil {
					break
				}
				time.Sleep(10 * time.Millisecond)
			}
			// The session copies output from a pipe a moment after the command wrote it,
			// and nothing here can observe that copy: let it land before the wait elapses.
			time.Sleep(500 * time.Millisecond)
			fire <- time.Now()
		}()
		return fire
	}
	rq := &retrievalScript{t: t, root: l.w.root, scripted: scripted{responses: []*provider.Response{
		respond("r1", shellItem("c1", "printf 'partial\\n'; : > ready; while [ ! -f release ]; do sleep .05; done; printf 'complete\\n'; exit 7")), nil, respond("r3", message("done")),
	}}}
	if _, err := loop.Run(context.Background(), l.rd, []any{userMessage("go")}, rq, loop.Hooks{}); err != nil {
		t.Fatal(err)
	}
	if len(rq.asked) != 3 {
		t.Fatalf("requests: %d", len(rq.asked))
	}
	text := shellResult(t, rq.asked[2], "c2")
	var result struct {
		Status     string `json:"status"`
		Output     string `json:"output"`
		ExitStatus int    `json:"exit_status"`
	}
	if err := json.Unmarshal([]byte(text), &result); err != nil || result.Status != "completed" || result.Output != "partial\ncomplete\n" || result.ExitStatus != 7 {
		t.Fatalf("retrieval: %q (%v)", text, err)
	}
}

func TestShellLifecycleUnusableHandles(t *testing.T) {
	for _, tc := range []struct {
		name    string
		present bool
		value   any
	}{
		{"absent", false, nil}, {"null", true, nil}, {"empty", true, ""}, {"whitespace", true, "   "},
		{"number", true, 42}, {"boolean", true, false}, {"array", true, []any{}}, {"object", true, map[string]any{}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			args := map[string]any{"command": "printf 'args-ok\\n'; exit 7"}
			if tc.present {
				args["handle"] = tc.value
			}
			if got := runShellArgs(t, args); got != "exit status: 7\nargs-ok\n" {
				t.Fatalf("output: %q", got)
			}
		})
	}
}

func TestShellLifecycleNeitherUsable(t *testing.T) {
	commands := []struct {
		name    string
		present bool
		value   any
	}{{"absent", false, nil}, {"empty", true, ""}, {"whitespace", true, "   "}}
	handles := []struct {
		name    string
		present bool
		value   any
	}{{"absent", false, nil}, {"null", true, nil}, {"empty", true, ""}, {"whitespace", true, "   "}, {"number", true, 42}}
	for _, command := range commands {
		for _, handle := range handles {
			t.Run(command.name+"/"+handle.name, func(t *testing.T) {
				args := map[string]any{}
				if command.present {
					args["command"] = command.value
				}
				if handle.present {
					args["handle"] = handle.value
				}
				if got := runShellArgs(t, args); !strings.HasPrefix(got, "error:") {
					t.Fatalf("output: %q", got)
				}
			})
		}
	}
}

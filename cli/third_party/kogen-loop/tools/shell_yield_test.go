package tools

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/KogenAI/kogen-loop/sys"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestShellYieldRetrievalScope(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	clock := newShellClock()
	tl := &Tools{Root: root, Session: sys.NewWith(os.Environ(), root), Enabled: []string{ShellTool}, ShellAfter: clock.After}
	defer tl.EndShellRound()
	decode := func(s string) map[string]any {
		t.Helper()
		var v map[string]any
		if err := json.Unmarshal([]byte(s), &v); err != nil {
			t.Fatalf("invalid JSON %q: %v", s, err)
		}
		return v
	}
	ch := callShell(tl, map[string]any{"command": "printf one; : > ready; while [ ! -f release ]; do sleep .05; done; printf two; exit 7"})
	yield := clock.next(t, "yield", 45*time.Second)
	appears(t, root, "ready")
	captured(t, tl, len("one"))
	held(t, "yield", ch)
	yield.fire <- time.Now()
	v := decode(finished(t, "yield", ch))
	if v["status"] != "running" || v["output"] != "one" {
		t.Fatalf("yield: %v", v)
	}
	id, ok := v["handle"].(string)
	if !ok || id == "" {
		t.Fatal(v)
	}
	if got := run(t, tl, ShellTool, map[string]any{"handle": " " + id + " "}); got != "error: unknown shell handle" {
		t.Fatalf("padded handle: %q", got)
	}
	select {
	case r := <-clock.requests:
		t.Fatalf("unknown handle asked ShellAfter for %v", r.wait)
	default:
	}
	ch = callShell(tl, map[string]any{"handle": id})
	retrieval := clock.next(t, "running retrieval", 30*time.Second)
	held(t, "running retrieval", ch)
	retrieval.fire <- time.Now()
	v = decode(finished(t, "running retrieval", ch))
	if v["status"] != "running" || v["output"] != "one" {
		t.Fatal(v)
	}
	ch = callShell(tl, map[string]any{"handle": id})
	woken := clock.next(t, "completion retrieval", 30*time.Second)
	held(t, "completion retrieval", ch)
	if err := os.WriteFile(filepath.Join(root, "release"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	got := finished(t, "completion retrieval", ch)
	select {
	case <-woken.fire:
		t.Fatal("the completion retrieval waited for its controlled wait")
	default:
	}
	for i := 0; i < 2; i++ {
		if i > 0 {
			ch = callShell(tl, map[string]any{"handle": id})
			clock.next(t, "repeat retrieval", 30*time.Second)
			got = finished(t, "repeat retrieval", ch)
		}
		v = decode(got)
		if v["status"] != "completed" || v["exit_status"] != float64(7) || v["output"] != "onetwo" {
			t.Fatal(v)
		}
	}
	tl.EndShellRound()
	for _, a := range []map[string]any{{}, {"handle": id}, {"handle": "unknown"}, {"command": "touch bad", "handle": id}, {"handle": 42}} {
		if got := run(t, tl, ShellTool, a); !strings.HasPrefix(got, "error:") {
			t.Fatalf("%v: %s", a, got)
		}
	}
	if _, err := os.Stat(filepath.Join(root, "bad")); !os.IsNotExist(err) {
		t.Fatal("invalid call launched command")
	}
}

func TestShellYieldLargeJSON(t *testing.T) {
	t.Parallel()
	for _, n := range []string{"16383", "16384", "16385", "200000"} {
		t.Run(n, func(t *testing.T) {
			t.Parallel()
			size, err := strconv.Atoi(n)
			if err != nil {
				t.Fatal(err)
			}
			root := t.TempDir()
			clock := newShellClock()
			tl := &Tools{Root: root, Session: sys.NewWith(os.Environ(), root), Enabled: []string{ShellTool}, ShellAfter: clock.After}
			defer tl.EndShellRound()
			parse := func(s string) map[string]any {
				t.Helper()
				var v map[string]any
				if len(s) > maxResult || json.Unmarshal([]byte(s), &v) != nil {
					t.Fatalf("invalid envelope length %d", len(s))
				}
				return v
			}
			ch := callShell(tl, map[string]any{"command": "head -c " + n + " /dev/zero; : > ready; while [ ! -f release ]; do sleep .05; done"})
			yield := clock.next(t, "yield", 45*time.Second)
			appears(t, root, "ready")
			captured(t, tl, size)
			held(t, "yield", ch)
			yield.fire <- time.Now()
			v := parse(finished(t, "yield", ch))
			if v["status"] != "running" {
				t.Fatal(v)
			}
			id := v["handle"]
			if err := os.WriteFile(filepath.Join(root, "release"), nil, 0600); err != nil {
				t.Fatal(err)
			}
			ch = callShell(tl, map[string]any{"handle": id})
			retrieval := clock.next(t, "retrieval", 30*time.Second)
			v = parse(finished(t, "retrieval", ch))
			if v["status"] != "completed" {
				t.Fatal(v)
			}
			select {
			case <-retrieval.fire:
				t.Fatal("the retrieval waited for its controlled wait")
			default:
			}
		})
	}
}

func TestShellYieldLargeMalformedOutput(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	clock := newShellClock()
	tl := &Tools{Root: root, Session: sys.NewWith(os.Environ(), root), Enabled: []string{ShellTool}, ShellAfter: clock.After}
	defer tl.EndShellRound()
	command := `printf '\377'; head -c 20000 /dev/zero | tr '\000' x; printf '\376'; : > ready; while [ ! -f release ]; do sleep .05; done`
	check := func(s string, status string) {
		t.Helper()
		var v map[string]any
		if len(s) > maxResult || json.Unmarshal([]byte(s), &v) != nil || v["status"] != status {
			t.Fatalf("bad envelope: %q", s)
		}
		output, ok := v["output"].(string)
		if !ok || !strings.HasPrefix(output, "�xxx") || !strings.HasSuffix(output, "xxx�") || !strings.Contains(output, "bytes omitted") {
			t.Fatalf("lost retained output: %q", output)
		}
	}
	ch := callShell(tl, map[string]any{"command": command})
	yield := clock.next(t, "yield", 45*time.Second)
	appears(t, root, "ready")
	captured(t, tl, 20002)
	yield.fire <- time.Now()
	s := finished(t, "yield", ch)
	check(s, "running")
	var v map[string]any
	if err := json.Unmarshal([]byte(s), &v); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "release"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	ch = callShell(tl, map[string]any{"handle": v["handle"]})
	clock.next(t, "retrieval", 30*time.Second)
	check(finished(t, "retrieval", ch), "completed")
}

func TestShellRetrievalCancellationStopsCommand(t *testing.T) {
	for _, mode := range []string{"cancel", "deadline"} {
		t.Run(mode, func(t *testing.T) {
			t.Parallel()
			root := t.TempDir()
			clock := newShellClock()
			tl := &Tools{Root: root, Session: sys.NewWith(os.Environ(), root), Enabled: []string{ShellTool}, ShellAfter: clock.After}
			defer tl.EndShellRound()
			ch := callShell(tl, map[string]any{"command": "echo $$ > actor.pid; exec sleep 600"})
			yield := clock.next(t, "yield", 45*time.Second)
			appears(t, root, "actor.pid")
			pid := 0
			for end := time.Now().Add(10 * time.Second); pid == 0; time.Sleep(10 * time.Millisecond) {
				data, err := os.ReadFile(filepath.Join(root, "actor.pid"))
				if strings.HasSuffix(string(data), "\n") && err == nil {
					pid, err = strconv.Atoi(strings.TrimSpace(string(data)))
					if err != nil || pid <= 1 {
						t.Fatalf("pid: %q", data)
					}
				} else if time.Now().After(end) {
					t.Fatalf("pid: %q %v", data, err)
				}
			}
			yield.fire <- time.Now()
			text := finished(t, "yield", ch)
			var v struct {
				Status string `json:"status"`
				Handle string `json:"handle"`
			}
			if err := json.Unmarshal([]byte(text), &v); err != nil || v.Status != "running" || v.Handle == "" {
				t.Fatalf("yield: %s %v", text, err)
			}
			var ctx context.Context
			var cancel context.CancelFunc
			want := context.Canceled
			if mode == "deadline" {
				ctx, cancel = context.WithTimeout(context.Background(), 2*time.Second)
				want = context.DeadlineExceeded
			} else {
				ctx, cancel = context.WithCancel(context.Background())
				timer := time.AfterFunc(2*time.Second, cancel)
				defer timer.Stop()
			}
			defer cancel()
			start := time.Now()
			_, err := tl.RunContext(ctx, ShellTool, map[string]any{"handle": v.Handle})
			if !errors.Is(err, want) || time.Since(start) > 7*time.Second {
				t.Fatalf("cancellation: %v after %v", err, time.Since(start))
			}
			// The retrieval's wait was queued before RunContext returned and never fired.
			clock.next(t, "retrieval", 30*time.Second)
			if err := syscall.Kill(pid, 0); !errors.Is(err, syscall.ESRCH) {
				t.Fatalf("command still exists: %v", err)
			}
		})
	}
}

func TestShellNewCommandCancellationStopsCommand(t *testing.T) {
	for _, mode := range []string{"cancel", "deadline"} {
		t.Run(mode, func(t *testing.T) {
			t.Parallel()
			root := t.TempDir()
			tl := &Tools{Root: root, Session: sys.NewWith(os.Environ(), root), Enabled: []string{ShellTool}}
			defer tl.EndShellRound()
			var ctx context.Context
			var cancel context.CancelFunc
			want := context.Canceled
			if mode == "deadline" {
				ctx, cancel = context.WithTimeout(context.Background(), 2*time.Second)
				want = context.DeadlineExceeded
			} else {
				ctx, cancel = context.WithCancel(context.Background())
				timer := time.AfterFunc(2*time.Second, cancel)
				defer timer.Stop()
			}
			defer cancel()
			start := time.Now()
			_, err := tl.RunContext(ctx, ShellTool, map[string]any{"command": "echo $$ > actor.pid; exec sleep 600"})
			if !errors.Is(err, want) || time.Since(start) > 7*time.Second {
				t.Fatalf("cancellation: %v after %v", err, time.Since(start))
			}
			data, err := os.ReadFile(filepath.Join(root, "actor.pid"))
			if err != nil {
				t.Fatal(err)
			}
			pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
			if err != nil || pid <= 1 {
				t.Fatalf("pid: %q", data)
			}
			if err := syscall.Kill(pid, 0); !errors.Is(err, syscall.ESRCH) {
				t.Fatalf("command still exists: %v", err)
			}
		})
	}
}

func TestShellNewCommandCompletesWithinBound(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	tl := &Tools{Root: root, Session: sys.NewWith(os.Environ(), root), Enabled: []string{ShellTool}}
	defer tl.EndShellRound()
	start := time.Now()
	got := run(t, tl, ShellTool, map[string]any{"command": "printf partial; sleep 2; printf ' complete'; exit 7"})
	if got != "exit status: 7\npartial complete" || time.Since(start) < 2*time.Second || time.Since(start) > 10*time.Second {
		t.Fatalf("%q after %v", got, time.Since(start))
	}
}

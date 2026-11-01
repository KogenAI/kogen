package tools

import (
	"context"
	"encoding/json"
	"errors"
	"kogen-loop/sys"
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
	tl := &Tools{Root: root, Session: sys.NewWith(os.Environ(), root), Enabled: []string{ShellTool}}
	defer tl.EndShellRound()
	decode := func(s string) map[string]any {
		t.Helper()
		var v map[string]any
		if err := json.Unmarshal([]byte(s), &v); err != nil {
			t.Fatalf("invalid JSON %q: %v", s, err)
		}
		return v
	}
	start := time.Now()
	v := decode(run(t, tl, ShellTool, map[string]any{"command": "printf one; while [ ! -f release ]; do sleep .05; done; printf two; exit 7"}))
	if v["status"] != "running" || v["output"] != "one" || time.Since(start) < 44*time.Second || time.Since(start) > 52*time.Second {
		t.Fatalf("yield: %v after %v", v, time.Since(start))
	}
	id, ok := v["handle"].(string)
	if !ok || id == "" {
		t.Fatal(v)
	}
	if got := run(t, tl, ShellTool, map[string]any{"handle": " " + id + " "}); got != "error: unknown shell handle" {
		t.Fatalf("padded handle: %q", got)
	}
	start = time.Now()
	v = decode(run(t, tl, ShellTool, map[string]any{"handle": id}))
	if v["status"] != "running" || v["output"] != "one" || time.Since(start) < 29*time.Second || time.Since(start) > 36*time.Second {
		t.Fatal(v)
	}
	release := make(chan error, 1)
	go func() {
		time.Sleep(2 * time.Second)
		release <- os.WriteFile(filepath.Join(root, "release"), nil, 0600)
	}()
	start = time.Now()
	for i := 0; i < 2; i++ {
		v = decode(run(t, tl, ShellTool, map[string]any{"handle": id}))
		if i == 0 && (time.Since(start) < time.Second || time.Since(start) > 6*time.Second) {
			t.Fatalf("completion did not wake retrieval promptly: %v", time.Since(start))
		}
		if v["status"] != "completed" || v["exit_status"] != float64(7) || v["output"] != "onetwo" {
			t.Fatal(v)
		}
	}
	if err := <-release; err != nil {
		t.Fatal(err)
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
			root := t.TempDir()
			tl := &Tools{Root: root, Session: sys.NewWith(os.Environ(), root), Enabled: []string{ShellTool}}
			defer tl.EndShellRound()
			parse := func(s string) map[string]any {
				t.Helper()
				var v map[string]any
				if len(s) > maxResult || json.Unmarshal([]byte(s), &v) != nil {
					t.Fatalf("invalid envelope length %d", len(s))
				}
				return v
			}
			v := parse(run(t, tl, ShellTool, map[string]any{"command": "head -c " + n + " /dev/zero; while [ ! -f release ]; do sleep .05; done"}))
			if v["status"] != "running" {
				t.Fatal(v)
			}
			id := v["handle"]
			if err := os.WriteFile(filepath.Join(root, "release"), nil, 0600); err != nil {
				t.Fatal(err)
			}
			v = parse(run(t, tl, ShellTool, map[string]any{"handle": id}))
			if v["status"] != "completed" {
				t.Fatal(v)
			}
		})
	}
}

func TestShellYieldLargeMalformedOutput(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	tl := &Tools{Root: root, Session: sys.NewWith(os.Environ(), root), Enabled: []string{ShellTool}}
	defer tl.EndShellRound()
	command := `printf '\377'; head -c 20000 /dev/zero | tr '\000' x; printf '\376'; while [ ! -f release ]; do sleep .05; done`
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
	s := run(t, tl, ShellTool, map[string]any{"command": command})
	check(s, "running")
	var v map[string]any
	if err := json.Unmarshal([]byte(s), &v); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "release"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	check(run(t, tl, ShellTool, map[string]any{"handle": v["handle"]}), "completed")
}

func TestShellRetrievalCancellationStopsCommand(t *testing.T) {
	for _, mode := range []string{"cancel", "deadline"} {
		t.Run(mode, func(t *testing.T) {
			t.Parallel()
			root := t.TempDir()
			tl := &Tools{Root: root, Session: sys.NewWith(os.Environ(), root), Enabled: []string{ShellTool}}
			defer tl.EndShellRound()
			var v struct {
				Status string `json:"status"`
				Handle string `json:"handle"`
			}
			text := run(t, tl, ShellTool, map[string]any{"command": "echo $$ > actor.pid; exec sleep 600"})
			if err := json.Unmarshal([]byte(text), &v); err != nil || v.Status != "running" || v.Handle == "" {
				t.Fatalf("yield: %s %v", text, err)
			}
			data, err := os.ReadFile(filepath.Join(root, "actor.pid"))
			if err != nil {
				t.Fatal(err)
			}
			pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
			if err != nil || pid <= 1 {
				t.Fatalf("pid: %q", data)
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
			_, err = tl.RunContext(ctx, ShellTool, map[string]any{"handle": v.Handle})
			if !errors.Is(err, want) || time.Since(start) > 7*time.Second {
				t.Fatalf("cancellation: %v after %v", err, time.Since(start))
			}
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

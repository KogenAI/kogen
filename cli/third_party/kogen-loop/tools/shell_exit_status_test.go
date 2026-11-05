package tools

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/KogenAI/kogen-loop/sys"
)

func wantStatus(t *testing.T, step string, c Classified, want *int) {
	t.Helper()
	switch {
	case want == nil && c.ExitStatus != nil:
		t.Errorf("%s: ExitStatus %d, want nil", step, *c.ExitStatus)
	case want != nil && c.ExitStatus == nil:
		t.Errorf("%s: ExitStatus nil, want %d", step, *want)
	case want != nil && *c.ExitStatus != *want:
		t.Errorf("%s: ExitStatus %d, want %d", step, *c.ExitStatus, *want)
	}
}

func intp(n int) *int { return &n }

func TestShellClassifiedExitStatus(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "f.txt"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	tl := &Tools{Root: root, Session: sys.New(), Enabled: []string{ShellTool, ReadFileTool}}
	run := func(args map[string]any) Classified {
		c, err := tl.RunClassified(context.Background(), ShellTool, args)
		if err != nil {
			t.Fatal(err)
		}
		return c
	}
	c := run(map[string]any{"command": "exit 3"})
	if c.Text != "exit status: 3\n" {
		t.Errorf("text %q", c.Text)
	}
	wantStatus(t, "exit 3", c, intp(3))
	wantStatus(t, "exit 0", run(map[string]any{"command": "exit 0"}), intp(0))
	wantStatus(t, "kill", run(map[string]any{"command": "kill -9 $$"}), intp(137))
	c = run(map[string]any{"command": "printf 'exit status: 9\\n'"})
	wantStatus(t, "printed", c, intp(0))
	wantStatus(t, "refused", run(map[string]any{"command": "pkill -f nothing-at-all"}), nil)
	wantStatus(t, "unknown handle", run(map[string]any{"handle": "nope"}), nil)
	wantStatus(t, "malformed", run(map[string]any{}), nil)
	c, err := tl.RunClassified(context.Background(), ReadFileTool, map[string]any{"path": "f.txt"})
	if err != nil {
		t.Fatal(err)
	}
	wantStatus(t, "read_file", c, nil)
}

func TestShellClassifiedExitStatusAcrossYieldAndRetrieval(t *testing.T) {
	t.Parallel()
	clock := newShellClock()
	root := t.TempDir()
	tl := &Tools{Root: root, Session: sys.New(), Enabled: []string{ShellTool}, ShellAfter: clock.After}
	type result struct {
		c   Classified
		err error
	}
	start := func(args map[string]any) chan result {
		ch := make(chan result, 1)
		go func() {
			c, err := tl.RunClassified(context.Background(), ShellTool, args)
			ch <- result{c, err}
		}()
		return ch
	}
	await := func(ch chan result) Classified {
		select {
		case r := <-ch:
			if r.err != nil {
				t.Fatal(r.err)
			}
			return r.c
		case <-time.After(10 * time.Second):
			t.Fatal("the shell call never returned")
		}
		return Classified{}
	}
	ch := start(map[string]any{"command": "echo go > started; while [ ! -f release ]; do sleep 0.01; done; exit 4"})
	clock.next(t, "start", 45*time.Second).fire <- time.Now()
	yielded := await(ch)
	wantStatus(t, "yield", yielded, nil)
	var env map[string]any
	if err := json.Unmarshal([]byte(yielded.Text), &env); err != nil || env["status"] != "running" {
		t.Fatalf("yield text %q %v", yielded.Text, err)
	}
	handle := env["handle"].(string)

	ch = start(map[string]any{"handle": handle})
	clock.next(t, "bound", 30*time.Second).fire <- time.Now()
	wantStatus(t, "bound", await(ch), nil)

	appears(t, root, "started")
	if err := writeRelease(root); err != nil {
		t.Fatal(err)
	}
	for _, step := range []string{"collect", "again"} {
		ch = start(map[string]any{"handle": handle})
		clock.next(t, step, 30*time.Second)
		c := await(ch)
		wantStatus(t, step, c, intp(4))
		if err := json.Unmarshal([]byte(c.Text), &env); err != nil || env["status"] != "completed" || env["exit_status"] != float64(4) {
			t.Errorf("%s text %q %v", step, c.Text, err)
		}
	}
}

func writeRelease(root string) error {
	return os.WriteFile(filepath.Join(root, "release"), nil, 0o644)
}

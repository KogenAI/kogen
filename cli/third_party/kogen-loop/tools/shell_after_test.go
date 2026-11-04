package tools

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"kogen-loop/api"
	"kogen-loop/sys"
)

// shellTimer is one wait a shell call asked its test for; sending on fire is the wait elapsing.
type shellTimer struct {
	wait time.Duration
	fire chan time.Time
}

// shellClock is the controlled time of a test: every wait a shell call reaches arrives on requests.
type shellClock struct {
	requests chan shellTimer
}

func newShellClock() *shellClock {
	return &shellClock{requests: make(chan shellTimer, 16)}
}

// After is the Tools.ShellAfter of the test.
func (c *shellClock) After(wait time.Duration) <-chan time.Time {
	fire := make(chan time.Time, 1)
	c.requests <- shellTimer{wait, fire}
	return fire
}

// next returns the wait the next shell call asked for, which must be want.
func (c *shellClock) next(t *testing.T, step string, want time.Duration) shellTimer {
	t.Helper()
	select {
	case r := <-c.requests:
		if r.wait != want {
			t.Fatalf("%s: the shell wait asked ShellAfter for %v, want %v", step, r.wait, want)
		}
		return r
	case <-time.After(10 * time.Second):
		t.Fatalf("%s: the shell wait never asked ShellAfter for its %v wait", step, want)
	}
	return shellTimer{}
}

// appears waits for a file the command writes once it has produced the output the test expects.
func appears(t *testing.T, root, name string) {
	t.Helper()
	end := time.Now().Add(10 * time.Second)
	for {
		if _, err := os.Stat(filepath.Join(root, name)); err == nil {
			return
		}
		if time.Now().After(end) {
			t.Fatalf("the command never wrote %s", name)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// captured waits until a command has written the file marker and the session has captured
// exactly size bytes of its output, so a yield returns what the test expects.
func captured(t *testing.T, tl *Tools, size int) {
	t.Helper()
	end := time.Now().Add(10 * time.Second)
	for {
		r := tl.registry()
		r.mu.Lock()
		got := -1
		for _, j := range r.jobs {
			res, _, _ := j.cmd.Snapshot()
			got = len(res.Output)
		}
		r.mu.Unlock()
		if got == size {
			return
		}
		if time.Now().After(end) {
			t.Fatalf("the session captured %d output bytes, want %d", got, size)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

type shellOutcome struct {
	text string
	err  error
}

// callShell runs a shell call in the background.
func callShell(tl *Tools, args map[string]any) <-chan shellOutcome {
	ch := make(chan shellOutcome, 1)
	go func() {
		out, err := tl.Run(ShellTool, args)
		ch <- shellOutcome{out.Text, err}
	}()
	return ch
}

// held fails when the call returns before its controlled wait has elapsed.
func held(t *testing.T, step string, ch <-chan shellOutcome) {
	t.Helper()
	select {
	case o := <-ch:
		t.Fatalf("%s: the call returned %q (%v) before its controlled wait elapsed", step, o.text, o.err)
	case <-time.After(200 * time.Millisecond):
	}
}

// finished is the result of a call that must return.
func finished(t *testing.T, step string, ch <-chan shellOutcome) string {
	t.Helper()
	select {
	case o := <-ch:
		if o.err != nil {
			t.Fatalf("%s: %v", step, o.err)
		}
		return o.text
	case <-time.After(10 * time.Second):
		t.Fatalf("%s: the shell call did not return", step)
	}
	return ""
}

// shellWaitOf runs a shell call and returns its classified result.
func shellWaitOf(t *testing.T, tl *Tools, args map[string]any, during func()) Classified {
	t.Helper()
	ch := make(chan Classified, 1)
	go func() {
		got, err := tl.RunClassified(context.Background(), ShellTool, args)
		if err != nil {
			t.Error(err)
		}
		ch <- got
	}()
	if during != nil {
		during()
	}
	select {
	case got := <-ch:
		return got
	case <-time.After(10 * time.Second):
		t.Fatal("the shell call did not return")
	}
	return Classified{}
}

func TestShellWaitRecordsWhyEachWaitEnded(t *testing.T) {
	root := t.TempDir()
	clock := newShellClock()
	tl := &Tools{Root: root, Session: sys.New(), Enabled: []string{ShellTool}, ShellAfter: clock.After}
	defer tl.EndShellRound()

	before := time.Now()
	var yielded Classified
	yielded = shellWaitOf(t, tl, map[string]any{"command": ": > ready; while [ ! -f release ]; do sleep .05; done"}, func() {
		r := clock.next(t, "yield", 45*time.Second)
		appears(t, root, "ready")
		r.fire <- time.Now()
	})
	w := yielded.ShellWait
	if w == nil || w.EndedBy != api.ShellWaitHandleYielded || w.Spawned.IsZero() {
		t.Fatalf("yield record %+v", w)
	}
	if w.WaitStarted.Before(before) || w.WaitEnded.Before(w.WaitStarted) || w.Spawned.After(w.WaitEnded) {
		t.Errorf("yield instants %+v", w)
	}
	var env struct {
		Handle string `json:"handle"`
	}
	if err := json.Unmarshal([]byte(yielded.Text), &env); err != nil || env.Handle == "" {
		t.Fatalf("yield text %q %v", yielded.Text, err)
	}

	bound := shellWaitOf(t, tl, map[string]any{"handle": env.Handle}, func() {
		clock.next(t, "bound", 30*time.Second).fire <- time.Now()
	})
	if b := bound.ShellWait; b == nil || b.EndedBy != api.ShellWaitBound || !b.Spawned.Equal(w.Spawned) {
		t.Fatalf("bound record %+v", b)
	}

	release := shellWaitOf(t, tl, map[string]any{"handle": env.Handle}, func() {
		clock.next(t, "release", 30*time.Second)
		if err := os.WriteFile(filepath.Join(root, "release"), nil, 0o600); err != nil {
			t.Error(err)
		}
	})
	if r := release.ShellWait; r == nil || r.EndedBy != api.ShellWaitExit || !r.Spawned.Equal(w.Spawned) {
		t.Fatalf("release record %+v", r)
	}
	again := shellWaitOf(t, tl, map[string]any{"handle": env.Handle}, func() { clock.next(t, "again", 30*time.Second) })
	if a := again.ShellWait; a == nil || a.EndedBy != api.ShellWaitExit || !a.Spawned.Equal(w.Spawned) {
		t.Fatalf("repeated retrieval record %+v", a)
	}

	exit := shellWaitOf(t, tl, map[string]any{"command": "exit 3"}, func() { clock.next(t, "exit", 45*time.Second) })
	if e := exit.ShellWait; e == nil || e.EndedBy != api.ShellWaitExit || e.Spawned.IsZero() || exit.Text != "exit status: 3\n" {
		t.Fatalf("exit record %+v %q", e, exit.Text)
	}
	refused := shellWaitOf(t, tl, map[string]any{"command": "pkill -f nothing-at-all"}, func() { clock.next(t, "refused", 45*time.Second) })
	if r := refused.ShellWait; r == nil || r.EndedBy != api.ShellWaitExit || !r.Spawned.IsZero() || refused.ErrorKind != api.ToolErrorForeignKill {
		t.Fatalf("refused record %+v %q", r, refused.ErrorKind)
	}

	for name, args := range map[string]map[string]any{
		"unknown":   {"handle": "no-such-handle"},
		"malformed": {},
	} {
		got, err := tl.RunClassified(context.Background(), ShellTool, args)
		if err != nil || got.ShellWait != nil {
			t.Errorf("%s: record %+v %v", name, got.ShellWait, err)
		}
	}
}

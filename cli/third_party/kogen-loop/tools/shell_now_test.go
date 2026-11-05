package tools

import (
	"context"
	"testing"
	"time"

	"github.com/KogenAI/kogen-loop/sys"
)

// The shell-wait record's wait instants read Now when it is set, and time.Now when it is nil.
func TestShellWaitInstantsReadNow(t *testing.T) {
	t.Parallel()
	args := map[string]any{"command": "pkill -f nothing-at-all"}
	at := time.Date(2026, 11, 5, 10, 0, 1, 400_000_000, time.UTC)
	tl := &Tools{Root: t.TempDir(), Session: sys.New(), Enabled: []string{ShellTool}, Now: func() time.Time { return at }}
	got, err := tl.RunClassified(context.Background(), ShellTool, args)
	if err != nil || got.ShellWait == nil {
		t.Fatalf("%+v %v", got, err)
	}
	if !got.ShellWait.WaitStarted.Equal(at) || !got.ShellWait.WaitEnded.Equal(at) {
		t.Errorf("wait instants %v %v, want %v", got.ShellWait.WaitStarted, got.ShellWait.WaitEnded, at)
	}

	tl = &Tools{Root: t.TempDir(), Session: sys.New(), Enabled: []string{ShellTool}}
	before := time.Now()
	got, err = tl.RunClassified(context.Background(), ShellTool, args)
	after := time.Now()
	if err != nil || got.ShellWait == nil {
		t.Fatalf("%+v %v", got, err)
	}
	for _, w := range []time.Time{got.ShellWait.WaitStarted, got.ShellWait.WaitEnded} {
		if w.Before(before) || w.After(after) {
			t.Errorf("nil Now: instant %v outside %v..%v", w, before, after)
		}
	}
}

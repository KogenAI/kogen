package claudecode

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// preflightFakeStart is shell text the fake claude runs first, before its background child and
// before it writes ready. Empty by default; an acceptance overlay sets it to delay or prevent the
// preflight's start.
var preflightFakeStart string

// Preflight launches the installed executable too: its children must not outlive
// cancellation or an early exit, even when they close their inherited output.
func TestPreflightStopsOwnedChildren(t *testing.T) {
	for _, cancelRun := range []bool{false, true} {
		name := "early_exit"
		if cancelRun {
			name = "cancelled"
		}
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			ready, effect := filepath.Join(dir, "ready"), filepath.Join(dir, "effect")
			binary := filepath.Join(dir, "claude")
			script := "#!/bin/sh\n" + preflightFakeStart + "(sleep 0.5; echo survived > \"$2\") >/dev/null 2>&1 &\necho ready > \"$1\"\n"
			if cancelRun {
				script += "wait\n"
			} else {
				script += "echo '2.1.312 (Claude Code)'\n"
			}
			if err := os.WriteFile(binary, []byte(script), 0o700); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			a := New(Options{}).(*adapter)
			done := make(chan error, 1)
			go func() {
				_, err := a.run(ctx, binary, nil, "", ready, effect)
				done <- err
			}()
			// Wait on the preflight's own start (ready) or its end, not a wall-clock bound.
			var err error
			returned := false
			for !returned {
				if _, statErr := os.Stat(ready); statErr == nil {
					break
				}
				select {
				case err = <-done:
					returned = true
				case <-time.After(5 * time.Millisecond):
				}
			}
			if returned {
				if _, statErr := os.Stat(ready); statErr != nil {
					t.Fatal("preflight did not start")
				}
			}
			if cancelRun {
				cancel()
			}
			if !returned {
				err = <-done
			}
			if cancelRun {
				wantError(t, err, "executor/interrupted")
			} else if err != nil {
				t.Fatal(err)
			}
			time.Sleep(700 * time.Millisecond)
			if _, err := os.Stat(effect); !os.IsNotExist(err) {
				t.Fatalf("preflight child outlived its command: effect stat = %v", err)
			}
		})
	}
}

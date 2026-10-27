package sys

import (
	"bufio"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"syscall"
	"testing"
	"time"
)

// Failed process observation must not postpone the timeout's termination signals.
// Isolate the descriptor limit from the test runner and every other test.
func TestCallerShellBoundObservationFailure(t *testing.T) {
	const helper = "CALLER_SHELL_BOUND_OBSERVATION_HELPER"
	if os.Getenv(helper) != "1" {
		ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestCallerShellBoundObservationFailure$")
		cmd.Env = append(os.Environ(), helper+"=1")
		if output, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("observation-failure helper: %v\n%s", err, output)
		}
		return
	}
	s := session(t)
	t.Cleanup(func() { s.Interrupt("SIGTERM"); Terminate(s.Groups()) })
	pipe := func(name string) *os.File {
		t.Helper()
		path := filepath.Join(s.Cwd, name)
		if err := syscall.Mkfifo(path, 0600); err != nil {
			t.Fatal(err)
		}
		f, err := os.OpenFile(path, os.O_RDWR, 0600)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { f.Close() })
		return f
	}
	ready, term := pipe("ready"), pipe("term")
	events := func(f *os.File) <-chan bool {
		ch := make(chan bool, 1)
		go func() { ch <- bufio.NewScanner(f).Scan() }()
		return ch
	}
	readyEvent, termEvent := events(ready), events(term)
	type outcome struct {
		result Result
		err    error
	}
	done := make(chan outcome, 1)
	go func() {
		r, err := s.Run(`trap 'echo term > term; exit 0' TERM; echo ready > ready; sleep 30 & wait`, s.Cwd, Options{Timeout: time.Second})
		done <- outcome{r, err}
	}()
	select {
	case ok := <-readyEvent:
		if !ok {
			t.Fatal("readiness stream ended")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("no readiness event")
	}
	var old syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &old); err != nil {
		t.Fatal(err)
	}
	low := old
	low.Cur = 0
	if err := syscall.Setrlimit(syscall.RLIMIT_NOFILE, &low); err != nil {
		t.Fatal(err)
	}
	// Restore even if this helper fails; the shell inherited the original limit,
	// so its trap can still report the signal through the already-open FIFO.
	defer syscall.Setrlimit(syscall.RLIMIT_NOFILE, &old)
	observed := false
	select {
	case observed = <-termEvent:
	case <-time.After(3 * time.Second):
	}
	if !observed {
		t.Fatal("timeout withheld SIGTERM while process observation failed")
	}
	select {
	case got := <-done:
		if runtime.GOOS == "darwin" {
			if got.err != nil || !got.result.TimedOut || got.result.Status != 0 {
				t.Fatalf("Run = %+v, %v", got.result, got.err)
			}
		} else if !errors.Is(got.err, ErrTimeoutObservation) || got.result != (Result{}) {
			t.Fatalf("Run = %+v, %v", got.result, got.err)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("timeout did not return while observation fault persisted")
	}
}

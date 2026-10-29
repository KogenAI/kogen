package sys

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func readPidFile(t *testing.T, path string) int {
	t.Helper()
	for deadline := time.Now().Add(20 * time.Second); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
		if data, err := os.ReadFile(path); err == nil && strings.HasSuffix(string(data), "\n") {
			if pid, err := strconv.Atoi(strings.TrimSpace(string(data))); err == nil {
				return pid
			}
		}
	}
	t.Fatalf("%s never appeared", path)
	return 0
}

func TestRunContextDoneStartsNothing(t *testing.T) {
	s := session(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r, err := s.RunContext(ctx, "echo started > started", s.Cwd, Options{})
	if !errors.Is(err, context.Canceled) || r != (Result{}) {
		t.Fatalf("%+v %v", r, err)
	}
	if _, err := os.Stat(filepath.Join(s.Cwd, "started")); err == nil {
		t.Error("a command started under a done context")
	}
	if len(s.Groups()) != 0 {
		t.Errorf("groups %v", s.Groups())
	}
}

func TestRunContextStopsAndJoinsARunningGroup(t *testing.T) {
	s := session(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	type outcome struct {
		r   Result
		err error
	}
	done := make(chan outcome, 1)
	go func() {
		r, err := s.RunContext(ctx, `sleep 600 & echo $! > pid; wait`, s.Cwd, Options{})
		done <- outcome{r, err}
	}()
	pid := readPidFile(t, filepath.Join(s.Cwd, "pid"))
	t.Cleanup(func() { syscall.Kill(pid, syscall.SIGKILL) })
	cancel()
	select {
	case got := <-done:
		if !errors.Is(got.err, context.Canceled) || got.r != (Result{}) {
			t.Fatalf("%+v", got)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("RunContext did not return after its context ended")
	}
	// The group's stop was joined before the return: nothing of it is left to race.
	for _, g := range s.Groups() {
		if err := syscall.Kill(-g, 0); err != syscall.ESRCH {
			// Only unreaped zombies may remain.
			if data, rerr := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat"); rerr == nil && !strings.Contains(string(data), ") Z ") {
				t.Errorf("group %d still has a live member: %v", g, err)
			}
		}
	}
}

func TestLiveGroupsAndRetireKeepALeftoverGroup(t *testing.T) {
	s := session(t)
	if r, err := s.Run(`true`, s.Cwd, Options{}); err != nil || r.Status != 0 {
		t.Fatalf("%+v %v", r, err)
	}
	if len(s.Groups()) != 1 || len(s.LiveGroups()) != 0 {
		t.Fatalf("an empty group stays live: groups %v live %v", s.Groups(), s.LiveGroups())
	}
	if _, err := s.Run(`sleep 600 >/dev/null 2>&1 & echo $! > pid`, s.Cwd, Options{}); err != nil {
		t.Fatal(err)
	}
	pid := readPidFile(t, filepath.Join(s.Cwd, "pid"))
	t.Cleanup(func() { syscall.Kill(pid, syscall.SIGKILL) })
	live := s.LiveGroups()
	if len(live) != 1 {
		t.Fatalf("the leftover group is not live: %v", live)
	}
	Terminate(live)
	s.Retire(live)
	for deadline := time.Now().Add(10 * time.Second); syscall.Kill(pid, 0) == nil; time.Sleep(20 * time.Millisecond) {
		if data, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat"); err == nil && strings.Contains(string(data), ") Z ") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the leftover process survived Terminate")
		}
	}
}

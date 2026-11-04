package consumes

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"

	"kogen-loop/sys"
)

func run(t *testing.T, f *fixture, command string, opts sys.Options) sys.Result {
	t.Helper()
	res, err := f.s.Run(command, f.dir, opts)
	if err != nil {
		t.Fatalf("Run(%q): %v", command, err)
	}
	return res
}

// alive is whether the process or, for a negative number, the process group exists.
func alive(pid int) bool { return syscall.Kill(pid, 0) == nil }

// recorded is what a command of the fixture wrote to the file name in its directory, which is how
// the tests observe a command: kogen looks at Status only.
func recorded(t *testing.T, f *fixture, name string) string {
	t.Helper()
	return strings.TrimSpace(readFile(t, filepath.Join(f.dir, name)))
}

// TestRunReturnsTheExitStatus: Run runs `/bin/sh -c command` in the directory it is given and
// returns its exit status, which readiness compares with 0 for each bundled tool. A command killed by
// a signal has status 128 plus the signal, one that is not found 127.
func TestRunReturnsTheExitStatus(t *testing.T) {
	f := newFixture(t)
	for _, c := range []struct {
		command string
		status  int
	}{
		{"exit 0", 0},
		{"echo out; echo err >&2", 0},
		{"exit 3", 3},
		{"kill -TERM $$", 128 + int(syscall.SIGTERM)},
		{"definitely-not-a-kogen-command", 127},
	} {
		if res := run(t, f, c.command, sys.Options{}); res.Status != c.status {
			t.Fatalf("Run(%q) status = %d, want %d", c.command, res.Status, c.status)
		}
	}
	run(t, f, "pwd -P > cwd", sys.Options{})
	dir, err := filepath.EvalSymlinks(recorded(t, f, "cwd"))
	if err != nil || dir != f.dir {
		t.Fatalf("the command ran in %q (%v), want %q", dir, err, f.dir)
	}
}

// TestRunOptionsEnvAddsToTheCallersEnvironment: Options.Env adds variables to the session's own
// environment for the command (readiness passes KOGEN_NODE, KOGEN_QUINT and KOGEN_CUCUMBER).
func TestRunOptionsEnvAddsToTheCallersEnvironment(t *testing.T) {
	f := newFixture(t, "KOGEN_SEEN=session")
	res := run(t, f, `printf '%s|%s|%s' "$KOGEN_SEEN" "$KOGEN_ADDED" "$HOME" > env`, sys.Options{Env: map[string]string{"KOGEN_ADDED": "option"}})
	if got := recorded(t, f, "env"); res.Status != 0 || got != "session|option|"+f.home {
		t.Fatalf("status %d, environment %q", res.Status, got)
	}
}

// TestRunStartsCommandsUnderTheSupervisor: with the supervisor enabled and sys.MaybeSupervise
// called first in the process's main, as kogen's main does and TestMain here, a command's shell
// is not a child of this process: a supervisor of this binary leads the command's process group
// and is its parent, and Groups names that group.
func TestRunStartsCommandsUnderTheSupervisor(t *testing.T) {
	f := newFixture(t)
	res := run(t, f, "echo $PPID > ppid", sys.Options{})
	ppid, err := strconv.Atoi(recorded(t, f, "ppid"))
	if err != nil || res.Status != 0 {
		t.Fatalf("status %d, parent %v", res.Status, err)
	}
	if ppid == os.Getpid() {
		t.Fatalf("the shell is a direct child of this process: no supervisor")
	}
	if groups := f.s.Groups(); len(groups) != 1 || groups[0] != ppid {
		t.Fatalf("Groups = %v, want the supervisor's group %d", groups, ppid)
	}
}

// TestMaybeSuperviseIgnoresOtherCommandLines: MaybeSupervise returns without effect unless the
// command line starts with the supervisor's hidden argument and a command, so kogen's main can
// call it first on every invocation.
func TestMaybeSuperviseIgnoresOtherCommandLines(t *testing.T) {
	for _, args := range [][]string{nil, {}, {"version"}, {"intent", "build", "my-feature"}, {"__kogen_supervise"}} {
		sys.MaybeSupervise(args)
	}
}

// TestGroupsAndTerminateStopWhatACommandLeftBehind: a command that leaves a background process
// in its group keeps the group alive after Run returns; kogen's runEngine ends every invocation
// with sys.Terminate(s.Groups()), which stops that process and returns only when the group has no
// member left. Terminating a group that is already gone is harmless.
func TestGroupsAndTerminateStopWhatACommandLeftBehind(t *testing.T) {
	f := newFixture(t)
	res := run(t, f, "sleep 600 >/dev/null 2>&1 & echo $! > pid", sys.Options{})
	pid, err := strconv.Atoi(recorded(t, f, "pid"))
	if err != nil || res.Status != 0 {
		t.Fatalf("status %d, pid %v", res.Status, err)
	}
	groups := f.s.Groups()
	t.Cleanup(func() { sys.Terminate(groups) })
	if len(groups) != 1 || !alive(pid) {
		t.Fatalf("Groups = %v, background process %d alive %v", groups, pid, alive(pid))
	}
	sys.Terminate(f.s.Groups())
	if alive(-groups[0]) {
		t.Fatalf("the group %d still has members", groups[0])
	}
	sys.Terminate(f.s.Groups())
	sys.Terminate(nil)
}

// TestRunOptionsKillGroupOnExitStopsTheCommandsGroup: with KillGroupOnExit the group is swept
// when the command's leader has ended, so a background process does not outlive Run, and Status
// is the command's.
func TestRunOptionsKillGroupOnExitStopsTheCommandsGroup(t *testing.T) {
	f := newFixture(t)
	res := run(t, f, "sleep 600 >/dev/null 2>&1 & echo $! > pid; exit 2", sys.Options{KillGroupOnExit: true})
	pid, err := strconv.Atoi(recorded(t, f, "pid"))
	if err != nil || res.Status != 2 {
		t.Fatalf("status %d, pid %v", res.Status, err)
	}
	if alive(pid) {
		syscall.Kill(pid, syscall.SIGKILL)
		t.Fatalf("background process %d outlived Run with KillGroupOnExit", pid)
	}
}

// TestRunAfterAnInterruptStartsNothing: once the caller has interrupted, Run returns an
// *sys.Interrupted with its exit code and does not start the command.
func TestRunAfterAnInterruptStartsNothing(t *testing.T) {
	f := newFixture(t)
	interrupt(t, f.s, syscall.SIGTERM)
	marker := filepath.Join(f.dir, "started")
	_, err := f.s.Run("touch "+marker, f.dir, sys.Options{})
	if !isInterrupted(err, 143) {
		t.Fatalf("Run after an interrupt returned %v (%T), want *sys.Interrupted with exit 143", err, err)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatalf("the command started after the interrupt")
	}
}

// TestRunInterruptedWhileRunningReturnsTheInterruptAndTerminateStopsTheCommand: an interrupt while
// a command runs ends Run with *sys.Interrupted, and sys.Terminate(s.Groups()) leaves nothing of
// the command running.
func TestRunInterruptedWhileRunningReturnsTheInterruptAndTerminateStopsTheCommand(t *testing.T) {
	f := newFixture(t)
	fifo := filepath.Join(f.dir, "up")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		_, err := f.s.Run("echo up > up; sleep 600", f.dir, sys.Options{})
		done <- err
	}()
	// Reading the fifo returns once the command has started and written to it.
	file, err := os.Open(fifo)
	if err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 3)
	if _, err := io.ReadFull(file, buf); err != nil || string(buf) != "up\n" {
		t.Fatalf("read %q (%v) from the running command", buf, err)
	}
	file.Close()
	groups := f.s.Groups()
	t.Cleanup(func() { sys.Terminate(groups) })
	interrupt(t, f.s, syscall.SIGINT)
	if err := <-done; !isInterrupted(err, 130) {
		var in *sys.Interrupted
		t.Fatalf("Run returned %v (%T, interrupted %v), want *sys.Interrupted with exit 130", err, err, errors.As(err, &in))
	}
	sys.Terminate(f.s.Groups())
	for _, g := range groups {
		if alive(-g) {
			t.Fatalf("group %d still has members after Terminate", g)
		}
	}
}

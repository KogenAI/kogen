package contract_test

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/KogenAI/kogen-loop/sys"
)

// TestErrorLine pins the error line `<class>/<reason>: <detail>` and its `\n` form.
// Adapted from kogen-coordinator project/intent_test.go and git/helper_test.go.
func TestErrorLine(t *testing.T) {
	e := sys.Fail("intent", "not_found", "Intent does not exist", 3)
	if e.Class != "intent" || e.Reason != "not_found" || e.Detail != "Intent does not exist" || e.Exit != 3 || e.Lines != nil {
		t.Fatalf("Fail = %+v", e)
	}
	if got := e.Error(); got != "intent/not_found: Intent does not exist" {
		t.Fatalf("Error() = %q", got)
	}
	if got := e.Render(); got != "intent/not_found: Intent does not exist\n" {
		t.Fatalf("Render() = %q", got)
	}
}

// TestErrorRenderLines pins the indented detail lines of Render.
// Adapted from kogen-coordinator project/config_test.go and kogen-shaping shape/approve_test.go.
func TestErrorRenderLines(t *testing.T) {
	e := &sys.Error{Class: "environment", Reason: "x", Detail: "d", Lines: []string{"l1"}, Exit: 2}
	if got := e.Render(); got != "environment/x: d\n  l1\n" {
		t.Fatalf("Render() = %q", got)
	}
	e.Lines = []string{"l1", "l2"}
	if got := e.Render(); got != "environment/x: d\n  l1\n  l2\n" {
		t.Fatalf("Render() = %q", got)
	}
	if got := e.Error(); got != "environment/x: d" {
		t.Fatalf("Error() = %q: detail lines are not part of the error line", got)
	}
}

// TestErrorProviderFailure pins the allowlisted provider diagnostics an error carries.
// Adapted from kogen-shaping shape/refine_test.go and kogen-build build/stop.go.
func TestErrorProviderFailure(t *testing.T) {
	e := &sys.Error{Class: "provider", Reason: "unavailable", Detail: "d", Exit: 4, ProviderFailure: map[string]any{"status": 503, "request_id": "req-1"}}
	if e.ProviderFailure["status"] != 503 || e.ProviderFailure["request_id"] != "req-1" || len(e.ProviderFailure) != 2 {
		t.Fatalf("ProviderFailure = %v", e.ProviderFailure)
	}
	if got := e.Render(); got != "provider/unavailable: d\n" {
		t.Fatalf("Render() = %q: provider diagnostics are not printed", got)
	}
}

// TestAsErrorFindsTheErrorInAChain pins AsError on a wrapped and a foreign error.
// Adapted from kogen-executor agent/budget_test.go and kogen-coordinator git/lock_test.go.
func TestAsErrorFindsTheErrorInAChain(t *testing.T) {
	inner := sys.Fail("provider", "unavailable", "ChatGPT response wait exceeded 30 minutes", 4)
	got, ok := sys.AsError(fmt.Errorf("round: %w", inner))
	if !ok || got != inner || got.Exit != 4 {
		t.Fatalf("AsError(wrapped) = %v, %v", got, ok)
	}
	if got, ok := sys.AsError(errors.New("plain")); ok || got != nil {
		t.Fatalf("AsError(plain) = %v, %v", got, ok)
	}
	if got, ok := sys.AsError(nil); ok || got != nil {
		t.Fatalf("AsError(nil) = %v, %v", got, ok)
	}
}

// TestInterruptedExitCodes pins the exit code of an interrupt by the signal that caused it.
// Adapted from kogen-shaping shape/shape_test.go (exit 130) and kogen-build build/executor_test.go.
func TestInterruptedExitCodes(t *testing.T) {
	for _, c := range []struct {
		signal string
		exit   int
	}{{"SIGINT", 130}, {"SIGTERM", 143}, {"SIGHUP", 129}} {
		in := &sys.Interrupted{Signal: c.signal}
		if in.Signal != c.signal || in.ExitCode() != c.exit || in.Error() != "interrupted by "+c.signal {
			t.Errorf("%s: exit %d, %q", c.signal, in.ExitCode(), in.Error())
		}
	}
}

// TestSessionInterruptRecordsTheFirstSignal pins Interrupt, Err and Context.
// Adapted from kogen-verification verify/interrupt_test.go and kogen-shaping shape/batch_test.go.
func TestSessionInterruptRecordsTheFirstSignal(t *testing.T) {
	s, _, _ := newSession(t)
	if s.Err() != nil || s.Context().Err() != nil {
		t.Fatalf("a new session is interrupted: %v", s.Err())
	}
	if !s.Interrupt("SIGTERM") {
		t.Fatal("the first interrupt did not count")
	}
	var in *sys.Interrupted
	if err := s.Err(); !errors.As(err, &in) || in.Signal != "SIGTERM" || in.ExitCode() != 143 {
		t.Fatalf("Err() = %v", err)
	}
	if s.Context().Err() == nil {
		t.Fatal("the session context is not cancelled")
	}
	if s.Interrupt("SIGINT") {
		t.Fatal("a second interrupt counted")
	}
	if err := s.Err(); !errors.As(err, &in) || in.Signal != "SIGTERM" {
		t.Fatalf("Err() after a second interrupt = %v", err)
	}
}

// TestSessionWatchSignalsTurnsASignalIntoAnInterrupt pins WatchSignals on a signal sent to
// this process. Adapted from kogen cli/engine.go, which watches signals for the whole run.
func TestSessionWatchSignalsTurnsASignalIntoAnInterrupt(t *testing.T) {
	s, _, _ := newSession(t)
	stop := s.WatchSignals()
	if err := syscall.Kill(os.Getpid(), syscall.SIGHUP); err != nil {
		stop()
		t.Fatal(err)
	}
	select {
	case <-s.Context().Done():
	case <-time.After(10 * time.Second):
		stop()
		t.Fatal("SIGHUP did not interrupt the session")
	}
	stop()
	var in *sys.Interrupted
	if err := s.Err(); !errors.As(err, &in) || in.Signal != "SIGHUP" || in.ExitCode() != 129 {
		t.Fatalf("Err() = %v", err)
	}
}

// TestSessionOutputAndEnvironment pins the writers and the explicit environment of NewWith.
// Adapted from kogen-build build/helper_test.go and kogen-shaping shape/helper_test.go.
func TestSessionOutputAndEnvironment(t *testing.T) {
	var out, errs bytes.Buffer
	s := sys.NewWith([]string{"A=1", "B=two", "A=3", "EMPTY="}, "/some/dir")
	s.Stdout, s.Stderr = &out, &errs
	if s.Cwd != "/some/dir" || len(s.Env) != 4 {
		t.Fatalf("Cwd %q Env %v", s.Cwd, s.Env)
	}
	if s.Getenv("A") != "3" || s.Getenv("B") != "two" || s.Getenv("MISSING") != "" {
		t.Fatalf("Getenv: A=%q B=%q", s.Getenv("A"), s.Getenv("B"))
	}
	if v, ok := s.LookupEnv("EMPTY"); !ok || v != "" {
		t.Fatalf("LookupEnv(EMPTY) = %q, %v", v, ok)
	}
	if v, ok := s.LookupEnv("MISSING"); ok || v != "" {
		t.Fatalf("LookupEnv(MISSING) = %q, %v", v, ok)
	}
	s.Out("no newline")
	s.Puts("line")
	s.Progress("working")
	s.Debug("hidden")
	if out.String() != "no newline"+"line\n" || errs.String() != "working\n" {
		t.Fatalf("stdout %q stderr %q", out.String(), errs.String())
	}
	d := sys.NewWith([]string{"KOGEN_LOG_LEVEL=debug"}, "/")
	d.Stderr = &errs
	d.Debug("shown")
	if errs.String() != "working\n[debug] shown\n" {
		t.Fatalf("stderr %q", errs.String())
	}
}

// TestNewTakesTheProcessEnvironment pins New: this process's environment and directory.
// Adapted from kogen cli/engine.go and kogen-verification features/steps/probetrust.go.
func TestNewTakesTheProcessEnvironment(t *testing.T) {
	s := sys.New()
	cwd, _ := os.Getwd()
	if s.Cwd != cwd || len(s.Env) != len(os.Environ()) || s.Getenv("PATH") != os.Getenv("PATH") {
		t.Fatalf("Cwd %q (want %q), %d variables (want %d)", s.Cwd, cwd, len(s.Env), len(os.Environ()))
	}
	if s.Stdout != os.Stdout || s.Stderr != os.Stderr {
		t.Fatal("New does not write to the process's standard streams")
	}
}

// TestRunStatusOutputEnv pins the result of a command: status, combined output, added environment.
// Adapted from kogen-shaping shape/init.go and kogen-build build/baseline.go (through their tests).
func TestRunStatusOutputEnv(t *testing.T) {
	t.Parallel()
	s := sys.NewWith(hermeticEnv(t.TempDir(), "A=1", "A=3"), t.TempDir())
	r, err := s.Run(`printf "$A-$X"; echo err >&2; exit 7`, s.Cwd, sys.Options{Env: map[string]string{"X": "x"}})
	if err != nil || r.Status != 7 || r.Output != "3-xerr\n" || r.TimedOut || r.Rule != "" {
		t.Fatalf("Run = %+v, %v", r, err)
	}
	r, err = s.Run("pwd -P; read x; echo \"read=$?\"", s.Cwd, sys.Options{})
	want, _ := filepath.EvalSymlinks(s.Cwd)
	if err != nil || r.Status != 0 || r.Output != want+"\nread=1\n" {
		t.Fatalf("Run in dir = %+v, %v (standard input must be closed)", r, err)
	}
}

// TestRunStartsEachCommandInItsOwnGroupUnderTheSupervisor pins EnableSupervisor and
// MaybeSupervise as consumers use them: a command's parent is this executable run as the
// supervisor, and its group is the one the session reports. Adapted from kogen cli/main.go
// and kogen-loop's own sys tests.
func TestRunStartsEachCommandInItsOwnGroupUnderTheSupervisor(t *testing.T) {
	t.Parallel()
	sys.EnableSupervisor()                                     // already on (TestMain); calling it again changes nothing
	sys.MaybeSupervise([]string{"not-the-supervise-argument"}) // returns: only SuperviseArg makes it the supervisor
	s, _, _ := newSession(t)
	r, err := s.Run(`ps -o pgid= -p $$; ps -o args= -p $PPID`, s.Cwd, sys.Options{})
	if err != nil || r.Status != 0 {
		t.Fatalf("Run = %+v, %v", r, err)
	}
	lines := strings.Split(strings.TrimSpace(r.Output), "\n")
	groups := s.Groups()
	if len(lines) != 2 || len(groups) != 1 || strings.TrimSpace(lines[0]) != fmt.Sprint(groups[0]) || groups[0] == syscall.Getpgrp() {
		t.Fatalf("output %q, groups %v, own group %d", r.Output, groups, syscall.Getpgrp())
	}
	if !strings.Contains(lines[1], sys.SuperviseArg) {
		t.Fatalf("the command's parent is %q, not the supervisor", lines[1])
	}
}

// TestRunTimeout pins Options.Timeout: a command still running at its timeout is stopped and
// reported as timed out with status 143. Adapted from kogen-verification verify/probe_deadline_test.go.
func TestRunTimeout(t *testing.T) {
	t.Parallel()
	s, _, _ := newSession(t)
	start := time.Now()
	r, err := s.Run("sleep 30", s.Cwd, sys.Options{Timeout: 200 * time.Millisecond, Context: context.Background()})
	if err != nil || !r.TimedOut || r.Status != 143 || time.Since(start) > 10*time.Second {
		t.Fatalf("Run = %+v, %v after %v", r, err, time.Since(start))
	}
	if g := s.Groups(); len(g) != 1 {
		t.Fatalf("groups %v", g)
	} else {
		waitGone(t, g[0], "the timed-out command's group")
	}
}

// TestRunTimeoutOptionsContextEndsTheCustodyWait pins Options.Context: a cancelled context ends
// the wait after a timeout fired and Run returns its error, not a timed-out result. Adapted
// from kogen-verification verify/probe_deadline_test.go (TestProbeCancelledContextStopsTheCustodyWait).
func TestRunTimeoutOptionsContextEndsTheCustodyWait(t *testing.T) {
	t.Parallel()
	s, _, _ := newSession(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r, err := s.Run("sleep 30", s.Cwd, sys.Options{Timeout: 100 * time.Millisecond, Context: ctx})
	defer sys.Terminate(s.Groups())
	if !errors.Is(err, context.Canceled) || r.TimedOut {
		t.Fatalf("Run = %+v, %v", r, err)
	}
}

// TestErrTimeoutObservationIsAStoppingError pins the sentinel consumers match with errors.Is.
// Adapted from kogen-verification verify/probe_deadline_test.go and kogen-shaping shape/refine_test.go.
func TestErrTimeoutObservationIsAStoppingError(t *testing.T) {
	err := fmt.Errorf("%w: group 42 still present", sys.ErrTimeoutObservation)
	if !errors.Is(err, sys.ErrTimeoutObservation) || sys.ErrTimeoutObservation.Error() != "timeout custody observation failed" {
		t.Fatalf("%v", err)
	}
	if _, ok := sys.AsError(err); ok {
		t.Fatal("the observation failure is a *sys.Error")
	}
}

// TestRunRefusesAForeignKill pins the refusal of RefuseForeignKill: nothing starts, status 126,
// the refusal text, the rule and no error. Adapted from kogen-verification verify/probe.go.
func TestRunRefusesAForeignKill(t *testing.T) {
	t.Parallel()
	s, _, _ := newSession(t)
	r, err := s.Run("pkill -f x", s.Cwd, sys.Options{RefuseForeignKill: true})
	want := sys.Result{Status: 126, Output: sys.RefusalText("pkill-killall"), Rule: "pkill-killall"}
	if err != nil || r != want {
		t.Fatalf("Run = %+v, %v, want %+v", r, err, want)
	}
	if r.Output == "" || len(s.Groups()) != 0 {
		t.Fatalf("a refused command started: groups %v", s.Groups())
	}
	r, err = s.Run("echo fine", s.Cwd, sys.Options{RefuseForeignKill: true})
	if err != nil || r.Status != 0 || r.Output != "fine\n" || r.Rule != "" {
		t.Fatalf("an ordinary command under RefuseForeignKill = %+v, %v", r, err)
	}
}

// TestRunKillGroupOnExit pins KillGroupOnExit and Terminate: a background process left in the
// command's group is gone when Run returns, and without the option it stays until Terminate
// stops it. Adapted from kogen-verification verify/attempt.go and kogen-coordinator git/commit.go.
func TestRunKillGroupOnExit(t *testing.T) {
	t.Parallel()
	s, _, _ := newSession(t)
	r, err := s.Run("sleep 60 & echo started", s.Cwd, sys.Options{KillGroupOnExit: true})
	groups := s.Groups()
	if err != nil || r.Status != 0 || r.Output != "started\n" || len(groups) != 1 {
		t.Fatalf("Run = %+v, %v, groups %v", r, err, groups)
	}
	// Run returned only once the group had no member, so none may be live now. Whether the
	// host's init has already reaped the swept processes is not part of that guarantee.
	if live := liveMembers(t, groups[0]); len(live) != 0 {
		t.Fatalf("the swept group %d has live members after Run returned: %q", groups[0], live)
	}

	left, _, _ := newSession(t)
	if _, err := left.Run("sleep 60 & echo started", left.Cwd, sys.Options{}); err != nil {
		t.Fatal(err)
	}
	g := left.Groups()
	if len(g) != 1 || syscall.Kill(-g[0], 0) != nil {
		t.Fatalf("without the option the background process should remain: %v", g)
	}
	sys.Terminate(g)
	if live := liveMembers(t, g[0]); len(live) != 0 {
		t.Fatalf("the group %d Terminate stopped has live members after it returned: %q", g[0], live)
	}
}

// liveMembers lists, from one ps listing, the rows of the process group pgid that are not zombie,
// dead or exiting. Those rows are not members that can still run.
func liveMembers(t *testing.T, pgid int) []string {
	t.Helper()
	out, err := exec.Command("ps", "-A", "-o", "pid=,pgid=,stat=").Output()
	if err != nil {
		t.Fatalf("ps -A -o pid=,pgid=,stat=: %v", err)
	}
	var live []string
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 3 || f[1] != strconv.Itoa(pgid) {
			continue
		}
		if strings.ContainsRune("ZXE", rune(f[2][0])) {
			continue
		}
		live = append(live, strings.Join(f, " "))
	}
	return live
}

// groupGone reports whether the process group has no member that can still run, with the error
// kill answered. The group is gone when kill reports ESRCH, or when /proc can be read and every
// member found there is a zombie: on Linux a killed member whose parent has not reaped it stays a
// zombie of the group and kill keeps succeeding. Where /proc cannot be read only ESRCH counts.
func groupGone(pgid int) (bool, error) {
	err := syscall.Kill(-pgid, 0)
	if err == syscall.ESRCH {
		return true, err
	}
	entries, rerr := os.ReadDir("/proc")
	if rerr != nil {
		return false, err
	}
	members := 0
	for _, e := range entries {
		if _, aerr := strconv.Atoi(e.Name()); aerr != nil {
			continue
		}
		state, group, ok := procStat(filepath.Join("/proc", e.Name(), "stat"))
		if !ok || group != pgid {
			continue
		}
		if state != "Z" {
			return false, err
		}
		members++
	}
	return members > 0, err
}

// procStat reads the state and the process group of a proc stat file, which are the first and the
// third field after the last closing parenthesis (the command name may contain one).
func procStat(path string) (state string, group int, ok bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", 0, false
	}
	s := string(b)
	f := strings.Fields(s[strings.LastIndex(s, ")")+1:])
	if len(f) < 3 {
		return "", 0, false
	}
	group, err = strconv.Atoi(f[2])
	if err != nil {
		return "", 0, false
	}
	return f[0], group, true
}

// waitGone waits for the process group to have no member that can still run (kill reports ESRCH,
// or every member is an unreaped zombie). A group that only has members that are ending can still
// answer EPERM or success for a moment on a loaded machine.
func waitGone(t *testing.T, pgid int, what string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		if gone, _ := groupGone(pgid); gone || !time.Now().Before(deadline) {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if gone, err := groupGone(pgid); !gone {
		t.Fatalf("%s remains: %v", what, err)
	}
}

var prctlNumber = map[string]uintptr{"amd64": 157, "arm64": 167, "386": 172, "arm": 172, "riscv64": 167, "loong64": 167, "ppc64le": 171, "s390x": 172}

// The test binary started with KGZ_PARENT=1 is the parent of TestWaitGoneCountsAnUnreapedZombieAsGone:
// it becomes a child subreaper, starts a child in a new process group that exits at once, prints
// the child's pid and then never waits for it.
func init() {
	if os.Getenv("KGZ_PARENT") != "1" {
		return
	}
	if n, ok := prctlNumber[runtime.GOARCH]; ok {
		syscall.RawSyscall(n, 36, 1, 0) // PR_SET_CHILD_SUBREAPER
	}
	child := exec.Command("sh", "-c", "exit 0")
	child.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := child.Start(); err != nil {
		os.Exit(2)
	}
	fmt.Println(child.Process.Pid)
	time.Sleep(time.Minute)
	os.Exit(0)
}

// TestWaitGoneCountsAnUnreapedZombieAsGone pins that a group whose only member is a zombie its
// parent never reaped is gone to waitGone at once instead of failing after its deadline.
func TestWaitGoneCountsAnUnreapedZombieAsGone(t *testing.T) {
	t.Parallel()
	if runtime.GOOS != "linux" {
		t.Skip("an unreaped zombie stays in its process group only on Linux")
	}
	parent := exec.Command(os.Args[0])
	parent.Env = append(os.Environ(), "KGZ_PARENT=1")
	out, err := parent.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := parent.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { parent.Process.Kill(); parent.Wait() })
	line, err := bufio.NewReader(out).ReadString('\n')
	pid, perr := strconv.Atoi(strings.TrimSpace(line))
	if err != nil || perr != nil {
		t.Fatalf("the parent reported %q: %v, %v", line, err, perr)
	}
	statePath := fmt.Sprintf("/proc/%d/stat", pid)
	state, _, _ := procStat(statePath)
	deadline := time.Now().Add(5 * time.Second)
	for state != "Z" && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
		state, _, _ = procStat(statePath)
	}
	if state != "Z" {
		t.Fatalf("member %d is not an unreaped zombie: state %q", pid, state)
	}
	if err := syscall.Kill(-pid, 0); err != nil {
		t.Fatalf("kill with signal 0 on the group of the zombie member %d = %v, want success", pid, err)
	}
	start := time.Now()
	waitGone(t, pid, "the zombie group")
	if d := time.Since(start); d > 2*time.Second {
		t.Fatalf("waitGone took %v for a group whose only member is a zombie", d)
	}
}

// TestWaitGoneFailsWhileAMemberRuns pins that a group with a running member still fails after the
// deadline with the remains message. waitGone fails the test that calls it, so the failing call runs
// in a child test process whose output is checked.
func TestWaitGoneFailsWhileAMemberRuns(t *testing.T) {
	t.Parallel()
	cmd := exec.Command(os.Args[0], "-test.run=^TestWaitGoneRunningMemberChild$")
	cmd.Env = append(os.Environ(), "KGZ_RUNNING=1")
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("waitGone returned without a failure for a group with a running member:\n%s", out)
	}
	if !strings.Contains(string(out), "the running group remains: <nil>") {
		t.Fatalf("waitGone failed without the remains message:\n%s", out)
	}
}

// TestWaitGoneRunningMemberChild is the failing call of TestWaitGoneFailsWhileAMemberRuns; it does
// nothing unless that test started this process.
func TestWaitGoneRunningMemberChild(t *testing.T) {
	if os.Getenv("KGZ_RUNNING") != "1" {
		t.Skip("run by TestWaitGoneFailsWhileAMemberRuns")
	}
	sleeper := exec.Command("sleep", "60")
	sleeper.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := sleeper.Start(); err != nil {
		t.Fatal(err)
	}
	pgid := sleeper.Process.Pid
	t.Cleanup(func() { syscall.Kill(-pgid, syscall.SIGKILL); sleeper.Wait() })
	waitGone(t, pgid, "the running group")
}

// startAndInterrupt runs command in a goroutine, waits for it to write ./ready and then
// interrupts the session with signal; it returns Run's error.
func startAndInterrupt(t *testing.T, s *sys.Session, command string, opts sys.Options, signal string) error {
	t.Helper()
	done := make(chan error, 1)
	go func() { _, err := s.Run(command, s.Cwd, opts); done <- err }()
	deadline := time.After(10 * time.Second)
	for {
		if _, err := os.Stat(filepath.Join(s.Cwd, "ready")); err == nil {
			break
		}
		select {
		case err := <-done:
			t.Fatalf("the command ended before it was ready: %v", err)
		case <-deadline:
			s.Interrupt("SIGINT")
			<-done
			t.Fatal("the command did not become ready")
		case <-time.After(10 * time.Millisecond):
		}
	}
	s.Interrupt(signal)
	return <-done
}

// TestRunInterruptStopsTheCommandAndRefusesLaterOnes pins what an interrupt does to a running
// command and to the next one. Adapted from kogen-verification verify/interrupt_test.go and
// kogen-shaping shape/approve_test.go.
func TestRunInterruptStopsTheCommandAndRefusesLaterOnes(t *testing.T) {
	t.Parallel()
	s, _, _ := newSession(t)
	err := startAndInterrupt(t, s, "echo ready > ready; sleep 30; touch after", sys.Options{}, "SIGINT")
	var in *sys.Interrupted
	if !errors.As(err, &in) || in.Signal != "SIGINT" || in.ExitCode() != 130 {
		t.Fatalf("Run error %v", err)
	}
	if _, err := os.Stat(filepath.Join(s.Cwd, "after")); err == nil {
		t.Fatal("the interrupted command kept running")
	}
	g := s.Groups()
	if len(g) != 1 {
		t.Fatalf("groups %v", g)
	}
	waitGone(t, g[0], "the interrupted group")
	if r, err := s.Run("touch never", s.Cwd, sys.Options{}); !errors.As(err, &in) || r.Output != "" {
		t.Fatalf("Run after an interrupt = %+v, %v", r, err)
	}
	if _, err := os.Stat(filepath.Join(s.Cwd, "never")); err == nil {
		t.Fatal("a command started after the interrupt")
	}
}

// TestRunFinishOnInterruptWaitsForTheCommand pins FinishOnInterrupt: the command ends its own
// way and what it leaves is there when Run returns. Adapted from kogen-coordinator git/commit.go
// (git commit) and kogen-loop's own sys tests.
func TestRunFinishOnInterruptWaitsForTheCommand(t *testing.T) {
	t.Parallel()
	s, _, _ := newSession(t)
	command := `trap 'sleep 0.3; touch trap; exit 1' TERM; echo ready > ready; sleep 30 & wait`
	err := startAndInterrupt(t, s, command, sys.Options{FinishOnInterrupt: true}, "SIGTERM")
	var in *sys.Interrupted
	if !errors.As(err, &in) || in.ExitCode() != 143 {
		t.Fatalf("Run error %v", err)
	}
	if _, err := os.Stat(filepath.Join(s.Cwd, "trap")); err != nil {
		t.Fatalf("Run returned before the command finished: %v", err)
	}
	sys.Terminate(s.Groups())
}

// TestTmpPathIsUnique pins TmpPath: <tmp>/<prefix>-<16 hex>, different on every call.
// Adapted from kogen-coordinator git/snapshot.go and kogen-shaping shape/common.go.
func TestTmpPathIsUnique(t *testing.T) {
	a, b := sys.TmpPath("kogen-contract"), sys.TmpPath("kogen-contract")
	re := regexp.MustCompile(`^` + regexp.QuoteMeta(filepath.Join(os.TempDir(), "kogen-contract-")) + `[0-9a-f]{16}$`)
	if !re.MatchString(a) || !re.MatchString(b) || a == b {
		t.Fatalf("%q and %q", a, b)
	}
}

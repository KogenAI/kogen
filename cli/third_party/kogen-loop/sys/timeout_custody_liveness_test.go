package sys

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// These channels exist only in the test binary built with the observer overlay.
// Keeping the replacement outside production avoids a mutable observer hook.
var custodyObserverEntered = make(chan struct{})
var custodyObserverRelease = make(chan struct{})

var (
	custodyBuildOnce sync.Once
	custodyBuildDir  string
	custodyBuildBin  string
	custodyBuildErr  error
)

func custodyObserverBinary(t *testing.T) string {
	t.Helper()
	custodyBuildOnce.Do(func() {
		custodyBuildBin, custodyBuildErr = buildCustodyObserver()
	})
	if custodyBuildErr != nil {
		t.Fatal(custodyBuildErr)
	}
	return custodyBuildBin
}

func buildCustodyObserver() (string, error) {
	dir, err := os.MkdirTemp("", "custody-observer-")
	if err != nil {
		return "", err
	}
	custodyBuildDir = dir
	source := filepath.Join(dir, "observer.go")
	code := `package sys
import ("errors"; "os")
func timeoutGroupAlive(int) (bool, error) {
 close(custodyObserverEntered)
 <-custodyObserverRelease
 return false, errors.New(os.Getenv("TIMEOUT_CUSTODY_FAULT"))
}
`
	if err := os.WriteFile(source, []byte(code), 0600); err != nil {
		return "", err
	}
	platform := runtime.GOOS
	if platform != "darwin" && platform != "linux" {
		platform = "other"
	}
	original, err := filepath.Abs("timeout_observation_" + platform + ".go")
	if err != nil {
		return "", err
	}
	data, err := json.Marshal(map[string]any{"Replace": map[string]string{original: source}})
	if err != nil {
		return "", err
	}
	overlay := filepath.Join(dir, "overlay.json")
	if err := os.WriteFile(overlay, data, 0600); err != nil {
		return "", err
	}
	binary := filepath.Join(dir, "custody.test")
	if output, err := exec.Command("go", "test", "-c", "-overlay", overlay, "-o", binary, ".").CombinedOutput(); err != nil {
		return "", fmt.Errorf("build observer fixture: %v\n%s", err, output)
	}
	return binary, nil
}

func custodyObserverChild(t *testing.T, binary, name, fault, stop string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, "-test.run=^"+name+"$", "-test.timeout=12s")
	cmd.Env = append(os.Environ(), "TIMEOUT_CUSTODY_HELPER=1", "TIMEOUT_CUSTODY_FAULT="+fault, "TIMEOUT_CUSTODY_STOP="+stop)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("observer fixture: %v\n%s", err, output)
	}
}

func custodyWaitFile(t *testing.T, path string) {
	t.Helper()
	deadline := time.After(3 * time.Second)
	for {
		if _, err := os.Stat(path); err == nil {
			return
		}
		select {
		case <-deadline:
			t.Fatal("no event: " + path)
		case <-time.After(time.Millisecond):
		}
	}
}

// Exercise Run, not a manually started Terminate: a query held unresolved must
// neither postpone its timer's signals nor prevent the caller from stopping.
func TestTimeoutCustodyBlockedObservation(t *testing.T) {
	if os.Getenv("TIMEOUT_CUSTODY_HELPER") != "1" {
		binary := custodyObserverBinary(t)
		for _, stop := range []string{"context", "interrupt"} {
			t.Run(stop, func(t *testing.T) {
				t.Parallel()
				custodyObserverChild(t, binary, "TestTimeoutCustodyBlockedObservation", "blocked query", stop)
			})
		}
		return
	}
	// Keep the fixture's single shell directly parented here, with no supervisor
	// or orphan descendants. Only this disposable child changes the setting.
	supervisorEnabled.Store(false)
	s := session(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	type outcome struct {
		result Result
		err    error
	}
	done := make(chan outcome, 1)
	go func() {
		r, err := s.Run(`trap 'echo term > term' TERM; echo ready > ready; while :; do :; done`, s.Cwd, Options{Timeout: 200 * time.Millisecond, Context: ctx})
		done <- outcome{r, err}
	}()
	// Failure cleanup kills only this fixture's group, and runs before the child
	// watchdog can exit. Successful runs already observe that group's absence.
	gone := false
	t.Cleanup(func() {
		if !gone {
			for _, g := range s.Groups() {
				syscall.Kill(-g, syscall.SIGKILL)
			}
		}
	})
	custodyWaitFile(t, filepath.Join(s.Cwd, "ready"))
	select {
	case <-custodyObserverEntered:
	case <-time.After(3 * time.Second):
		t.Fatal("observer not entered")
	}
	custodyWaitFile(t, filepath.Join(s.Cwd, "term"))
	pgid := s.Groups()[0]
	if err := syscall.Kill(-pgid, 0); err != nil {
		t.Fatalf("TERM grace was skipped: %v", err)
	}
	select {
	case got := <-done:
		t.Fatalf("unresolved observation returned: %+v", got)
	default:
	}
	if os.Getenv("TIMEOUT_CUSTODY_STOP") == "interrupt" {
		s.Interrupt("SIGINT")
	}
	cancel()
	select {
	case got := <-done:
		if got.result != (Result{}) {
			t.Fatalf("published stopping result: %+v", got.result)
		}
		if os.Getenv("TIMEOUT_CUSTODY_STOP") == "interrupt" {
			var interrupted *Interrupted
			if !errors.As(got.err, &interrupted) || interrupted.Signal != "SIGINT" {
				t.Fatal(got.err)
			}
		} else if got.err != context.Canceled {
			t.Fatal(got.err)
		}
	case <-time.After(time.Second):
		t.Fatal("stop blocked by observation")
	}
	// Do not release the query. Independently observe SIGKILL after Run returned;
	// the builtin infinite loop cannot exit on its trapped SIGTERM.
	deadline := time.After(7 * time.Second)
	for syscall.Kill(-pgid, 0) != syscall.ESRCH {
		select {
		case <-deadline:
			t.Fatal("blocked observation postponed SIGKILL")
		case <-time.After(10 * time.Millisecond):
		}
	}
	gone = true
}

func TestTimeoutCustodyObservationError(t *testing.T) {
	if os.Getenv("TIMEOUT_CUSTODY_HELPER") != "1" {
		binary := custodyObserverBinary(t)
		for _, fault := range []string{"native query failed", "native timeout custody observation unsupported on this platform"} {
			for _, stop := range []string{"", "context", "deadline", "interrupt"} {
				t.Run(fault+"/"+stop, func(t *testing.T) {
					custodyObserverChild(t, binary, "TestTimeoutCustodyObservationError", fault, stop)
				})
			}
		}
		return
	}
	supervisorEnabled.Store(false)
	s := session(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stop := os.Getenv("TIMEOUT_CUSTODY_STOP")
	if stop == "deadline" {
		var deadlineCancel context.CancelFunc
		ctx, deadlineCancel = context.WithTimeout(ctx, 2*time.Second)
		defer deadlineCancel()
	}
	var callCtx context.Context
	if stop != "" {
		callCtx = ctx
	} // the error contract also covers nil Context
	type outcome struct {
		result Result
		err    error
	}
	done := make(chan outcome, 1)
	go func() {
		r, err := s.Run(`trap 'echo term > term; exit 0' TERM; printf partial; while :; do :; done`, s.Cwd, Options{Timeout: 200 * time.Millisecond, Context: callCtx})
		done <- outcome{r, err}
	}()
	t.Cleanup(func() { Terminate(s.Groups()) })
	select {
	case <-custodyObserverEntered:
	case <-time.After(3 * time.Second):
		t.Fatal("observer not entered")
	}
	custodyWaitFile(t, filepath.Join(s.Cwd, "term"))
	if stop == "interrupt" {
		s.Interrupt("SIGINT")
		cancel()
	}
	if stop == "context" {
		cancel()
	}
	if stop == "deadline" {
		<-ctx.Done()
	}
	close(custodyObserverRelease)
	select {
	case got := <-done:
		if got.result != (Result{}) {
			t.Fatalf("error published result: %+v", got.result)
		}
		switch stop {
		case "":
			if !errors.Is(got.err, ErrTimeoutObservation) {
				t.Fatal(got.err)
			}
		case "context":
			if got.err != context.Canceled {
				t.Fatal(got.err)
			}
		case "deadline":
			if got.err != context.DeadlineExceeded {
				t.Fatal(got.err)
			}
		case "interrupt":
			var interrupted *Interrupted
			if !errors.As(got.err, &interrupted) || interrupted.Signal != "SIGINT" {
				t.Fatal(got.err)
			}
		}
	case <-time.After(3 * time.Second):
		t.Fatal("observation failure did not stop Run")
	}
}

func TestTimeoutCustodyMembership(t *testing.T) {
	if target := os.Getenv("TIMEOUT_MOVE_GROUP"); target != "" {
		pgid, _ := strconv.Atoi(target)
		if err := syscall.Setpgid(0, pgid); err != nil {
			os.Exit(2)
		}
		os.Stdout.WriteString("moved\n")
		time.Sleep(30 * time.Second)
		os.Exit(0)
	}
	// An exited but deliberately unreaped child still belongs to its group.
	cmd := exec.Command("true")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer cmd.Wait()
	deadline := time.After(3 * time.Second)
	for {
		out, err := exec.Command("/bin/ps", "-o", "stat=", "-p", strconv.Itoa(cmd.Process.Pid)).Output()
		if err == nil && strings.Contains(string(out), "Z") {
			break
		}
		select {
		case <-deadline:
			t.Fatal("no zombie")
		case <-time.After(time.Millisecond):
		}
	}
	if alive, err := timeoutGroupAlive(cmd.Process.Pid); err != nil || !alive {
		t.Fatalf("zombie: %v %v", alive, err)
	}
	cmd.Wait()
	if alive, err := timeoutGroupAlive(cmd.Process.Pid); err != nil || alive {
		t.Fatalf("reaped: %v %v", alive, err)
	}
	moved := exec.Command(os.Args[0], "-test.run=^TestTimeoutCustodyMembership$")
	moved.Env = append(os.Environ(), "TIMEOUT_MOVE_GROUP="+strconv.Itoa(syscall.Getpgrp()))
	moved.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	r, err := moved.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	if err := moved.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { moved.Process.Kill(); moved.Wait() }()
	ready := make(chan string, 1)
	go func() { b := make([]byte, 6); n, _ := r.Read(b); ready <- string(b[:n]) }()
	select {
	case text := <-ready:
		if text != "moved\n" {
			t.Fatal(text)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("move not ready")
	}
	if err := syscall.Kill(moved.Process.Pid, 0); err != nil {
		t.Fatal(err)
	}
	if alive, err := timeoutGroupAlive(moved.Process.Pid); err != nil || alive {
		t.Fatalf("outside member held custody: %v %v", alive, err)
	}
}

// A dispatched timer whose Stop fails still cannot label ordinary completion as
// timed out unless its callback actually claimed teardown first.
func TestTimeoutCustodyCompletionArbitration(t *testing.T) {
	var ordinary commandLifecycle
	ordinary.complete()
	if ordinary.timeout() || ordinary.timedOut() {
		t.Fatal("late callback stole ordinary completion")
	}
	var expired commandLifecycle
	if !expired.timeout() {
		t.Fatal("timeout did not acquire execution")
	}
	expired.complete()
	if !expired.timedOut() {
		t.Fatal("completion stole timeout teardown")
	}
}

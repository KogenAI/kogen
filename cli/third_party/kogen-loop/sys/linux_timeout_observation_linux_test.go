//go:build linux

package sys

import (
	"os"
	"os/exec"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

func linuxObsKill(c *exec.Cmd) {
	if c.Process != nil && c.ProcessState == nil {
		syscall.Kill(-c.Process.Pid, syscall.SIGKILL)
		c.Process.Kill()
		c.Wait()
	}
}

// linuxObsGroup starts an owned group leader that signals readiness on stdout
// and then waits for stdin to close.
func linuxObsGroup(t *testing.T, script string) *exec.Cmd {
	t.Helper()
	c := exec.Command("/bin/sh", "-c", script)
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	in, err := c.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	out, err := c.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { in.Close(); linuxObsKill(c) })
	ready := make(chan struct{})
	go func() {
		b := make([]byte, 5)
		if n, _ := out.Read(b); string(b[:n]) == "ready" {
			close(ready)
		}
	}()
	select {
	case <-ready:
	case <-time.After(5 * time.Second):
		t.Fatal("owned group not ready")
	}
	return c
}

func linuxObsWaitAbsent(t *testing.T, pgid int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		alive, err := timeoutGroupAlive(pgid)
		if err != nil {
			t.Fatal(err)
		}
		if !alive {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("group still present")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestLinuxTimeoutObservationChurn(t *testing.T) {
	stop := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < 3; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				exec.Command("/bin/true").Run()
			}
		}()
	}
	var calls, errs atomic.Int64
	var first atomic.Value
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		calls.Add(1)
		if _, err := timeoutGroupAlive(1 << 30); err != nil {
			errs.Add(1)
			first.CompareAndSwap(nil, err.Error())
		}
	}
	close(stop)
	wg.Wait()
	if errs.Load() != 0 {
		t.Fatalf("calls=%d errors=%d first=%v", calls.Load(), errs.Load(), first.Load())
	}
	t.Logf("calls=%d errors=%d first=%v", calls.Load(), errs.Load(), first.Load())
}

func TestLinuxTimeoutObservationZombie(t *testing.T) {
	c := exec.Command("/bin/sh", "-c", "exit 0")
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { linuxObsKill(c) })
	pid := c.Process.Pid
	deadline := time.Now().Add(5 * time.Second)
	for {
		data, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
		if err == nil {
			s := string(data)
			if rest := s[lastParen(s)+1:]; len(rest) > 1 && rest[1] == 'Z' {
				break
			}
		}
		if time.Now().After(deadline) {
			t.Fatal("owned child did not become a zombie")
		}
		time.Sleep(time.Millisecond)
	}
	alive, err := timeoutGroupAlive(pid)
	if err != nil || !alive {
		t.Fatalf("held zombie: %v %v", alive, err)
	}
	if err := c.Wait(); err != nil {
		t.Fatal(err)
	}
	linuxObsWaitAbsent(t, pid)
}

func lastParen(s string) int {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == ')' {
			return i
		}
	}
	return -1
}

// TestLinuxTimeoutObservationMovedHelper is the member process of the Moved test.
func TestLinuxTimeoutObservationMovedHelper(t *testing.T) {
	if os.Getenv("LINUX_TIMEOUT_OBSERVATION_MOVER") != "1" {
		t.Skip("helper")
	}
	if err := syscall.Setpgid(0, 0); err != nil {
		t.Fatal(err)
	}
	os.Stdout.WriteString("moved")
	b := make([]byte, 1)
	os.Stdin.Read(b)
}

func TestLinuxTimeoutObservationMoved(t *testing.T) {
	leader := linuxObsGroup(t, "printf ready; read x")
	group := leader.Process.Pid
	member := exec.Command(os.Args[0], "-test.run=^TestLinuxTimeoutObservationMovedHelper$")
	member.Env = append(os.Environ(), "LINUX_TIMEOUT_OBSERVATION_MOVER=1")
	member.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pgid: group}
	in, err := member.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	out, err := member.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := member.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { in.Close(); linuxObsKill(member) })
	moved := make(chan struct{})
	go func() {
		b := make([]byte, 5)
		if n, _ := out.Read(b); string(b[:n]) == "moved" {
			close(moved)
		}
	}()
	select {
	case <-moved:
	case <-time.After(10 * time.Second):
		t.Fatal("member did not move")
	}
	if alive, err := timeoutGroupAlive(group); err != nil || !alive {
		t.Fatalf("leader present: %v %v", alive, err)
	}
	leader.Process.Kill()
	leader.Wait()
	// The live member now belongs to its own group and must not retain the old one.
	linuxObsWaitAbsent(t, group)
	if alive, err := timeoutGroupAlive(member.Process.Pid); err != nil || !alive {
		t.Fatalf("moved member group: %v %v", alive, err)
	}
}

func TestLinuxTimeoutObservationAgreement(t *testing.T) {
	c := linuxObsGroup(t, "printf ready; read x")
	pgid := c.Process.Pid
	a1, e1 := timeoutGroupAlive(pgid)
	a2, e2 := linuxTimeoutGroupAlive(pgid, os.DirFS("/proc"))
	if a1 != a2 || (e1 == nil) != (e2 == nil) {
		t.Fatalf("pgid %d: %v %v vs %v %v", pgid, a1, e1, a2, e2)
	}
	if alive, err := timeoutGroupAlive(pgid); err != nil || !alive {
		t.Fatalf("live: %v %v", alive, err)
	}
}

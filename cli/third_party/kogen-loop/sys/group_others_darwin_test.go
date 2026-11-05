//go:build darwin

package sys

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"testing"
	"time"
)

// TestKernelGroupOthersAnswersFromTheKernel asks about a group with one live member, with
// only an unreaped zombie, and with nobody.
func TestKernelGroupOthersAnswersFromTheKernel(t *testing.T) {
	t.Parallel()
	cmd := exec.Command("/bin/sleep", "600")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	pid := cmd.Process.Pid
	reaped := false
	defer func() {
		if !reaped {
			syscall.Kill(-pid, syscall.SIGKILL)
			cmd.Wait()
		}
	}()
	ask := func(when string, want bool) {
		t.Helper()
		got, err := groupOthers(pid, os.Getpid())
		if err != nil || got != want {
			t.Fatalf("%s: groupOthers = %v, %v; want %v, nil", when, got, err, want)
		}
	}
	ask("live", true)
	syscall.Kill(pid, syscall.SIGKILL)
	deadline := time.Now().Add(10 * time.Second)
	for {
		out, _ := exec.Command("/bin/ps", "-o", "stat=", "-p", fmt.Sprint(pid)).Output()
		if strings.HasPrefix(strings.TrimSpace(string(out)), "Z") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the killed child never became a zombie")
		}
		time.Sleep(5 * time.Millisecond)
	}
	ask("unreaped zombie", false)
	cmd.Wait()
	reaped = true
	ask("reaped", false)
}

// TestKernelGroupOthersExcludesSelf re-runs the test binary as a helper that leads its own
// group: asking with its own pid finds nobody, asking with 0 excludes nobody.
func TestKernelGroupOthersExcludesSelf(t *testing.T) {
	if os.Getenv("KGO_HELPER") != "" {
		alone, err1 := groupOthers(syscall.Getpgrp(), os.Getpid())
		all, err2 := groupOthers(syscall.Getpgrp(), 0)
		fmt.Printf("KGO %v %v %v %v\n", alone, err1, all, err2)
		return
	}
	t.Parallel()
	cmd := exec.Command(os.Args[0], "-test.run=^TestKernelGroupOthersExcludesSelf$", "-test.count=1")
	cmd.Env = append(os.Environ(), "KGO_HELPER=1")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("helper: %v\n%s", err, out)
	}
	if !strings.Contains(string(out), "KGO false <nil> true <nil>\n") {
		t.Fatalf("unexpected helper output:\n%s", out)
	}
}

func TestKernelGroupOthersFailedQueryIsAnError(t *testing.T) {
	t.Parallel()
	sentinel := errors.New("query failed")
	asked := -1
	got, err := kernelGroupOthers(77, 0, func(pgid int) ([]byte, error) {
		asked = pgid
		return nil, sentinel
	})
	if got || !errors.Is(err, sentinel) || asked != 77 {
		t.Fatalf("kernelGroupOthers = %v, %v (asked %d); want false and the query error for 77", got, err, asked)
	}
	if _, err := kernelGroupOthers(77, 0, func(int) ([]byte, error) { return make([]byte, kinfoProcSize+1), nil }); err == nil {
		t.Fatal("a partial record was not an error")
	}
}

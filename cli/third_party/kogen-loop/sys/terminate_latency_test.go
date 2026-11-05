package sys

import (
	"bufio"
	"os/exec"
	"sort"
	"syscall"
	"testing"
	"time"
)

func TestTerminateEndsPromptlyWhenTheGroupExitsOnSIGTERM(t *testing.T) {
	const runs = 5
	took := make([]time.Duration, 0, runs)
	for i := 0; i < runs; i++ {
		cmd := exec.Command("/bin/sh", "-c", "sleep 30 >/dev/null & sleep 30 >/dev/null & echo ready; wait")
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		out, err := cmd.StdoutPipe()
		if err != nil {
			t.Fatal(err)
		}
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		pgid := cmd.Process.Pid
		if line, err := bufio.NewReader(out).ReadString('\n'); err != nil || line != "ready\n" {
			syscall.Kill(-pgid, syscall.SIGKILL)
			t.Fatalf("group did not start: %q %v", line, err)
		}
		go cmd.Wait()
		start := time.Now()
		Terminate([]int{pgid})
		took = append(took, time.Since(start))
		if err := syscall.Kill(-pgid, 0); err != syscall.ESRCH {
			t.Fatalf("group %d is not gone after Terminate: %v", pgid, err)
		}
	}
	sort.Slice(took, func(i, j int) bool { return took[i] < took[j] })
	if median := took[runs/2]; median >= 50*time.Millisecond {
		t.Errorf("median Terminate took %v, want under 50ms (%v)", median, took)
	}
}

func TestBackoffKeepsSleepingTheCapAfterManySteps(t *testing.T) {
	const most = time.Millisecond
	var b backoff
	for i := 1; i <= 100; i++ {
		start := time.Now()
		b.sleep(most, time.Time{})
		if took := time.Since(start); i > 1 && took < most {
			t.Fatalf("sleep %d took %v, want the %v cap", i, took, most)
		}
	}
}

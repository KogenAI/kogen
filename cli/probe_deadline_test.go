package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"kogen/verify"
)

// TestInstalledProbeDeadline is invoked by the acceptance suite's compiled Go test binary
// (SHP-10). It runs the real `kogen intent shape` command in this process against the
// installed root, in the project folder the binary was started in. Only the probe deadline
// is contracted, to 200 ms, after checking that the production deadline is five minutes. No
// timeout result or elapsed time is fabricated: the production probe code stops the
// process group, reports the timeout to the model and removes its scratch folder.
func TestInstalledProbeDeadline(t *testing.T) {
	if os.Getenv("KOGEN_TEST_PROBE_DEADLINE") != "1" {
		return
	}
	root := os.Getenv("KOGEN_TEST_ROOT")
	request, err := os.Open(os.Getenv("KOGEN_TEST_PROBE_REQUEST"))
	if err != nil {
		t.Fatal(err)
	}
	defer request.Close()
	defer func(stdin *os.File) { os.Stdin = stdin }(os.Stdin)
	os.Stdin = request

	var probes []verify.ProbeObservation
	production, restore := verify.ContractProbeDeadline(200*time.Millisecond, func(o verify.ProbeObservation) {
		probes = append(probes, o)
	})
	defer restore()
	if production != 5*time.Minute {
		t.Fatalf("the production probe deadline is %v, want 5m0s", production)
	}

	exit := make(chan int, 1)
	args := []string{"intent", "shape", os.Getenv("KOGEN_TEST_PROBE_SLUG"), "-"}
	go func() { exit <- run(args, func() (string, error) { return root, nil }) }()
	var code int
	select {
	case code = <-exit:
	case <-time.After(45 * time.Second):
		t.Fatal("installed probe deadline driver exceeded 45 seconds")
	}
	if code != 0 || len(probes) != 1 {
		t.Fatalf("shaping exit %d, observed probes %+v", code, probes)
	}
	probe := probes[0]
	if probe.Command != "sleep 600" || probe.Deadline != 200*time.Millisecond {
		t.Fatalf("expected one hanging probe under the contracted deadline: %+v", probe)
	}
	if probe.Group <= 1 || probe.Result.Status == 0 || !probe.Result.TimedOut {
		t.Fatalf("expected genuine timed-out process: group=%d status=%d timed_out=%v", probe.Group, probe.Result.Status, probe.Result.TimedOut)
	}
	// Check before any cleanup, so cleanup cannot hide a broken executor.
	waitForProcessGroupGone(t, probe.Group, 3*time.Second)
	if !filepath.IsAbs(probe.Scratch) || !strings.HasPrefix(filepath.Base(probe.Scratch), "kogen-probe-") {
		t.Fatalf("probe did not use a scratch folder: %q", probe.Scratch)
	}
	if _, err := os.Stat(probe.Scratch); !os.IsNotExist(err) {
		t.Fatalf("probe scratch remains: %s (%v)", probe.Scratch, err)
	}
	receipt, _ := json.Marshal(map[string]any{
		"original_timeout_ms": production.Milliseconds(), "executed_timeout_ms": probe.Deadline.Milliseconds(),
		"command": probe.Command, "scratch": probe.Scratch, "pgid": probe.Group,
		"exec_status": probe.Result.Status, "timed_out": probe.Result.TimedOut,
		"process_group_stopped": true, "scratch_removed": true, "shape_exit": code,
	})
	if err := os.WriteFile(os.Getenv("KOGEN_TEST_PROBE_RECEIPT"), append(receipt, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
}

func waitForProcessGroupGone(t *testing.T, pgid int, timeout time.Duration) {
	t.Helper()
	for deadline := time.Now().Add(timeout); time.Now().Before(deadline); time.Sleep(50 * time.Millisecond) {
		if err := syscall.Kill(-pgid, 0); err != nil {
			return
		}
	}
	syscall.Kill(-pgid, syscall.SIGKILL)
	t.Fatalf("process group %d is still running after %v", pgid, timeout)
}

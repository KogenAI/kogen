package verify

import (
	"context"
	"os"
	"syscall"
	"testing"
	"time"
)

// SHP-10: the production deadline is five minutes; a probe still running at its deadline is
// stopped with its whole process group, reported as timed out, and its scratch folder goes.
func TestProbeDeadlineStopsTheProbeAndReportsTimedOut(t *testing.T) {
	root := t.TempDir()
	var seen []ProbeObservation
	production, restore := ContractProbeDeadline(200*time.Millisecond, func(o ProbeObservation) { seen = append(seen, o) })
	defer restore()
	if production != 5*time.Minute {
		t.Fatalf("production probe deadline = %v, want 5m0s", production)
	}
	r, err := RunProbe(context.Background(), sessionFor(root), root, "sleep 600", nil)
	if err != nil {
		t.Fatal(err)
	}
	if !r.TimedOut || r.Status == 0 {
		t.Fatalf("probe = %+v, want timed out with a failing status", r)
	}
	if len(seen) != 1 || seen[0].Deadline != 200*time.Millisecond || seen[0].Command != "sleep 600" || seen[0].Group <= 1 {
		t.Fatalf("observed probes = %+v", seen)
	}
	if err := syscall.Kill(-seen[0].Group, 0); err == nil {
		t.Fatalf("process group %d of the timed-out probe is still alive", seen[0].Group)
	}
	if _, err := os.Stat(seen[0].Scratch); !os.IsNotExist(err) {
		t.Fatalf("probe scratch remains: %s (%v)", seen[0].Scratch, err)
	}
}

func TestContractedProbeDeadlineIsRestored(t *testing.T) {
	_, restore := ContractProbeDeadline(time.Second, nil)
	restore()
	if probeDeadline != ProbeTimeout || probeObserver != nil {
		t.Fatalf("probe deadline %v after restore, want %v", probeDeadline, ProbeTimeout)
	}
}

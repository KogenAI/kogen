package verify

import (
	"errors"
	"os"
	"testing"

	"kogen/sys"
)

// A verification command that would start after the caller interrupted returns the interrupt
// itself, so the Build exits 130/143/129 rather than reporting an internal "context canceled"
// (spec 04 "Ordinary implementation failures keep repairing until the caller stops it").
func TestACommandAfterTheCallersInterruptReturnsTheInterrupt(t *testing.T) {
	for _, signal := range []string{"SIGINT", "SIGTERM", "SIGHUP"} {
		s := sys.NewWith([]string{"HOME=" + t.TempDir(), "PATH=" + os.Getenv("PATH")}, t.TempDir())
		s.Interrupt(signal)
		_, err := run(s.Context(), s, Tools{}, "echo never", s.Cwd, nil)
		var in *sys.Interrupted
		if !errors.As(err, &in) || in.Signal != signal {
			t.Fatalf("%s: got %v, want the interrupt", signal, err)
		}
	}
}

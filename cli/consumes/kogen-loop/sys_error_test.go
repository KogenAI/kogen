package consumes

import (
	"errors"
	"fmt"
	"syscall"
	"testing"

	"github.com/KogenAI/kogen-loop/sys"
)

// TestFailIsAnErrorWithItsExitAndDetail: sys.Fail(class, reason, detail, exit) is the error kogen
// raises for its own refusals (cli/main.go): an *sys.Error with that Detail and Exit, rendered
// as `class/reason: detail` and one line, and usable as an error.
func TestFailIsAnErrorWithItsExitAndDetail(t *testing.T) {
	e := sys.Fail("intent", "invalid_slug", "Slug must be 3 to 48 characters.", 2)
	var err error = e
	if e.Detail != "Slug must be 3 to 48 characters." || e.Exit != 2 || len(e.Lines) != 0 {
		t.Fatalf("Detail %q, Exit %d, Lines %q", e.Detail, e.Exit, e.Lines)
	}
	if got := e.Render(); got != "intent/invalid_slug: Slug must be 3 to 48 characters.\n" {
		t.Fatalf("Render = %q", got)
	}
	if got := err.Error(); got != "intent/invalid_slug: Slug must be 3 to 48 characters." {
		t.Fatalf("Error = %q", got)
	}
}

// TestRenderPrintsTheDetailLinesIndented: the Lines of an error follow its first line, each
// indented by two spaces and ending in a newline (kogen prints Render for every refusal;
// readiness reads Lines and Detail of a configuration error).
func TestRenderPrintsTheDetailLinesIndented(t *testing.T) {
	e := sys.Fail("environment", "project_config_invalid", "invalid configuration", 3)
	e.Lines = []string{"line 3: unknown key", "line 7: bad value"}
	want := "environment/project_config_invalid: invalid configuration\n  line 3: unknown key\n  line 7: bad value\n"
	if got := e.Render(); got != want {
		t.Fatalf("Render = %q, want %q", got, want)
	}
	if e.Exit != 3 || e.Detail != "invalid configuration" || len(e.Lines) != 2 {
		t.Fatalf("Exit %d, Detail %q, Lines %q", e.Exit, e.Detail, e.Lines)
	}
}

// TestAsErrorFindsTheErrorInAChain: kogen's exitFor and readiness take an *sys.Error out of
// whatever error came back, wrapped or not, and know when there is none.
func TestAsErrorFindsTheErrorInAChain(t *testing.T) {
	e := sys.Fail("provider", "login", "not signed in", 4)
	got, ok := sys.AsError(e)
	if !ok || got != e {
		t.Fatalf("AsError(e) = %v, %v", got, ok)
	}
	got, ok = sys.AsError(fmt.Errorf("while asking: %w", e))
	if !ok || got != e || got.Exit != 4 {
		t.Fatalf("AsError(wrapped) = %v, %v", got, ok)
	}
	if got, ok := sys.AsError(errors.New("plain")); ok || got != nil {
		t.Fatalf("AsError(plain) = %v, %v", got, ok)
	}
	if _, ok := sys.AsError(nil); ok {
		t.Fatalf("AsError(nil) found an error")
	}
	if _, ok := sys.AsError(&sys.Interrupted{}); ok {
		t.Fatalf("AsError(interrupted) found an error")
	}
}

// interrupt watches the session's signals, sends the signal to this process and waits until the
// session has seen it. The signal is caught, so nothing else is affected.
func interrupt(t *testing.T, s *sys.Session, sig syscall.Signal) {
	t.Helper()
	stop := s.WatchSignals()
	defer stop()
	if err := syscall.Kill(syscall.Getpid(), sig); err != nil {
		t.Fatal(err)
	}
	<-s.Context().Done()
}

// TestWatchSignalsTurnsTheCallersSignalsIntoAnInterrupt: after SIGINT, SIGTERM or SIGHUP the
// session's Context is done and Err is an *sys.Interrupted whose ExitCode is 130, 143 or 129,
// the code kogen exits with. Before, Err is nil.
func TestWatchSignalsTurnsTheCallersSignalsIntoAnInterrupt(t *testing.T) {
	for sig, code := range map[syscall.Signal]int{syscall.SIGINT: 130, syscall.SIGTERM: 143, syscall.SIGHUP: 129} {
		t.Run(sig.String(), func(t *testing.T) {
			f := newFixture(t)
			if f.s.Err() != nil {
				t.Fatalf("Err = %v before the signal", f.s.Err())
			}
			interrupt(t, f.s, sig)
			err := f.s.Err()
			var in *sys.Interrupted
			if !errors.As(err, &in) || in.ExitCode() != code {
				t.Fatalf("Err = %v (%T), want *sys.Interrupted with exit %d", err, err, code)
			}
			if f.s.Context().Err() == nil {
				t.Fatalf("Context is not cancelled")
			}
		})
	}
}

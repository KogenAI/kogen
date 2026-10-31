package verify

import (
	"context"
	"testing"
	"time"

	"kogen-loop/sys"
)

// shortenGrace sets the fixed no-live-process grace for one test and restores it. Such tests
// cannot run in parallel.
func shortenGrace(t *testing.T, d time.Duration) {
	t.Helper()
	old := noLiveGrace
	noLiveGrace = d
	t.Cleanup(func() { noLiveGrace = old })
}

func TestVerifyEndedCommandNoticed(t *testing.T) {
	shortenGrace(t, 50*time.Millisecond)
	root := t.TempDir()
	s := sys.NewWith(testEnv(), root)
	const command = "printf done"
	before := groupSet(s)
	// A real command in a real group that has ended; only the delivery of its result is withheld.
	if res, err := s.Run(command, root, sys.Options{}); err != nil || res.Output != "done" {
		t.Fatalf("%+v %v", res, err)
	}
	log := &memLog{}
	type answer struct {
		res sys.Result
		err error
	}
	got := make(chan answer, 1)
	go func() {
		res, err := awaitResult(s, before, "acceptance", command, log, make(chan outcome))
		got <- answer{res, err}
	}()
	var a answer
	select {
	case a = <-got:
	case <-time.After(60 * time.Second):
		t.Fatal("the watch never gave up on a command with no live process")
	}
	e, ok := sys.AsError(a.err)
	if !ok || e.Class != "environment" || e.Reason != "command_no_progress" || e.Exit != 1 {
		t.Fatalf("error = %v", a.err)
	}
	eq(t, "detail", e.Detail, "acceptance had no live process for 50ms but its result never reached Kogen; stopped waiting for: "+command)
	events := log.named("command_no_progress")
	if len(events) != 1 {
		t.Fatalf("events = %v", log.events)
	}
	ev := events[0]
	eq(t, "name", ev["name"], any("acceptance"))
	eq(t, "command", ev["command"], any(command))
	eq(t, "rule", ev["rule"], any("no_live_process"))
	eq(t, "after_ms", ev["after_ms"], any(int64(50)))
}

func TestVerifyLiveSilentCommandWaits(t *testing.T) {
	isolateTmp(t)
	shortenGrace(t, 50*time.Millisecond)
	p := newProj(t)
	p.Config.Setup = []string{"sleep 1; printf 'late\\n'; exit 4"}
	s, _ := p.session()
	log := &memLog{}
	in := p.input(1)
	in.Log = log
	pass, err := Verify(context.Background(), s, in)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "setup count", len(pass.Setup), 1)
	eq(t, "status", pass.Setup[0].Status, 4)
	eq(t, "output", pass.Setup[0].Output, "late\n")
	eqSlice(t, "failing", pass.Failing, []string{"setup-1"})
	eq(t, "no_progress events", len(log.named("command_no_progress")), 0)
}

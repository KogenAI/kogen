package loop

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/KogenAI/kogen-loop/internal/delivery"
	"github.com/KogenAI/kogen-loop/provider"
	"github.com/KogenAI/kogen-loop/tools"
)

// A hooked round whose context ends stops at that point: it makes no further hook,
// tool or model calls and returns the context error.
func TestHookedRoundStopsWhenCancelled(t *testing.T) {
	t.Parallel()

	t.Run("before a call starts", func(t *testing.T) {
		t.Parallel()
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		rq := &scriptRequester{script: [][]map[string]any{{fcall("a", "search_text", `{}`)}, {fcall("end", "finish", `{}`)}}}
		var before atomic.Int32
		h := Hooks{
			AfterResponse: func(context.Context, *provider.Response, []any) error { cancel(); return nil },
			BeforeCall:    func(context.Context, tools.Call, []any) error { before.Add(1); return nil },
		}
		_, err := Run(ctx, Round{Definitions: olDefs()}, []any{userMsg("go")}, rq, h)
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("error %v, want context.Canceled", err)
		}
		if n := before.Load(); n != 0 {
			t.Fatalf("BeforeCall ran %d times after cancellation", n)
		}
		if len(rq.requests) != 1 {
			t.Fatalf("%d requests, want 1", len(rq.requests))
		}
	})

	t.Run("while a tool call runs", func(t *testing.T) {
		t.Parallel()
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		repo := newOLRepo(t)
		rq := &scriptRequester{script: [][]map[string]any{{olSearch("a", "p")}, {fcall("end", "finish", `{}`)}}}
		var after atomic.Int32
		h := Hooks{
			AfterCall: func(context.Context, tools.Call, tools.Output, bool, []any) error { after.Add(1); return nil },
		}
		rd := Round{Definitions: olDefs(), Tools: olTools(t.TempDir(), repo, nil)}
		run := olStart(ctx, rd, []any{userMsg("go")}, rq, h)
		select {
		case <-repo.started:
		case <-time.After(olWatchdog):
			t.Fatal("the tool call did not start")
		}
		cancel()
		repo.release("p")
		_, err := run.wait(t)
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("error %v, want context.Canceled", err)
		}
		if n := after.Load(); n != 0 {
			t.Fatalf("AfterCall ran %d times with a call that returned after cancellation", n)
		}
		if len(rq.requests) != 1 {
			t.Fatalf("%d requests, want 1", len(rq.requests))
		}
	})
}

// A response attempt that is superseded has its running calls' context cancelled, so a
// call that waits on its context stops and the retry can begin.
func TestSupersededAttemptCancelsRunningCall(t *testing.T) {
	t.Parallel()
	w := struct{ root, ready, gate string }{t.TempDir(), olFifo(t, t.TempDir(), "ready"), olFifo(t, t.TempDir(), "gate")}
	t.Cleanup(func() { olOpen(w.gate) })
	rd := Round{Definitions: olDefs(), Tools: olTools(w.root, newOLRepo(t), nil)}
	st := newStage(context.Background(), rd.Tools, DefaultTerminal)
	var sink delivery.Sink = st
	sink.Attempt()
	sink.Done(0, olShell("a", olHold(w.ready, w.gate, "echo never")))
	pid := olReadPid(t, w.ready)

	superseded := make(chan struct{})
	go func() { sink.Attempt(); close(superseded) }()
	select {
	case <-superseded:
	case <-time.After(olWatchdog):
		t.Fatal("a superseded attempt's running call was not cancelled")
	}
	if procLive(t, pid) {
		t.Fatal("the superseded call's shell is still running")
	}
	st.close()
}

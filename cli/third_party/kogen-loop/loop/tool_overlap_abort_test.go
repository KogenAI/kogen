package loop

import (
	"context"
	"errors"
	"reflect"
	"sync/atomic"
	"testing"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
)

// A round that does not complete leaves nothing running, nothing staged and nothing
// published: no next request, no result, and the error it always returned.
func TestToolOverlapAbort(t *testing.T) {
	// world is a root with the FIFOs a held shell reports through.
	type world struct {
		root, ready, gate string
	}
	newWorld := func(t *testing.T) world {
		dir := t.TempDir()
		return world{root: t.TempDir(), ready: olFifo(t, dir, "ready"), gate: olFifo(t, dir, "gate")}
	}
	noPublication := func(t *testing.T, res Result, prov *olProvider, requests int) {
		t.Helper()
		if res.Input != nil || res.Ending != "" || res.Requests != 0 || res.Response != nil {
			t.Fatalf("a result was published: %+v", res)
		}
		if n := len(prov.requests()); n != requests {
			t.Fatalf("%d requests, want %d", n, requests)
		}
	}

	// cancel stops the round while its response is still streaming and its first call runs.
	cancelRound := func(t *testing.T, hooked bool, limit time.Duration) (Result, error, int, *olProvider) {
		w := newWorld(t)
		sent := make(chan struct{})
		prov := newOLProvider(t, "responses",
			func(s *olStream) {
				s.call(0, "a", "shell", string(mustJSON(map[string]any{"command": olHold(w.ready, w.gate, "echo never")})))
				close(sent)
				s.wait(nil) // until the client leaves
			},
			olFinish,
		)
		d, role, sess := olDirect(t, prov)
		rd := Round{Role: role, Definitions: olDefs(), Tools: olTools(w.root, newOLRepo(t), sess)}
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		var h Hooks
		if hooked {
			// A hooked round never starts the call: it waits for a validated response.
			h.AfterResponse = func(context.Context, *provider.Response, []any) error { return nil }
		}
		if limit > 0 {
			ctx, cancel = context.WithTimeout(ctx, limit)
			defer cancel()
		}
		run := olStart(ctx, rd, []any{userMsg("go")}, d, h)
		<-sent
		pid := 0
		if !hooked {
			pid = olReadPid(t, w.ready)
		}
		if limit == 0 {
			cancel()
		}
		res, err := run.wait(t)
		return res, err, pid, prov
	}

	t.Run("cancelled mid-stream", func(t *testing.T) {
		res, err, pid, prov := cancelRound(t, false, 0)
		if err == nil {
			t.Fatal("no error")
		}
		noPublication(t, res, prov, 1)
		if procLive(t, pid) {
			t.Fatal("the running shell outlived the round")
		}
		// The error is the one the round returned before overlap existed.
		_, want, _, _ := cancelRound(t, true, 0)
		if err.Error() != want.Error() || reflect.TypeOf(err) != reflect.TypeOf(want) {
			t.Fatalf("error %T %q, want %T %q", err, err, want, want)
		}
	})

	t.Run("deadline mid-stream", func(t *testing.T) {
		res, err, pid, prov := cancelRound(t, false, 2*time.Second)
		if err == nil {
			t.Fatal("no error")
		}
		noPublication(t, res, prov, 1)
		if procLive(t, pid) {
			t.Fatal("the running shell outlived the round")
		}
	})

	// A cut stream is retried by the provider's own policy. The failed attempt's call is
	// stopped and its result dropped before the wait that precedes the retry, and nothing
	// of it reaches the retried attempt's results.
	for _, early := range []string{"running", "finished"} {
		t.Run("retried response/"+early, func(t *testing.T) {
			w := newWorld(t)
			first := olHold(w.ready, w.gate, "echo attempt1")
			if early == "finished" {
				first = `echo $$ > ` + olQuote(w.ready) + `; echo attempt1`
			}
			sent, cutNow := make(chan struct{}), make(chan struct{})
			prov := newOLProvider(t, "responses",
				func(s *olStream) {
					s.call(0, "a", "shell", string(mustJSON(map[string]any{"command": first})))
					close(sent)
					s.wait(cutNow)
					s.cut()
				},
				func(s *olStream) {
					s.call(0, "a", "shell", `{"command":"echo attempt2"}`)
					s.end()
				},
				olFinish,
			)
			d, role, sess := olDirect(t, prov)
			var pid, slept atomic.Int64
			var leftover atomic.Bool
			d.Client.Sleep = func(ctx context.Context, _ time.Duration) error {
				slept.Add(1)
				leftover.Store(procLive(t, int(pid.Load())))
				return ctx.Err()
			}
			rd := Round{Role: role, Definitions: olDefs(), Tools: olTools(w.root, newOLRepo(t), sess)}
			run := olStart(context.Background(), rd, []any{userMsg("go")}, d, Hooks{})
			pid.Store(int64(olReadPid(t, w.ready)))
			<-sent
			close(cutNow)
			res, err := run.wait(t)
			if err != nil || res.Ending != EndTerminal || res.Requests != 2 {
				t.Fatalf("%+v %v", res, err)
			}
			if slept.Load() != 1 || leftover.Load() {
				t.Fatalf("%d waits before the retry; the failed attempt's shell still running: %v", slept.Load(), leftover.Load())
			}
			if got := olOutputIDs("responses", prov.requests()[2]); !reflect.DeepEqual(got, []string{"a"}) {
				t.Fatalf("outputs %v", got)
			}
			var outs []string
			for _, it := range res.Input {
				if m, ok := it.(map[string]any); ok && m["type"] == "function_call_output" {
					outs = append(outs, m["output"].(string))
				}
			}
			if !reflect.DeepEqual(outs, []string{"exit status: 0\nattempt2\n"}) {
				t.Fatalf("outputs %q: only the retried attempt's call may be published", outs)
			}
			if n := len(prov.requests()); n != 3 {
				t.Fatalf("%d requests", n)
			}
		})
	}

	t.Run("failed response", func(t *testing.T) {
		w := newWorld(t)
		sent, failNow := make(chan struct{}), make(chan struct{})
		prov := newOLProvider(t, "responses",
			func(s *olStream) {
				s.call(0, "a", "shell", string(mustJSON(map[string]any{"command": olHold(w.ready, w.gate, "echo never")})))
				close(sent)
				s.wait(failNow)
				s.event("response.failed", map[string]any{"response": map[string]any{"error": map[string]any{"code": "invalid_prompt", "message": "refused"}}})
			},
			olFinish,
		)
		d, role, sess := olDirect(t, prov)
		rd := Round{Role: role, Definitions: olDefs(), Tools: olTools(w.root, newOLRepo(t), sess)}
		run := olStart(context.Background(), rd, []any{userMsg("go")}, d, Hooks{})
		pid := olReadPid(t, w.ready)
		<-sent
		close(failNow)
		res, err := run.wait(t)
		var se *sys.Error
		if !errors.As(err, &se) || se.Class != "provider" {
			t.Fatalf("error %T %v", err, err)
		}
		noPublication(t, res, prov, 1)
		if procLive(t, pid) {
			t.Fatal("the failed response's shell outlived the round")
		}
	})

	// A stopped shell is a stopping error, returned unchanged, with no next request.
	t.Run("tool stop", func(t *testing.T) {
		w := newWorld(t)
		prov := newOLProvider(t, "responses",
			func(s *olStream) {
				s.call(0, "a", "shell", string(mustJSON(map[string]any{"command": olHold(w.ready, w.gate, "echo never")})))
				s.call(1, "b", "shell", `{"command":"echo never"}`)
				s.end()
			},
			olFinish,
		)
		d, role, sess := olDirect(t, prov)
		rd := Round{Role: role, Definitions: olDefs(), Tools: olTools(w.root, newOLRepo(t), sess)}
		run := olStart(context.Background(), rd, []any{userMsg("go")}, d, Hooks{})
		pid := olReadPid(t, w.ready)
		sess.Interrupt("SIGINT")
		res, err := run.wait(t)
		var in *sys.Interrupted
		if !errors.As(err, &in) || in.Signal != "SIGINT" {
			t.Fatalf("error %T %v", err, err)
		}
		noPublication(t, res, prov, 1)
		if procLive(t, pid) {
			t.Fatal("the interrupted shell outlived the round")
		}
	})
}

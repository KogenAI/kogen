package provider

import (
	"context"
	"errors"
	"io"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// Default per-attempt silence limits. The first response progress must come within firstByteChatGPT
// (ChatGPT) or firstByteDefault (every other provider) of the request's dispatch; afterwards no
// more than streamIdle may pass between progress reads. Keep-alive bytes are not progress. The
// limits are absolute within an attempt and never renew the call's budget.
const (
	firstByteChatGPT = 90 * time.Second
	firstByteDefault = 45 * time.Second
	streamIdle       = 180 * time.Second
)

// idlePoll caps one real-time wait of an attempt's watchdog, which re-reads Client.Now between
// waits so that a simulated clock is honored. Tests lower it.
var idlePoll = time.Second

// liveWatches counts the watchdogs still running; it is zero between attempts.
var liveWatches atomic.Int64

var errIdle = errors.New("idle timeout")

// idleWatch is one attempt's first-byte and idle timer. All elapsed-time decisions use now
// (Client.Now): a read at or after the limit is too late, a progress read strictly before it renews
// the idle clock. When the limit passes while the attempt is blocked, the watchdog cancels the
// request and closes the body so the blocked call returns.
type idleWatch struct {
	now    func() time.Time
	cancel context.CancelFunc

	mu       sync.Mutex
	last     time.Time
	limit    time.Duration
	idle     bool // progress has arrived: the limit is the idle one
	timedOut bool
	body     io.Closer

	quit chan struct{}
	done chan struct{}
}

// newWatch starts the attempt's clock at dispatch. cancel ends the request context.
func (r *run) newWatch(cancel context.CancelFunc) *idleWatch {
	first := firstByteDefault
	if r.k.info.chatgpt() {
		first = firstByteChatGPT
	}
	now := r.k.c.now
	w := &idleWatch{now: now, cancel: cancel, last: now(), limit: first, quit: make(chan struct{}), done: make(chan struct{})}
	r.watch = w
	liveWatches.Add(1)
	go w.run()
	return w
}

func (w *idleWatch) run() {
	defer close(w.done)
	defer liveWatches.Add(-1)
	t := time.NewTimer(idlePoll)
	defer t.Stop()
	for {
		w.mu.Lock()
		rem := w.limit - w.now().Sub(w.last)
		if rem <= 0 || w.timedOut {
			w.timedOut = true
			body := w.body
			w.mu.Unlock()
			w.cancel()
			if body != nil {
				body.Close()
			}
			return
		}
		w.mu.Unlock()
		if rem > idlePoll {
			rem = idlePoll
		}
		t.Reset(rem)
		select {
		case <-t.C:
		case <-w.quit:
			return
		}
	}
}

// stop ends the watchdog and waits for it, so no timer outlives its attempt.
func (w *idleWatch) stop() {
	if w == nil {
		return
	}
	close(w.quit)
	<-w.done
}

// attach lets the watchdog close the response body when the attempt times out.
func (w *idleWatch) attach(body io.Closer) {
	w.mu.Lock()
	w.body = body
	late := w.timedOut
	w.mu.Unlock()
	if late {
		body.Close()
	}
}

// observe reports whether the silence ended the attempt by at. A progress read strictly inside the
// limit starts or renews the idle clock; a read at or past it, or one that is not progress
// (no bytes, keep-alive bytes), does not.
func (w *idleWatch) observe(at time.Time, progress bool) bool {
	if w == nil {
		return false
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.timedOut || at.Sub(w.last) >= w.limit {
		w.timedOut = true
		return true
	}
	if progress {
		w.last, w.limit, w.idle = at, streamIdle, true
	}
	return false
}

// expired is observe without a byte, at the current time.
func (w *idleWatch) expired() bool {
	if w == nil {
		return false
	}
	return w.observe(w.now(), false)
}

// detail is the transient failure text of the phase that timed out.
func (w *idleWatch) detail() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.idle {
		return "stream idle for " + strconv.Itoa(int(streamIdle/time.Second)) + " s"
	}
	return "no first byte within " + strconv.Itoa(int(w.limit/time.Second)) + " s"
}

// idleStop ends an attempt whose watch expired: a caller's stop or the spent budget win,
// otherwise the attempt is a transient idle failure.
func (r *run) idleStop(ctx context.Context, w *idleWatch) (result, error) {
	if stop, ok := r.k.stopped(); ok {
		r.so.finishFailure(r.k, ctx.Err())
		return result{}, stop
	}
	r.so.finishIdle()
	return result{kind: resTransient, detail: w.detail()}, nil
}

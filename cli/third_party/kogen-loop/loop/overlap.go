package loop

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"sync"

	"kogen-loop/internal/footprint"
	"kogen-loop/tools"
)

// stage runs the tool calls of one response while it is still arriving. It is the
// delivery.Sink the engine hands to the requester through the context: a complete streamed
// call is started as soon as everything before it is known not to conflict with it, and
// Run publishes nothing until the validated response has finished all of its calls.
//
// Dependency edges follow the original call order. A call starts only when every earlier
// stream position has settled and no earlier call that has not finished conflicts with it
// (see footprint.Overlap): shell, probe and any call whose effects are not understood
// conflict with everything. Results stay in the slots, indexed by original call position;
// they are never published by the stage.
type stage struct {
	run      context.Context
	tl       *tools.Tools // nil: every call is an unknown tool
	terminal []string

	mu     sync.Mutex
	cond   *sync.Cond
	gen    *attempt
	closed bool
}

// attempt is the work of one transport attempt.
type attempt struct {
	ctx      context.Context
	cancel   context.CancelFunc
	wg       sync.WaitGroup
	settled  map[int]bool // stream positions whose item is complete
	slots    []*slot      // calls by stream position
	complete bool         // the validated response has registered every call
	errs     []error      // the errors of calls, in arrival order
	failed   bool
}

type slotState int

const (
	waiting slotState = iota
	running
	finished
)

type slot struct {
	pos      int
	call     tools.Call
	state    slotState
	terminal bool
	fp       footprint.Footprint // set when the call starts
	out      tools.Output
}

func newStage(run context.Context, tl *tools.Tools, terminal []string) *stage {
	s := &stage{run: run, tl: tl, terminal: terminal}
	s.cond = sync.NewCond(&s.mu)
	s.gen = s.fresh()
	return s
}

func (s *stage) fresh() *attempt {
	ctx, cancel := context.WithCancel(s.run)
	return &attempt{ctx: ctx, cancel: cancel, settled: map[int]bool{}}
}

// retire replaces the current attempt with an empty one, cancels the old attempt's calls and
// returns once they have all stopped. With closed set, nothing more is accepted.
func (s *stage) retire(closed bool) {
	s.mu.Lock()
	old := s.gen
	s.gen = s.fresh()
	s.closed = s.closed || closed
	s.mu.Unlock()
	old.cancel()
	old.wg.Wait()
	// A yielded call has returned, but its process is still owned by this attempt.
	// Discarded streaming attempts must stop it before a retry starts.
	if s.tl != nil {
		for _, sl := range old.slots {
			if sl.call.Name != tools.ShellTool {
				continue
			}
			var result struct {
				Status string `json:"status"`
				Handle string `json:"handle"`
			}
			if json.Unmarshal([]byte(sl.out.Text), &result) == nil && result.Status == "running" && result.Handle != "" {
				s.tl.CancelShellHandle(result.Handle)
			}
		}
	}
}

// Attempt implements delivery.Sink.
func (s *stage) Attempt() { s.retire(false) }

// Abort implements delivery.Sink.
func (s *stage) Abort() { s.retire(false) }

// close stops everything the stage started; Run calls it when the round ends in an error.
func (s *stage) close() { s.retire(true) }

// Done implements delivery.Sink.
func (s *stage) Done(pos int, item map[string]any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	g := s.gen
	if s.closed || g.complete || g.settled[pos] {
		return
	}
	g.settled[pos] = true
	if item != nil {
		g.slots = append(g.slots, s.newSlot(pos, callOf(item)))
		slices.SortFunc(g.slots, func(a, b *slot) int { return a.pos - b.pos })
	}
	s.advance(g)
}

func callOf(item map[string]any) tools.Call {
	name, _ := item["name"].(string)
	args, _ := item["arguments"].(string)
	return tools.Call{Item: item, Name: name, Arguments: args}
}

// newSlot is a call's slot. A terminal call does not execute, and without tools every call
// is an unknown tool; both are finished from the start.
func (s *stage) newSlot(pos int, c tools.Call) *slot {
	sl := &slot{pos: pos, call: c, terminal: slices.Contains(s.terminal, c.Name)}
	switch {
	case sl.terminal:
		sl.state = finished
	case s.tl == nil:
		sl.state, sl.out = finished, tools.Output{Text: "error: unknown tool " + c.Name}.Cut()
	}
	return sl
}

func (s *stage) footprint(c tools.Call) footprint.Footprint {
	if footprint.Of == nil {
		return footprint.Footprint{Barrier: true}
	}
	return footprint.Of(s.tl, c.Name, c.Args())
}

// advance starts every call that is allowed to start. It runs with s.mu held.
func (s *stage) advance(g *attempt) {
	if s.gen != g || s.closed || g.failed || g.ctx.Err() != nil {
		return
	}
	front := 0
	for g.settled[front] {
		front++
	}
	if g.complete {
		front = int(^uint(0) >> 1)
	}
	now := map[*slot]footprint.Footprint{}
	of := func(sl *slot) footprint.Footprint {
		if sl.state == running {
			return sl.fp
		}
		fp, ok := now[sl]
		if !ok {
			fp = s.footprint(sl.call)
			now[sl] = fp
		}
		return fp
	}
	for _, sl := range g.slots {
		if sl.pos >= front {
			break
		}
		if sl.state != waiting {
			continue
		}
		fp := of(sl)
		blocked := false
		for _, e := range g.slots {
			if e == sl {
				break
			}
			if e.state != finished && footprint.Overlap(fp, of(e)) {
				blocked = true
				break
			}
		}
		if blocked {
			continue
		}
		sl.fp, sl.state = fp, running
		g.wg.Add(1)
		go s.work(g, sl)
	}
}

func (s *stage) work(g *attempt, sl *slot) {
	out, err := s.tl.CallContext(g.ctx, sl.call)
	if err == nil {
		out = out.Cut()
	}
	s.mu.Lock()
	sl.state, sl.out = finished, out
	if err != nil {
		g.errs = append(g.errs, err)
		if !g.failed {
			g.failed = true
			g.cancel()
		}
	}
	s.advance(g)
	s.cond.Broadcast()
	s.mu.Unlock()
	g.wg.Done()
}

// same reports whether a started call is the call the validated response holds.
func same(a, b tools.Call) bool {
	return a.Name == b.Name && a.Arguments == b.Arguments && a.CallID() == b.CallID()
}

// finish takes the validated response's calls, runs those that have not started and waits
// for all of them. It returns the output of each call in original order (zero for a terminal
// call). Calls it started from the stream are kept only if they are the response's calls at
// the same positions; otherwise their work is cancelled and joined and every call runs
// again. A tool error, cancellation or deadline cancels and joins everything first and is
// returned; nothing is published here either way.
func (s *stage) finish(calls []tools.Call) ([]tools.Output, error) {
	s.mu.Lock()
	g := s.gen
	front := 0
	for g.settled[front] {
		front++
	}
	kept := 0
	for kept < len(g.slots) && g.slots[kept].pos < front {
		kept++
	}
	ok := kept <= len(calls)
	for k := 0; ok && k < kept; k++ {
		ok = same(g.slots[k].call, calls[k])
	}
	if !ok {
		s.mu.Unlock()
		s.retire(false)
		s.mu.Lock()
		g, kept = s.gen, 0
	}
	g.slots = g.slots[:kept]
	for k := kept; k < len(calls); k++ {
		g.slots = append(g.slots, s.newSlot(len(g.slots), calls[k]))
	}
	g.complete = true
	stop := context.AfterFunc(s.run, func() { s.mu.Lock(); s.cond.Broadcast(); s.mu.Unlock() })
	defer stop()
	s.advance(g)
	for !g.failed && s.run.Err() == nil && !allFinished(g) {
		s.cond.Wait()
	}
	cancelled := s.run.Err() != nil
	s.closed = true
	failed := g.failed || cancelled
	s.mu.Unlock()
	if failed {
		g.cancel()
	}
	g.wg.Wait()
	if !failed {
		var outs []tools.Output
		for _, sl := range g.slots {
			outs = append(outs, sl.out)
		}
		return outs, nil
	}
	return nil, firstError(g.errs, s.run)
}

// firstError is the error a failed round returns: the first call error that is not just the
// context ending (an interrupt, say, which the call reports itself), else the first call error,
// else the round's context error.
func firstError(errs []error, run context.Context) error {
	for _, err := range errs {
		if !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded) {
			return err
		}
	}
	if err := run.Err(); err != nil {
		return err
	}
	return errs[0]
}

func allFinished(g *attempt) bool {
	for _, sl := range g.slots {
		if sl.state != finished {
			return false
		}
	}
	return true
}

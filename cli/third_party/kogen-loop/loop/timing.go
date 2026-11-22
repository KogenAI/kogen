package loop

import (
	"maps"
	"slices"
	"time"

	"github.com/KogenAI/kogen-loop/api"
)

// attemptTiming is what one provider attempt record says about time: the operation (one
// Respond call) it belongs to, its offset from that call's start and its own duration.
type attemptTiming struct {
	operation  any
	offsetMS   int64
	wallMS     int64
	hasOffsets bool
}

// turnTiming is the open turn: it starts at the turn's request.started and ends when the
// session emits the turn's turn.timing event.
type turnTiming struct {
	open     bool
	n        int
	start    time.Time
	attempts []attemptTiming
	toolMS   map[string]int64
	spans    []span // the intervals of the turn's tool calls that produced a tool.result
}

type span struct{ from, to time.Time }

// timingSum is the timing of the turns a Session ran itself, summed.
type timingSum struct {
	wallMS, providerWaitMS, backoffMS, toolWallMS, overheadMS int64
	toolMS                                                    map[string]int64
}

func int64Of(v any) (int64, bool) {
	switch n := v.(type) {
	case int64:
		return n, true
	case int:
		return int64(n), true
	case float64:
		return int64(n), true
	}
	return 0, false
}

func (t *turnTiming) attempt(record map[string]any) {
	if !t.open {
		return
	}
	a := attemptTiming{operation: record["operation_id"]}
	a.wallMS, _ = int64Of(record["wall_ms"])
	a.offsetMS, a.hasOffsets = int64Of(record["request_offset_ms"])
	t.attempts = append(t.attempts, a)
}

func (t *turnTiming) tool(name string, elapsedMS int64, from, to time.Time) {
	if t.toolMS == nil {
		t.toolMS = map[string]int64{}
	}
	t.toolMS[name] += elapsedMS
	t.spans = append(t.spans, span{from, to})
}

// providerAndBackoff are the time the turn's attempts took and the time between the attempts
// of one request (its backoff and every other wait before the next attempt).
func (t *turnTiming) providerAndBackoff() (providerMS, backoffMS int64) {
	last := map[any]attemptTiming{}
	for _, a := range t.attempts {
		providerMS += a.wallMS
		if prev, ok := last[a.operation]; ok && prev.hasOffsets && a.hasOffsets {
			backoffMS += max(0, a.offsetMS-prev.offsetMS-prev.wallMS)
		}
		last[a.operation] = a
	}
	return providerMS, backoffMS
}

// toolWall is the length of the union of the turn's tool call intervals.
func (t *turnTiming) toolWall() time.Duration {
	spans := slices.Clone(t.spans)
	slices.SortFunc(spans, func(a, b span) int { return a.from.Compare(b.from) })
	var total time.Duration
	var cur span
	for i, s := range spans {
		switch {
		case i == 0:
			cur = s
		case !s.from.After(cur.to):
			if s.to.After(cur.to) {
				cur.to = s.to
			}
		default:
			total += cur.to.Sub(cur.from)
			cur = s
		}
	}
	if len(spans) > 0 {
		total += cur.to.Sub(cur.from)
	}
	return total
}

// closeTurn ends the open turn at the time now reports: it emits the turn's turn.timing event and adds the turn
// to the Session's summary. It does nothing when no turn is open.
func (s *Session) closeTurn(now func() time.Time) {
	t := &s.turn
	if !t.open {
		return
	}
	wall := max(0, now().Sub(t.start).Milliseconds())
	providerMS, backoffMS := t.providerAndBackoff()
	toolWallMS := max(0, t.toolWall().Milliseconds())
	overhead := max(0, wall-providerMS-backoffMS-toolWallMS)
	toolMS := maps.Clone(t.toolMS)
	if toolMS == nil {
		toolMS = map[string]int64{}
	}
	s.emit(api.EventTurnTiming, map[string]any{
		"n": int64(t.n), "wall_ms": wall, "provider_wait_ms": providerMS, "backoff_ms": backoffMS,
		"tool_ms": toolMS, "tool_wall_ms": toolWallMS, "overhead_ms": overhead,
	})
	sum := &s.sum
	sum.wallMS += wall
	sum.providerWaitMS += providerMS
	sum.backoffMS += backoffMS
	sum.toolWallMS += toolWallMS
	sum.overheadMS += overhead
	if sum.toolMS == nil {
		sum.toolMS = map[string]int64{}
	}
	for name, ms := range toolMS {
		sum.toolMS[name] += ms
	}
	*t = turnTiming{}
}

// Timing is the timing of the turns this Session ran itself (a resumed Session counts only its
// own): the keys of the turn.timing events except n, summed. The CLI adds session_wall_ms.
// A nil Session has run no turn.
func (s *Session) Timing() map[string]any {
	var sum timingSum
	if s != nil {
		s.mu.Lock()
		sum = s.sum
		sum.toolMS = maps.Clone(s.sum.toolMS)
		s.mu.Unlock()
	}
	if sum.toolMS == nil {
		sum.toolMS = map[string]int64{}
	}
	return map[string]any{
		"wall_ms": sum.wallMS, "provider_wait_ms": sum.providerWaitMS, "backoff_ms": sum.backoffMS,
		"tool_ms": sum.toolMS, "tool_wall_ms": sum.toolWallMS, "overhead_ms": sum.overheadMS,
	}
}

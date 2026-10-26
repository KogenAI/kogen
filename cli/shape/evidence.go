package shape

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen/project"
	"kogen/verify"
)

// Evidence is the append-only record of one shaping or refinement run: the events in
// `<dir>/events.ndjson` (provider calls, probes, context selection, batch jobs, feasibility
// checks) and, at Finish, the usage totals, phase durations and session end. Bytes are not
// tokens. It implements verify.Evidence, so readiness counts and times its setup, acceptance
// and model runs here, and it is safe for concurrent use (workers record from their own
// goroutines).
type Evidence struct {
	Dir  string
	Slug string

	// Now is the clock; nil is time.Now. Tests set it before the first event.
	Now func() time.Time

	mu          sync.Mutex
	origin      time.Time
	timestamp   string
	intervals   map[string][][2]int64
	eventOffset int64
	counts      map[string]int
}

var _ verify.Evidence = (*Evidence)(nil)

// NewEvidence starts a run's evidence in dir (created if needed), after whatever earlier
// runs appended to its events file.
func NewEvidence(dir, slug string) (*Evidence, error) { return NewEvidenceWithClock(dir, slug, nil) }

// NewEvidenceWithClock is NewEvidence with a clock (nil is time.Now), for tests.
func NewEvidenceWithClock(dir, slug string, now func() time.Time) (*Evidence, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	path := filepath.Join(dir, "events.ndjson")
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o666)
	if err != nil {
		return nil, err
	}
	f.Close()
	e := &Evidence{Dir: dir, Slug: slug, Now: now, intervals: map[string][][2]int64{}, counts: map[string]int{}}
	e.origin = e.clock()
	e.timestamp = e.origin.UTC().Format("2006-01-02T15:04:05.000000Z")
	if st, err := os.Stat(path); err == nil {
		e.eventOffset = st.Size()
	}
	return e, nil
}

func (e *Evidence) clock() time.Time {
	if e.Now != nil {
		return e.Now()
	}
	return time.Now()
}

// Millis is the time in milliseconds since the run started.
func (e *Evidence) Millis() int64 { return e.clock().Sub(e.origin).Milliseconds() }

// Offset is t, a Millis value, relative to the run's start (identical here, as Millis counts
// from the start).
func (e *Evidence) Offset(t int64) int64 { return t }

// Record appends an event to the events file. Text that is not valid UTF-8 (a probe's
// output) is made valid first, so recording never fails the run.
func (e *Evidence) Record(event map[string]any) {
	b, err := project.EncodeJSON(event)
	if err != nil {
		b, err = project.EncodeJSON(scrub(event))
		if err != nil {
			return
		}
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	f, err := os.OpenFile(filepath.Join(e.Dir, "events.ndjson"), os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o666)
	if err != nil {
		return
	}
	defer f.Close()
	f.Write(append(b, '\n'))
}

// scrub replaces invalid UTF-8 in every string of a decoded JSON value.
func scrub(v any) any {
	switch x := v.(type) {
	case string:
		return strings.ToValidUTF8(x, "�")
	case []any:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = scrub(e)
		}
		return out
	case []string:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = scrub(e)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, e := range x {
			out[strings.ToValidUTF8(k, "�")] = scrub(e)
		}
		return out
	case verify.ProbeResult:
		x.Output = strings.ToValidUTF8(x.Output, "�")
		return map[string]any{"status": x.Status, "timed_out": x.TimedOut, "output": x.Output, "wall": x.Wall}
	}
	return v
}

// Count notes one execution of "setup", "acceptance" or "quint".
func (e *Evidence) Count(kind string) {
	e.mu.Lock()
	e.counts[kind]++
	e.mu.Unlock()
}

// Counted is how often kind ran.
func (e *Evidence) Counted(kind string) int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.counts[kind]
}

// Interval adds the span from a to b (Millis values) to a phase's time.
func (e *Evidence) Interval(phase string, a, b int64) {
	e.mu.Lock()
	e.intervals[phase] = append(e.intervals[phase], [2]int64{a, b})
	e.mu.Unlock()
}

// Timed runs fn and adds its duration to phase, whatever fn returns.
func (e *Evidence) Timed(phase string, fn func() error) error {
	t := e.Millis()
	defer func() { e.Interval(phase, t, e.Millis()) }()
	return fn()
}

// Unknown is the usage of a call that reported none.
func Unknown() map[string]any {
	return map[string]any{"input": nil, "cached": nil, "output": nil, "reasoning": nil}
}

// Probe runs one declared check and records its result as a probe_result event.
func (e *Evidence) Probe(fn func() (verify.ProbeResult, error)) (verify.ProbeResult, error) {
	t := e.Millis()
	r, err := fn()
	ended := e.Millis()
	if err != nil {
		e.Record(map[string]any{
			"event": "probe_result", "started_ms": t, "wall_ms": ended - t,
			"status": cancelledOrFailed(err), "detail": inspectError(err),
		})
		e.Interval("probe", t, ended)
		return r, err
	}
	status := "failed"
	if r.Status == 0 {
		status = "completed"
	}
	e.Record(map[string]any{
		"event": "probe_result", "started_ms": t, "wall_ms": ended - t,
		"status": status, "timeout": r.TimedOut, "detail": r,
	})
	e.Interval("probe", t, ended)
	return r, nil
}

// ProbeText records the probe tool's result text (what the model is shown) as a
// probe_result event; metadata (a worker's job and role) is merged into the event. The
// probe passed when the text starts with `exit status: 0`.
func (e *Evidence) ProbeText(metadata map[string]any, fn func() (string, error)) (string, error) {
	t := e.Millis()
	text, err := fn()
	ended := e.Millis()
	event := map[string]any{}
	for k, v := range metadata {
		event[k] = v
	}
	event["event"], event["started_ms"], event["wall_ms"] = "probe_result", t, ended-t
	if err != nil {
		event["status"], event["detail"] = cancelledOrFailed(err), inspectError(err)
	} else {
		status := "failed"
		if strings.HasPrefix(text, "exit status: 0\n") {
			status = "completed"
		}
		event["status"], event["timeout"], event["detail"] = status, strings.Contains(text, "timed_out: true"), text
	}
	e.Record(event)
	e.Interval("probe", t, ended)
	return text, err
}

func cancelledOrFailed(err error) string {
	var i *sys.Interrupted
	if errors.As(err, &i) {
		return "cancelled"
	}
	return "failed"
}

func inspectError(err error) string {
	var i *sys.Interrupted
	if errors.As(err, &i) {
		return `{:cancel, "` + i.Signal + `"}`
	}
	return err.Error()
}

// Call is one logical provider request of the run: the main shaper conversation's request or
// a worker's. It is the provider.Observer of that request: every transport attempt (retries
// included) is its own provider_call event, and a request that never reached the transport
// (no login, an interrupt before sending) is one event that says how it ended.
type Call struct {
	ev       *Evidence
	base     map[string]any
	t        int64
	attempts int
}

var _ provider.Observer = (*Call)(nil)

// BeginCall opens a provider request. role is "shape" or a worker's role; job is the
// worker's job id ("" for the main conversation); scope names what the request is for.
func (e *Evidence) BeginCall(role, job string, revision any, scope string, cfg project.Role) *Call {
	t := e.Millis()
	var jobValue any
	if job != "" {
		jobValue = job
	}
	return &Call{ev: e, t: t, base: map[string]any{
		"event": "provider_call", "role": role, "job": jobValue, "revision": revision, "scope": scope,
		"configured_model": cfg.Model, "effective_model": nil,
		"configured_effort": cfg.Effort, "effective_effort": nil,
		"started_ms": t,
	}}
}

// Attempt records one transport attempt (provider.Observer).
func (c *Call) Attempt(rec map[string]any) {
	ended := c.ev.Millis()
	c.attempts++
	wall, _ := rec["wall_ms"].(int64)
	started := max(ended-wall, 0)
	status, _ := rec["outcome"].(string)
	usage := Unknown()
	if status == "completed" {
		if u, ok := rec["usage"].(map[string]any); ok {
			usage = u
		}
	}
	event := map[string]any{}
	for k, v := range c.base {
		event[k] = v
	}
	event["started_ms"], event["status"], event["usage"], event["wall_ms"] = started, status, usage, wall
	event["provider"], event["error"] = rec, rec["error"]
	c.ev.Record(event)
	c.ev.Interval("model", started, ended)
}

// End closes the request. When no attempt reached the transport it records the call
// itself: completed, failed with the error's message, or cancelled with the signal.
func (c *Call) End(resp *provider.Response, err error) {
	if c.attempts > 0 {
		return
	}
	ended := c.ev.Millis()
	event := map[string]any{}
	for k, v := range c.base {
		event[k] = v
	}
	event["wall_ms"] = ended - c.t
	var i *sys.Interrupted
	switch {
	case err == nil && resp != nil:
		event["status"], event["usage"] = "completed", resp.Known.Map()
	case errors.As(err, &i):
		event["status"], event["usage"], event["error"] = "cancelled", Unknown(), map[string]any{"signal": i.Signal}
	default:
		event["status"], event["usage"], event["error"] = "failed", Unknown(), errorMessage(err)
	}
	c.ev.Record(event)
	c.ev.Interval("model", c.t, ended)
}

func errorMessage(err error) string {
	if err == nil {
		return ""
	}
	if e, ok := sys.AsError(err); ok {
		return e.Error()
	}
	return err.Error()
}

// Union is the total length of the spans, overlaps counted once.
func Union(spans [][2]int64) int64 {
	sorted := slices.Clone(spans)
	slices.SortFunc(sorted, func(a, b [2]int64) int {
		if a[0] != b[0] {
			return int(a[0] - b[0])
		}
		return int(a[1] - b[1])
	})
	var total, last int64
	have := false
	for _, s := range sorted {
		a, b := s[0], s[1]
		from := a
		if have {
			from = max(a, last)
		}
		total += max(0, b-from)
		if !have {
			last, have = b, true
		} else {
			last = max(b, last)
		}
	}
	return total
}

// Finish appends the run's summary events: usage totals, the duration of each phase and the
// session end. Only the events of this run count, not those earlier runs appended.
func (e *Evidence) Finish() error {
	events, err := e.events()
	if err != nil {
		return err
	}
	var calls []map[string]any
	probes := 0
	for _, ev := range events {
		switch ev["event"] {
		case "provider_call":
			calls = append(calls, ev)
		case "probe_result":
			probes++
		}
	}
	known := map[string]any{}
	for _, k := range []string{"input", "cached", "output", "reasoning"} {
		var sum int64
		for _, c := range calls {
			if p, ok := c["provider"].(map[string]any); ok && p["usage_state"] == "inconsistent" {
				continue
			}
			usage, _ := c["usage"].(map[string]any)
			if n, ok := usage[k].(float64); ok && n == float64(int64(n)) {
				sum += int64(n)
			}
		}
		known[k] = sum
	}
	unknownCalls := 0
	for _, c := range calls {
		usage, _ := c["usage"].(map[string]any)
		for _, v := range usage {
			if v == nil {
				unknownCalls++
				break
			}
		}
	}
	e.Record(map[string]any{"event": "usage_totals", "known": known, "unknown_calls": unknownCalls})

	e.mu.Lock()
	intervals := map[string][][2]int64{}
	for k, v := range e.intervals {
		intervals[k] = v
	}
	e.mu.Unlock()
	for _, phase := range []string{"setup", "preparation", "model", "probe", "readiness"} {
		var spans [][2]int64
		if phase == "model" || phase == "probe" {
			kind := "provider_call"
			if phase == "probe" {
				kind = "probe_result"
			}
			for _, ev := range events {
				if ev["event"] != kind {
					continue
				}
				a, _ := ev["started_ms"].(float64)
				w, _ := ev["wall_ms"].(float64)
				spans = append(spans, [2]int64{int64(a), int64(a) + int64(w)})
			}
		} else {
			spans = intervals[phase]
		}
		e.Record(map[string]any{"event": "phase_duration", "phase": phase, "wall_ms": Union(spans)})
	}
	elapsed := e.Millis()
	e.Record(map[string]any{"event": "phase_duration", "phase": "shape", "timestamp": e.timestamp, "wall_ms": elapsed})
	e.Record(map[string]any{
		"event": "session_end", "elapsed_ms": elapsed, "provider_calls": len(calls), "probe_count": probes,
		"setup_executions": e.Counted("setup"), "acceptance_executions": e.Counted("acceptance"),
		"model_executions": e.Counted("quint"),
	})
	return nil
}

// events reads the events this run appended.
func (e *Evidence) events() ([]map[string]any, error) {
	f, err := os.Open(filepath.Join(e.Dir, "events.ndjson"))
	if err != nil {
		return nil, err
	}
	defer f.Close()
	if _, err := f.Seek(e.eventOffset, io.SeekStart); err != nil {
		return nil, err
	}
	data, err := io.ReadAll(f)
	if err != nil {
		return nil, err
	}
	var out []map[string]any
	for _, line := range strings.Split(string(data), "\n") {
		if line == "" {
			continue
		}
		var ev map[string]any
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			return nil, fmt.Errorf("shaping evidence: %w", err)
		}
		out = append(out, ev)
	}
	return out, nil
}

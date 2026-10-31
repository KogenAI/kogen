package shape

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen/project"
	"kogen/verify"
)

// shpClock is a clock the test moves.
type shpClock struct{ t time.Time }

func (c *shpClock) now() time.Time { return c.t }

func (c *shpClock) advance(ms int64) { c.t = c.t.Add(time.Duration(ms) * time.Millisecond) }

func newTestEvidence(t *testing.T) (*Evidence, *shpClock, string) {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "shaping")
	clock := &shpClock{t: time.Unix(1_800_000_000, 0)}
	ev, err := NewEvidenceWithClock(dir, "fixture", clock.now)
	if err != nil {
		t.Fatal(err)
	}
	return ev, clock, dir
}

func readEvents(t *testing.T, dir string) []map[string]any {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, "events.ndjson"))
	if err != nil {
		t.Fatal(err)
	}
	var out []map[string]any
	for _, line := range strings.Split(string(b), "\n") {
		if line == "" {
			continue
		}
		var ev map[string]any
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			t.Fatal(err)
		}
		out = append(out, ev)
	}
	return out
}

func phaseWall(events []map[string]any, phase string) []float64 {
	var out []float64
	for _, e := range events {
		if e["phase"] == phase {
			out = append(out, e["wall_ms"].(float64))
		}
	}
	return out
}

func TestEvidenceCancellationAndOverlappingCompletedCallsRemainInTimingAndUsage(t *testing.T) {
	parallel(t)
	// ExUnit: shape_speed_test cancellation and overlapping completed calls remain in final timing and usage
	ev, clock, dir := newTestEvidence(t)
	// A completed HTTP call can append while its owner is inside a probe; final phase
	// accounting must retain it.
	for _, a := range []int64{0, 5} {
		ev.Record(map[string]any{
			"event": "provider_call", "started_ms": a, "wall_ms": 10,
			"usage": map[string]any{"input": 10, "cached": nil, "output": 2, "reasoning": nil},
		})
	}
	call := ev.BeginCall("shape", "", map[string]any{}, "main", project0("sol", "high"))
	clock.advance(3)
	call.End(nil, &sys.Interrupted{Signal: "SIGTERM"})
	if err := ev.Finish(); err != nil {
		t.Fatal(err)
	}
	events := readEvents(t, dir)
	calls := shpNamed(events, "provider_call")
	cancelled := 0
	var spans [][2]int64
	for _, c := range calls {
		if c["status"] == "cancelled" {
			cancelled++
			shpEq(t, "cancelled error", c["error"].(map[string]any)["signal"], any("SIGTERM"))
		}
		a, w := int64(c["started_ms"].(float64)), int64(c["wall_ms"].(float64))
		spans = append(spans, [2]int64{a, a + w})
	}
	shpEq(t, "cancelled calls", cancelled, 1)
	model := phaseWall(events, "model")
	shpEq(t, "one model phase", len(model), 1)
	shpEq(t, "model wall is the union of the calls", int64(model[0]), Union(spans))
	shpEq(t, "union value", Union(spans), int64(15))
	totals := shpNamed(events, "usage_totals")[0]
	shpEq(t, "known input", totals["known"].(map[string]any)["input"], any(float64(20)))
	shpEq(t, "unknown calls", totals["unknown_calls"], any(float64(3)))

	// A later invocation must not recount earlier append-only events.
	again, err := NewEvidenceWithClock(dir, "fixture", clock.now)
	if err != nil {
		t.Fatal(err)
	}
	again.Finish()
	last := phaseWall(readEvents(t, dir), "model")
	shpEq(t, "later model wall", last[len(last)-1], float64(0))
}

func project0(model, effort string) project.Role { return project.Role{Model: model, Effort: effort} }

func TestEvidenceRecoveryRecordsEachTransportWithoutClaimingRetryDelayAsModelTime(t *testing.T) {
	parallel(t)
	// ExUnit: shape_speed_test main recovery records each completed transport without claiming retry delay as model time
	ev, clock, dir := newTestEvidence(t)
	call := ev.BeginCall("shape", "", map[string]any{}, "main", project0("sol", "high"))
	clock.advance(5)
	call.Attempt(map[string]any{"outcome": "failed", "wall_ms": int64(5), "error": "provider_failure", "usage": map[string]any{"input": nil}, "usage_state": "unknown"})
	clock.advance(2000) // the retry's wait
	clock.advance(7)
	call.Attempt(map[string]any{"outcome": "completed", "wall_ms": int64(7), "error": nil, "usage_state": "known",
		"usage": map[string]any{"input": 7, "cached": nil, "output": 2, "reasoning": nil}})
	call.End(&provider.Response{}, nil)
	ev.Finish()
	events := readEvents(t, dir)
	calls := shpNamed(events, "provider_call")
	shpEq(t, "calls", len(calls), 2)
	shpEq(t, "first status", calls[0]["status"], any("failed"))
	shpEq(t, "first error", calls[0]["error"], any("provider_failure"))
	shpEq(t, "second status", calls[1]["status"], any("completed"))
	shpEq(t, "second usage", calls[1]["usage"].(map[string]any)["input"], any(float64(7)))
	shpEq(t, "failed usage is unknown", calls[0]["usage"].(map[string]any)["output"], nil)
	model := phaseWall(events, "model")[0]
	if model != 12 {
		t.Fatalf("model time = %v ms, want the two attempts (5 + 7), not the 2 s between them", model)
	}
	for _, c := range calls {
		shpEq(t, "attempt record kept", c["provider"] != nil, true)
	}
}

func TestEvidenceInconsistentUsageIsLeftOutOfTheTotals(t *testing.T) {
	parallel(t)
	ev, _, dir := newTestEvidence(t)
	ev.Record(map[string]any{"event": "provider_call", "started_ms": 0, "wall_ms": 1, "usage": map[string]any{"input": 5, "cached": 0, "output": 1, "reasoning": 0}, "provider": map[string]any{"usage_state": "known"}})
	ev.Record(map[string]any{"event": "provider_call", "started_ms": 1, "wall_ms": 1, "usage": map[string]any{"input": 99, "cached": 0, "output": 99, "reasoning": 0}, "provider": map[string]any{"usage_state": "inconsistent"}})
	ev.Finish()
	totals := shpNamed(readEvents(t, dir), "usage_totals")[0]
	known := totals["known"].(map[string]any)
	shpEq(t, "input", known["input"], any(float64(5)))
	shpEq(t, "output", known["output"], any(float64(1)))
}

func TestEvidenceIntervalUnionsDoNotDoubleCountOverlapsAndHandleAdjacentBoundaries(t *testing.T) {
	parallel(t)
	// ExUnit: shape_speed_test interval unions do not double count overlaps and handle adjacent boundaries
	for _, tc := range []struct {
		spans [][2]int64
		want  int64
	}{
		{nil, 0},
		{[][2]int64{{0, 0}}, 0},
		{[][2]int64{{0, 10}, {5, 15}, {15, 20}}, 20},
		{[][2]int64{{10, 20}, {0, 5}, {12, 16}, {30, 35}}, 20},
	} {
		shpEq(t, "union", Union(tc.spans), tc.want)
	}
}

func TestEvidencePhasesFromTimedIntervalsAndCounts(t *testing.T) {
	parallel(t)
	ev, clock, dir := newTestEvidence(t)
	boom := errors.New("boom")
	err := ev.Timed("setup", func() error { clock.advance(30); return boom })
	shpEq(t, "Timed returns what fn returned", err, boom)
	ev.Timed("setup", func() error { clock.advance(20); return nil })
	ev.Timed("readiness", func() error { clock.advance(11); return nil })
	ev.Count("setup")
	ev.Count("setup")
	ev.Count("acceptance")
	ev.Count("quint")
	clock.advance(9)
	ev.Finish()
	events := readEvents(t, dir)
	shpEq(t, "setup", phaseWall(events, "setup")[0], float64(50))
	shpEq(t, "readiness", phaseWall(events, "readiness")[0], float64(11))
	shpEq(t, "preparation", phaseWall(events, "preparation")[0], float64(0))
	shpEq(t, "shape", phaseWall(events, "shape")[0], float64(70))
	shape := shpNamed(events, "phase_duration")
	if ts, _ := shape[len(shape)-1]["timestamp"].(string); !strings.HasPrefix(ts, "2027-") || !strings.HasSuffix(ts, "Z") {
		t.Fatalf("shape phase timestamp = %q", ts)
	}
	end := shpNamed(events, "session_end")[0]
	shpEq(t, "elapsed", end["elapsed_ms"], any(float64(70)))
	shpEq(t, "setup executions", end["setup_executions"], any(float64(2)))
	shpEq(t, "acceptance executions", end["acceptance_executions"], any(float64(1)))
	shpEq(t, "model executions", end["model_executions"], any(float64(1)))
}

func TestEvidenceProbeResultsAreRecordedWithTheirStatus(t *testing.T) {
	parallel(t)
	ev, clock, dir := newTestEvidence(t)
	ev.Probe(func() (verify.ProbeResult, error) {
		clock.advance(4)
		return verify.ProbeResult{Status: 0, Output: "ok\n", Wall: 0.1}, nil
	})
	ev.Probe(func() (verify.ProbeResult, error) {
		clock.advance(6)
		return verify.ProbeResult{Status: 124, TimedOut: true, Output: "slow", Wall: 5}, nil
	})
	_, err := ev.Probe(func() (verify.ProbeResult, error) { return verify.ProbeResult{}, &sys.Interrupted{Signal: "SIGINT"} })
	if err == nil {
		t.Fatal("an interrupt passes through")
	}
	ev.ProbeText(map[string]any{"job": "j"}, func() (string, error) { return "exit status: 0\ntimed_out: false\nwall: 0.0 s\n", nil })
	ev.ProbeText(nil, func() (string, error) { return "exit status: 1\ntimed_out: true\nwall: 5.0 s\n", nil })
	ev.Finish()
	events := readEvents(t, dir)
	probes := shpNamed(events, "probe_result")
	var got []string
	for _, p := range probes {
		got = append(got, p["status"].(string))
	}
	shpEq(t, "statuses", strings.Join(got, ","), "completed,failed,cancelled,completed,failed")
	shpEq(t, "timeout", probes[1]["timeout"], any(true))
	shpEq(t, "detail is the result", probes[0]["detail"].(map[string]any)["output"], any("ok\n"))
	shpEq(t, "cancel detail", probes[2]["detail"], any(`{:cancel, "SIGINT"}`))
	shpEq(t, "metadata merged", probes[3]["job"], any("j"))
	shpEq(t, "text timeout", probes[4]["timeout"], any(true))
	shpEq(t, "probe phase", phaseWall(events, "probe")[0], float64(10))
	shpEq(t, "probe count", shpNamed(events, "session_end")[0]["probe_count"], any(float64(5)))
}

func TestEvidenceRecordSurvivesTextThatIsNotUTF8(t *testing.T) {
	parallel(t)
	ev, _, dir := newTestEvidence(t)
	ev.Record(map[string]any{"event": "probe_result", "detail": "bad \xff byte"})
	events := readEvents(t, dir)
	shpEq(t, "events", len(events), 1)
	shpContains(t, "detail", events[0]["detail"].(string), "bad ")
}

func TestEvidenceCallWithoutAnAttemptRecordsHowItEnded(t *testing.T) {
	parallel(t)
	ev, clock, dir := newTestEvidence(t)
	c := ev.BeginCall("shape", "", map[string]any{"head": "h"}, "main shaping", project0("sol", "high"))
	clock.advance(2)
	c.End(nil, sys.Fail("provider", "login", "not signed in", 4))
	w := ev.BeginCall("probe", "job-1", nil, "scope", project0("luna", "medium"))
	w.End(&provider.Response{}, nil)
	calls := shpNamed(readEvents(t, dir), "provider_call")
	shpEq(t, "calls", len(calls), 2)
	shpEq(t, "failed", calls[0]["status"], any("failed"))
	shpEq(t, "message", calls[0]["error"], any("provider/login: not signed in"))
	shpEq(t, "wall", calls[0]["wall_ms"], any(float64(2)))
	shpEq(t, "configured model", calls[0]["configured_model"], any("sol"))
	shpEq(t, "completed", calls[1]["status"], any("completed"))
	shpEq(t, "job", calls[1]["job"], any("job-1"))
	shpEq(t, "main has no job", calls[0]["job"], nil)
}

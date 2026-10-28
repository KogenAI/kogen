package build

import (
	"fmt"
	"reflect"
	"strings"
	"testing"
)

func TestNativeBuildRoundLimit(t *testing.T) {
	for _, limit := range []int{1, 2, 3} {
		t.Run(fmt.Sprint(limit), func(t *testing.T) {
			e := newEnv(t)
			for i := 0; i < limit+1; i++ {
				e.prov.then(e.prov.calls("read_file", map[string]any{"path": "app.txt"}))
			}
			start := e.head()
			a := e.build(func(in *Input) { in.NativeRoundLimits = map[string]int{"build": limit} })
			if a.exit != 1 || e.prov.count() != limit || e.head() != start {
				t.Fatalf("exit=%d requests=%d head changed=%v: %s", a.exit, e.prov.count(), e.head() != start, a.shown())
			}
			reason := fmt.Sprint(a.err) + a.shown()
			if !strings.Contains(strings.ToLower(reason), "round") || !strings.Contains(reason, fmt.Sprint(limit)) {
				t.Fatalf("reason: %s", reason)
			}
			if got := e.result(e.onlyRun())["outcome"]; got != "native_round_limit" {
				t.Fatalf("outcome: %v", got)
			}
			events := eventsNamed(e.events(e.onlyRun()), "native_round_limit")
			if len(events) != 1 || events[0]["role"] != "build" || events[0]["limit"] != float64(limit) || events[0]["rounds"] != float64(limit) {
				t.Fatalf("events: %v", events)
			}
		})
	}
}

func TestNativeBuildRoundLimitBoundary(t *testing.T) {
	for _, terminal := range []bool{true, false} {
		t.Run(fmt.Sprint(terminal), func(t *testing.T) {
			e := newEnv(t)
			e.prov.then(e.prov.calls("write_file", map[string]any{"path": "app.txt", "content": "candidate\n"}))
			if terminal {
				e.prov.then(e.prov.calls("finish", map[string]any{"summary": "done"}))
			} else {
				e.prov.then(sse(), e.prov.calls("finish", map[string]any{"summary": "done"}))
			}
			a := e.build(func(in *Input) { in.NativeRoundLimits = map[string]int{"build": 2} })
			want := 2
			if !terminal {
				want = 3
			}
			if a.exit != 0 || e.prov.count() != want {
				t.Fatalf("exit=%d requests=%d %s", a.exit, e.prov.count(), a.shown())
			}
			if ev := eventsNamed(e.events(e.onlyRun()), "native_round_limit"); len(ev) != 0 {
				t.Fatalf("events %v", ev)
			}
		})
	}
}

func TestNativeUnsupportedReviewLimit(t *testing.T) {
	for _, configured := range []bool{false, true} {
		t.Run(fmt.Sprint(configured), func(t *testing.T) {
			e := newEnv(t)
			f := e.prov
			f.then(landScript(f)...)
			f.then(f.calls("read_file", map[string]any{"path": "app.txt"}), submit(f, "approve"))
			a := e.reviewed(func(in *Input) {
				if configured {
					in.NativeRoundLimits = map[string]int{"review": 1}
				}
			})
			if a.exit != 0 || len(f.reviewRequests()) != 2 || len(eventsNamed(e.events(e.onlyRun()), "native_round_limit")) != 0 {
				t.Fatalf("exit %d review requests %d: %s", a.exit, len(f.reviewRequests()), a.shown())
			}
		})
	}
}

func TestNativeBuildZeroMatchesOmitted(t *testing.T) {
	type observation struct {
		inputs []string
		events []string
		calls  []string
	}
	run := func(zero bool) observation {
		e := newEnv(t)
		e.prov.then(e.prov.calls("read_file", map[string]any{"path": "app.txt"}), e.prov.calls("read_file", map[string]any{"path": "app.txt"}))
		e.prov.then(landScript(e.prov)...)
		a := e.build(func(in *Input) {
			if zero {
				in.NativeRoundLimits = map[string]int{"build": 0}
			}
		})
		if a.exit != 0 {
			t.Fatalf("exit %d: %s", a.exit, a.shown())
		}
		var o observation
		for _, r := range e.prov.requests() {
			o.inputs = append(o.inputs, fmt.Sprint(len(requestInput(r))))
		}
		for _, ev := range e.events(e.onlyRun()) {
			o.events = append(o.events, fmt.Sprint(ev["event"]))
			if ev["event"] == "tool_call" {
				o.calls = append(o.calls, fmt.Sprint(ev["name"]))
			}
		}
		return o
	}
	a, b := run(false), run(true)
	if !reflect.DeepEqual(a, b) {
		t.Fatalf("omitted: %+v\nzero: %+v", a, b)
	}
}

package shape

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"kogen-loop/sys"
	"kogen/executor"
)

// The no-tool answer policy of native Shape and Refine: an answer with zero tool calls makes the
// next inference require the terminal submission tool at API level (where the route can), is
// counted apart from invalid submissions, and is bounded by its own ceiling. The tests run the
// real entry points against a scripted local provider.

const forceTarget = "submit"

func forceTargetOf(owner string) string {
	if owner == "refine" {
		return "submit_refinement"
	}
	return forceTarget
}

func forceReminderOf(owner string) string {
	if owner == "refine" {
		return refineReminder
	}
	return shapeReminder
}

// forceEventsOf are the events of a fixture's invocation, whichever owner ran.
func forceEventsOf(f any) []map[string]any {
	switch x := f.(type) {
	case *refFx:
		return x.evidenceEvents()
	case *shpFx:
		return x.events()
	}
	panic("fixture")
}

// forceVerify checks the enforcement record against what the provider actually received: the
// requests at forcedAt carry the named terminal tool (when the route supports it), every other
// request keeps the ordinary automatic choice, each forced_submit_turn event describes its
// request with the counters at that time, and the exit event has the final counters.
func forceVerify(t *testing.T, w *forceWire, owner string, events, reqs []map[string]any, supported bool, forcedAt []int, counters [][2]int, final [2]int) {
	t.Helper()
	target := forceTargetOf(owner)
	forced := shpNamed(events, "forced_submit_turn")
	if len(forced) != len(forcedAt) || len(counters) != len(forcedAt) {
		t.Fatalf("forced_submit_turn events %v, want %d", forced, len(forcedAt))
	}
	at := map[int]bool{}
	for i, idx := range forcedAt {
		at[idx] = true
		e := forced[i]
		shpEq(t, "event owner", e["owner"], any(owner))
		shpEq(t, "event target", e["target"], any(target))
		shpEq(t, "event provider", e["provider"], any(w.provider))
		shpEq(t, "event api_forcing_supported", e["api_forcing_supported"], any(supported))
		shpEq(t, "event no_tool_turns", e["no_tool_turns"], any(float64(counters[i][0])))
		shpEq(t, "event invalid_submissions", e["invalid_submissions"], any(float64(counters[i][1])))
	}
	for i, req := range reqs {
		want := w.auto
		if supported && at[i] {
			want = w.forced(target)
		}
		if !reflect.DeepEqual(req["tool_choice"], want) {
			t.Fatalf("request %d tool_choice %v, want %v", i+1, req["tool_choice"], want)
		}
	}
	counts := shpNamed(events, "shaping_turn_counts")
	if len(counts) != 1 {
		t.Fatalf("shaping_turn_counts events %v", counts)
	}
	shpEq(t, "counts owner", counts[0]["owner"], any(owner))
	shpEq(t, "counts no_tool_turns", counts[0]["no_tool_turns"], any(float64(final[0])))
	shpEq(t, "counts invalid_submissions", counts[0]["invalid_submissions"], any(float64(final[1])))
}

// forceSameTools: the forced request keeps the complete tool set and the whole conversation of
// the request before it.
func forceSameTools(t *testing.T, reqs []map[string]any, i int) {
	t.Helper()
	if !reflect.DeepEqual(reqs[i]["tools"], reqs[0]["tools"]) {
		t.Fatalf("request %d tools differ from request 1", i+1)
	}
}

func forceHasReminder(t *testing.T, raws []shpRaw, i int, reminder string) {
	t.Helper()
	b, _ := json.Marshal(reminder)
	if !strings.Contains(string(raws[i].body), strings.Trim(string(b), `"`)) {
		t.Fatalf("request %d lacks the reminder %q", i+1, reminder)
	}
}

func TestShapeForceRecovery(t *testing.T) {
	for _, w := range []*forceWire{responsesWire, chatWire} {
		t.Run(w.name+"/shape", func(t *testing.T) {
			f := w.newShape(t, w.prose("The package is described above."), w.shapeSubmit("c1", shpFiles()), w.shapeAck("c2"))
			exit, err := f.shape("Add calc.is_even(n).")
			if err != nil || exit != 0 {
				t.Fatalf("exit %d: %v", exit, err)
			}
			shpEq(t, "published", f.read(refIntentPath), shpIntentMD)
			reqs := f.Prov.requests()
			shpEq(t, "requests", len(reqs), 3)
			forceVerify(t, w, "shape", f.events(), reqs, true, []int{1}, [][2]int{{1, 0}}, [2]int{1, 0})
			forceSameTools(t, reqs, 1)
			forceHasReminder(t, f.Prov.rawRequests(), 1, shapeReminder)
		})
		t.Run(w.name+"/refine", func(t *testing.T) {
			f := w.newRefine(t, w.prose("The draft is fine."), w.refineSubmit("c1", refIntentPath, refTitled))
			before := f.pkg()
			exit, err := f.refine(f.hash0)
			if err != nil || exit != 0 {
				t.Fatalf("exit %d: %v", exit, err)
			}
			refEqual(t, "package", f.pkg(), refWith(before, refIntentPath, refTitled))
			reqs := f.Prov.requests()
			shpEq(t, "requests", len(reqs), 2)
			forceVerify(t, w, "refine", f.evidenceEvents(), reqs, true, []int{1}, [][2]int{{1, 0}}, [2]int{1, 0})
			forceSameTools(t, reqs, 1)
			forceHasReminder(t, f.Prov.rawRequests(), 1, refineReminder)
		})
	}
}

func TestShapeForceFallback(t *testing.T) {
	w := anthropicWire
	sameSettings := func(t *testing.T, reqs []map[string]any) {
		t.Helper()
		for _, k := range []string{"model", "thinking", "output_config", "tools"} {
			if !reflect.DeepEqual(reqs[0][k], reqs[1][k]) {
				t.Fatalf("%s changed for the reminder-only request: %v -> %v", k, reqs[0][k], reqs[1][k])
			}
		}
		if thinking, _ := reqs[1]["thinking"].(map[string]any); thinking["type"] != "adaptive" {
			t.Fatalf("thinking %v", reqs[1]["thinking"])
		}
	}
	t.Run("anthropic/shape", func(t *testing.T) {
		f := w.newShape(t, w.prose("Done."), w.shapeSubmit("c1", shpFiles()), w.shapeAck("c2"))
		exit, err := f.shape("Add calc.is_even(n).")
		if err != nil || exit != 0 {
			t.Fatalf("exit %d: %v", exit, err)
		}
		shpEq(t, "published", f.read(refIntentPath), shpIntentMD)
		reqs := f.Prov.requests()
		shpEq(t, "requests", len(reqs), 3)
		forceVerify(t, w, "shape", f.events(), reqs, false, []int{1}, [][2]int{{1, 0}}, [2]int{1, 0})
		forceHasReminder(t, f.Prov.rawRequests(), 1, shapeReminder)
		sameSettings(t, reqs)
	})
	t.Run("anthropic/refine", func(t *testing.T) {
		f := w.newRefine(t, w.prose("Done."), w.refineSubmit("c1", refIntentPath, refTitled))
		before := f.pkg()
		exit, err := f.refine(f.hash0)
		if err != nil || exit != 0 {
			t.Fatalf("exit %d: %v", exit, err)
		}
		refEqual(t, "package", f.pkg(), refWith(before, refIntentPath, refTitled))
		reqs := f.Prov.requests()
		shpEq(t, "requests", len(reqs), 2)
		forceVerify(t, w, "refine", f.evidenceEvents(), reqs, false, []int{1}, [][2]int{{1, 0}}, [2]int{1, 0})
		forceHasReminder(t, f.Prov.rawRequests(), 1, refineReminder)
		sameSettings(t, reqs)
	})
	// An external executor has no API tool choice: its invalid submission returns the existing
	// feedback, and no forced wire request is claimed.
	t.Run("external/shape", func(t *testing.T) {
		f := newShpFx(t)
		f.useExternalShape(6)
		both := map[string]any{"questions": []any{shpQuestion("Q?")}, "files": shpFiles()["files"]}
		x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){result(both), result(shpFiles())}}
		f.setReport("PASSED", 0)
		if exit, err := f.shapeWith(x, "Add calc.is_even(n)."); err != nil || exit != 0 {
			t.Fatalf("exit %d: %v", exit, err)
		}
		shpContains(t, "feedback", x.inputs[1].Feedback, "invalid submission:")
		shpEq(t, "forced events", len(shpNamed(f.events(), "forced_submit_turn")), 0)
		noNativeRequests(t, f)
	})
	t.Run("external/refine", func(t *testing.T) {
		f := newRefFx(t, refOpts{external: 6})
		before := f.pkg()
		good := map[string]any{"files": []any{map[string]any{"path": refIntentPath, "content": refTitled}}}
		x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){result(map[string]any{"files": []any{}}), result(good)}}
		if exit, err := f.refineWith(x, f.hash0); err != nil || exit != 0 {
			t.Fatalf("exit %d: %v", exit, err)
		}
		refText(t, "feedback", x.inputs[1].Feedback, "invalid: "+strings.TrimPrefix(refineInvalidShape, "invalid: "))
		refEqual(t, "package", f.pkg(), refWith(before, refIntentPath, refTitled))
		shpEq(t, "forced events", len(shpNamed(f.evidenceEvents(), "forced_submit_turn")), 0)
		noNativeRequests(t, f.shpFx)
	})
}

func TestShapeForceInvalidBudget(t *testing.T) {
	w := responsesWire
	t.Run("shape", func(t *testing.T) {
		both := map[string]any{"questions": []any{shpQuestion("Q?")}, "files": shpFiles()["files"]}
		f := w.newShape(t, w.prose("Done."), w.shapeSubmit("c1", both), w.shapeSubmit("c2", both), w.shapeSubmit("c3", both), w.shapeSubmit("c4", shpFiles()))
		exit, err := f.shape("Add calc.is_even(n).")
		shpWantError(t, err, "shape", "invalid_output", "the shaper's output was not a valid Intent after 3 attempts", 1)
		shpEq(t, "exit", exit, 1)
		reqs := f.Prov.requests()
		shpEq(t, "requests", len(reqs), 4)
		forceVerify(t, w, "shape", f.events(), reqs, true, []int{1}, [][2]int{{1, 0}}, [2]int{1, 3})
		shapeAbsent(t, f)
	})
	t.Run("refine", func(t *testing.T) {
		empty := func(id string) shpStep {
			return w.calls(shpCall(id, "submit_refinement", map[string]any{"files": []any{}}))
		}
		f := w.newRefine(t, w.prose("Done."), empty("c1"), empty("c2"), empty("c3"), w.refineSubmit("c4", refIntentPath, refTitled))
		before := f.pkg()
		exit, err := f.refine(f.hash0)
		shpWantError(t, err, "shape", "refinement_invalid", "no valid ready correction after 3 submissions; the original draft is preserved", 1)
		shpEq(t, "exit", exit, 1)
		reqs := f.Prov.requests()
		shpEq(t, "requests", len(reqs), 4)
		forceVerify(t, w, "refine", f.evidenceEvents(), reqs, true, []int{1}, [][2]int{{1, 0}}, [2]int{1, 3})
		refEqual(t, "preserved", f.pkg(), before)
	})
}

func TestShapeForceNoToolBound(t *testing.T) {
	w := responsesWire
	t.Run("shape", func(t *testing.T) {
		f := w.newShape(t, w.prose("one"), w.prose("two"), w.prose("three"), w.shapeSubmit("c1", shpFiles()))
		exit, err := f.shape("Add calc.is_even(n).")
		e := shpWantError(t, err, "shape", "invalid_output", "the shaper answered without calling any tool 3 times (no-tool limit); no submission was made", 1)
		shpEq(t, "exit", exit, 1)
		shpEq(t, "problem", strings.Join(e.Lines, "|"), "the shaper ended without calling submit")
		reqs := f.Prov.requests()
		shpEq(t, "requests", len(reqs), 3)
		forceVerify(t, w, "shape", f.events(), reqs, true, []int{1, 2}, [][2]int{{1, 0}, {2, 0}}, [2]int{3, 0})
		shapeAbsent(t, f)
	})
	t.Run("refine", func(t *testing.T) {
		f := w.newRefine(t, w.prose("one"), w.prose("two"), w.prose("three"), w.refineSubmit("c1", refIntentPath, refTitled))
		before := f.pkg()
		exit, err := f.refine(f.hash0)
		shpWantError(t, err, "shape", "refinement_invalid", "the refiner answered without calling any tool 3 times (no-tool limit); no correction was submitted and the original draft is preserved", 1)
		shpEq(t, "exit", exit, 1)
		reqs := f.Prov.requests()
		shpEq(t, "requests", len(reqs), 3)
		forceVerify(t, w, "refine", f.evidenceEvents(), reqs, true, []int{1, 2}, [][2]int{{1, 0}, {2, 0}}, [2]int{3, 0})
		refEqual(t, "preserved", f.pkg(), before)
	})
	// Discovery without a submission is not a no-tool answer, and a refusal between prose
	// answers does not reset the no-tool count: prose, refusal, prose, prose stops.
	t.Run("counters are independent", func(t *testing.T) {
		both := map[string]any{"questions": []any{shpQuestion("Q?")}, "files": shpFiles()["files"]}
		f := w.newShape(t, w.readReadme("r"), w.prose("one"), w.shapeSubmit("c1", both), w.prose("two"), w.prose("three"), w.shapeSubmit("c2", shpFiles()))
		_, err := f.shape("Add calc.is_even(n).")
		shpWantError(t, err, "shape", "invalid_output", "the shaper answered without calling any tool 3 times (no-tool limit); no submission was made", 1)
		reqs := f.Prov.requests()
		shpEq(t, "requests", len(reqs), 5)
		forceVerify(t, w, "shape", f.events(), reqs, true, []int{2, 4}, [][2]int{{1, 0}, {2, 1}}, [2]int{3, 1})
	})
	// A provider error exit keeps the final counters too.
	t.Run("provider error", func(t *testing.T) {
		f := w.newShape(t, w.prose("one"), shpStep{status: 400, code: "invalid_request_error"})
		_, err := f.shape("Add calc.is_even(n).")
		if e, ok := sys.AsError(err); !ok || e.Class != "shape" || e.Reason != "provider_failed" {
			t.Fatalf("error %v", err)
		}
		forceVerify(t, w, "shape", f.events(), f.Prov.requests(), true, []int{1}, [][2]int{{1, 0}}, [2]int{1, 0})
		r := w.newRefine(t, w.prose("one"), shpStep{status: 400, code: "invalid_request_error"})
		if _, err := r.refine(r.hash0); err == nil {
			t.Fatal("the provider error was swallowed")
		}
		forceVerify(t, w, "refine", r.evidenceEvents(), r.Prov.requests(), true, []int{1}, [][2]int{{1, 0}}, [2]int{1, 0})
	})
	forceResets(t, w)
}

// forceResetRoute scripts a conversation whose complete request reaches the input budget exactly
// at the inference after its first tool-free answer: padding reads grow it, then one long prose
// answer pushes the next request over, so the working-window reset falls between a no-tool
// answer and the request that must be forced.
func forceResetRoute(w *forceWire, refuse shpStep, pad string) func(map[string]any) *shpStep {
	const budget, prose = 524288, 100_000
	phase := 0
	return func(req map[string]any) *shpStep {
		raw, _ := json.Marshal(req)
		var step shpStep
		switch {
		case phase == 0:
			phase, step = 1, refuse
		case phase == 1 && len(raw) < budget-prose+30_000:
			step = w.calls(shpCall("pad", "read_file", map[string]any{"path": pad}))
		case phase == 1:
			phase, step = 2, w.prose(strings.Repeat("long prose ", prose/11))
		default:
			step = w.prose("more prose")
		}
		return &step
	}
}

func forceCheckReset(t *testing.T, events, reqs []map[string]any, raws []shpRaw, owner string) {
	t.Helper()
	resets := shpNamed(events, "working_context_reset")
	if len(resets) == 0 {
		t.Fatal("the conversation never reset its window")
	}
	// The forced request after the long prose answer is the one that carries the handoff.
	var handoffs []int
	for i, raw := range raws {
		if strings.Contains(string(raw.body), "Local working-window reset") {
			handoffs = append(handoffs, i)
		}
	}
	if len(handoffs) == 0 {
		t.Fatal("no request carries a reset handoff")
	}
	first := handoffs[0]
	if len(raws[first].body) > 524288 {
		t.Fatalf("the reset request is %d bytes", len(raws[first].body))
	}
	text := string(raws[first].body)
	for _, want := range []string{`\"no_tool_turns\":1`, `\"forced_submit_pending\":\"` + forceTargetOf(owner) + `\"`, `\"invalid_submissions\":1`} {
		if !strings.Contains(text, want) {
			t.Fatalf("handoff of request %d lacks %s", first+1, want)
		}
	}
}

// forceResets runs the reset cases of TestShapeForceNoToolBound.
func forceResets(t *testing.T, w *forceWire) {
	t.Helper()
	t.Run("reset/shape", func(t *testing.T) {
		both := map[string]any{"questions": []any{shpQuestion("Q?")}, "files": shpFiles()["files"]}
		f := w.newShape(t)
		seedPadding(f)
		f.Prov.route = forceResetRoute(w, w.shapeSubmit("c0", both), "padding.txt")
		_, err := f.shape("Add calc.is_even(n).")
		shpWantError(t, err, "shape", "invalid_output", "the shaper answered without calling any tool 3 times (no-tool limit); no submission was made", 1)
		reqs := f.Prov.requests()
		forced := len(reqs) - 2
		forceVerify(t, w, "shape", f.events(), reqs, true, []int{forced, forced + 1}, [][2]int{{1, 1}, {2, 1}}, [2]int{3, 1})
		forceCheckReset(t, f.events(), reqs, f.Prov.rawRequests(), "shape")
	})
	t.Run("reset/refine", func(t *testing.T) {
		f := w.newRefine(t)
		seedPadding(f.shpFx)
		f.Prov.route = forceResetRoute(w, w.calls(shpCall("c0", "submit_refinement", map[string]any{"files": []any{}})), "padding.txt")
		before := f.pkg()
		_, err := f.refine(f.hash0)
		shpWantError(t, err, "shape", "refinement_invalid", "the refiner answered without calling any tool 3 times (no-tool limit); no correction was submitted and the original draft is preserved", 1)
		reqs := f.Prov.requests()
		forced := len(reqs) - 2
		forceVerify(t, w, "refine", f.evidenceEvents(), reqs, true, []int{forced, forced + 1}, [][2]int{{1, 1}, {2, 1}}, [2]int{3, 1})
		forceCheckReset(t, f.evidenceEvents(), reqs, f.Prov.rawRequests(), "refine")
		refEqual(t, "preserved", f.pkg(), before)
	})
}

// forceConversation is the conversation a request carries on its wire.
func forceConversation(req map[string]any) []any {
	for _, k := range []string{"input", "messages"} {
		if items, ok := req[k].([]any); ok {
			return items
		}
	}
	return nil
}

// forceRetained: the forced request carries every earlier item and the complete tool set.
func forceRetained(t *testing.T, reqs []map[string]any, i int) {
	t.Helper()
	before, after := forceConversation(reqs[i-1]), forceConversation(reqs[i])
	if len(after) <= len(before) || !reflect.DeepEqual(after[:len(before)], before) {
		t.Fatalf("request %d does not retain the conversation of request %d", i+1, i)
	}
	forceSameTools(t, reqs, i)
}

func TestShapeForceWireCompatibility(t *testing.T) {
	// Ordinary sessions send the bytes and headers they sent before enforcement existed.
	golden := forceGolden(t)
	seen := 0
	for _, w := range []*forceWire{responsesWire, chatWire} {
		for _, owner := range []string{"shape", "refine"} {
			key := owner + "/" + w.name
			want, ok := golden[key]
			if !ok {
				t.Fatalf("no golden for %s", key)
			}
			seen++
			if got := forceOrdinary(t, w, owner); !reflect.DeepEqual(got, want) {
				t.Errorf("%s: ordinary requests changed\n got %+v\nwant %+v", key, got, want)
			}
		}
	}
	shpEq(t, "golden cases", len(golden), seen)

	// Only the inference after a tool-free answer requires the terminal tool; discovery without
	// a submission does not, and the answer to a forced request restores the automatic choice.
	for _, w := range []*forceWire{responsesWire, chatWire} {
		t.Run(w.name+"/shape", func(t *testing.T) {
			f := w.newShape(t, w.readReadme("r"), w.prose("Thinking out loud."), w.shapeSubmit("c1", shpFiles()), w.shapeAck("c2"))
			if exit, err := f.shape("Add calc.is_even(n)."); err != nil || exit != 0 {
				t.Fatalf("exit %d: %v", exit, err)
			}
			reqs := f.Prov.requests()
			shpEq(t, "requests", len(reqs), 4)
			forceVerify(t, w, "shape", f.events(), reqs, true, []int{2}, [][2]int{{1, 0}}, [2]int{1, 0})
			forceRetained(t, reqs, 2)
			shpEq(t, "published", f.read(refIntentPath), shpIntentMD)
		})
		t.Run(w.name+"/refine", func(t *testing.T) {
			empty := w.calls(shpCall("c1", "submit_refinement", map[string]any{"files": []any{}}))
			f := w.newRefine(t, w.readReadme("r"), w.prose("Thinking out loud."), empty, w.refineSubmit("c2", refIntentPath, refTitled))
			before := f.pkg()
			if exit, err := f.refine(f.hash0); err != nil || exit != 0 {
				t.Fatalf("exit %d: %v", exit, err)
			}
			reqs := f.Prov.requests()
			shpEq(t, "requests", len(reqs), 4)
			forceVerify(t, w, "refine", f.evidenceEvents(), reqs, true, []int{2}, [][2]int{{1, 0}}, [2]int{1, 1})
			forceRetained(t, reqs, 2)
			refEqual(t, "package", f.pkg(), refWith(before, refIntentPath, refTitled))
		})
	}
}

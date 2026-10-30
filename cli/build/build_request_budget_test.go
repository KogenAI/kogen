package build

import (
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"regexp"
	"strings"
	"testing"
)

// redTry is a builder response that leaves the candidate red and finishes: the pass fails
// and the same builder gets the feedback.
func redTry(f *fakeProvider) handler {
	return f.calls("write_file", map[string]any{"path": "app.txt", "content": "red\n"}, "finish", map[string]any{"summary": "try"})
}

// budgetOf is the saved budget of a checkpoint's state (nil when absent).
func budgetOf(state map[string]any) any { return state["build_request_budget"] }

func budgetEvents(e *env, id string) []map[string]any {
	return eventsNamed(e.events(id), "build_request_budget")
}

func TestBuildRequestBudgetAcrossPasses(t *testing.T) {
	for _, limit := range []int{1, 2, 4} {
		t.Run(fmt.Sprintf("stops before request %d", limit+1), func(t *testing.T) {
			e := newEnv(t)
			f := e.prov
			for i := 0; i < limit+2; i++ {
				f.then(redTry(f))
			}
			start := e.head()
			a := e.build(func(in *Input) { in.BuildRequestBudget = limit })
			if a.exit != 1 || f.count() != limit || e.head() != start {
				t.Fatalf("exit=%d requests=%d head changed=%v: %s", a.exit, f.count(), e.head() != start, a.shown())
			}
			contains(t, "stdout", a.shown(), "candidate/build_request_budget")
			id := e.onlyRun()
			res := e.result(id)
			eq(t, "outcome", res["outcome"], any("build_request_budget"))
			eq(t, "passes", res["passes"], any(float64(limit)))
			eq(t, "retained candidate", e.read("app.txt"), "red\n")
			ev := budgetEvents(e, id)
			if len(ev) != 1 || ev[0]["role"] != "build" || ev[0]["count"] != float64(limit) || ev[0]["limit"] != float64(limit) {
				t.Fatalf("events: %v", ev)
			}
			doc, state := e.checkpoint(id)
			eq(t, "budget", budgetOf(state), any(map[string]any{"limit": float64(limit), "count": float64(limit)}))
			if doc["approval"] == "" || e.gitOut("status", "--porcelain", "app.txt") == "" {
				t.Fatalf("checkpoint approval or candidate lost: %v", doc["approval"])
			}
			if _, err := os.Stat(e.root + "/.kogen/local/approvals/fixture.json"); err != nil {
				t.Fatalf("approval not preserved: %v", err)
			}
		})
		t.Run(fmt.Sprintf("finish on request %d lands", limit), func(t *testing.T) {
			e := newEnv(t)
			f := e.prov
			for i := 1; i < limit; i++ {
				f.then(redTry(f))
			}
			f.then(landScript(f)...)
			start := e.head()
			a := e.build(func(in *Input) { in.BuildRequestBudget = limit })
			if a.exit != 0 || f.count() != limit || e.gitOut("rev-list", "--count", start+"..HEAD") != "1" {
				t.Fatalf("exit=%d requests=%d: %s", a.exit, f.count(), a.shown())
			}
			if ev := budgetEvents(e, e.onlyRun()); len(ev) != 0 {
				t.Fatalf("events: %v", ev)
			}
		})
	}
	t.Run("a response batch completes before the stop", func(t *testing.T) {
		e := newEnv(t)
		f := e.prov
		f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": "partial\n"}, "read_file", map[string]any{"path": "app.txt"}))
		f.then(landScript(f)...)
		a := e.build(func(in *Input) { in.BuildRequestBudget = 1 })
		if a.exit != 1 || f.count() != 1 {
			t.Fatalf("exit=%d requests=%d: %s", a.exit, f.count(), a.shown())
		}
		eq(t, "write ran", e.read("app.txt"), "partial\n")
		id := e.onlyRun()
		_, state := e.checkpoint(id)
		cont := state["continuation"].(map[string]any)
		input, _ := cont["input"].([]any)
		var outputs int
		for _, it := range input {
			if m, _ := it.(map[string]any); m["type"] == "function_call_output" {
				outputs++
			}
		}
		eq(t, "tool outputs kept", outputs, 2)
		eq(t, "events", len(budgetEvents(e, id)), 1)
	})
}

func TestBuildRequestBudgetResume(t *testing.T) {
	t.Run("interrupted, resumed and exhausted", func(t *testing.T) {
		e := newEnv(t)
		f := e.prov
		start := e.head()
		opened := make(chan struct{})
		f.then(f.calls("read_file", map[string]any{"path": "app.txt"}), hang(opened))
		a, done := e.start(func(in *Input) { in.BuildRequestBudget = 4 })
		<-opened
		a.s.Interrupt("SIGINT")
		<-done
		eq(t, "interrupted exit", a.exit, 130)
		id := e.onlyRun()
		_, state := e.checkpoint(id)
		eq(t, "saved budget", budgetOf(state), any(map[string]any{"limit": float64(4), "count": float64(2)}))
		before := e.result(id)

		f.replace(f.calls("read_file", map[string]any{"path": "app.txt"}), f.calls("read_file", map[string]any{"path": "app.txt"}),
			f.calls("read_file", map[string]any{"path": "app.txt"}), f.calls("finish", map[string]any{"summary": "late"}))
		r := e.resume(id)
		if r.exit != 1 || f.count() != 4 || e.head() != start {
			t.Fatalf("exit=%d requests=%d: %s", r.exit, f.count(), r.shown())
		}
		child := ""
		for _, c := range e.runIDs() {
			if c != id {
				child = c
			}
		}
		eq(t, "outcome", e.result(child)["outcome"], any("build_request_budget"))
		ev := budgetEvents(e, child)
		if len(ev) != 1 || ev[0]["count"] != float64(4) || ev[0]["limit"] != float64(4) || ev[0]["role"] != "build" {
			t.Fatalf("events: %v", ev)
		}
		_, state = e.checkpoint(child)
		eq(t, "child budget", budgetOf(state), any(map[string]any{"limit": float64(4), "count": float64(4)}))

		// An exhausted Build sends nothing more, however often it is resumed.
		again := e.resume(child)
		if again.exit != 1 || f.count() != 4 {
			t.Fatalf("exit=%d requests=%d: %s", again.exit, f.count(), again.shown())
		}
		var grand string
		for _, c := range e.runIDs() {
			if c != id && c != child {
				grand = c
			}
		}
		eq(t, "outcome", e.result(grand)["outcome"], any("build_request_budget"))
		if ev := budgetEvents(e, grand); len(ev) != 1 || ev[0]["count"] != float64(4) || ev[0]["limit"] != float64(4) {
			t.Fatalf("events: %v", ev)
		}
		// The earlier runs keep their evidence.
		eq(t, "interrupted result", e.result(id), before)
		eq(t, "candidate", e.head(), start)
	})
	t.Run("a failed request is an attempt", func(t *testing.T) {
		e := newEnv(t)
		f := e.prov
		f.then(f.calls("read_file", map[string]any{"path": "app.txt"}), failure(500, "server_error", "scripted failure"))
		a := e.build(func(in *Input) { in.BuildRequestBudget = 2 })
		if a.exit == 0 || f.count() < 2 {
			t.Fatalf("exit=%d requests=%d: %s", a.exit, f.count(), a.shown())
		}
		sent := f.count()
		id := e.onlyRun()
		_, state := e.checkpoint(id)
		eq(t, "count", budgetOf(state), any(map[string]any{"limit": float64(2), "count": float64(2)}))
		f.replace(landScript(f)...)
		r := e.resume(id)
		if r.exit != 1 || f.count() != sent {
			t.Fatalf("exit=%d requests=%d (was %d): %s", r.exit, f.count(), sent, r.shown())
		}
	})
}

// budgetObservation is everything a Build sent and recorded, with the run identities that
// differ between two Builds replaced.
type budgetObservation struct {
	requests, log, checkpoint, result, outcome string
}

// volatileKeys are the nondeterministic values of a run: its timing, clock and the random
// run, operation and prompt-cache identities.
var volatileKeys = map[string]bool{
	"wall_ms": true, "model_active_ms": true, "t0": true, "at": true, "timestamp": true, "started_at": true,
	"operation_id": true, "attempt_id": true, "conversation_id": true, "session_id": true, "prompt_cache_key": true,
	"cache_id": true, "run_id": true, "approval": true, "approval_bytes": true, "index": true, "identity": true, "request_bytes": true, "ttft_ms": true, "duration_ms": true,
	"headers_ms": true, "first_byte_ms": true, "last_byte_ms": true, "last_progress_ms": true, "max_gap_ms": true, "gap_hist": true,
}

var cacheIdentity = regexp.MustCompile(`conversation-[0-9a-f]+`)

var hexHash = regexp.MustCompile(`^(?:[0-9a-f]{40}|[0-9a-f]{64})$`)

func observeBuild(t *testing.T, e *env, id string) budgetObservation {
	t.Helper()
	replace := func(s string) string {
		for from, to := range map[string]string{e.root: "<root>", e.home: "<home>", e.aux: "<aux>", e.hooks: "<hooks>", e.prov.srv.URL: "<url>"} {
			s = strings.ReplaceAll(s, from, to)
		}
		return cacheIdentity.ReplaceAllString(strings.ReplaceAll(s, id, "<run>"), "conversation-<random>")
	}
	// walk rewrites the volatile values of a decoded document in place.
	var walk func(v any) any
	walk = func(v any) any {
		switch x := v.(type) {
		case map[string]any:
			out := map[string]any{}
			for k, val := range x {
				switch {
				case volatileKeys[k]:
					out[k] = "<volatile>"
				case k == "cache_ids":
					ids := map[string]any{}
					for name := range val.(map[string]any) {
						ids[name] = "<volatile>"
					}
					out[k] = ids
				default:
					out[k] = walk(val)
				}
			}
			return out
		case string:
			// Hashes of text that holds a temporary path (the configuration, the commits) differ
			// between two Builds; the texts themselves are compared in the requests.
			if hexHash.MatchString(x) {
				return "<hash>"
			}
		case []any:
			out := make([]any, len(x))
			for i, val := range x {
				out[i] = walk(val)
			}
			return out
		}
		return v
	}
	norm := func(raw string) string {
		var lines []string
		for _, line := range strings.Split(strings.TrimSpace(raw), "\n") {
			var doc any
			if err := json.Unmarshal([]byte(line), &doc); err != nil {
				t.Fatalf("not JSON: %q: %v", line, err)
			}
			lines = append(lines, replace(jsonText(walk(doc))))
		}
		return strings.Join(lines, "\n")
	}
	read := func(name string) string {
		b, err := os.ReadFile(e.runPath(id, name))
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	var requests []string
	for _, r := range e.prov.requests() {
		requests = append(requests, jsonText(r))
	}
	return budgetObservation{
		requests: norm(strings.Join(requests, "\n")), log: norm(read("log.jsonl")), checkpoint: norm(read("checkpoint.json")),
		result: norm(read("result.json")), outcome: e.gitOut("log", "-1", "--format=%B"),
	}
}

func TestBuildRequestBudgetOff(t *testing.T) {
	run := func(zero bool) (budgetObservation, int) {
		e := newEnv(t)
		f := e.prov
		// More than four builder requests: nothing stops a Build whose budget is off.
		for i := 0; i < 5; i++ {
			f.then(f.calls("read_file", map[string]any{"path": "app.txt"}))
		}
		f.then(redTry(f), redTry(f))
		f.then(landScript(f)...)
		a := e.build(func(in *Input) {
			if zero {
				in.BuildRequestBudget = 0
			}
		})
		if a.exit != 0 {
			t.Fatalf("exit %d: %s", a.exit, a.shown())
		}
		id := e.onlyRun()
		obs := observeBuild(t, e, id)
		for name, text := range map[string]string{"log": obs.log, "checkpoint": obs.checkpoint, "result": obs.result} {
			lacks(t, name, text, "build_request_budget")
		}
		if ev := budgetEvents(e, id); len(ev) != 0 {
			t.Fatalf("events: %v", ev)
		}
		_, state := e.checkpoint(id)
		if _, ok := state["build_request_budget"]; ok {
			t.Fatal("budget field in checkpoint state")
		}
		return obs, f.count()
	}
	omitted, n := run(false)
	zero, m := run(true)
	if n != 8 || m != 8 {
		t.Fatalf("requests %d and %d, want 8", n, m)
	}
	if !reflect.DeepEqual(omitted, zero) {
		for _, p := range [][3]string{
			{"requests", omitted.requests, zero.requests}, {"log", omitted.log, zero.log},
			{"checkpoint", omitted.checkpoint, zero.checkpoint}, {"result", omitted.result, zero.result}, {"commit", omitted.outcome, zero.outcome},
		} {
			if p[1] != p[2] {
				a, b := strings.Split(p[1], "\n"), strings.Split(p[2], "\n")
				for i := range a {
					if i >= len(b) || a[i] != b[i] {
						other := b[min(i, len(b)-1)]
						at := 0
						for at < len(a[i]) && at < len(other) && a[i][at] == other[at] {
							at++
						}
						t.Errorf("%s line %d differs at byte %d:\nomitted: ...%.300s\nzero:    ...%.300s", p[0], i, at, a[i][max(0, at-100):], other[max(0, at-100):])
						break
					}
				}
			}
		}
	}
}

func TestBuildRequestBudgetReview(t *testing.T) {
	e := newEnv(t)
	f := e.prov
	f.then(landScript(f)...)
	approve := map[string]any{"verdict": "approve", "findings": []any{}}
	// The review and its repair send two requests of their own after the single builder request.
	f.then(f.calls("read_file", map[string]any{"path": "app.txt"}),
		f.calls(append(writeApp("candidate\nrepaired\n"), "submit_review", approve)...))
	start := e.head()
	a := e.reviewed(func(in *Input) { in.BuildRequestBudget = 1 })
	if a.exit != 0 || len(f.reviewRequests()) != 2 || f.count() != 3 {
		t.Fatalf("exit=%d review requests=%d total=%d: %s", a.exit, len(f.reviewRequests()), f.count(), a.shown())
	}
	eq(t, "commits", e.gitOut("rev-list", "--count", start+"..HEAD"), "1")
	id := e.onlyRun()
	if ev := budgetEvents(e, id); len(ev) != 0 {
		t.Fatalf("events: %v", ev)
	}
	_, state := e.checkpoint(id)
	eq(t, "count", budgetOf(state), any(map[string]any{"limit": float64(1), "count": float64(1)}))
}

package build

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	looptools "kogen-loop/tools"
	"kogen/agent"
	"kogen/verify"
)

// Tests of the single fresh review after any verdictless end (Intent k-reviewretry2): the real
// Build entry, real temporary Git and the scripted provider.

// filler is a reviewer call whose long replayed arguments fill the working window.
func filler(f *fakeProvider, bytes int) handler {
	return f.calls("search_text", map[string]any{"query": strings.Repeat("x", bytes)})
}

// reviewBodies are the bodies of the reviewer's requests exactly as the provider received them.
func (f *fakeProvider) reviewBodies() [][]byte {
	var out [][]byte
	raw := f.rawRequests()
	for i, req := range f.requests() {
		if requestInstructions(req) == agent.Prompt(agent.Reviewer) {
			out = append(out, raw[i])
		}
	}
	return out
}

// resetSizedTo is the window_reset event of the review conversation whose measured request had
// exactly this many bytes, or nil.
func resetSizedTo(events []map[string]any, bytes int) map[string]any {
	for _, ev := range eventsNamed(events, "window_reset") {
		if ev["owner"] == "review" && ev["input_tokens_after"] == float64(bytes) {
			return ev
		}
	}
	return nil
}

// forcedReminderIndex is the index (among the review requests) of the first request that named
// submit_review as its tool choice.
func forcedReminderIndex(t *testing.T, reqs []map[string]any) int {
	t.Helper()
	for i, req := range reqs {
		if fmt.Sprint(req["tool_choice"]) == fmt.Sprint(forcedSubmit) {
			return i
		}
	}
	t.Fatal("no request required submit_review")
	return -1
}

// TestKReviewRetry2LogReplay reproduces the shape of the S-HISTSUPER Build 45d63b0d (studio,
// Terra medium): a review-and-fix reviewer that used its tools, a working-window reset, prose,
// the api_forced reminder, and a text-only answer to it ended verdictless as
// no_tool_reminder_exhausted. The Build must start review 2 (it used to stop review_invalid).
func TestKReviewRetry2LogReplay(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	f := e.prov
	f.then(landScript(f)...)
	// Review 1: a tool call, filler that nearly fills the window, one large prose-only turn that
	// pushes the reminder request over the budget (the reset happens in that very request), and
	// a text-only answer to the forced reminder.
	f.then(f.calls("shell", map[string]any{"command": "true"}), filler(f, 150_000), filler(f, 150_000), filler(f, 150_000),
		prose(strings.Repeat("Everything is fine. ", 5_000)), prose("Nothing to add."))
	f.then(submit(f, "approve", finding("note", "fine")))
	start := e.head()
	a := e.reviewed()
	if a.exit != 0 || a.err != nil {
		t.Fatalf("exit %d err %v\n%s", a.exit, a.err, a.shown())
	}
	id := e.onlyRun()
	events := e.events(id)
	reqs := f.reviewRequests()
	eq(t, "review requests: review 1 (six), review 2 (one)", len(reqs), 7)

	// A reset really happened, in the reminder request, and that request left the process
	// forced: the transmitted body names the tool and is exactly the size that was measured.
	reminder := forcedReminderIndex(t, reqs)
	eq(t, "the reminder follows the prose turn", reminder, 5)
	if resetHandoff(t, reqs[reminder]) == nil {
		t.Fatal("the reminder request was sent without a working-window reset")
	}
	if resetHandoff(t, reqs[reminder-1]) != nil {
		t.Fatal("the reset happened before the reminder request")
	}
	// The transmitted body (not the request object the Build held before the reset) names the
	// tool, carries the reset's handoff and fits the ceiling that reset was measured against.
	body := f.reviewBodies()[reminder]
	var wire map[string]any
	if err := json.Unmarshal(body, &wire); err != nil {
		t.Fatal(err)
	}
	eq(t, "transmitted tool_choice", wire["tool_choice"], any(forcedSubmit))
	resets := eventsNamed(events, "window_reset")
	eq(t, "resets", len(resets), 1)
	if after := int(resets[0]["input_tokens_after"].(float64)); after >= int(resets[0]["input_tokens_before"].(float64)) || len(body) > looptools.InputBudgetBytes {
		t.Fatalf("reset %v, sent %d bytes", resets[0], len(body))
	}
	contains(t, "reminder text", requestText(reqs[reminder]), "Call submit_review.")
	choice := eventsNamed(events, "review_tool_choice")
	eq(t, "choice events", len(choice), 1)
	eq(t, "mode", choice[0]["mode"], any("api_forced"))

	// The text-only answer is a provider fault with route and model, never an exempt turn.
	faults := eventsNamed(events, "provider_fault")
	eq(t, "provider faults", len(faults), 1)
	eq(t, "fault", faults[0]["fault"], any("forced_tool_not_called"))
	eq(t, "fault review", faults[0]["review"], any(float64(1)))
	eq(t, "fault route", faults[0]["route"], any("chatgpt"))
	eq(t, "fault model", faults[0]["model"], any("gpt-6.1-sol"))
	eq(t, "fault tool", faults[0]["tool"], any("submit_review"))
	var allowances []string
	for _, ev := range eventsNamed(events, "review_allowance") {
		allowances = append(allowances, ev["why"].(string))
	}
	eq(t, "allowances", allowances, []string{"no_tool_turn"})

	// Review 1 is verdictless; review 2 is a fresh conversation and the Build lands once.
	verdicts := e.reviewVerdicts(id)
	eq(t, "review events", len(verdicts), 2)
	eq(t, "review 1 verdict", verdicts[0]["verdict"], any("invalid"))
	eq(t, "review 1 reason", verdicts[0]["reason"], any("no_tool_reminder_exhausted"))
	eq(t, "review 2", verdicts[1]["review"], any(float64(2)))
	eq(t, "review 2 verdict", verdicts[1]["verdict"], any("approve"))
	retries := eventsNamed(events, "review_retry")
	eq(t, "retry events", len(retries), 1)
	eq(t, "retry kind", retries[0]["kind"], any("automatic"))
	eq(t, "retry to", retries[0]["review"], any(float64(2)))
	if cacheKey(reqs[6]) == "" || cacheKey(reqs[6]) == cacheKey(reqs[0]) {
		t.Fatalf("review 2 did not start a conversation of its own: %q %q", cacheKey(reqs[6]), cacheKey(reqs[0]))
	}
	eq(t, "fresh conversation input", len(requestInput(reqs[6])), 1)
	eq(t, "commits", e.gitOut("rev-list", "--count", start+"..HEAD"), "1")
	eq(t, "builder requests", f.count()-len(reqs), 1)
	res := e.result(id)
	eq(t, "reviews", res["reviews"], any(float64(2)))
	eq(t, "passes: no completed check was rerun", res["passes"], any(float64(1)))
}

// verdictless is a reviewer that ends every review without a valid verdict, for the given
// reason, the way reviewRun.invalidStop leaves it for the Build.
func verdictless(reason string, calls *int) *scriptedReviewer {
	return &scriptedReviewer{review: func(ctx context.Context, b *Attempt, pass verify.Pass) (Approved, error) {
		*calls++
		b.Review++
		b.Run.Event(map[string]any{"event": "review", "review": b.Review, "verdict": "invalid", "problems": []string{reason}, "reason": reason})
		b.LastReview = &ReviewRecord{N: b.Review, Verdict: "invalid", Findings: []map[string]any{}}
		b.invalid = &invalidReview{Review: b.Review, Reason: reason, Problems: []string{reason}, Pass: pass}
		return Approved{}, reviewInvalidError()
	}}
}

// TestKReviewRetry2AnyEnd: every verdictless ending shares the one-fresh-review gate, whatever
// its reason (no allowlist): the second failure stops review_invalid after exactly one automatic
// retry, and each explicit resume starts exactly one further review.
func TestKReviewRetry2AnyEnd(t *testing.T) {
	for _, reason := range []string{
		"no_tool_reminder_exhausted", "rejected_verdict_exhausted", "window_reset_without_verdict", "reason_no_list_names",
	} {
		t.Run(reason, func(t *testing.T) {
			t.Parallel()
			e := newEnv(t)
			f := e.prov
			f.then(landScript(f)...)
			var reviews int
			rev := verdictless(reason, &reviews)
			start := e.head()
			a := e.build(func(in *Input) { in.Reviewer = rev })
			wantStop(t, a, "candidate/review_invalid")
			id := e.onlyRun()
			eq(t, "reviews started: the first and one automatic retry", reviews, 2)
			retries := eventsNamed(e.events(id), "review_retry")
			eq(t, "automatic retry events", len(retries), 1)
			eq(t, "retry kind", retries[0]["kind"], any("automatic"))
			eq(t, "retry from", retries[0]["from_review"], any(float64(1)))
			eq(t, "retry to", retries[0]["review"], any(float64(2)))
			only := eventsNamed(e.events(id), "review_only")
			eq(t, "review-only events", len(only), 2)
			eq(t, "first next", only[0]["next"], any("automatic"))
			eq(t, "second next", only[1]["next"], any("stop"))
			eq(t, "stage", e.checkpointStage(id), StageReviewOnly)
			eq(t, "builder requests", f.count(), 1)
			eq(t, "head", e.head(), start)

			// Each explicit resume starts exactly one further review, never the builder or a check.
			again := verdictless(reason, &reviews)
			r := e.resume(id, func(in *ResumeInput) { in.Reviewer = again })
			wantStop(t, r, "candidate/review_invalid")
			eq(t, "one further review per resume", reviews, 3)
			second := e.runNotIn(id)
			eq(t, "no automatic retry restored", len(eventsNamed(e.events(second), "review_retry")), 1)
			eq(t, "resume kind", eventsNamed(e.events(second), "review_retry")[0]["kind"], any("resume"))
			approving := &scriptedReviewer{review: func(ctx context.Context, b *Attempt, pass verify.Pass) (Approved, error) {
				reviews++
				return approve(b, pass), nil
			}}
			r = e.resume(second, func(in *ResumeInput) { in.Reviewer = approving })
			if r.exit != 0 {
				t.Fatalf("exit %d\n%s", r.exit, r.shown())
			}
			eq(t, "one further review", reviews, 4)
			eq(t, "commits", e.commitsSince(start), "1")
			eq(t, "builder requests", f.count(), 1)
			eq(t, "committed", e.gitOut("show", "HEAD:app.txt"), "candidate")
		})
	}
}

// runNotIn is the one run of the project that is not among seen: the run an explicit resume made.
func (e *env) runNotIn(seen ...string) string {
	e.t.Helper()
	var fresh []string
	for _, id := range e.runIDs() {
		if !slices.Contains(seen, id) {
			fresh = append(fresh, id)
		}
	}
	if len(fresh) != 1 {
		e.t.Fatalf("new runs %v, want one", fresh)
	}
	return fresh[0]
}

// checkoutSeenBy runs h after recording the checkout as it is when the request arrives.
func checkoutSeenBy(e *env, seen *map[string]string, h handler) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		got := map[string]string{}
		for _, name := range []string{"app.txt", "README.md", "notes.txt"} {
			if b, err := os.ReadFile(filepath.Join(e.root, name)); err == nil {
				got[name] = string(b)
			}
		}
		*seen = got
		h(w, r)
	}
}

// TestKReviewRetry2DiscardEdits: a review-and-fix reviewer that edited the checkout (tracked
// modification, tracked deletion, an addition) and ended without a verdict gets one fresh review
// that starts from the exact green candidate tree: the edits are discarded, logged and never
// seen by review 2. A reviewer that committed its change is not eligible and nothing is undone.
func TestKReviewRetry2DiscardEdits(t *testing.T) {
	edits := func(f *fakeProvider) handler {
		return f.calls("write_file", map[string]any{"path": "app.txt", "content": "reviewer edit\n"},
			"shell", map[string]any{"command": "rm README.md && printf 'scratch\\n' > notes.txt"})
	}

	t.Run("uncommitted edits are discarded before review 2", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		f := e.prov
		f.then(landScript(f)...)
		f.then(edits(f), prose("done"), prose("really done"))
		var seen map[string]string
		f.then(checkoutSeenBy(e, &seen, submit(f, "approve", finding("note", "fine"))))
		start := e.head()
		a := e.reviewed()
		if a.exit != 0 || a.err != nil {
			t.Fatalf("exit %d err %v\n%s", a.exit, a.err, a.shown())
		}
		id := e.onlyRun()
		// Review 2 began on the green candidate: the builder's bytes, not the reviewer's and not
		// HEAD's pre-build tree.
		eq(t, "checkout when review 2 began", seen, map[string]string{"app.txt": "candidate\n", "README.md": "# Fixture project\n"})
		reqs := f.reviewRequests()
		eq(t, "review requests", len(reqs), 4)
		eq(t, "review 2 opening material", jsonOf(requestInput(reqs[3])[0]), jsonOf(requestInput(reqs[0])[0]))
		eq(t, "fresh conversation input", len(requestInput(reqs[3])), 1)
		for _, leaked := range []string{"reviewer edit", "scratch", "function_call"} {
			lacks(t, "review 2", requestText(reqs[3]), leaked)
		}
		if cacheKey(reqs[0]) == "" || cacheKey(reqs[0]) == cacheKey(reqs[3]) || cacheKey(reqs[0]) != cacheKey(reqs[2]) {
			t.Fatalf("cache identities %q %q %q", cacheKey(reqs[0]), cacheKey(reqs[2]), cacheKey(reqs[3]))
		}
		eq(t, "builder requests", f.count()-len(reqs), 1)

		// The run log names what was discarded, from the checkout's point of view.
		events := e.events(id)
		discarded := eventsNamed(events, "review_edits_discarded")
		eq(t, "discard events", len(discarded), 1)
		eq(t, "discarded review", discarded[0]["review"], any(float64(1)))
		var paths []string
		for _, p := range discarded[0]["paths"].([]any) {
			m := p.(map[string]any)
			paths = append(paths, m["change"].(string)+":"+m["path"].(string))
		}
		eq(t, "discarded paths", paths, []string{"deleted:README.md", "modified:app.txt", "added:notes.txt"})
		retries := eventsNamed(events, "review_retry")
		eq(t, "retry events", len(retries), 1)
		eq(t, "retry tree is the discard's tree", retries[0]["tree"], discarded[0]["tree"])

		// The landed commit is exactly the green candidate.
		eq(t, "commits", e.commitsSince(start), "1")
		eq(t, "committed tree", e.gitOut("rev-parse", "HEAD^{tree}"), discarded[0]["tree"].(string))
		eq(t, "committed app.txt", e.gitOut("show", "HEAD:app.txt"), "candidate")
		eq(t, "committed README.md", e.gitOut("show", "HEAD:README.md"), "# Fixture project")
		eq(t, "status", e.gitOut("status", "--porcelain"), "")
		if _, err := os.Stat(filepath.Join(e.root, "notes.txt")); !os.IsNotExist(err) {
			t.Fatal("the reviewer's added file survived")
		}
		eq(t, "passes: no completed check was rerun", e.result(id)["passes"], any(float64(1)))
		eq(t, "reviews", e.result(id)["reviews"], any(float64(2)))
	})

	t.Run("a second failure stops with the checkout as it is", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		f := e.prov
		f.then(landScript(f)...)
		// Review 2 edits as well and fails as well: the allowance is spent and nothing more is
		// discarded or started.
		f.then(prose("a"), prose("b"), edits(f), prose("c"), prose("d"))
		a := e.reviewed()
		wantStop(t, a, "candidate/review_invalid")
		id := e.onlyRun()
		eq(t, "review requests", len(f.reviewRequests()), 5)
		eq(t, "discard events", len(eventsNamed(e.events(id), "review_edits_discarded")), 0)
		eq(t, "retry events", len(eventsNamed(e.events(id), "review_retry")), 1)
		only := eventsNamed(e.events(id), "review_only")
		eq(t, "last review-only", only[len(only)-1]["eligible"], any(false))
		eq(t, "the second reviewer's edit is left in place", e.read("app.txt"), "reviewer edit\n")
	})

	t.Run("a committed reviewer change is not undone and not retried", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		f := e.prov
		f.then(landScript(f)...)
		f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": "reviewer edit\n"},
			"shell", map[string]any{"command": "git commit -q -am reviewer-commit"}), prose("a"), prose("b"))
		start := e.head()
		a := e.reviewed()
		wantStop(t, a, "candidate/review_invalid")
		id := e.onlyRun()
		eq(t, "review requests: no fresh review", len(f.reviewRequests()), 3)
		events := e.events(id)
		eq(t, "retry events", len(eventsNamed(events, "review_retry")), 0)
		eq(t, "discard events", len(eventsNamed(events, "review_edits_discarded")), 0)
		only := eventsNamed(events, "review_only")
		eq(t, "review-only events", len(only), 1)
		eq(t, "eligible", only[0]["eligible"], any(false))
		contains(t, "why", only[0]["why"].(string), "HEAD moved")
		eq(t, "the reviewer's commit stays", e.gitOut("log", "-1", "--format=%s"), "reviewer-commit")
		eq(t, "commits", e.commitsSince(start), "1")
		eq(t, "its bytes stay", e.gitOut("show", "HEAD:app.txt"), "reviewer edit")
	})
}

// chatCall answers a Chat Completions request with one tool call.
func chatCall(name string, args map[string]any) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		raw, _ := json.Marshal(args)
		io.WriteString(w, jsonText(map[string]any{"id": "chatcmpl-fixture", "model": "kimi-k3", "choices": []any{map[string]any{
			"message": map[string]any{"role": "assistant", "content": nil, "tool_calls": []any{map[string]any{
				"id": "call_" + name, "type": "function", "function": map[string]any{"name": name, "arguments": string(raw)}}}},
			"finish_reason": "tool_calls"}},
			"usage": map[string]any{"prompt_tokens": 7, "completion_tokens": 4, "prompt_tokens_details": map[string]any{"cached_tokens": 0},
				"completion_tokens_details": map[string]any{"reasoning_tokens": 0}}}))
	}
}

// TestKReviewRetry2ForcedReset: on every route that supports named tool selection the reminder
// request that comes right after a real working-window reset still requires submit_review in the
// body that is transmitted, and a text-only answer to it is a provider fault logged with route
// and model, never an exempt turn; it is the ordinary no-tool handling, not another allowance.
func TestKReviewRetry2ForcedReset(t *testing.T) {
	big := strings.Repeat("Everything is fine. ", 5_000)
	type route struct {
		name, model string
		role        string
		script      func(f *fakeProvider) []handler
		forced      any
		requests    func(f *fakeProvider) (reqs []map[string]any, bodies [][]byte)
	}
	responses := func(f *fakeProvider) (reqs []map[string]any, bodies [][]byte) {
		return f.reviewRequests(), f.reviewBodies()
	}
	chat := func(f *fakeProvider) (reqs []map[string]any, bodies [][]byte) {
		raw := f.rawRequests()
		for i, req := range f.requests() {
			if _, ok := req["reasoning_effort"]; ok {
				reqs, bodies = append(reqs, req), append(bodies, raw[i])
			}
		}
		return reqs, bodies
	}
	fill := map[string]any{"query": strings.Repeat("x", 150_000)}
	for _, rt := range []route{
		{name: "chatgpt", model: "gpt-6.1-sol", forced: forcedSubmit, requests: responses,
			script: func(f *fakeProvider) []handler {
				return []handler{filler(f, 150_000), filler(f, 150_000), filler(f, 150_000), prose(big), prose("Nothing to add."),
					submit(f, "approve", finding("note", "fine"))}
			}},
		{name: "opencode-go", model: "kimi-k3", role: "{provider: opencode-go, model: kimi-k3, effort: high}", requests: chat,
			forced: map[string]any{"type": "function", "function": map[string]any{"name": "submit_review"}},
			script: func(f *fakeProvider) []handler {
				return []handler{chatCall("search_text", fill), chatCall("search_text", fill), chatCall("search_text", fill),
					chatReply(big, nil), chatReply("Nothing to add.", nil), chatReply("", map[string]any{"verdict": "approve", "findings": []any{}})}
			}},
	} {
		t.Run(rt.name, func(t *testing.T) {
			t.Parallel()
			e := newEnv(t)
			if rt.role != "" {
				e.reviewRole(rt.role, rt.name)
			}
			f := e.prov
			f.then(landScript(f)...)
			f.then(rt.script(f)...)
			a := e.reviewed()
			if a.exit != 0 || a.err != nil {
				t.Fatalf("exit %d err %v\n%s\n%s", a.exit, a.err, a.shown(), a.errs)
			}
			id := e.onlyRun()
			events := e.events(id)
			reqs, bodies := rt.requests(f)
			eq(t, "review requests: five in review 1, one in review 2", len(reqs), 6)

			// The reset really happened, in the request that carries the reminder.
			resets := eventsNamed(events, "window_reset")
			eq(t, "resets", len(resets), 1)
			eq(t, "reset owner", resets[0]["owner"], any("review"))
			var wire map[string]any
			if err := json.Unmarshal(bodies[4], &wire); err != nil {
				t.Fatal(err)
			}
			eq(t, "reset handoff in the reminder request", strings.Contains(string(bodies[4]), "Local working-window reset"), true)
			eq(t, "no reset before", strings.Contains(string(bodies[3]), "Local working-window reset"), false)
			if len(bodies[4]) >= len(bodies[3]) || len(bodies[4]) > looptools.InputBudgetBytes {
				t.Fatalf("the reminder request (%d bytes) is not a reset of the window before it (%d bytes)", len(bodies[4]), len(bodies[3]))
			}
			// The transmitted body requires submit_review; ordinary requests do not.
			eq(t, "transmitted tool_choice after the reset", wire["tool_choice"], rt.forced)
			for i, body := range bodies {
				var w map[string]any
				if err := json.Unmarshal(body, &w); err != nil {
					t.Fatal(err)
				}
				if i != 4 && fmt.Sprint(w["tool_choice"]) == fmt.Sprint(rt.forced) {
					t.Fatalf("request %d required submit_review", i)
				}
			}
			choice := eventsNamed(events, "review_tool_choice")
			eq(t, "choice events", len(choice), 1)
			eq(t, "mode", choice[0]["mode"], any("api_forced"))

			// The text-only answer: a fault of this route and model, an ordinary no-tool turn.
			faults := eventsNamed(events, "provider_fault")
			eq(t, "provider faults", len(faults), 1)
			eq(t, "fault route", faults[0]["route"], any(rt.name))
			eq(t, "fault model", faults[0]["model"], any(rt.model))
			eq(t, "fault tool", faults[0]["tool"], any("submit_review"))
			eq(t, "fault mode", faults[0]["mode"], any("api_forced"))
			var allowances []string
			for _, ev := range eventsNamed(events, "review_allowance") {
				allowances = append(allowances, ev["why"].(string)+":"+jsonOf(counters(ev)))
			}
			eq(t, "allowances", allowances, []string{"no_tool_turn:[0,1]"})
			verdicts := e.reviewVerdicts(id)
			eq(t, "review events", len(verdicts), 2)
			eq(t, "review 1 reason", verdicts[0]["reason"], any("no_tool_reminder_exhausted"))
			eq(t, "review 2 verdict", verdicts[1]["verdict"], any("approve"))
			eq(t, "retry events: the fault earned no allowance of its own", len(eventsNamed(events, "review_retry")), 1)
		})
	}
}

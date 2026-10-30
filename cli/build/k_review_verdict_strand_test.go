package build

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	looptools "kogen-loop/tools"
	"kogen/project"
)

// Tests of Intent k-review-verdict-strand: a completed green candidate stays reviewable when
// independent reviewers never submit a verdict. Real Build and CLI Resume, temporary Git and the
// scripted provider; nothing here reaches a paid route.

// strandEdits is a reviewer turn that edits the checkout in every way (modification, deletion,
// addition, mode) before the reviewer goes verdictless.
func strandEdits(f *fakeProvider) handler {
	return f.calls("write_file", map[string]any{"path": "app.txt", "content": "reviewer edit\n"},
		"shell", map[string]any{"command": "rm README.md && printf 'scratch\\n' > notes.txt && chmod +x features/steps/integration_steps.js"})
}

// strandBuilder is the builder's one response: a candidate whose pinned source needs many parts.
func strandBuilder(f *fakeProvider) handler {
	return f.calls("write_file", map[string]any{"path": "app.txt", "content": bigFile()}, "finish", map[string]any{"summary": "done"})
}

// authorityOf is the first block of a review's opening message, the exact authority and check
// results; the second block is the catalog of that review's own pinned parts.
func authorityOf(req map[string]any) string {
	blocks, _ := requestInput(req)[0].(map[string]any)["content"].([]any)
	return jsonOf(blocks[0])
}

// forcedBodies are the transmitted bodies of the review requests that named submit_review as
// their tool choice, with the index of each among the review requests.
func forcedBodies(t *testing.T, f *fakeProvider) (indexes []int, bodies [][]byte) {
	t.Helper()
	for i, body := range f.reviewBodies() {
		var wire map[string]any
		if err := json.Unmarshal(body, &wire); err != nil {
			t.Fatal(err)
		}
		if jsonOf(wire["tool_choice"]) == jsonOf(forcedSubmit) {
			indexes, bodies = append(indexes, i), append(bodies, body)
		}
	}
	return indexes, bodies
}

// TestKReviewVerdictStrandReset: a forced submit_review request that comes right after a real
// working-window reset (pinned source, one earlier unread-progress rejection) is transmitted
// forced; its text-only answer is a provider fault naming route and model and the ordinary
// no-tool exhaustion, never an unread-progress exemption; a fresh independent review of the
// same green tree then approves and lands.
func TestKReviewVerdictStrandReset(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	f := e.prov
	f.then(strandBuilder(f))
	// Review 1: a changes verdict with unread pinned parts (the one legitimate exemption), a large
	// prose-only turn that pushes the reminder request over the ceiling (the reset happens in
	// that very request, which also carries native source prefill) and a text-only answer to it.
	f.then(submit(f, "changes", finding("blocking", "wrong")), prose(strings.Repeat("Everything is fine. ", 7_000)), prose("Nothing to add."))
	f.then(repeatHandler(confirmingReviewer(t, f, nil), 40)...)
	start := e.head()
	a := e.reviewed()
	if a.exit != 0 || a.err != nil {
		t.Fatalf("exit %d err %v\n%s", a.exit, a.err, a.shown())
	}
	id := e.onlyRun()
	events := e.events(id)
	reqs, bodies := f.reviewRequests(), f.reviewBodies()

	// The forced request really followed a reset and was transmitted forced, within the ceiling.
	forced, forcedBody := forcedBodies(t, f)
	eq(t, "forced requests", len(forced), 1)
	if resetHandoff(t, reqs[forced[0]]) == nil || resetHandoff(t, reqs[forced[0]-1]) != nil {
		t.Fatal("the forced request is not the one that came right after a working-window reset")
	}
	resets := eventsNamed(events, "window_reset")
	if len(resets) == 0 || resets[0]["input_tokens_after"].(float64) >= resets[0]["input_tokens_before"].(float64) || len(forcedBody[0]) > looptools.InputBudgetBytes {
		t.Fatalf("resets %v, forced request %d bytes", resets, len(forcedBody[0]))
	}
	eq(t, "the reset is part of the forced request's body", strings.Contains(string(bodies[forced[0]]), "Local working-window reset"), true)
	contains(t, "reminder", requestText(reqs[forced[0]]), "Call submit_review.")
	eq(t, "tool choice events", len(eventsNamed(events, "review_tool_choice")), 1)
	eq(t, "mode", eventsNamed(events, "review_tool_choice")[0]["mode"], any("api_forced"))
	if len(eventsNamed(events, "review_source_prefill")) < 2 {
		t.Fatalf("no native source prefill progress around the forced turn: %v", eventsNamed(events, "review_source_prefill"))
	}

	// The text-only answer: a fault of this route and model, an ordinary no-tool turn. The
	// only exemption is the earlier real unread-parts rejection.
	faults := eventsNamed(events, "provider_fault")
	eq(t, "provider faults", len(faults), 1)
	eq(t, "fault", faults[0]["fault"], any("forced_tool_not_called"))
	eq(t, "fault route", faults[0]["route"], any("chatgpt"))
	eq(t, "fault model", faults[0]["model"], any("gpt-6.1-terra"))
	eq(t, "fault tool", faults[0]["tool"], any("submit_review"))
	var allowances []string
	for _, ev := range eventsNamed(events, "review_allowance") {
		allowances = append(allowances, ev["why"].(string)+":"+jsonOf(counters(ev)))
	}
	eq(t, "allowances", allowances, []string{"unread_progress_exempt:[0,0]", "no_tool_turn:[0,1]"})
	verdicts := e.reviewVerdicts(id)
	eq(t, "review events", len(verdicts), 2)
	eq(t, "review 1", verdicts[0]["verdict"], any("invalid"))
	eq(t, "review 1 reason", verdicts[0]["reason"], any("no_tool_reminder_exhausted"))
	eq(t, "review 2", verdicts[1]["verdict"], any("approve"))

	// Review 2 is a fresh conversation of the same green tree; the Build lands once.
	retries := eventsNamed(events, "review_retry")
	eq(t, "retry events", len(retries), 1)
	eq(t, "retry kind", retries[0]["kind"], any("automatic"))
	second := slices.IndexFunc(reqs, func(req map[string]any) bool { return cacheKey(req) != cacheKey(reqs[0]) })
	if second < 0 {
		t.Fatal("review 2 did not start a conversation of its own")
	}
	eq(t, "same authority", authorityOf(reqs[second]), authorityOf(reqs[0]))
	lacks(t, "review 2", requestText(reqs[second]), "function_call")
	eq(t, "commits", e.commitsSince(start), "1")
	eq(t, "committed", e.gitOut("show", "HEAD:app.txt")+"\n", bigFile())
	res := e.result(id)
	eq(t, "reviews", res["reviews"], any(float64(2)))
	eq(t, "passes: no completed check was rerun", res["passes"], any(float64(1)))
	eq(t, "builder requests", f.count()-len(reqs), 1)
}

// TestKReviewVerdictStrandPinnedResume: two successive verdictless reviewers of one completed
// green pass, with pinned source delivered by native prefill around the forced turn, leave an
// exact-green review-only checkpoint with the automatic retry spent; the real `kogen intent
// resume` starts one fresh review that obtains a valid verdict and lands only the reviewed
// green tree, with no builder round and no completed verification rerun.
func TestKReviewVerdictStrandPinnedResume(t *testing.T) {
	bin := buildKogen(t)
	e := newEnv(t)
	e.credentials()
	f := e.prov
	f.then(strandBuilder(f))
	// Review 1: edits, then two prose-only turns (the second answers the forced request).
	f.then(strandEdits(f), prose("done"), prose("really done"))
	// Review 2, the automatic retry on the exact green tree and unchanged by its reviewer: tools,
	// filler that fills the window so that native prefill delivers pinned parts in window after
	// window, a prose turn and a text-only answer to the forced request after the reset.
	f.then(f.calls("shell", map[string]any{"command": "git status --short; ls"}),
		filler(f, 150_000), filler(f, 150_000), filler(f, 150_000),
		prose(strings.Repeat("Everything is fine. ", 5_000)), prose("really done"))
	start := e.head()
	code, out := e.cli(bin, "intent", "build", testSlug)
	if code != 1 || !strings.Contains(out, "candidate/review_invalid") {
		t.Fatalf("build exit %d\n%s", code, out)
	}
	id := buildIDOf.FindStringSubmatch(out)[1]
	events := e.events(id)
	reqs := f.reviewRequests()
	// The pinned source is the actual generated fixture's, many parts, delivered completely by
	// the prefill of review 2 across several of its requests.
	parts := catalogParts(reviewCatalog(t, reqs[3]))
	if len(parts) < 100 {
		t.Fatalf("only %d pinned parts", len(parts))
	}
	var delivered []float64
	var prefills int
	for _, ev := range eventsNamed(events, "review_source_prefill") {
		if ev["review"] == float64(2) {
			prefills++
			for _, p := range ev["parts"].([]any) {
				delivered = append(delivered, p.(float64))
			}
		}
	}
	eq(t, "review 2 prefill requests", prefills, 3)
	eq(t, "review 2 parts delivered by prefill", len(union(delivered)), len(parts))
	faults := eventsNamed(events, "provider_fault")
	eq(t, "provider faults, one per review", len(faults), 2)
	forced, _ := forcedBodies(t, f)
	eq(t, "forced requests, one per review", len(forced), 2)
	if resetHandoff(t, reqs[forced[1]]) == nil {
		t.Fatal("review 2's forced request carries no working-window reset")
	}

	// The stopped result: the first reviewer's edits were discarded (and logged), the second
	// reviewer's unchanged checkout needed no discard, and the green tree is retained.
	discarded := eventsNamed(events, "review_edits_discarded")
	eq(t, "discard events", len(discarded), 1)
	eq(t, "discarded review", discarded[0]["review"], any(float64(1)))
	var paths []string
	for _, p := range discarded[0]["paths"].([]any) {
		m := p.(map[string]any)
		paths = append(paths, m["change"].(string)+":"+m["path"].(string))
	}
	eq(t, "discarded paths", paths, []string{"deleted:README.md", "modified:app.txt", "modified:features/steps/integration_steps.js", "added:notes.txt"})
	only := eventsNamed(events, "review_only")
	eq(t, "review-only events", len(only), 2)
	eq(t, "first next", only[0]["next"], any("automatic"))
	eq(t, "second eligible", only[1]["eligible"], any(true))
	eq(t, "second next", only[1]["next"], any("stop"))
	eq(t, "no further review started", len(eventsNamed(events, "review_retry")), 1)
	green := treeOfCandidate(e)
	eq(t, "tree of review 2's stop", only[1]["tree"], any(green))
	_, state := e.checkpoint(id)
	cont := state["continuation"].(map[string]any)
	eq(t, "stage", cont["stage"], any("review_only"))
	eq(t, "preserved green tree", cont["pass"].(map[string]any)["tree"], any(green))
	eq(t, "preserved green pass", cont["pass"].(map[string]any)["green"], any(true))
	rr := state["review_retry"].(map[string]any)
	eq(t, "automatic spent", rr["automatic"], any(true))
	eq(t, "invalid reviews", len(rr["invalid"].([]any)), 2)
	res := e.result(id)
	eq(t, "outcome", res["outcome"], any("review_invalid"))
	eq(t, "reviews", res["reviews"], any(float64(2)))
	eq(t, "passes", res["passes"], any(float64(1)))
	eq(t, "candidate preserved", e.read("app.txt"), bigFile())
	eq(t, "README preserved", e.read("README.md"), "# Fixture project\n")
	eq(t, "modified files", e.gitOut("diff", "--name-only"), "app.txt")
	eq(t, "no reviewer addition", e.gitOut("ls-files", "--others", "--exclude-standard", "--", "notes.txt"), "")
	eq(t, "head", e.head(), start)
	buildRequests := f.count() - len(reqs)
	eq(t, "builder requests", buildRequests, 1)

	// Explicit resume: one fresh reviewer reads every part and approves.
	before, reviewBefore := f.count(), len(reqs)
	f.then(repeatHandler(confirmingReviewer(t, f, nil), 80)...)
	code, out = e.cli(bin, "intent", "resume", id)
	if code != 0 || !strings.Contains(out, "landed "+testSlug+" ") {
		t.Fatalf("resume exit %d\n%s", code, out)
	}
	resumed := e.runNotIn(id)
	eq(t, "every new request is the fresh review's", f.count()-before, len(f.reviewRequests())-reviewBefore)
	reqs = f.reviewRequests()
	third := reqs[reviewBefore]
	eq(t, "same authority", authorityOf(third), authorityOf(reqs[0]))
	for i := 0; i < reviewBefore; i++ {
		if cacheKey(reqs[i]) == cacheKey(third) {
			t.Fatalf("review 3 reused the conversation identity of request %d", i)
		}
	}
	lacks(t, "review 3", requestText(third), "function_call")
	revents := e.events(resumed)
	for _, name := range []string{"pass", "command", "command_result", "executor_round"} {
		eq(t, name+" events in the resumed run", len(eventsNamed(revents, name)), 0)
	}
	rres := e.result(resumed)
	eq(t, "outcome", rres["outcome"], any("landed"))
	eq(t, "resumed from", rres["resumed_from"], any(id))
	eq(t, "reviews", rres["reviews"], any(float64(3)))
	eq(t, "no new pass", rres["passes"], any(float64(1)))
	retries := eventsNamed(revents, "review_retry")
	eq(t, "retry events", len(retries), 1)
	eq(t, "retry kind", retries[0]["kind"], any("resume"))
	verdicts := eventsNamed(revents, "review")
	eq(t, "verdict events", len(verdicts), 1)
	eq(t, "approved review", verdicts[0]["review"], any(float64(3)))
	eq(t, "approved tree", verdicts[0]["tree"], any(green))
	var material map[string]any
	for _, ev := range eventsNamed(revents, "review_material") {
		material = ev
	}
	eq(t, "every part read before approval", material["parts_read"], any(float64(len(parts))))
	eq(t, "commits", e.commitsSince(start), "1")
	eq(t, "committed tree", e.gitOut("rev-parse", "HEAD^{tree}"), green)
	eq(t, "committed", e.gitOut("show", "HEAD:app.txt")+"\n", bigFile())
	eq(t, "status", e.gitOut("status", "--porcelain"), "")
	eq(t, "the first run keeps its own failed result", e.result(id)["outcome"], any("review_invalid"))
}

// TestKReviewVerdictStrandSafety: recovery of the exact green candidate and its truthful
// refusals. An unchanged candidate after a discarded first review stays eligible; an edited,
// committed or restaged candidate is refused for what it actually is, with the checkout left as
// the reviewer left it; a changed stopped candidate refuses an explicit resume naming the
// observed and green trees and the changed paths; substantive verdicts are not verdictless.
func TestKReviewVerdictStrandSafety(t *testing.T) {
	// stopWith runs two verdictless reviews in this process; second is review 2's first turn,
	// which may touch the checkout.
	stopWith := func(t *testing.T, first, second func(f *fakeProvider) handler) (*env, string, string) {
		e := newEnv(t)
		f := e.prov
		f.then(landScript(f)...)
		if first != nil {
			f.then(first(f))
		}
		f.then(prose("a"), prose("b"))
		if second != nil {
			f.then(second(f))
		}
		f.then(prose("c"), prose("d"))
		start := e.head()
		a := e.reviewed()
		wantStop(t, a, "candidate/review_invalid")
		return e, e.onlyRun(), start
	}
	lastOnly := func(e *env, id string) map[string]any {
		only := eventsNamed(e.events(id), "review_only")
		return only[len(only)-1]
	}

	t.Run("an unchanged candidate after discarded edits stays reviewable", func(t *testing.T) {
		t.Parallel()
		e, id, _ := stopWith(t, strandEdits, nil)
		only := eventsNamed(e.events(id), "review_only")
		eq(t, "review-only events", len(only), 2)
		eq(t, "second eligible: the unchanged second reviewer caused no false drift", only[1]["eligible"], any(true))
		eq(t, "discard events", len(eventsNamed(e.events(id), "review_edits_discarded")), 1)
		eq(t, "stage", e.checkpointStage(id), StageReviewOnly)
		eq(t, "candidate", e.read("app.txt"), "candidate\n")
		e.prov.then(submit(e.prov, "approve"))
		if r := e.resumeReviewed(id); r.exit != 0 {
			t.Fatalf("resume exit %d\n%s", r.exit, r.shown())
		}
	})

	t.Run("an edited candidate is refused as drift, naming trees and paths, and is not restored", func(t *testing.T) {
		t.Parallel()
		e, id, start := stopWith(t, nil, func(f *fakeProvider) handler {
			return f.calls("write_file", map[string]any{"path": "app.txt", "content": "reviewer edit\n"})
		})
		only := lastOnly(e, id)
		eq(t, "eligible", only["eligible"], any(false))
		why := only["why"].(string)
		green := eventsNamed(e.events(id), "review_only")[0]["tree"].(string)
		contains(t, "why", why, "the candidate changed after its green pass")
		contains(t, "why", why, "changed paths: app.txt")
		contains(t, "why: green tree", why, "green tree "+short(green))
		lacks(t, "why", why, "HEAD")
		if treeOfCandidate(e) == green {
			t.Fatal("the stopped candidate is not the edited one")
		}
		eq(t, "the reviewer's edit is left in place", e.read("app.txt"), "reviewer edit\n")
		eq(t, "discard events", len(eventsNamed(e.events(id), "review_edits_discarded")), 0)
		eq(t, "head", e.head(), start)
		if _, err := os.Stat(filepath.Join(e.root, ".kogen/local/runs", id, "index-at-start")); err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(project.ApprovalPath(e.root, testSlug)); err != nil {
			t.Fatal("approval was not preserved")
		}
	})

	t.Run("a moved HEAD is reported as HEAD, not as drift of contents", func(t *testing.T) {
		t.Parallel()
		e, id, start := stopWith(t, nil, func(f *fakeProvider) handler {
			return f.calls("write_file", map[string]any{"path": "app.txt", "content": "reviewer edit\n"},
				"shell", map[string]any{"command": "git commit -q -am reviewer-commit"})
		})
		why := lastOnly(e, id)["why"].(string)
		eq(t, "eligible", lastOnly(e, id)["eligible"], any(false))
		contains(t, "why", why, "HEAD moved")
		lacks(t, "why", why, "candidate changed")
		eq(t, "commits", e.commitsSince(start), "1")
		eq(t, "the reviewer's commit stays", e.gitOut("log", "-1", "--format=%s"), "reviewer-commit")
	})

	t.Run("a restaged index is reported as the index, not as drift of contents", func(t *testing.T) {
		t.Parallel()
		e, id, start := stopWith(t, nil, func(f *fakeProvider) handler {
			return f.calls("shell", map[string]any{"command": "printf 'x\\n' > staged.txt && git add staged.txt"})
		})
		only := lastOnly(e, id)
		eq(t, "eligible", only["eligible"], any(false))
		contains(t, "why", only["why"].(string), "staged index changed")
		lacks(t, "why", only["why"].(string), "candidate changed")
		eq(t, "head", e.head(), start)
		eq(t, "the reviewer's file is left in place", e.read("staged.txt"), "x\n")
	})

	t.Run("an explicit resume of a changed or inconsistent stopped candidate names the actual fact", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		id, _ := e.stopNatively()
		doc, state := e.checkpoint(id)
		green := state["continuation"].(map[string]any)["pass"].(map[string]any)["tree"].(string)
		raw, err := os.ReadFile(e.runPath(id, "checkpoint.json"))
		if err != nil {
			t.Fatal(err)
		}
		refused := func(name string, want ...string) {
			t.Helper()
			before, requests := e.snapshot(), e.prov.count()
			r := e.resumeReviewed(id)
			if r.exit != 1 || !strings.Contains(r.shown(), "candidate/") {
				t.Fatalf("%s: exit %d, want a refusal\n%s", name, r.exit, r.shown())
			}
			for _, w := range want {
				contains(t, name, r.shown(), w)
			}
			eq(t, name+": provider requests", e.prov.count(), requests)
			after := e.snapshot()
			eq(t, name+": files", after.files, before.files)
			eq(t, name+": index", after.index, before.index)
			eq(t, name+": HEAD", after.head, before.head)
			eq(t, name+": approval", after.approval, before.approval)
			eq(t, name+": runs", after.runs, before.runs)
			eq(t, name+": no commit", e.commitsSince(before.head), "0")
		}

		e.write("app.txt", "drifted\n")
		observed := treeOfCandidate(e)
		refused("changed candidate", "app.txt", "observed tree "+short(observed), "green tree "+short(green))
		eq(t, "the edited candidate is not restored", e.read("app.txt"), "drifted\n")
		e.write("app.txt", "candidate\n")

		// The checkpoint's own pass names another tree than the unchanged candidate: the refusal
		// reports both trees and why the paths cannot be listed, not a claim of changed contents.
		other := strings.Repeat("0", 40)
		state["continuation"].(map[string]any)["pass"].(map[string]any)["tree"] = other
		doc["state"] = state
		e.writeCheckpoint(id, doc)
		refused("another pass's tree", "observed tree", "green tree "+short(other), "cannot be inspected")
		if err := os.WriteFile(e.runPath(id, "checkpoint.json"), raw, 0o600); err != nil {
			t.Fatal(err)
		}
		eq(t, "saved green tree", green, treeOfCandidate(e))

		// Everything restored: the same checkpoint resumes.
		e.prov.then(submit(e.prov, "approve"))
		if r := e.resumeReviewed(id); r.exit != 0 {
			t.Fatalf("control resume exit %d\n%s", r.exit, r.shown())
		}
	})

	t.Run("a blocking or rejected verdict is not a missing verdict", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		f := e.prov
		f.then(landScript(f)...)
		f.then(submit(f, "changes", finding("blocking", "app.txt is wrong")))
		wantStop(t, e.reviewed(), "candidate/review_blocked")
		id := e.onlyRun()
		for _, name := range []string{"review_retry", "review_only", "review_allowance"} {
			eq(t, name+" events", len(eventsNamed(e.events(id), name)), 0)
		}
		eq(t, "review requests", len(f.reviewRequests()), 1)

		// A rejected verdict spends only its own allowance, bounded at one send-back.
		e = newEnv(t)
		f = e.prov
		f.then(landScript(f)...)
		bad := finding("blocking", "An approve verdict cannot contain a blocking finding.")
		f.then(submit(f, "approve", bad), submit(f, "approve", bad), prose("a"), prose("b"))
		wantStop(t, e.reviewed(), "candidate/review_invalid")
		id = e.onlyRun()
		verdicts := e.reviewVerdicts(id)
		eq(t, "review 1 reason", verdicts[0]["reason"], any("rejected_verdict_exhausted"))
		eq(t, "review 1 counters", counters(verdicts[0]), [2]float64{1, 0})
		eq(t, "review requests", len(f.reviewRequests()), 4)
	})
}

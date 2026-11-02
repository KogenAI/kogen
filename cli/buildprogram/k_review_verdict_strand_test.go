package buildprogram

import (
	"encoding/json"
	"strings"
	"testing"
)

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

// TestKReviewVerdictStrandPinnedResume: two successive verdictless reviewers of one completed
// green pass, with pinned source delivered by native prefill around the forced turn, leave an
// exact-green review-only checkpoint with the automatic retry spent; the real `kogen intent
// resume` starts one fresh review that obtains a valid verdict and lands only the reviewed
// green tree, with no builder round and no completed verification rerun.
func TestKReviewVerdictStrandPinnedResume(t *testing.T) {
	t.Parallel()
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

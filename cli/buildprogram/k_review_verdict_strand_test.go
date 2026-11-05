package buildprogram

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// strandEdits is a reviewer turn that edits the checkout in every way (modification, deletion,
// addition, mode) before the reviewer goes verdictless.
func strandEdits(f *fakeProvider) handler {
	return f.calls("write_file", map[string]any{"path": "app.txt", "content": "reviewer edit\n"},
		"shell", map[string]any{"command": "rm README.md && printf 'scratch\\n' > notes.txt && chmod +x features/steps/integration_steps.js"})
}

// strandFile is the strand candidate: twice bigFile(), so that its source, delivered once, still
// exceeds the reviewer's input window and is pinned in parts.
func strandFile() string { return strings.Repeat(bigFile(), 2) }

// strandBuilder is the builder's one response: a candidate whose pinned source needs many parts.
func strandBuilder(f *fakeProvider) handler {
	return f.calls("write_file", map[string]any{"path": "app.txt", "content": strandFile()}, "finish", map[string]any{"summary": "done"})
}

// strandParts reads the pinned part files <runs dir>/review-source/<review>-<tree>/<n>.json that
// kogen-build wrote for one review: n = 1..N without gaps, each with an empty input and a
// review_source of that review, part n and parts N. It returns their paths in part order.
func strandParts(t *testing.T, dir string, review int) []string {
	t.Helper()
	paths := partPaths(dir)
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "files in "+dir, len(entries), len(paths))
	for i, path := range paths {
		var doc struct {
			Input        any `json:"input"`
			ReviewSource struct {
				Review int    `json:"review"`
				Part   int    `json:"part"`
				Parts  int    `json:"parts"`
				Text   string `json:"text"`
			} `json:"review_source"`
		}
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(data, &doc); err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		src := doc.ReviewSource
		if jsonOf(doc.Input) != "[]" && doc.Input != nil && doc.Input != "" || src.Review != review || src.Part != i+1 || src.Parts != len(paths) {
			t.Fatalf("%s: input %v, review_source review %d part %d parts %d, want an empty input, review %d part %d parts %d",
				path, doc.Input, src.Review, src.Part, src.Parts, review, i+1, len(paths))
		}
	}
	return paths
}

// partPaths are the part files 1.json, 2.json, ... in dir up to the first missing number.
func partPaths(dir string) []string {
	var paths []string
	for n := 1; ; n++ {
		path := filepath.Join(dir, strconv.Itoa(n)+".json")
		if _, err := os.Stat(path); err != nil {
			return paths
		}
		paths = append(paths, path)
	}
}

// partNumber is n of a path <review>-<tree>/<n>.json under the part directory named dirName, or 0.
func partNumber(path, dirName string) int {
	if filepath.Base(filepath.Dir(path)) != dirName {
		return 0
	}
	n, err := strconv.Atoi(strings.TrimSuffix(filepath.Base(path), ".json"))
	if err != nil {
		return 0
	}
	return n
}

// confirmingReviewer is a reviewer that approves only after it has read what it cannot confirm
// was delivered. In each request it reads, at most 8 per response, the parts of the review whose
// part files match partsGlob that the request itself does not show as delivered: by a completed
// read_file in its window, by a native prefill message, or (in a current reset handoff) by not
// being listed as unread. When no part is left it approves.
func confirmingReviewer(t *testing.T, f *fakeProvider, partsGlob string) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		reqs := f.reviewRequests()
		req := reqs[len(reqs)-1]
		var paths []string
		if dirs, _ := filepath.Glob(partsGlob); len(dirs) == 1 {
			paths = partPaths(dirs[0])
		}
		name := filepath.Base(partsGlob)
		known := map[int]bool{}
		read, _ := inWindow(req)
		for path := range read {
			known[partNumber(path, name)] = true
		}
		for path := range prefilledParts(t, req) {
			known[partNumber(path, name)] = true
		}
		if reset := resetHandoff(t, req); reset != nil {
			if d, ok := reset["review_delivery"].(map[string]any); ok {
				if source, ok := d["source"].(map[string]any); ok && source["current"] == true {
					unread := map[int]bool{}
					for _, n := range source["unread"].([]any) {
						unread[int(n.(float64))] = true
					}
					for n := range paths {
						if !unread[n+1] {
							known[n+1] = true
						}
					}
				}
			}
		}
		var pairs []any
		for n, p := range paths {
			if !known[n+1] && len(pairs) < 16 {
				pairs = append(pairs, "read_file", map[string]any{"path": p})
			}
		}
		if len(pairs) > 0 {
			f.calls(pairs...)(w, r)
			return
		}
		submit(f, "approve")(w, r)
	}
}

// TestKReviewVerdictStrandPinnedResume: two successive verdictless reviewers of one completed
// green pass, with pinned source delivered by native prefill around the forced turn, leave an
// exact-green review-only checkpoint with the automatic retry spent; the real `kogen intent
// resume` starts one fresh review whose early approval, with pinned parts unread, is refused and
// names them, and which then obtains a valid verdict and lands only the reviewed green tree, with
// no builder round and no completed verification rerun. It asserts outcomes (kogen-build's part
// files, prefill and reset handoff, events, results, Git state), not kogen-review's request
// layout, request counts or bytes, or its prompt and refusal wording.
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
	green := treeOfCandidate(e)
	// The pinned source is the actual generated fixture's: many parts, in kogen-build's part files.
	parts2 := strandParts(t, filepath.Join(e.runPath(id, "review-source"), "2-"+green), 2)
	if len(parts2) < 20 {
		t.Fatalf("only %d pinned parts", len(parts2))
	}
	prefills := 0
	for _, ev := range eventsNamed(events, "review_source_prefill") {
		if ev["review"] != float64(2) {
			continue
		}
		prefills++
		for _, p := range ev["parts"].([]any) {
			if n, _ := p.(float64); n < 1 || n > float64(len(parts2)) {
				t.Fatalf("review 2 prefill lists part %v, outside 1..%d", p, len(parts2))
			}
		}
	}
	if prefills == 0 {
		t.Fatal("no review_source_prefill event of review 2")
	}
	faults := eventsNamed(events, "provider_fault")
	eq(t, "provider faults, one per review", len(faults), 2)
	for i, ev := range faults {
		eq(t, "fault of review", ev["review"], any(float64(i+1)))
		eq(t, "fault", ev["fault"], any("forced_tool_not_called"))
	}
	// The stopped run's reviewer requests belong to exactly two conversations, review 1's then
	// review 2's, each with a request that names submit_review as the tool choice; review 2's last
	// such request carries the working-window reset.
	var keys []string
	lastForced := map[string]map[string]any{}
	for _, req := range reqs {
		key := cacheKey(req)
		if len(keys) == 0 || keys[len(keys)-1] != key {
			for _, k := range keys {
				if k == key {
					t.Fatalf("conversation %s resumed after another began", key)
				}
			}
			keys = append(keys, key)
		}
		if jsonOf(req["tool_choice"]) == jsonOf(forcedSubmit) {
			lastForced[key] = req
		}
	}
	eq(t, "reviewer conversations", len(keys), 2)
	for i, key := range keys {
		if lastForced[key] == nil {
			t.Fatalf("review %d's conversation has no request that names submit_review as its tool choice", i+1)
		}
	}
	if resetHandoff(t, lastForced[keys[1]]) == nil {
		t.Fatal("review 2's last forced request carries no working-window reset")
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
	eq(t, "candidate preserved", e.read("app.txt"), strandFile())
	eq(t, "README preserved", e.read("README.md"), "# Fixture project\n")
	eq(t, "modified files", e.gitOut("diff", "--name-only"), "app.txt")
	eq(t, "no reviewer addition", e.gitOut("ls-files", "--others", "--exclude-standard", "--", "notes.txt"), "")
	eq(t, "head", e.head(), start)
	buildRequests := f.count() - len(reqs)
	eq(t, "builder requests", buildRequests, 1)

	// Explicit resume: one fresh reviewer approves at once, with pinned parts unread, and is
	// refused; it then reads every part it cannot confirm was delivered and approves.
	before, reviewBefore := f.count(), len(reqs)
	early := f.call("submit_review", map[string]any{"verdict": "approve", "findings": []any{}})
	partsGlob := filepath.Join(e.root, ".kogen/local/runs/*/review-source/3-"+green)
	f.then(sse(early))
	f.then(repeatHandler(confirmingReviewer(t, f, partsGlob), 80)...)
	code, out = e.cli(bin, "intent", "resume", id)
	if code != 0 || !strings.Contains(out, "landed "+testSlug+" ") {
		t.Fatalf("resume exit %d\n%s", code, out)
	}
	resumed := e.runNotIn(id)
	eq(t, "every new request is the fresh review's", f.count()-before, len(f.reviewRequests())-reviewBefore)
	reqs = f.reviewRequests()
	third := reqs[reviewBefore]
	parts3 := strandParts(t, filepath.Join(e.runPath(resumed, "review-source"), "3-"+green), 3)
	dirName := "3-" + green
	// The early approval is refused, naming at least one part that the first request's prefill
	// did not carry.
	var refusal string
	for _, req := range reqs[reviewBefore+1:] {
		for _, it := range requestInput(req) {
			m, _ := it.(map[string]any)
			if m["type"] == "function_call_output" && m["call_id"] == early["call_id"] {
				refusal, _ = m["output"].(string)
				if refusal == "" {
					refusal = jsonOf(m["output"])
				}
			}
		}
		if refusal != "" {
			break
		}
	}
	if refusal == "" {
		t.Fatal("the approval with unread parts was accepted: no later request carries the output of its submit_review call")
	}
	carried := map[int]bool{}
	for path := range prefilledParts(t, third) {
		carried[partNumber(path, dirName)] = true
	}
	named := 0
	for n := range parts3 {
		if !strings.Contains(refusal, "/"+dirName+"/"+strconv.Itoa(n+1)+".json") {
			continue
		}
		named++
		if carried[n+1] {
			t.Fatalf("the refusal names part %d, which the first request's prefill carried", n+1)
		}
	}
	if named == 0 {
		t.Fatalf("the refusal of the approval with unread parts names no review 3 part path:\n%s", refusal)
	}
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
	eq(t, "every part read before approval", material["parts_read"], any(float64(len(parts3))))
	eq(t, "commits", e.commitsSince(start), "1")
	eq(t, "committed tree", e.gitOut("rev-parse", "HEAD^{tree}"), green)
	eq(t, "committed", e.gitOut("show", "HEAD:app.txt")+"\n", strandFile())
	eq(t, "status", e.gitOut("status", "--porcelain"), "")
	eq(t, "the first run keeps its own failed result", e.result(id)["outcome"], any("review_invalid"))
}

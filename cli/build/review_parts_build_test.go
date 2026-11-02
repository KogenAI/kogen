package build

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen/executor"
)

// partsBuilder is a builder round whose candidate is six added files of about 120 KB each: a
// review prompt of well over the 524288-byte ceiling, which fits in two parts.
func partsBuilder(t *testing.T) func(n int, root string, in executor.Input) (executor.RoundResult, error) {
	return func(n int, root string, in executor.Input) (executor.RoundResult, error) {
		lineupWriteApp(t, root, "candidate\n")
		for i := 1; i <= 6; i++ {
			writeFile(t, filepath.Join(root, fmt.Sprintf("big-%d.txt", i)), strings.Repeat(fmt.Sprintf("file %d: a line of a changed file, kept whole\n", i), 2600), 0o644)
		}
		return executor.RoundResult{Claim: "done"}, nil
	}
}

// partOf is the 1-based part a review task carries ("# Review part <k> of <N>").
func partOf(t *testing.T, task executor.Task) int {
	t.Helper()
	var k, n int
	if _, err := fmt.Sscanf(task.Brief.Dynamic, "# Review part %d of %d\n", &k, &n); err != nil {
		t.Fatalf("the task is not a review part: %.60q", task.Brief.Dynamic)
	}
	return k
}

func readMaterial(t *testing.T, e *env, id string, review int) reviewMaterial {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(e.runPath(id, "executor-review"), fmt.Sprintf("review-%d-material.json", review)))
	if err != nil {
		t.Fatal(err)
	}
	var ev reviewMaterial
	if err := json.Unmarshal(raw, &ev); err != nil {
		t.Fatal(err)
	}
	return ev
}

// A source whose complete prompt does not fit the ceiling is reviewed in ordered parts, each
// in its own fresh session with the complete authority and its exact piece of the source; the
// Build commits once, after the last part's approval.
func TestReviewInPartsLands(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	e.useLineup("")
	start := e.head()
	f := newLineupExec(t)
	f.build = partsBuilder(t)
	f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
		return executor.RoundResult{Structured: verdictJSON("approve"), Usage: harnessUsage(10, 5, 2, 0.01)}, nil
	}
	a := e.build(withLineup(f))
	if a.exit != 0 || a.err != nil {
		t.Fatalf("exit %d err %v\n%s", a.exit, a.err, a.shown())
	}
	eq(t, "commits", e.commitsSince(start), "1")
	tasks := f.starts[executor.RoleReview]
	if len(tasks) != 2 {
		t.Fatalf("%d review sessions, want one per part", len(tasks))
	}
	id := e.onlyRun()
	dir := e.runPath(id, "executor-review")
	ev := readMaterial(t, e, id, 1)
	source, err := os.ReadFile(filepath.Join(dir, "review-1-source.txt"))
	if err != nil {
		t.Fatal(err)
	}
	authority, _ := os.ReadFile(filepath.Join(dir, "review-1-authority.txt"))
	if len(ev.ReviewParts) != 2 || ev.Source.Bytes != len(source) || !ev.Delivered {
		t.Fatalf("material %+v", ev)
	}
	contains(t, "parts task", string(authority), "reviewed in ordered parts")
	lacks(t, "parts task", string(authority), "are included in this message")
	at := 0
	for i, task := range tasks {
		p := ev.ReviewParts[i]
		eq(t, "part number", partOf(t, task), i+1)
		eq(t, "stable text", task.Brief.Stable, string(authority))
		if prompt := len(task.Brief.Stable) + len(task.Brief.Dynamic); prompt > reviewCeiling || p.PromptBytes != prompt {
			t.Errorf("part %d: prompt %d bytes, recorded %d, ceiling %d", i+1, prompt, p.PromptBytes, reviewCeiling)
		}
		text, err := os.ReadFile(filepath.Join(dir, p.File))
		if err != nil || string(text) != task.Brief.Dynamic || p.Bytes != len(text) || p.SHA256 != hashHex(text) {
			t.Errorf("part %d file %s: %v", i+1, p.File, err)
		}
		if st, _ := os.Stat(filepath.Join(dir, p.File)); st.Mode().Perm() != 0o600 {
			t.Errorf("part file mode %v", st.Mode().Perm())
		}
		if p.From != at || !strings.HasSuffix(string(text), string(source[p.From:p.To])) {
			t.Errorf("part %d carries [%d, %d) after %d", i+1, p.From, p.To, at)
		}
		at = p.To
		if !p.Delivered || p.DeliveredRound != 1 || p.SessionID == "" {
			t.Errorf("part %d evidence %+v", i+1, p)
		}
		if !strings.HasSuffix(task.Dir, fmt.Sprintf("executor-review/part-%d", i+1)) {
			t.Errorf("part %d session folder %s", i+1, task.Dir)
		}
		for _, want := range []string{
			fmt.Sprintf("# Review part %d of 2", i+1), "# Check results of the final pass", "# Every changed path", fmt.Sprintf("# Source part %d of 2", i+1),
			"SHA-256 " + hashHex(source),
		} {
			contains(t, "part text", task.Brief.Dynamic, want)
		}
	}
	if at != len(source) || ev.ReviewParts[0].SessionID == ev.ReviewParts[1].SessionID {
		t.Fatalf("the parts cover %d of %d bytes; sessions %q", at, len(source), []string{ev.ReviewParts[0].SessionID, ev.ReviewParts[1].SessionID})
	}
	// Nothing of a path that fits one part is split.
	for i := 1; i <= 6; i++ {
		block := fmt.Sprintf("--- big-%d.txt (added; mode 100644)\n", i) + strings.Repeat(fmt.Sprintf("file %d: a line of a changed file, kept whole\n", i), 2600)
		if !strings.Contains(tasks[0].Brief.Dynamic, block) && !strings.Contains(tasks[1].Brief.Dynamic, block) {
			t.Errorf("big-%d.txt was split across parts", i)
		}
	}

	events := e.events(id)
	want := []map[string]any{{"event": "review_parts", "review": 1.0, "parts": 2.0, "source_bytes": float64(len(source)), "ceiling": float64(reviewCeiling)}}
	if got := eventsNamed(events, "review_parts"); fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("review_parts events %v, want %v", got, want)
	}
	var parts []any
	for _, ev := range eventsNamed(events, "executor_round") {
		if ev["role"] == executor.RoleReview {
			parts = append(parts, ev["part"])
		}
	}
	eq(t, "round events' parts", fmt.Sprint(parts), "[1 2]")
	progress := a.out.String() + a.errs.String()
	contains(t, "progress", progress, "kogen: reviewing (review 1) in 2 parts: the complete review prompt would be ")
	contains(t, "progress", progress, " bytes, over the 524288-byte ceiling")
	contains(t, "progress", progress, "kogen: reviewing (review 1, part 1 of 2)")
	contains(t, "progress", progress, "kogen: reviewing (review 1, part 2 of 2)")
	res := e.result(id)
	rx := res["review_executor"].(map[string]any)
	eq[any](t, "newest part's session", rx["session_id"], ev.ReviewParts[1].SessionID)
	eq[any](t, "usage of every part session", rx["usage"].(map[string]any)["input"], 20.0)
}

// A blocking verdict of any part stops the Build as today, and later parts are never started.
func TestReviewInPartsBlockStopsLaterParts(t *testing.T) {
	t.Parallel()
	for _, blocked := range []int{1, 2} {
		t.Run(fmt.Sprintf("part %d", blocked), func(t *testing.T) {
			t.Parallel()
			e := newEnv(t)
			e.useLineup("")
			start := e.head()
			f := newLineupExec(t)
			f.build = partsBuilder(t)
			f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
				if partOf(t, task) == blocked {
					return executor.RoundResult{Structured: verdictJSON("changes", blockingFinding)}, nil
				}
				return executor.RoundResult{Structured: verdictJSON("approve")}, nil
			}
			a := e.build(withLineup(f))
			wantStop(t, a, "candidate/review_blocked")
			contains(t, "finding", a.shown(), "review: app.txt:1: wrong")
			eq(t, "HEAD", e.head(), start)
			eq(t, "review sessions", len(f.starts[executor.RoleReview]), blocked)
			if e.read("big-6.txt") == "" {
				t.Fatal("the candidate was not kept")
			}
		})
	}
}

// A repair of an earlier part is verified (red results return to that part's session) and the
// next part reviews the pass that approval bound; the commit is of that exact tree.
func TestReviewInPartsRepairIsVerifiedBeforeTheNextPart(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	e.useLineup("")
	start := e.head()
	f := newLineupExec(t)
	f.build = partsBuilder(t)
	var seen string
	f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
		if partOf(t, task) == 2 {
			seen = e.read("app.txt")
			return executor.RoundResult{Structured: verdictJSON("approve")}, nil
		}
		if n == 1 {
			lineupWriteApp(t, root, "red\n")
		} else {
			lineupWriteApp(t, root, "fixed by the first part's reviewer\n")
		}
		return executor.RoundResult{Structured: verdictJSON("approve")}, nil
	}
	a := e.build(withLineup(f))
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	eq(t, "commits", e.commitsSince(start), "1")
	eq(t, "committed app.txt", e.gitOut("show", "HEAD:app.txt"), "fixed by the first part's reviewer")
	eq(t, "the second part's reviewer saw the verified repair", seen, "fixed by the first part's reviewer\n")
	eq(t, "review sessions", len(f.starts[executor.RoleReview]), 2)
	rounds := f.rounds(executor.RoleReview)
	if len(rounds) != 3 || !strings.Contains(rounds[1].Feedback, "is not green") {
		t.Fatalf("review inputs %+v: red results return to the part's own session", rounds)
	}
	ev := readMaterial(t, e, e.onlyRun(), 1)
	if ev.ReviewParts[0].DeliveredRound != 1 || ev.ReviewParts[1].DeliveredRound != 1 {
		t.Fatalf("evidence %+v", ev.ReviewParts)
	}
}

// A part that ends without a valid verdict ends the whole review: the one automatic fresh review
// starts the part sequence again from part 1, as a new review number.
func TestReviewInPartsVerdictlessPartRestartsFromPartOne(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	e.useLineup("")
	start := e.head()
	f := newLineupExec(t)
	f.build = partsBuilder(t)
	var order []string
	f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
		order = append(order, fmt.Sprintf("%d", partOf(t, task)))
		if len(order) == 2 { // review 1's part 2
			return executor.RoundResult{Ending: executor.EndNoCall}, nil
		}
		return executor.RoundResult{Structured: verdictJSON("approve")}, nil
	}
	a := e.build(withLineup(f))
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	eq(t, "commits", e.commitsSince(start), "1")
	eq(t, "parts reviewed", strings.Join(order, ","), "1,2,1,2")
	id := e.onlyRun()
	events := e.events(id)
	eq(t, "automatic retries", len(eventsNamed(events, "review_retry")), 1)
	var reviews []any
	for _, ev := range eventsNamed(events, "review_parts") {
		reviews = append(reviews, ev["review"])
	}
	eq(t, "review_parts events", fmt.Sprint(reviews), "[1 2]")
	first, second := readMaterial(t, e, id, 1), readMaterial(t, e, id, 2)
	// Part 2 of review 1 ended without a completed round: it was never delivered.
	if !first.ReviewParts[0].Delivered || first.ReviewParts[1].Delivered || len(second.ReviewParts) != 2 || !second.ReviewParts[1].Delivered || second.ReviewParts[0].SessionID == first.ReviewParts[0].SessionID {
		t.Fatalf("review 1 %+v review 2 %+v", first.ReviewParts, second.ReviewParts)
	}
}

// A part's file is held to the same custody as the authority and the source.
func TestReviewInPartsCustody(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	e.useLineup("")
	start := e.head()
	f := newLineupExec(t)
	f.build = partsBuilder(t)
	f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
		if partOf(t, task) == 2 {
			matches, _ := filepath.Glob(filepath.Join(root, ".kogen/local/runs/*/executor-review/review-1-part-2.txt"))
			if len(matches) != 1 {
				t.Fatalf("no part file: %v", matches)
			}
			os.WriteFile(matches[0], []byte("abbreviated"), 0o600)
		}
		return executor.RoundResult{Structured: verdictJSON("approve")}, nil
	}
	a := e.build(withLineup(f))
	wantStop(t, a, "candidate/context_custody_invalid")
	contains(t, "custody", a.shown(), "review-1-part-2.txt changed")
	eq(t, "HEAD", e.head(), start)
}

// Mandatory review material that leaves no room for source stops before any session starts.
func TestReviewInPartsMandatoryMaterialStopsBeforeSending(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	e.useLineup("")
	start := e.head()
	f := newLineupExec(t)
	f.build = func(n int, root string, in executor.Input) (executor.RoundResult, error) {
		lineupWriteApp(t, root, "candidate\n")
		writeFile(t, filepath.Join(root, "README.md"), strings.Repeat("a README line that every review prompt carries\n", 12000), 0o644)
		return executor.RoundResult{Claim: "done"}, nil
	}
	f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
		t.Error("a review session started")
		return executor.RoundResult{Structured: verdictJSON("approve")}, nil
	}
	a := e.build(withLineup(f))
	shown := wantStop(t, a, "candidate/context_budget_exceeded")
	for _, want := range []string{
		"review: mandatory review prompt of executor claude-code is ", " bytes without candidate source; fewer than 6000 bytes remain for source under the inclusive 524288-byte ceiling; nothing was sent.",
		"ordinary Refine and new exact approval are required if the Intent, README or diagnostic context must shrink",
	} {
		contains(t, "stop", shown, want)
	}
	eq(t, "HEAD", e.head(), start)
	eq(t, "review sessions", len(f.starts[executor.RoleReview]), 0)
	eq[any](t, "outcome", e.result(e.onlyRun())["outcome"], "context_budget_exceeded")
	if e.read("README.md") == "" {
		t.Fatal("the candidate was not kept")
	}
}

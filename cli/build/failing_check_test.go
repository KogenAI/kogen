package build

import (
	"strings"
	"testing"

	"kogen/project"
)

// A configured check that already fails does not stop the Build from starting: its result is
// recorded as a baseline, shown to the user, the builder and the reviewer, and never waives
// the rule that every configured check passes before landing (AUT-5).

// committing adds committed files to the fixture project, the way an existing project's files
// are there before the Build starts.
func (e *env) committing(files map[string]string) {
	e.t.Helper()
	for path, content := range files {
		e.write(path, content)
		e.run("git", "add", path)
	}
	e.run("git", "commit", "-qm", "fixture files")
}

// checkRows are the rows of result.json's retained before/after comparison.
func checkRows(t *testing.T, result map[string]any) []map[string]any {
	t.Helper()
	cmp, ok := result["check_comparison"].(map[string]any)
	if !ok {
		t.Fatalf("result has no check_comparison: %v", result)
	}
	var rows []map[string]any
	for _, r := range cmp["checks"].([]any) {
		rows = append(rows, r.(map[string]any))
	}
	return rows
}

// side is one side of a row: its state, its status (-1 for none) and its output.
func side(t *testing.T, row map[string]any, which string) (string, int, string) {
	t.Helper()
	m := row[which].(map[string]any)
	status := -1
	if s, ok := m["status"].(float64); ok {
		status = int(s)
	}
	output, _ := m["output"].(string)
	return m["state"].(string), status, output
}

func expectSide(t *testing.T, row map[string]any, which, state string, status int, output string) {
	t.Helper()
	gotState, gotStatus, gotOutput := side(t, row, which)
	if gotState != state || gotStatus != status || !strings.Contains(gotOutput, output) || (output == "" && gotOutput != "") {
		t.Fatalf("%s %s = (%q, %d, %q), want (%q, %d, containing %q)", row["name"], which, gotState, gotStatus, gotOutput, state, status, output)
	}
}

// commandResults are the command_result events of a check in a run's log, in order.
func commandResults(evs []map[string]any, name string) []int {
	var out []int
	for _, ev := range evs {
		if ev["event"] == "command_result" && ev["name"] == name {
			out = append(out, int(ev["status"].(float64)))
		}
	}
	return out
}

func TestFailingCheckBuildRepair(t *testing.T) {
	t.Parallel()
	// The macOS failure of K-PROBE-COUNT-MAC: BSD wc -l pads a zero count. The literal padded
	// count keeps the failure on every host, and the scripted repair trims it.
	e := newEnv(t, func(c *project.Config) {
		c.Checks = []project.Check{{Name: "count", Run: `echo "count is [$(cat count.txt)]"; test "$(cat count.txt)" = 0`}}
	})
	e.committing(map[string]string{"count.txt": "       0\n"})
	f := e.prov
	f.then(f.calls("shell", map[string]any{"command": "sed 's/^ *//' count.txt > count.trim && mv count.trim count.txt"},
		"finish", map[string]any{"summary": "trimmed the padded zero"}))
	f.then(submit(f, "approve"))
	start := e.head()
	a := e.reviewed()
	if a.exit != 0 || a.err != nil {
		t.Fatalf("exit %d err %v\n%s", a.exit, a.err, a.shown())
	}
	id := e.onlyRun()

	// The failing check did not stop the start: the builder was invoked and saw the failure.
	reqs := f.requests()
	builder := requestText(reqs[0])
	contains(t, "builder request", builder, "Baseline check results (before any edit)")
	contains(t, "builder request", builder, "1. count (")
	contains(t, "builder request", builder, "failed (status=1)")
	contains(t, "builder request", builder, "count is [       0]")
	contains(t, "builder request", builder, "not a waiver")

	// The check ran again on the candidate and passed; the baseline stayed a failure.
	evs := e.events(id)
	eq(t, "count results", commandResults(evs, "count"), []int{1, 0})
	passes := eventsNamed(evs, "pass")
	eq(t, "passes", len(passes), 1)
	eq(t, "green", passes[0]["green"], any(true))

	// The independent reviewer was invoked on the green candidate with baseline and final results.
	reviews := f.reviewRequests()
	eq(t, "review requests", len(reviews), 1)
	review := requestText(reviews[0])
	contains(t, "review request", review, "1. count (")
	contains(t, "review request", review, "baseline failed (status=1) → final passed")
	contains(t, "review request", review, "count is [       0]")

	eq(t, "commits", e.gitOut("rev-list", "--count", start+"..HEAD"), "1")
	eq(t, "committed count", e.gitOut("show", "HEAD:count.txt"), "0")

	out := a.out.String()
	contains(t, "stdout", out, "baseline: 1 of 1 configured check(s) fail before the Build changes anything")
	contains(t, "stdout", out, "landed fixture ")
	contains(t, "stdout", out, "    1. count: failed (status=1) → passed\n")
	rows := checkRows(t, e.result(id))
	eq(t, "rows", len(rows), 1)
	expectSide(t, rows[0], "before", "failed", 1, "count is [       0]")
	expectSide(t, rows[0], "after", "passed", 0, "")
}

func TestFailingCheckBuildEvidence(t *testing.T) {
	t.Parallel()
	e := newEnv(t, func(c *project.Config) {
		c.Checks = []project.Check{
			{Name: "first", Run: `grep -qx first=ok flags.txt || { echo FIRST-MARKER; exit 3; }`},
			{Name: "second", Run: `grep -qx second=ok flags.txt || { echo SECOND-MARKER; exit 5; }`},
			{Name: "third", Run: `echo THIRD-MARKER`},
		}
	})
	e.committing(map[string]string{"flags.txt": "first=bad\nsecond=bad\n"})
	f := e.prov
	// The first round edits something else; the provider then refuses, which stops the Build
	// resumably with the red verification as its last result.
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": "unrelated\n"}, "finish", map[string]any{"summary": "edited app"}), refused())
	a := e.reviewed()
	if a.exit != 4 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	id := e.onlyRun()

	// Every check was collected in configured order although the first one failed.
	evs := e.events(id)
	var before []string
	for _, ev := range evs {
		if ev["event"] == "command_result" && ev["name"] != nil && len(before) < 3 {
			before = append(before, ev["name"].(string))
		}
	}
	eq(t, "collection order", before, []string{"first", "second", "third"})
	eq(t, "baseline event", eventsNamed(evs, "baseline_checks")[0]["failing"], any([]any{"first", "second"}))

	// The builder saw every state, in order.
	builder := requestText(f.requests()[0])
	iFirst, iSecond, iThird := strings.Index(builder, "1. first ("), strings.Index(builder, "2. second ("), strings.Index(builder, "3. third (")
	if iFirst < 0 || iFirst > iSecond || iSecond > iThird {
		t.Fatalf("baseline order %d %d %d in builder request:\n%s", iFirst, iSecond, iThird, builder)
	}
	contains(t, "builder request", builder, "FIRST-MARKER")
	contains(t, "builder request", builder, "SECOND-MARKER")
	contains(t, "builder request", builder, "3. third (echo THIRD-MARKER): passed")
	// The red feedback names the check that is still failing.
	contains(t, "feedback", requestText(f.requests()[1]), "check first (")

	// The user saw them, and the stopped Build compares them with what was not run.
	out := a.out.String()
	contains(t, "stdout", out, "baseline: 2 of 3 configured check(s) fail")
	contains(t, "stdout", out, "  check first (grep -qx first=ok flags.txt || { echo FIRST-MARKER; exit 3; }) failed (status=3)\n    FIRST-MARKER\n")
	contains(t, "stdout", out, "  check second (grep -qx second=ok flags.txt || { echo SECOND-MARKER; exit 5; }) failed (status=5)\n    SECOND-MARKER\n")
	contains(t, "stdout", out, "checks, before the Build → after (verification pass 1):\n"+
		"    1. first: failed (status=3) → failed (status=3)\n")
	contains(t, "stdout", out, "    2. second: failed (status=5) → not run\n")
	contains(t, "stdout", out, "    3. third: passed → not run\n")
	contains(t, "stdout", out, "       before output:\n         FIRST-MARKER\n       after output:\n         FIRST-MARKER\n")
	lacks(t, "stdout", out, "landed")

	// The retained result and checkpoint say the same.
	rows := checkRows(t, e.result(id))
	eq(t, "rows", len(rows), 3)
	expectSide(t, rows[0], "before", "failed", 3, "FIRST-MARKER")
	expectSide(t, rows[0], "after", "failed", 3, "FIRST-MARKER")
	expectSide(t, rows[1], "before", "failed", 5, "SECOND-MARKER")
	expectSide(t, rows[1], "after", "not run", -1, "")
	expectSide(t, rows[2], "before", "passed", 0, "")
	expectSide(t, rows[2], "after", "not run", -1, "")
	_, state := e.checkpoint(id)
	saved := state["check_baseline"].([]any)
	eq(t, "saved baseline", len(saved), 3)
	for i, want := range []struct {
		name   string
		status float64
		marker string
	}{{"first", 3, "FIRST-MARKER"}, {"second", 5, "SECOND-MARKER"}, {"third", 0, "THIRD-MARKER"}} {
		got := saved[i].(map[string]any)
		eq(t, "saved name", got["name"], any(want.name))
		eq(t, "saved status", got["status"], any(want.status))
		contains(t, "saved output", got["output"].(string), want.marker)
	}

	// An explicit resume keeps the baseline and continues the same builder: the second round
	// repairs only the first check (the second is now what fails), the third repairs both.
	f.then(
		f.calls("write_file", map[string]any{"path": "flags.txt", "content": "first=ok\nsecond=bad\n"}, "finish", map[string]any{"summary": "first"}),
		f.calls("write_file", map[string]any{"path": "flags.txt", "content": "first=ok\nsecond=ok\n"}, "finish", map[string]any{"summary": "both"}),
		submit(f, "approve"),
	)
	start := e.head()
	r := e.resumeReviewed(id)
	if r.exit != 0 {
		t.Fatalf("resume exit %d\n%s", r.exit, r.shown())
	}
	var resumed string
	for _, other := range e.runIDs() {
		if other != id {
			resumed = other
		}
	}
	passes := eventsNamed(e.events(resumed), "pass")
	eq(t, "resumed passes", len(passes), 2)
	eq(t, "red pass failing", passes[0]["failing"], any([]any{"second"}))
	eq(t, "red pass not run", passes[0]["not_run"], any([]any{"third"}))
	eq(t, "final pass green", passes[1]["green"], any(true))
	rows = checkRows(t, e.result(resumed))
	expectSide(t, rows[0], "before", "failed", 3, "FIRST-MARKER")
	expectSide(t, rows[1], "before", "failed", 5, "SECOND-MARKER")
	expectSide(t, rows[2], "before", "passed", 0, "")
	for _, row := range rows {
		expectSide(t, row, "after", "passed", 0, "")
	}
	_, state = e.checkpoint(resumed)
	eq(t, "resumed baseline", len(state["check_baseline"].([]any)), 3)
	for _, line := range []string{"    1. first: failed (status=3) → passed\n", "    2. second: failed (status=5) → passed\n", "    3. third: passed → passed\n"} {
		contains(t, "resume stdout", r.out.String(), line)
	}
	contains(t, "resume stdout", r.out.String(), "       before output:\n         SECOND-MARKER\n")

	// The reviewer got the baseline and the actual final results of every check.
	reviews := f.reviewRequests()
	eq(t, "review requests", len(reviews), 1)
	review := requestText(reviews[0])
	contains(t, "review request", review, "1. first (")
	contains(t, "review request", review, "baseline failed (status=3) → final passed")
	contains(t, "review request", review, "baseline failed (status=5) → final passed")
	contains(t, "review request", review, "baseline passed → final passed")
	contains(t, "review request", review, "FIRST-MARKER")
	eq(t, "commits", e.gitOut("rev-list", "--count", start+"..HEAD"), "1")
}

func TestFailingCheckBuildUnrelated(t *testing.T) {
	t.Parallel()
	e := newEnv(t, func(c *project.Config) {
		c.Checks = []project.Check{{Name: "unrelated", Run: `grep -qx ok flags.txt || { echo UNRELATED-FAILURE; exit 6; }`}}
	})
	e.committing(map[string]string{"flags.txt": "bad\n"})
	f := e.prov
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": "requested edit\n"}, "finish", map[string]any{"summary": "requested edit"}))
	f.then(sayings(5)...)
	start := e.head()
	a := e.reviewed()
	if a.exit != 1 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	id := e.onlyRun()
	out := a.out.String()

	// The requested edit was done, the unrelated failure stayed red: red feedback to the
	// builder, no review, no commit, nothing reported green.
	contains(t, "feedback", requestText(f.requests()[1]), "UNRELATED-FAILURE")
	eq(t, "reviews", len(f.reviewRequests()), 0)
	eq(t, "head", e.head(), start)
	eq(t, "candidate", e.read("app.txt"), "requested edit\n")
	contains(t, "stdout", out, "candidate/no_progress")
	contains(t, "stdout", out, "  still failing: unrelated\n")
	contains(t, "stdout", out, "    1. unrelated: failed (status=6) → failed (status=6)\n")
	lacks(t, "stdout", out, "landed")
	lacks(t, "stderr", a.errs.String(), "all checks passed")
	res := e.result(id)
	eq(t, "outcome", res["outcome"], any("no_progress"))
	rows := checkRows(t, res)
	expectSide(t, rows[0], "before", "failed", 6, "UNRELATED-FAILURE")
	expectSide(t, rows[0], "after", "failed", 6, "UNRELATED-FAILURE")
	for _, p := range eventsNamed(e.events(id), "pass") {
		eq(t, "green", p["green"], any(false))
	}
}

func TestFailingCheckBuildRegression(t *testing.T) {
	t.Parallel()
	e := newEnv(t, func(c *project.Config) {
		c.Checks = []project.Check{
			{Name: "old", Run: `grep -qx old=ok flags.txt || { echo OLD-BASELINE-FAILURE; exit 4; }`},
			{Name: "guard", Run: `grep -qx guard=ok flags.txt || { echo GUARD-REGRESSION; exit 9; }`},
		}
	})
	e.committing(map[string]string{"flags.txt": "guard=ok\n"})
	f := e.prov
	// The repair of the failing check removes what the formerly green one needs.
	f.then(f.calls("write_file", map[string]any{"path": "flags.txt", "content": "old=ok\n"}, "finish", map[string]any{"summary": "repaired old"}))
	f.then(sayings(5)...)
	start := e.head()
	a := e.reviewed()
	if a.exit != 1 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	id := e.onlyRun()
	out := a.out.String()

	feedback := requestText(f.requests()[1])
	contains(t, "feedback", feedback, "check guard (")
	contains(t, "feedback", feedback, "GUARD-REGRESSION")
	lacks(t, "feedback", feedback, "check old (grep")
	eq(t, "reviews", len(f.reviewRequests()), 0)
	eq(t, "head", e.head(), start)
	contains(t, "stdout", out, "  still failing: guard\n")
	contains(t, "stdout", out, "    1. old: failed (status=4) → passed\n")
	contains(t, "stdout", out, "    2. guard: passed → failed (status=9)\n")
	lacks(t, "stdout", out, "landed")
	rows := checkRows(t, e.result(id))
	expectSide(t, rows[0], "before", "failed", 4, "OLD-BASELINE-FAILURE")
	expectSide(t, rows[0], "after", "passed", 0, "")
	expectSide(t, rows[1], "before", "passed", 0, "")
	expectSide(t, rows[1], "after", "failed", 9, "GUARD-REGRESSION")
	for _, p := range eventsNamed(e.events(id), "pass") {
		eq(t, "green", p["green"], any(false))
	}
}

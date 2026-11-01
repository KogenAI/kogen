package shape

import (
	"encoding/json"
	"kogen/executor"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const unwrittenHeadline = "Acceptance depends on tests the Build would have to invent: 1 scenario(s) run named tests that do not exist before the Build; nothing was published. " +
	"Acceptance must observe behaviour that any correct implementation produces (run the program, call the code or inspect its output), " +
	"not test names or files the Build has to write. Rewrite these steps; resubmitting them unchanged is refused again."

const unwrittenFeedback = unwrittenHeadline + "\n- Even numbers (line 2): TestWidgetDoubles: did not run (no tests to run)"

// unwrittenReport is the red report of shpFeature in which the first scenario's failing step ran
// a named test against a tree without it, and the second one failed on its own assertion.
func (f *shpFx) unwrittenReport() {
	f.t.Helper()
	f.setReport("FAILED", 1)
	path := filepath.Join(f.Aux, "report")
	b, err := os.ReadFile(path)
	if err != nil {
		f.t.Fatal(err)
	}
	was, _ := json.Marshal("assertion failed in scenario Even numbers")
	now, _ := json.Marshal("must run exactly once: 0 !== 1\ncd cli && go test -count=1 -json -run ^TestWidgetDoubles$ .\n{\"Action\":\"start\",\"Package\":\"example/widget\"}\nno tests to run")
	if !strings.Contains(string(b), string(was)) {
		f.t.Fatal("report has no failure message to replace")
	}
	if err := os.WriteFile(path, []byte(strings.Replace(string(b), string(was), string(now), 1)), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

func unwrittenOutput(t *testing.T, req map[string]any, call string) string {
	t.Helper()
	out, ok := shpOutputs(req)[call]
	if !ok {
		t.Fatalf("request has no output for %s: %v", call, shpOutputs(req))
	}
	return out
}

// behaviouralFiles is the package with a trailing comment in the feature: another candidate whose
// scenario lines are unchanged.
func behaviouralFiles() map[string]any {
	files := shpFiles()
	list := files["files"].([]any)
	list[1] = map[string]any{"path": ".kogen/intents/is-even/acceptance.feature", "content": shpFeature + "# behavioural\n"}
	return files
}

func TestUnwrittenTestsAreRefusedAlsoUnchangedAndABehaviouralPackageIsPublished(t *testing.T) {
	parallel(t)
	f := newShpFx(t)
	f.Prov.seq = []shpStep{
		shpSubmit("c1", shpFiles()),
		shpSubmit("c2", shpFiles()),
		shpAnswer(shpCall("c3-inspect", "read_file", map[string]any{"path": "README.md"}), shpCall("c3", "submit", behaviouralFiles())),
		shpSubmit("c4", map[string]any{"files": []any{
			map[string]any{"path": ".kogen/intents/is-even/acceptance.feature", "content": shpFeature + "# behavioural\n"},
		}}),
	}
	// The behavioural candidate observes no named test: its red is the plain one.
	f.unwrittenReport()
	f.Prov.route = func(req map[string]any) *shpStep {
		if _, ok := shpOutputs(req)["c2"]; ok {
			f.setReport("FAILED", 1)
		}
		return nil
	}
	exit, err := f.shape("Add calc.is_even(n).")
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\nstderr: %s", exit, err, f.Stderr)
	}
	reqs := f.Prov.requests()
	shpEq(t, "requests", len(reqs), 4)
	shpEq(t, "feedback 1", unwrittenOutput(t, reqs[1], "c1"), unwrittenFeedback)
	shpEq(t, "feedback 2", unwrittenOutput(t, reqs[2], "c2"), unwrittenFeedback)
	shpContains(t, "feedback 3", unwrittenOutput(t, reqs[3], "c3"), "Readiness observations")
	if strings.Contains(unwrittenOutput(t, reqs[3], "c3"), "Acceptance depends on tests") {
		t.Fatal("the behavioural package was refused")
	}
	var refused int
	for _, e := range shpNamed(f.events(), "submission_refused") {
		shpEq(t, "gate", e["gate"], any("unwritten_tests"))
		shpEq(t, "problems", len(e["problems"].([]any)), 1)
		refused++
	}
	shpEq(t, "refused events", refused, 2)
	shpEq(t, "published", f.read(".kogen/intents/is-even/acceptance.feature"), shpFeature+"# behavioural\n")
	instructions, _ := reqs[0]["instructions"].(string)
	shpContains(t, "instructions", instructions, unwrittenTestGuidance)
}

func TestUnwrittenTestsThreeTimesEndNotReadyWithTheItems(t *testing.T) {
	parallel(t)
	f := newShpFx(t, shpSubmit("c1", shpFiles()), shpSubmit("c2", shpFiles()), shpSubmit("c3", shpFiles()))
	f.unwrittenReport()
	exit, err := f.shape("Add calc.is_even(n).")
	e := shpWantError(t, err, "intent", "not_ready", "the Intent is not ready to build", 1)
	shpEq(t, "exit", exit, 1)
	shpEq(t, "lines", strings.Join(e.Lines, "\n"), "- Even numbers (line 2): TestWidgetDoubles: did not run (no tests to run)")
	shpEq(t, "requests", len(f.Prov.requests()), 3)
	shpEq(t, "refused events", len(shpNamed(f.events(), "submission_refused")), 3)
	if f.exists(".kogen/local/readiness/is-even.json") {
		t.Fatal("a refused candidate left readiness evidence")
	}
	// The files of the last attempt stay.
	shpEq(t, "feature kept", f.read(".kogen/intents/is-even/acceptance.feature"), shpFeature)
}

func TestExternalShapeReceivesTheUnwrittenTestsRefusalAsFeedback(t *testing.T) {
	parallel(t)
	f := newShpFx(t)
	f.useExternalShape(6)
	f.unwrittenReport()
	x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){result(shpFiles()), result(shpFiles()), result(shpFiles())}}
	exit, err := f.shapeWith(x, "Add calc.is_even(n).")
	shpWantError(t, err, "intent", "not_ready", "the Intent is not ready to build", 1)
	shpEq(t, "exit", exit, 1)
	shpEq(t, "rounds", x.calls, 3)
	for _, in := range x.inputs[1:] {
		if !strings.HasPrefix(in.Feedback, unwrittenFeedback+"\n\nCumulative proposal manifest: ") {
			t.Fatalf("feedback = %q", in.Feedback)
		}
	}
}

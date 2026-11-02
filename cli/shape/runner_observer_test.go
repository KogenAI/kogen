package shape

import (
	"encoding/json"
	"kogen/executor"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const runnerObserverHeadline = "Acceptance rejects the test runner's real output: 2 scenario(s) fail although the test runner reported a passing run, or pass an anchored regular expression as a name filter the runner matches literally; nothing was published. " +
	"A step that observes a test runner must accept the summary the runner really prints on the unchanged tree (minitest's default reporter prints \"N runs\", other reporters \"N tests\") " +
	"and give a literal name filter (minitest's -n and -i) only the plain test name. Rewrite these steps; resubmitting them unchanged is refused again."

const (
	runnerObserverItem1 = "- Even numbers (line 2): the step failed although the test runner reported a passing run: 1 runs, 7 assertions, 0 failures, 0 errors, 0 skips"
	runnerObserverItem2 = "- Odd numbers (line 5): the name filter -n ^test_widget_passes$ is a regular expression that the runner matched as a literal test name, so nothing ran: 0 runs, 0 assertions, 0 failures, 0 errors, 0 skips"
	runnerObserverFeed  = runnerObserverHeadline + "\n" + runnerObserverItem1 + "\n" + runnerObserverItem2
)

// replaceFailure replaces the failure message of the scenario's step in the report.
func (f *shpFx) replaceFailure(was, now string) {
	f.t.Helper()
	path := filepath.Join(f.Aux, "report")
	b, err := os.ReadFile(path)
	if err != nil {
		f.t.Fatal(err)
	}
	from, _ := json.Marshal(was)
	to, _ := json.Marshal(now)
	if !strings.Contains(string(b), string(from)) {
		f.t.Fatalf("report has no failure message %q to replace", was)
	}
	if err := os.WriteFile(path, []byte(strings.Replace(string(b), string(from), string(to), 1)), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

// runnerObserverReport is the red report of shpFeature in which the first scenario's observer
// rejected a passing minitest run and the second one's anchored -n filter ran nothing.
func (f *shpFx) runnerObserverReport() {
	f.t.Helper()
	f.setReport("FAILED", 1)
	f.replaceFailure("assertion failed in scenario Even numbers",
		"Required test; bin/rails test test/models/widget_test.rb -n test_widget_passes; exit 0\nRun options: -n test_widget_passes --seed 4242\n\n# Running:\n\n.\n\nFinished in 0.010000s.\n1 runs, 7 assertions, 0 failures, 0 errors, 0 skips\n")
	f.replaceFailure("assertion failed in scenario Odd numbers",
		"bin/rails test test/models/widget_test.rb -n ^test_widget_passes$; exit 1\nRun options: -n \"^test_widget_passes$\" --seed 4242\n\n# Running:\n\n\nFinished in 0.010000s.\n0 runs, 0 assertions, 0 failures, 0 errors, 0 skips\n")
}

func TestRunnerObserversAreRefusedAlsoUnchangedAndACorrectedPackageIsPublished(t *testing.T) {
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
	f.runnerObserverReport()
	// The corrected candidate's red is the plain one.
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
	shpEq(t, "feedback 1", unwrittenOutput(t, reqs[1], "c1"), runnerObserverFeed)
	shpEq(t, "feedback 2", unwrittenOutput(t, reqs[2], "c2"), runnerObserverFeed)
	shpContains(t, "feedback 3", unwrittenOutput(t, reqs[3], "c3"), "Readiness observations")
	var refused int
	for _, e := range shpNamed(f.events(), "submission_refused") {
		shpEq(t, "gate", e["gate"], any("runner_observer"))
		shpEq(t, "problems", len(e["problems"].([]any)), 2)
		refused++
	}
	shpEq(t, "refused events", refused, 2)
	shpEq(t, "published", f.read(".kogen/intents/is-even/acceptance.feature"), shpFeature+"# behavioural\n")
}

func TestRunnerObserversThreeTimesEndNotReadyWithTheItems(t *testing.T) {
	parallel(t)
	f := newShpFx(t, shpSubmit("c1", shpFiles()), shpSubmit("c2", shpFiles()), shpSubmit("c3", shpFiles()))
	f.runnerObserverReport()
	exit, err := f.shape("Add calc.is_even(n).")
	e := shpWantError(t, err, "intent", "not_ready", "the Intent is not ready to build", 1)
	shpEq(t, "exit", exit, 1)
	shpEq(t, "lines", strings.Join(e.Lines, "\n"), runnerObserverItem1+"\n"+runnerObserverItem2)
	shpEq(t, "requests", len(f.Prov.requests()), 3)
	shpEq(t, "refused events", len(shpNamed(f.events(), "submission_refused")), 3)
	if f.exists(".kogen/local/readiness/is-even.json") {
		t.Fatal("a refused candidate left readiness evidence")
	}
	shpEq(t, "feature kept", f.read(".kogen/intents/is-even/acceptance.feature"), shpFeature)
}

func TestExternalShapeReceivesTheRunnerObserverRefusalAsFeedback(t *testing.T) {
	parallel(t)
	f := newShpFx(t)
	f.useExternalShape(6)
	f.runnerObserverReport()
	x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){result(shpFiles()), result(shpFiles()), result(shpFiles())}}
	exit, err := f.shapeWith(x, "Add calc.is_even(n).")
	shpWantError(t, err, "intent", "not_ready", "the Intent is not ready to build", 1)
	shpEq(t, "exit", exit, 1)
	shpEq(t, "rounds", x.calls, 3)
	for _, in := range x.inputs[1:] {
		if !strings.HasPrefix(in.Feedback, runnerObserverFeed+"\n\nCumulative proposal manifest: ") {
			t.Fatalf("feedback = %q", in.Feedback)
		}
	}
}

func TestUnwrittenTestsRefusalWinsOverTheRunnerObserverRefusal(t *testing.T) {
	parallel(t)
	f := newShpFx(t, shpSubmit("c1", shpFiles()), shpSubmit("c2", shpFiles()), shpSubmit("c3", shpFiles()))
	f.unwrittenReport()
	f.replaceFailure("assertion failed in scenario Odd numbers",
		"Run options: -n test_widget_passes --seed 4242\n1 runs, 7 assertions, 0 failures, 0 errors, 0 skips\n")
	_, err := f.shape("Add calc.is_even(n).")
	e := shpWantError(t, err, "intent", "not_ready", "the Intent is not ready to build", 1)
	shpEq(t, "lines", strings.Join(e.Lines, "\n"), "- Even numbers (line 2): TestWidgetDoubles: did not run (no tests to run)")
	reqs := f.Prov.requests()
	shpEq(t, "feedback", unwrittenOutput(t, reqs[1], "c1"), unwrittenFeedback)
	for _, ev := range shpNamed(f.events(), "submission_refused") {
		shpEq(t, "gate", ev["gate"], any("unwritten_tests"))
	}
}

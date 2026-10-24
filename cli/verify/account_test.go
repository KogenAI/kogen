package verify

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"kogen/project"
)

func TestAccountOnlyFinishedCompleteScenariosWithNoExtrasPass(t *testing.T) {
	allStatuses := []string{"PASSED", "FAILED", "UNDEFINED", "PENDING", "SKIPPED", "AMBIGUOUS"}
	dir := t.TempDir()
	_, other := featureWithSteps(t, "extra", 1)
	n := 0
	for stepCount := 1; stepCount <= 5; stepCount++ {
		_, expected := featureWithSteps(t, "generated", stepCount)
		for reported := 0; reported <= stepCount; reported++ {
			for _, status := range allStatuses {
				for _, finished := range []bool{true, false} {
					for _, unexpected := range []bool{false, true} {
						n++
						opts := reportOpts{prefix: "expected", unfinished: !finished, results: statuses(repeatString(status, stepCount)...)}.withReported(reported)
						events := simpleMessages(testFeature, expected, opts)
						if unexpected {
							events = append(events, simpleMessages("features/unexpected.feature", other, reportOpts{prefix: "unexpected"})...)
						}
						report := writeReport(t, dir, "generated.ndjson", events)
						got := account(dir, expected, report, 0, "")

						complete := finished && reported == stepCount
						passed := complete && status == "PASSED"
						want := "report_invalid"
						if complete {
							want = strings.ToLower(status)
						}
						name := fmt.Sprintf("steps=%d reported=%d %s finished=%v unexpected=%v", stepCount, reported, status, finished, unexpected)
						if passed && !unexpected {
							if len(got.Problems) != 0 {
								t.Fatalf("%s: problems %q", name, got.Problems)
							}
						} else if len(got.Problems) == 0 {
							t.Fatalf("%s: no problems", name)
						}
						eq(t, name+" status", got.Scenarios[0].Status, want)
						wantPassed := 0
						if passed {
							wantPassed = 1
						}
						eq(t, name+" passed", got.Passed, wantPassed)
						if unexpected && !slices.ContainsFunc(got.Problems, func(p string) bool { return strings.HasPrefix(p, "unexpected:") }) {
							t.Fatalf("%s: no unexpected problem in %q", name, got.Problems)
						}
					}
				}
			}
		}
	}
	if n != 480 {
		t.Fatalf("checked %d combinations, want 480", n)
	}
}

func TestAccountBindingProblemsSurviveFailedAssertionsUnlikeSkippedSteps(t *testing.T) {
	dir := t.TempDir()
	_, expected := featureWithSteps(t, "mixed", 2)
	for _, status := range []string{"UNDEFINED", "AMBIGUOUS", "SKIPPED"} {
		report := writeReport(t, dir, status+".ndjson", simpleMessages(testFeature, expected, reportOpts{results: statuses("FAILED", status)}))
		got := account(dir, expected, report, 1, "")
		eq(t, status+" scenario", got.Scenarios[0].Status, "failed")
		if status == "SKIPPED" {
			eqSlice(t, "binding problems", got.BindingProblems, nil)
			continue
		}
		if len(got.BindingProblems) != 1 {
			t.Fatalf("%s: binding problems %q", status, got.BindingProblems)
		}
		contains(t, "binding problem", got.BindingProblems[0], strings.ToLower(status)+" step:")
	}
}

func TestAccountScenarioAbsentFromReportIsMissing(t *testing.T) {
	dir := t.TempDir()
	_, expected := featureWithSteps(t, "expected", 1)
	report := writeReport(t, dir, "missing-scenario.ndjson", simpleMessages(testFeature, expected, reportOpts{notStarted: true}))
	got := account(dir, expected, report, 0, "")
	eq(t, "status", got.Scenarios[0].Status, "missing")
	eqSlice(t, "problems", got.Problems, []string{"missing: expected (line 2)"})
}

func TestAccountSameScenarioKeyReportedTwiceIsDuplicate(t *testing.T) {
	dir := t.TempDir()
	_, expected := featureWithSteps(t, "duplicated", 1)
	report := writeReport(t, dir, "duplicate.ndjson", simpleMessages(testFeature, expected, reportOpts{repeat: 2}))
	got := account(dir, expected, report, 0, "")
	eq(t, "status", got.Scenarios[0].Status, "duplicate")
	eqSlice(t, "problems", got.Problems, []string{"duplicate: duplicated (line 2)"})
}

func TestAccountResultForUnexpectedFeatureRemainsAProblem(t *testing.T) {
	dir := t.TempDir()
	_, expected := featureWithSteps(t, "expected", 1)
	_, other := featureWithSteps(t, "unexpected", 1)
	events := append(simpleMessages(testFeature, expected, reportOpts{prefix: "expected"}),
		simpleMessages("features/unexpected.feature", other, reportOpts{prefix: "unexpected"})...)
	got := account(dir, expected, writeReport(t, dir, "unexpected.ndjson", events), 0, "")
	eq(t, "status", got.Scenarios[0].Status, "passed")
	eqSlice(t, "problems", got.Problems, []string{"unexpected: features/unexpected.feature line 2 (unexpected)"})
}

func TestAccountWillBeRetriedExcludesTheFailedAttemptWhenRetryPasses(t *testing.T) {
	dir := t.TempDir()
	_, expected := featureWithSteps(t, "retried", 2)
	s := expected[0]
	ids := makeASTIDs(s, 1, "case")
	events := []obj{documentMessage(testFeature, []project.Scenario{s}, []astIDs{ids})}
	events = append(events, caseMessages(s, testFeature, []string{ids.scenario}, "attempt-one",
		reportOpts{results: statuses("FAILED", "SKIPPED"), retried: true, astSteps: ids.steps})...)
	events = append(events, caseMessages(s, testFeature, []string{ids.scenario}, "attempt-two", reportOpts{astSteps: ids.steps})...)
	got := account(dir, expected, writeReport(t, dir, "retry.ndjson", events), 0, "")
	eq(t, "status", got.Scenarios[0].Status, "passed")
	eqSlice(t, "problems", got.Problems, nil)
	eq(t, "passed", got.Passed, 1)
	eq(t, "retried skips excluded", encode(got.Scenarios[0].UnexercisedSteps), "[]")
}

func TestAccountTruncatedReportsAreInvalid(t *testing.T) {
	dir := t.TempDir()
	_, expected := featureWithSteps(t, "truncated", 2)
	for name, opts := range map[string]reportOpts{
		"unfinished":          {unfinished: true},
		"missing-step-result": reportOpts{}.withReported(1),
	} {
		got := account(dir, expected, writeReport(t, dir, name+".ndjson", simpleMessages(testFeature, expected, opts)), 0, "")
		eq(t, name+" status", got.Scenarios[0].Status, "report_invalid")
		contains(t, name+" problem", got.Problems[0], "report_invalid: truncated (line 2)")
	}
}

func TestAccountGarbageLineMakesTheReportInvalid(t *testing.T) {
	dir := t.TempDir()
	_, expected := featureWithSteps(t, "garbage", 1)
	report := writeReport(t, dir, "garbage.ndjson", simpleMessages(testFeature, expected, reportOpts{}))
	text, _ := os.ReadFile(report)
	os.WriteFile(report, append(text, "not-json\n"...), 0o644)
	got := account(dir, expected, report, 0, "")
	if len(got.Problems) != 1 || !strings.HasPrefix(got.Problems[0], "report_invalid: the acceptance command exited 0") {
		t.Fatalf("problems = %q", got.Problems)
	}
	eq(t, "status", got.Scenarios[0].Status, "report_invalid")
}

func TestAccountMissingReportIsReportedOnceWithExitStatusAndOutput(t *testing.T) {
	dir := t.TempDir()
	_, expected := featureWithSteps(t, "missing report", 1)
	got := account(dir, expected, filepath.Join(dir, "does-not-exist.ndjson"), 1, "Cucumber can only run on Node.js versions 22 || 24 || >=26\n")
	eqSlice(t, "problems", got.Problems, []string{"report_missing: the acceptance command exited 1; its output:\nCucumber can only run on Node.js versions 22 || 24 || >=26"})
	eq(t, "status", got.Scenarios[0].Status, "report_missing")
}

func TestAccountNonzeroExitWithEveryScenarioPassedIsStillAProblem(t *testing.T) {
	dir := t.TempDir()
	_, expected := featureWithSteps(t, "passed", 1)
	report := writeReport(t, dir, "passed.ndjson", simpleMessages(testFeature, expected, reportOpts{}))
	got := account(dir, expected, report, 7, "runner output")
	eq(t, "status", got.Scenarios[0].Status, "passed")
	eqSlice(t, "problems", got.Problems, []string{"exit 7 with all scenarios passed"})
	eq(t, "exit", got.Status, 7)
}

func TestAccountScenarioOutlineResultsUseEachExamplesRowLineAsTheKey(t *testing.T) {
	dir := t.TempDir()
	text := "Feature: Outline accounting\n  Scenario Outline: value <value>\n    Given the value is <value>\n    Then it is accepted\n  Examples:\n    | value |\n    | first |\n    | second |\n"
	expected, err := project.ParseGherkin(text)
	if err != nil {
		t.Fatal(err)
	}
	if len(expected) != 2 || expected[0].Name != "value first" || expected[0].Line != 7 || expected[1].Name != "value second" || expected[1].Line != 8 {
		t.Fatalf("expected = %+v", expected)
	}
	stepIDs := []string{"outline-step-1", "outline-step-2"}
	var rows, steps []any
	for _, e := range expected {
		rows = append(rows, obj{"id": fmt.Sprintf("outline-row-%d", e.Line), "location": obj{"line": e.Line}})
	}
	for i, st := range expected[0].Steps {
		steps = append(steps, obj{"id": stepIDs[i], "location": obj{"line": st.Line}, "keyword": st.Keyword})
	}
	events := []obj{{"gherkinDocument": obj{"uri": testFeature, "feature": obj{"children": []any{
		obj{"scenario": obj{"id": "outline-scenario", "location": obj{"line": 2}, "steps": steps, "examples": []any{obj{"tableBody": rows}}}},
	}}}}}
	for i, e := range expected {
		events = append(events, caseMessages(e, testFeature, []string{"outline-scenario", fmt.Sprintf("outline-row-%d", e.Line)},
			fmt.Sprintf("outline-%d", i+1), reportOpts{astSteps: stepIDs})...)
	}
	got := account(dir, expected, writeReport(t, dir, "outline.ndjson", events), 0, "")
	var summary []string
	for _, s := range got.Scenarios {
		summary = append(summary, fmt.Sprintf("%s/%d/%s", s.Name, s.Line, s.Status))
	}
	eqSlice(t, "scenarios", summary, []string{"value first/7/passed", "value second/8/passed"})
	eqSlice(t, "problems", got.Problems, nil)
}

// ---- parity with Kogen.Checks.account (testdata/gen/accounts.exs) ----

type goldenAccount struct {
	Name    string          `json:"name"`
	Feature string          `json:"feature"`
	Report  *[]string       `json:"report"`
	Status  int             `json:"status"`
	Output  string          `json:"output"`
	Result  json.RawMessage `json:"result"`
}

func TestAccountEqualsTheElixirAccountingOnEveryReference(t *testing.T) {
	var cases []goldenAccount
	readGolden(t, "accounts.json", &cases)
	if len(cases) < 50 {
		t.Fatalf("only %d reference cases", len(cases))
	}
	const root = "/nonexistent/kogen-root"
	dir := t.TempDir()
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			expected, err := project.ParseGherkin(c.Feature)
			if err != nil {
				t.Fatal(err)
			}
			report := filepath.Join(dir, "absent.ndjson")
			if c.Report != nil {
				report = filepath.Join(dir, "report.ndjson")
				body := strings.Join(*c.Report, "\n")
				if len(*c.Report) > 0 {
					body += "\n"
				}
				if err := os.WriteFile(report, []byte(body), 0o644); err != nil {
					t.Fatal(err)
				}
			} else {
				os.Remove(report)
			}
			got := Account(root, testFeature, expected, report, c.Status, c.Output)
			// Historical parity covers unchanged accounting; new observations have
			// dedicated execution-projection regressions below.
			legacy := generic(got).(map[string]any)
			for _, scenario := range legacy["scenarios"].([]any) {
				delete(scenario.(map[string]any), "unexercised_steps")
			}
			sameJSON(t, "account", legacy, c.Result)
		})
	}
}

func TestAccountRetainsOnlyActuallySkippedSteps(t *testing.T) {
	dir := t.TempDir()
	_, expected := featureWithSteps(t, "observed", 4)
	for _, statusesList := range [][]string{{"FAILED", "SKIPPED", "PASSED", "SKIPPED"}, {"PASSED", "PASSED", "PASSED", "PASSED"}} {
		events := simpleMessages(testFeature, expected, reportOpts{results: statuses(statusesList...)})
		got := account(dir, expected, writeReport(t, dir, "skipped.ndjson", events), 1, "")
		want := []StepRecord{}
		for i, status := range statusesList {
			if status == "SKIPPED" {
				st := expected[0].Steps[i]
				want = append(want, StepRecord{Keyword: st.Keyword, Text: st.Text, Line: st.Line})
			}
		}
		if encode(got.Scenarios[0].UnexercisedSteps) != encode(want) {
			t.Fatalf("got %s want %s", encode(got.Scenarios[0].UnexercisedSteps), encode(want))
		}
	}
	for _, opts := range []reportOpts{{unfinished: true}, {repeat: 2}, {notStarted: true}} {
		got := account(dir, expected, writeReport(t, dir, "unknown.ndjson", simpleMessages(testFeature, expected, opts)), 1, "")
		if got.Scenarios[0].UnexercisedSteps != nil {
			t.Fatal("incomplete/nonunique execution must remain unknown")
		}
	}
}

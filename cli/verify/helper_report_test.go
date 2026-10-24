package verify

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen/project"
)

// Builders of Cucumber Messages reports for the accounting tests: the same shapes the
// ExUnit tests of Kogen.Checks build, so a report here is one a real runner could write.

const testFeature = "features/acceptance.feature"

type obj = map[string]any

// reportOpts selects how a generated case reports.
type reportOpts struct {
	prefix     string
	repeat     int      // copies of each case (default 1)
	notStarted bool     // the case is declared but never started
	unfinished bool     // no testCaseFinished
	retried    bool     // testCaseFinished has willBeRetried
	reported   int      // test steps with a result (default all)
	hasReport  bool     // reported is set
	results    []obj    // per test step result (default PASSED)
	astSteps   []string // AST step ids (default generated)
}

func (o reportOpts) withReported(n int) reportOpts { o.reported, o.hasReport = n, true; return o }

func statuses(list ...string) []obj {
	out := make([]obj, len(list))
	for i, s := range list {
		out[i] = obj{"status": s}
	}
	return out
}

// featureWithSteps is a feature with one scenario of n steps and its expected scenarios.
func featureWithSteps(t *testing.T, name string, n int) (string, []project.Scenario) {
	t.Helper()
	var steps []string
	for i := 1; i <= n; i++ {
		steps = append(steps, fmt.Sprintf("    Given step %d", i))
	}
	text := fmt.Sprintf("Feature: Accounting\n  Scenario: %s\n%s\n", name, strings.Join(steps, "\n"))
	expected, err := project.ParseGherkin(text)
	if err != nil {
		t.Fatal(err)
	}
	return text, expected
}

type astIDs struct {
	scenario string
	steps    []string
}

func makeASTIDs(s project.Scenario, index int, prefix string) astIDs {
	ids := astIDs{scenario: fmt.Sprintf("ast-%s-scenario-%d", prefix, index)}
	for i := range s.Steps {
		ids.steps = append(ids.steps, fmt.Sprintf("ast-%s-step-%d-%d", prefix, index, i+1))
	}
	return ids
}

func documentMessage(feature string, scenarios []project.Scenario, sets []astIDs) obj {
	var children []any
	for i, s := range scenarios {
		var steps []any
		for j, st := range s.Steps {
			steps = append(steps, obj{"id": sets[i].steps[j], "location": obj{"line": st.Line}, "keyword": st.Keyword})
		}
		children = append(children, obj{"scenario": obj{
			"id": sets[i].scenario, "location": obj{"line": s.Line}, "steps": steps, "examples": []any{},
		}})
	}
	return obj{"gherkinDocument": obj{"uri": feature, "feature": obj{"children": children}}}
}

// caseMessages are the messages of one executed scenario.
func caseMessages(s project.Scenario, feature string, astScenario []string, prefix string, o reportOpts) []obj {
	astSteps := o.astSteps
	if astSteps == nil {
		for i := range s.Steps {
			astSteps = append(astSteps, fmt.Sprintf("%s-ast-step-%d", prefix, i+1))
		}
	}
	pickleID, caseID, startedID := prefix+"-pickle", prefix+"-case", prefix+"-started"
	var pickleSteps, testSteps []any
	for i, st := range s.Steps {
		id := fmt.Sprintf("%s-pickle-step-%d", prefix, i+1)
		pickleSteps = append(pickleSteps, obj{"id": id, "astNodeIds": []any{astSteps[i]}, "text": st.Text})
		testSteps = append(testSteps, obj{"id": fmt.Sprintf("%s-test-step-%d", prefix, i+1), "pickleStepId": id})
	}
	reported := len(testSteps)
	if o.hasReport {
		reported = o.reported
	}
	results := o.results
	if results == nil {
		results = statuses(repeatString("PASSED", len(testSteps))...)
	}
	var stepEvents []obj
	for i, ts := range testSteps[:reported] {
		stepEvents = append(stepEvents, obj{"testStepFinished": obj{
			"testCaseStartedId": startedID, "testStepId": ts.(obj)["id"], "testStepResult": results[i],
		}})
	}
	astIDsAny := make([]any, len(astScenario))
	for i, a := range astScenario {
		astIDsAny[i] = a
	}
	events := []obj{
		{"pickle": obj{"id": pickleID, "uri": feature, "name": s.Name, "astNodeIds": astIDsAny, "steps": pickleSteps}},
		{"testCase": obj{"id": caseID, "pickleId": pickleID, "testSteps": testSteps}},
	}
	if o.notStarted {
		return events
	}
	events = append(events, obj{"testCaseStarted": obj{"id": startedID, "testCaseId": caseID}})
	events = append(events, stepEvents...)
	if !o.unfinished {
		events = append(events, obj{"testCaseFinished": obj{"testCaseStartedId": startedID, "willBeRetried": o.retried}})
	}
	return events
}

func repeatString(s string, n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = s
	}
	return out
}

// simpleMessages is a report with one case (or o.repeat copies) per expected scenario.
func simpleMessages(feature string, expected []project.Scenario, o reportOpts) []obj {
	prefix := o.prefix
	if prefix == "" {
		prefix = "case"
	}
	var sets []astIDs
	for i, s := range expected {
		sets = append(sets, makeASTIDs(s, i+1, prefix))
	}
	events := []obj{documentMessage(feature, expected, sets)}
	repeat := max(o.repeat, 1)
	for i, s := range expected {
		for copy := 1; copy <= repeat; copy++ {
			c := o
			c.astSteps = sets[i].steps
			events = append(events, caseMessages(s, feature, []string{sets[i].scenario}, fmt.Sprintf("%s-%d-%d", prefix, i+1, copy), c)...)
		}
	}
	return events
}

func reportLines(events []obj) []string {
	lines := make([]string, len(events))
	for i, e := range events {
		lines[i] = encode(e)
	}
	return lines
}

// writeReport writes events as an NDJSON report in dir and returns its path.
func writeReport(t *testing.T, dir, name string, events []obj) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(strings.Join(reportLines(events), "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// account runs the accounting of expected against a report with the given exit status.
func account(root string, expected []project.Scenario, report string, status int, output string) Acceptance {
	return Account(root, testFeature, expected, report, status, output)
}

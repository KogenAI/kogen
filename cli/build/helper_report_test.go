package build

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen/project"
)

// Builders of Cucumber Messages reports for the acceptance script of the fixtures: the
// shapes a real runner writes (the same ones the verify package's tests build).

type obj = map[string]any

func statuses(list ...string) []obj {
	out := make([]obj, len(list))
	for i, s := range list {
		out[i] = obj{"status": s}
	}
	return out
}

func documentMessage(feature string, scenarios []project.Scenario) obj {
	var children []any
	for i, s := range scenarios {
		var steps []any
		for j, st := range s.Steps {
			steps = append(steps, obj{"id": fmt.Sprintf("ast-step-%d-%d", i+1, j+1), "location": obj{"line": st.Line}, "keyword": st.Keyword})
		}
		children = append(children, obj{"scenario": obj{
			"id": fmt.Sprintf("ast-scenario-%d", i+1), "location": obj{"line": s.Line}, "steps": steps, "examples": []any{},
		}})
	}
	return obj{"gherkinDocument": obj{"uri": feature, "feature": obj{"children": children}}}
}

func caseMessages(s project.Scenario, index int, feature string, results []obj) []obj {
	prefix := fmt.Sprintf("case-%d", index)
	var pickleSteps, testSteps []any
	for i, st := range s.Steps {
		id := fmt.Sprintf("%s-pickle-step-%d", prefix, i+1)
		pickleSteps = append(pickleSteps, obj{"id": id, "astNodeIds": []any{fmt.Sprintf("ast-step-%d-%d", index, i+1)}, "text": st.Text})
		testSteps = append(testSteps, obj{"id": fmt.Sprintf("%s-test-step-%d", prefix, i+1), "pickleStepId": id})
	}
	events := []obj{
		{"pickle": obj{"id": prefix + "-pickle", "uri": feature, "name": s.Name, "astNodeIds": []any{fmt.Sprintf("ast-scenario-%d", index)}, "steps": pickleSteps}},
		{"testCase": obj{"id": prefix + "-case", "pickleId": prefix + "-pickle", "testSteps": testSteps}},
		{"testCaseStarted": obj{"id": prefix + "-started", "testCaseId": prefix + "-case"}},
	}
	for i, ts := range testSteps {
		events = append(events, obj{"testStepFinished": obj{
			"testCaseStartedId": prefix + "-started", "testStepId": ts.(obj)["id"], "testStepResult": results[i],
		}})
	}
	return append(events, obj{"testCaseFinished": obj{"testCaseStartedId": prefix + "-started", "willBeRetried": false}})
}

// reportFor is the report of running every scenario of feature with the given step status.
func reportFor(t *testing.T, feature, text, status string) string {
	t.Helper()
	scenarios, err := project.ParseGherkin(text)
	if err != nil {
		t.Fatal(err)
	}
	events := []obj{documentMessage(feature, scenarios)}
	for i, s := range scenarios {
		events = append(events, caseMessages(s, i+1, feature, statuses(repeat(status, len(s.Steps))...))...)
	}
	lines := make([]string, len(events))
	for i, e := range events {
		b, err := encodeJSON(e)
		if err != nil {
			t.Fatal(err)
		}
		lines[i] = string(b)
	}
	return strings.Join(lines, "\n") + "\n"
}

func repeat(s string, n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = s
	}
	return out
}

func writeFile(t *testing.T, path, content string, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
}

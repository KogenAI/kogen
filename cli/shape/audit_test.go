package shape

import (
	"strings"
	"testing"

	"kogen/executor"
)

func TestUncoveredDefects(t *testing.T) {
	defect := map[string]any{"kind": "conflict", "quote_a": "QA text", "quote_b": "QB text", "exposing_input": "f(0)", "result_a": "True", "result_b": "False"}
	undefined := map[string]any{"kind": "undefined", "quote_a": "makes a gadget", "quote_b": "Widget", "exposing_input": "any", "result_a": "", "result_b": ""}
	intent := func(lines ...string) string {
		return "# T\n\n## Decisions\n" + strings.Join(lines, "\n") + "\n\n## Tests\n- f(0) returns True and False\n"
	}
	ask := func(text string) []map[string]any { return []map[string]any{{"question": text}} }
	cases := []struct {
		name      string
		defect    map[string]any
		intent    string
		questions []map[string]any
		covered   bool
	}{
		{"decision with one result", defect, intent("- f(0) returns True. (source: request)"), nil, true},
		{"decision with both results", defect, intent("- f(0) returns True or False."), nil, false},
		{"decision without the input", defect, intent("- Other."), nil, false},
		{"input outside Decisions", defect, "## Decisions\n- x\n\n## Tests\n- f(0) returns True\n", nil, false},
		{"question with both quotes", defect, "", ask("QA text but QB text?"), true},
		{"question with one quote", defect, "", ask("QA text?"), false},
		{"undefined asked with the name", undefined, "", ask("makes a gadget: what is Widget?"), true},
		{"undefined defined by colon", undefined, intent("- Widget: a part. (source: request)"), nil, true},
		{"undefined defined by equals", undefined, intent("- Widget = a part."), nil, true},
		{"undefined defined by means", undefined, intent("- Widget  means a part."), nil, true},
		{"undefined defined by is", undefined, intent("- Widget is a part."), nil, true},
		{"undefined mention only", undefined, intent("- Uses Widget here. (source: request)"), nil, false},
		{"undefined other name", undefined, intent("- Gadget is a part."), nil, false},
		{"undefined marker before name", undefined, intent("- Note: Widget"), nil, false},
		{"undefined marker not a word", undefined, intent("- Widget isolated."), nil, false},
		{"empty result does not disqualify", map[string]any{"kind": "conflict", "quote_a": "QA", "quote_b": "QB", "exposing_input": "f(0)", "result_a": "True", "result_b": ""}, intent("- f(0) returns True."), nil, true},
		{"undefined asked without the name", undefined, "", ask("makes a gadget?"), false},
		{"input across a line break", map[string]any{"kind": "conflict", "quote_a": "QA", "quote_b": "QB", "exposing_input": "f(0)\r\nwith  two", "result_a": "True", "result_b": "False"}, intent("- f(0) with two returns True."), nil, true},
		{"input with another word", map[string]any{"kind": "conflict", "quote_a": "QA", "quote_b": "QB", "exposing_input": "f(0)\nwith three", "result_a": "True", "result_b": "False"}, intent("- f(0) with two returns True."), nil, false},
		{"question quotes across line breaks", defect, "", ask("QA\ttext but QB\ntext?"), true},
		{"question quote with another case", defect, "", ask("qa text but QB text?"), false},
	}
	for _, c := range cases {
		got := uncoveredDefects([]map[string]any{c.defect}, c.intent, c.questions)
		if (len(got) == 0) != c.covered {
			t.Errorf("%s: uncovered %v", c.name, got)
		}
	}
}

func TestAuditGateFeedback(t *testing.T) {
	sh := &shaping{slug: "s", proposed: map[string]string{}, auditResult: &auditResult{defects: []map[string]any{
		{"kind": "conflict", "quote_a": "QA", "quote_b": "QB", "exposing_input": "f(0)", "result_a": "T", "result_b": "F"}}}}
	got := sh.auditGate(submission{questions: []map[string]any{{"question": "x"}}})
	want := []string{"Request audit: 1 defects are not decided or asked; decide each with its exposing input or ask with both quotes:", "quote_a: QA | quote_b: QB | exposing_input: f(0)",
		"- Decision: for f(0) the result is T (because …) (source: request)",
		"- Decision: for f(0) the result is F (because …) (source: request)",
		"- Question: \"QA\" versus \"QB\": which applies?"}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("feedback %q", got)
	}
	if sh.auditGate(submission{blocked: true}) != nil {
		t.Error("a blocked report was gated")
	}
}

// TestExternalShapeAudit: an external shaper runs the audit as one fresh session with the audit
// schema, records the event, and applies the same gate to its first submission.
func TestExternalShapeAudit(t *testing.T) {
	f := newShpFx(t)
	f.useExternalShape(6)
	f.write(".kogen/project.yaml", f.read(".kogen/project.yaml")+"shape_audit:\n  enabled: true\n")
	f.git("add", ".kogen/project.yaml")
	f.git("commit", "-qm", "audit")
	audit := map[string]any{
		"examples": []any{map[string]any{"quote": "QA"}}, "rules": []any{map[string]any{"quote": "QB"}},
		"cells":   []any{map[string]any{"example": 0, "rule": 0, "result": "conflicts"}},
		"defects": []any{map[string]any{"kind": "conflict", "quote_a": "QA", "quote_b": "QB", "exposing_input": "is_even(0)", "result_a": "True", "result_b": "False"}},
	}
	x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){result(audit), result(shpFiles())}}
	f.shapeWith(x, "Add calc.is_even(n). QA QB")
	if len(x.starts) != 2 {
		t.Fatalf("%d sessions", len(x.starts))
	}
	shpContains(t, "audit schema", string(x.starts[0].Schema), "exposing_input")
	shpContains(t, "audit task", x.starts[0].Brief.Stable, "Add calc.is_even(n). QA QB")
	if strings.Contains(x.starts[0].Brief.Stable, "# Calc") {
		t.Error("the audit saw repository context")
	}
	shpContains(t, "feedback", x.inputs[2].Feedback, "Request audit: 1 defects are not decided or asked; decide each with its exposing input or ask with both quotes:\nquote_a: QA | quote_b: QB | exposing_input: is_even(0)")
	// Attempts one and two are refused with the template; the third is the last attempt and is
	// published, recording the uncovered defect in a second request_audit event.
	shpContains(t, "template", x.inputs[2].Feedback, "- Decision: for is_even(0) the result is True (because …) (source: request)")
	evs := shpNamed(f.events(), "request_audit")
	if len(evs) != 2 {
		t.Fatalf("%d request_audit events", len(evs))
	}
	if _, ok := evs[0]["uncovered"]; ok {
		t.Error("first event has uncovered")
	}
	if u, _ := evs[1]["uncovered"].([]any); len(u) != 1 {
		t.Fatalf("uncovered %v", evs[1]["uncovered"])
	}
	if !f.exists(".kogen/intents/is-even") {
		t.Error("the last attempt was not published")
	}
	if lines := unresolvedLines(f.Root, "is-even"); len(lines) != 1 || lines[0] != "  - quote_a: QA | quote_b: QB | exposing_input: is_even(0)" {
		t.Errorf("card lines %q", lines)
	}
	noNativeRequests(t, f)
}

// TestDefectTemplates: each pasted template line covers its defect; empty results and undefined.
func TestDefectTemplates(t *testing.T) {
	cases := []map[string]any{
		{"kind": "conflict", "quote_a": "QA", "quote_b": "QB", "exposing_input": "f(0)", "result_a": "T", "result_b": "F"},
		{"kind": "precedence", "quote_a": "QA", "quote_b": "QB", "exposing_input": "f(1)", "result_a": "", "result_b": "F"},
		{"kind": "precedence", "quote_a": "QA", "quote_b": "QB", "exposing_input": "f(2)", "result_a": "", "result_b": ""},
		{"kind": "undefined", "quote_a": "QA", "quote_b": "widget", "exposing_input": "f(3)", "result_a": "", "result_b": ""},
	}
	counts := []int{3, 2, 2, 2}
	for i, d := range cases {
		lines := defectTemplates(d)
		if len(lines) != counts[i] {
			t.Fatalf("case %d: %q", i, lines)
		}
		for _, l := range lines[:len(lines)-1] {
			intent := "## Decisions\n" + l + "\n"
			if len(uncoveredDefects([]map[string]any{d}, intent, nil)) != 0 {
				t.Errorf("case %d: %q does not cover", i, l)
			}
		}
		q := []map[string]any{{"question": strings.TrimPrefix(lines[len(lines)-1], "- Question: ")}}
		if len(uncoveredDefects([]map[string]any{d}, "", q)) != 0 {
			t.Errorf("case %d: question does not cover", i)
		}
	}
}

// TestNativeAuditRefusalKeepsTheSubmittedFiles: a well-formed files submission refused by the
// audit gate stays in the accumulated proposals, so an intent.md-only correction publishes
// with the earlier acceptance.feature and steps.
func TestNativeAuditRefusalKeepsTheSubmittedFiles(t *testing.T) {
	cover := strings.Replace(shpIntentMD, "- Non-integers raise TypeError. (source: request)\n",
		"- Non-integers raise TypeError. (source: request)\n- Decision: for is_even(0) the result is True (because the example states it) (source: request)\n", 1)
	f := newShpFx(t, shpSubmit("c1", shpFiles()),
		shpSubmit("c2", map[string]any{"files": []any{map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": cover}}}))
	f.write(".kogen/project.yaml", f.read(".kogen/project.yaml")+"shape_audit:\n  enabled: true\n")
	f.git("add", ".kogen/project.yaml")
	f.git("commit", "-qm", "audit")
	f.setReport("PASSED", 0)
	audit := shpAnswer(shpCall("a1", SubmitAuditTool, map[string]any{
		"examples": []any{map[string]any{"quote": "QA"}}, "rules": []any{map[string]any{"quote": "QB"}},
		"cells":   []any{map[string]any{"example": 0, "rule": 0, "result": "conflicts"}},
		"defects": []any{map[string]any{"kind": "conflict", "quote_a": "QA", "quote_b": "QB", "exposing_input": "is_even(0)", "result_a": "True", "result_b": "False"}},
	}))
	f.Prov.route = func(req map[string]any) *shpStep {
		if names := shpToolNames(req); len(names) == 1 && names[0] == SubmitAuditTool {
			return &audit
		}
		return nil
	}
	if exit, err := f.shape("Add calc.is_even(n). QA QB"); err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stdout)
	}
	shpEq(t, "feature", f.read(".kogen/intents/is-even/acceptance.feature"), shpFeature)
	shpEq(t, "steps", f.read("features/steps/is_even_steps.js"), shpSteps)
	shpEq(t, "intent", f.read(".kogen/intents/is-even/intent.md"), cover)
	refused := shpNamed(f.events(), "submission_refused")
	if len(refused) != 1 || refused[0]["gate"] != "audit" || refused[0]["attempt"] != float64(1) {
		t.Fatalf("refused %v", refused)
	}
}

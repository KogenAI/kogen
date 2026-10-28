package shape

import (
	"slices"
	"strings"
	"testing"

	"kogen/executor"
	"kogen/project"
)

func TestDecisionOutcomeRules(t *testing.T) {
	const request = "Add f. f(0) returns True."
	const decision = "- f(0) returns False. (source: request)"
	const assumed = "- Zero is even. (assumption: silent) (source: request)"
	intent := "## Decisions\n" + decision + "\n" + assumed + "\n"
	item := func(statement string, quotes []string, verdict string) decisionItem {
		return decisionItem{statement: statement, quotes: quotes, verdict: verdict, why: "w"}
	}
	cases := []struct {
		name     string
		item     decisionItem
		verdict  string
		feedback []string
	}{
		{"follows", item(decision, []string{"f(0) returns True."}, "follows"), "follows", nil},
		{"contradicts", item(decision, []string{"f(0) returns True."}, "contradicts"),
			"contradicts", []string{`statement: ` + decision + ` | request_quotes: "f(0) returns True." | why: w`}},
		{"unsupported without quotes", item(decision, nil, "unsupported"),
			"unsupported", []string{`statement: ` + decision + ` | request_quotes:  | why: w`}},
		{"statement not in intent", item("- other", []string{"f(0) returns True."}, "follows"),
			"unsupported", []string{`statement: - other | request_quotes: "f(0) returns True." | why: w`}},
		{"quote not in request", item(decision, []string{"f(0) returns True.", "nope"}, "follows"),
			"unsupported", []string{`statement: ` + decision + ` | request_quotes: "f(0) returns True.", "nope" | why: w`}},
		{"assumption not fed back", item(assumed, nil, "unsupported"), "unsupported", nil},
		{"assumption contradicting not fed back", item(assumed, []string{"nope"}, "contradicts"), "unsupported", nil},
	}
	for _, c := range cases {
		event, lines := decisionOutcome([]decisionItem{c.item}, request, intent)
		if event["event"] != "decision_check" || event[c.verdict] != 1 {
			t.Errorf("%s: event %v", c.name, event)
		}
		items := event["items"].([]any)
		if items[0].(map[string]any)["verdict"] != c.verdict {
			t.Errorf("%s: verdict %v", c.name, items[0])
		}
		if c.feedback == nil {
			if lines != nil {
				t.Errorf("%s: feedback %q", c.name, lines)
			}
			continue
		}
		head := "Decision check: 1 stated decisions are not supported by the request; follow the request, or ask, or mark the decision as an assumption the user must confirm:"
		if !slices.Equal(lines, append([]string{head}, c.feedback...)) {
			t.Errorf("%s: lines %q", c.name, lines)
		}
	}
}

func TestAssumptionLines(t *testing.T) {
	intent := "## Decisions\n- A. (source: request)\n- B. (assumption: x) (source: request)\n\n## Tests\n- C (assumption: y)\n"
	on := &project.Config{ShapeDecisionCheck: project.DecisionCheck{Enabled: true}}
	if got := assumptionLines(on, intent); !slices.Equal(got, []string{"B. (assumption: x) (source: request)"}) {
		t.Errorf("got %q", got)
	}
	if got := assumptionLines(&project.Config{}, intent); got != nil {
		t.Errorf("off: %q", got)
	}
}

// TestExternalShapeDecisionCheck: an external shaper runs the check as one fresh session per
// candidate with the check schema, applies the mechanical rules and feeds problems back.
func TestExternalShapeDecisionCheck(t *testing.T) {
	f := newShpFx(t)
	f.useExternalShape(8)
	f.write(".kogen/project.yaml", f.read(".kogen/project.yaml")+"shape_decision_check:\n  enabled: true\n")
	f.git("add", ".kogen/project.yaml")
	f.git("commit", "-qm", "decision check")
	const decision = "- Non-integers raise TypeError. (source: request)"
	check := func(verdict string) map[string]any {
		return map[string]any{"items": []any{map[string]any{"statement": decision, "request_quotes": []any{"Non-integers raise TypeError."}, "verdict": verdict, "why": "because"}}}
	}
	x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){
		result(shpFiles()), result(check("contradicts")), result(shpFiles()), result(check("follows")), result(shpFiles()), result(check("follows"))}}
	f.shapeWith(x, "Add calc.is_even(n). Non-integers raise TypeError.")
	var checks []executor.Task
	for _, s := range x.starts {
		if strings.Contains(string(s.Schema), "request_quotes") {
			checks = append(checks, s)
		}
	}
	if len(checks) != 3 {
		t.Fatalf("%d check sessions of %d", len(checks), len(x.starts))
	}
	shpContains(t, "task", checks[0].Brief.Stable, "# Candidate intent.md")
	if strings.Contains(checks[0].Brief.Stable, "# Calc") {
		t.Error("the check saw repository context")
	}
	var feedback string
	for _, in := range x.inputs {
		feedback += in.Feedback
	}
	shpContains(t, "feedback", feedback, "Decision check: 1 stated decisions are not supported by the request;")
	shpContains(t, "feedback line", feedback, "statement: "+decision+` | request_quotes: "Non-integers raise TypeError." | why: because`)
	if n := len(shpNamed(f.events(), "decision_check")); n != 3 {
		t.Fatalf("%d decision_check events", n)
	}
	noNativeRequests(t, f)
}

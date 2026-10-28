package shape

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"kogen-loop/sys"
	"kogen/verify"
)

// Observation only: it mounts as a test with go -overlay, changes no production source and
// drives the real decision-check and audit comparisons, the title shortening helper and the
// real native Shape path with a scripted provider, then the real approval card.
const (
	k26dLong     = "Add an is-even check for integers and also reject every string"
	k26dTool     = "submit_decision_check"
	k26dRequest  = "Add calc.is_even(n). Example: is_even(0) returns True. Non-integers raise\nTypeError. Use only the\nGo standard library."
	k26dRuleA    = "- Non-integers raise TypeError. (source: request)"
	k26dRuleB    = "- Use only the Go standard library. (source: request)"
	k26dIntentAn = "- Non-integers raise TypeError. (source: request)\n"
)

func k26dFiles(title string, extra string) map[string]any {
	intent := strings.Replace(shpIntentMD, "# Add an is-even check\n", "# "+title+"\n", 1)
	if extra != "" {
		intent = strings.Replace(intent, k26dIntentAn, k26dIntentAn+extra+"\n", 1)
	}
	return map[string]any{"files": []any{
		map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": intent},
		map[string]any{"path": ".kogen/intents/is-even/acceptance.feature", "content": shpFeature},
		map[string]any{"path": "features/steps/is_even_steps.js", "content": shpSteps},
	}}
}

func k26dCheck() *shpStep {
	items := []any{
		map[string]any{"statement": k26dRuleA, "request_quotes": []any{"Non-integers raise TypeError."}, "verdict": "follows", "why": "Request states this directly"},
		map[string]any{"statement": k26dRuleB, "request_quotes": []any{"Use only the Go standard library."}, "verdict": "follows", "why": "Stated directly"},
	}
	st := shpAnswer(shpCall("check-1", k26dTool, map[string]any{"items": items}))
	return &st
}

func k26dUnit() map[string]any {
	const intent = "## Decisions\n" + k26dRuleA + "\n"
	verdict := func(statement, quote, request string) string {
		ev, _ := decisionOutcome([]decisionItem{{statement: statement, quotes: []string{quote}, verdict: "follows", why: "w"}}, request, intent)
		return ev["items"].([]any)[0].(map[string]any)["verdict"].(string)
	}
	const q = "Non-integers raise TypeError."
	covered := func(d map[string]any, intent string, qs []map[string]any) bool {
		return len(uncoveredDefects([]map[string]any{d}, intent, qs)) == 0
	}
	defect := func(qa, in string) map[string]any {
		return map[string]any{"kind": "conflict", "quote_a": qa, "quote_b": "Rule B: zero returns False.", "exposing_input": in, "result_a": "True", "result_b": "False"}
	}
	const audit = "## Decisions\n- For is_even(0) returns True the result is True. (source: request)\n"
	const qtext = "Rule A: even numbers return True. versus Rule B: zero returns False."
	asked := []map[string]any{{"question": qtext}}
	return map[string]any{
		"wrapped":        verdict(k26dRuleA, q, "Add f. Non-integers raise\nTypeError. Done."),
		"crlf":           verdict(k26dRuleA, q, "Non-integers raise\r\nTypeError."),
		"tabs":           verdict(k26dRuleA, q, "Non-integers\traise \t TypeError."),
		"spaces":         verdict(k26dRuleA, q, "Non-integers   raise  TypeError."),
		"statement_ws":   verdict("-  Non-integers raise TypeError.\t(source: request)", q, "Non-integers raise TypeError."),
		"one_word":       verdict(k26dRuleA, "Non-integers throw TypeError.", "Non-integers raise\nTypeError."),
		"case":           verdict(k26dRuleA, "non-integers raise TypeError.", "Non-integers raise\nTypeError."),
		"audit_input":    covered(defect("QA", "is_even(0) returns\nTrue"), audit, nil),
		"audit_wrong":    covered(defect("QA", "is_even(0) returns\nFalse"), audit, nil),
		"question":       covered(defect("Rule A:\neven numbers  return True.", "zzz"), "", asked),
		"question_wrong": covered(defect("Rule A: even numbers return False.", "zzz"), "", asked),
		"title_plain":    shortenTitle(k26dLong),
		"title_punct":    shortenTitle("Add an is-even check for integers and also reject, every string"),
		"title_mid":      shortenTitle("Add an is-even check for integers and also rejection of strings"),
	}
}

func TestK26dWhitespaceObservation(t *testing.T) {
	mode := os.Getenv("KOGEN_K26D_MODE")
	out := map[string]any{"mode": mode, "exit": 0, "error_text": "", "published": false, "intent": "", "feedback1": "",
		"decision_checks": 0, "refused": []any{}, "decision_events": []any{}, "title_events": []any{}, "card_exit": -1, "card": "", "unit": map[string]any{}}
	write := func() {
		raw, _ := json.Marshal(out)
		if err := os.WriteFile(os.Getenv("KOGEN_K26D_OUTPUT"), raw, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if mode == "unit" {
		out["unit"] = k26dUnit()
		write()
		return
	}
	tools := verify.Tools{Node: os.Getenv("KOGEN_NODE"), Quint: os.Getenv("KOGEN_QUINT"), Cucumber: os.Getenv("KOGEN_CUCUMBER")}
	var steps []shpStep
	request := "Add calc.is_even(n). Non-integers raise TypeError."
	switch mode {
	case "wrap":
		steps = []shpStep{shpSubmit("c1", k26dFiles("Add an is-even check", k26dRuleB))}
		request = k26dRequest
	case "title_last":
		steps = []shpStep{shpSubmit("c1", k26dFiles(k26dLong, "")), shpSubmit("c2", k26dFiles(k26dLong, "")), shpSubmit("c3", k26dFiles(k26dLong, ""))}
	case "title_first":
		steps = []shpStep{shpSubmit("c1", k26dFiles(k26dLong, "")), shpSubmit("c2", k26dFiles("Add an is-even check", ""))}
	default:
		t.Fatalf("unknown mode %q", mode)
	}
	f := newShpFx(t, steps...)
	f.write("features/steps/calc_steps.js", "const { Given } = require('@cucumber/cucumber');\nGiven('a calculator', function () {});\n")
	if mode == "wrap" {
		f.write(".kogen/project.yaml", f.read(".kogen/project.yaml")+"shape_decision_check:\n  enabled: true\n")
	}
	f.git("add", "-A")
	f.git("commit", "-qm", "valid calc steps and config")
	f.setReport("PASSED", 0)
	f.Prov.route = func(req map[string]any) *shpStep {
		if names := shpToolNames(req); len(names) == 1 && names[0] == k26dTool {
			return k26dCheck()
		}
		return nil
	}
	f.newSession()
	exit, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: request, Client: f.Client, Tools: tools})
	out["exit"] = exit
	if err != nil {
		text := err.Error()
		if e, ok := sys.AsError(err); ok {
			text += "\n" + strings.Join(e.Lines, "\n")
		}
		out["error_text"] = text
	}
	var shaper []map[string]any
	checks := 0
	for _, r := range f.Prov.requests() {
		if names := shpToolNames(r); len(names) == 1 && names[0] == k26dTool {
			checks++
			continue
		}
		shaper = append(shaper, r)
	}
	out["decision_checks"] = checks
	if len(shaper) > 1 {
		out["feedback1"] = shpOutputs(shaper[1])["c1"]
	}
	out["published"] = err == nil && exit == 0 && f.exists(".kogen/intents/is-even/intent.md")
	if out["published"] == true {
		out["intent"] = f.read(".kogen/intents/is-even/intent.md")
	}
	if f.exists(".kogen/local/shaping/is-even/events.ndjson") {
		events := f.events()
		if r := shpNamed(events, "submission_refused"); r != nil {
			out["refused"] = r
		}
		if r := shpNamed(events, "decision_check"); r != nil {
			out["decision_events"] = r
		}
		if r := shpNamed(events, "title_shortened"); r != nil {
			out["title_events"] = r
		}
	}
	if out["published"] == true {
		f.newSession()
		code, cerr := Approve(context.Background(), f.S, ApproveInput{Project: f.Root, Slug: shpSlug, Tools: tools})
		out["card_exit"] = code
		out["card"] = f.Stdout.String()
		if cerr != nil {
			out["card"] = out["card"].(string) + "\nERROR: " + cerr.Error()
		}
	}
	write()
}

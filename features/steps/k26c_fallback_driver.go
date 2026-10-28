package shape

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"kogen-loop/sys"
	"kogen/executor"
	"kogen/verify"
)

// Observation only: it mounts as a test with go -overlay, changes no production source and
// drives the real Shape path (native with a scripted provider, or a scripted external shaper),
// then the real approval card.
const (
	k26cRequest = "Add calc.is_even(n). Example: is_even(0) returns True. Non-integers raise TypeError."
	k26cRule    = "Non-integers raise TypeError."
	k26cBase    = "- Non-integers raise TypeError. (source: request)"
	k26cZero    = "- Zero counts as even. (source: request)"
	k26cAnchor  = "- Non-integers raise TypeError. (source: request)\n"
	k26cTool    = "submit_decision_check"

	k26cAuditRequest = "Add calc.is_even(n). Example: is_even(0) returns True. Rule A: even numbers return True. Rule B: zero returns False."
	k26cQuoteA       = "Example: is_even(0) returns True."
	k26cQuoteB       = "Rule B: zero returns False."
	k26cCover        = "- Decision: for is_even(0) the result is True (because the example states it) (source: request)"
)

func k26cFiles(decision string) map[string]any {
	intent := shpIntentMD
	if decision != "" {
		intent = strings.Replace(shpIntentMD, k26cAnchor, k26cAnchor+decision+"\n", 1)
	}
	return map[string]any{"files": []any{
		map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": intent},
		map[string]any{"path": ".kogen/intents/is-even/acceptance.feature", "content": shpFeature},
		map[string]any{"path": "features/steps/is_even_steps.js", "content": shpSteps},
	}}
}

func k26cAudit() map[string]any {
	return map[string]any{
		"examples": []any{map[string]any{"quote": k26cQuoteA}},
		"rules":    []any{map[string]any{"quote": "Rule A: even numbers return True."}, map[string]any{"quote": k26cQuoteB}},
		"cells": []any{map[string]any{"example": 0, "rule": 0, "result": "agrees"},
			map[string]any{"example": 0, "rule": 1, "result": "conflicts"}},
		"defects": []any{map[string]any{"kind": "conflict", "quote_a": k26cQuoteA, "quote_b": k26cQuoteB,
			"exposing_input": "is_even(0)", "result_a": "True", "result_b": "False"}},
	}
}

func k26cCheck(mode string, req map[string]any) *shpStep {
	zero := k26cZero
	for _, l := range strings.Split(shpBody(req), "\n") {
		if strings.HasPrefix(l, "- Zero counts as even.") {
			zero = strings.TrimSpace(l)
		}
	}
	items := []any{map[string]any{"statement": k26cBase, "request_quotes": []any{k26cRule}, "verdict": "follows", "why": "the request states it"}}
	switch mode {
	case "unsupported":
		items = append(items, map[string]any{"statement": zero, "request_quotes": []any{}, "verdict": "unsupported", "why": "the request is silent on zero"})
	case "contradicts":
		items = append(items, map[string]any{"statement": zero, "request_quotes": []any{"Example: is_even(0) returns True."}, "verdict": "contradicts", "why": "the request says otherwise"})
	case "bounded":
		for i := 0; i < 25; i++ {
			items = append(items, map[string]any{"statement": "- Invented decision " + string(rune('A'+i)) + ". (source: request)", "request_quotes": []any{},
				"verdict": "unsupported", "why": strings.Repeat("x", 400)})
		}
	}
	st := shpAnswer(shpCall("check-1", k26cTool, map[string]any{"items": items}))
	return &st
}

func TestK26cFallbackObservation(t *testing.T) {
	mode := os.Getenv("KOGEN_K26C_MODE")
	out := map[string]any{"mode": mode, "exit": 0, "error_text": "", "published": false, "intent": "", "feedback1": "",
		"decision_checks": 0, "refused": []any{}, "marked": []any{}, "card_exit": -1, "card": "",
		"feature_exists": false, "steps_exists": false, "intent_disk": ""}
	write := func() {
		raw, _ := json.Marshal(out)
		if err := os.WriteFile(os.Getenv("KOGEN_K26C_OUTPUT"), raw, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	tools := verify.Tools{Node: os.Getenv("KOGEN_NODE"), Quint: os.Getenv("KOGEN_QUINT"), Cucumber: os.Getenv("KOGEN_CUCUMBER")}
	fail := func(err error) string {
		text := err.Error()
		if e, ok := sys.AsError(err); ok {
			text += "\n" + strings.Join(e.Lines, "\n")
		}
		return text
	}
	// published means Shape ended ready; a refused Shape may leave its written files on disk.
	finish := func(f *shpFx, exit int, err error) {
		out["published"] = err == nil && exit == 0 && f.exists(".kogen/intents/is-even/intent.md")
		out["feature_exists"] = f.exists(".kogen/intents/is-even/acceptance.feature")
		out["steps_exists"] = f.exists("features/steps/is_even_steps.js")
		if f.exists(".kogen/intents/is-even/intent.md") {
			out["intent_disk"] = f.read(".kogen/intents/is-even/intent.md")
		}
		if out["published"] == true {
			out["intent"] = out["intent_disk"]
		}
		if f.exists(".kogen/local/shaping/is-even/events.ndjson") {
			events := f.events()
			if r := shpNamed(events, "submission_refused"); r != nil {
				out["refused"] = r
			}
			if m := shpNamed(events, "decision_assumptions_marked"); m != nil {
				out["marked"] = m
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
	}

	if mode == "wrapcol" {
		f := newShpFx(t)
		f.useExternalShape(6)
		f.write("features/steps/calc_steps.js", "const { Given } = require('@cucumber/cucumber');\nGiven('a calculator', function () {});\n")
		f.write(".kogen/project.yaml", f.read(".kogen/project.yaml")+"shape_audit:\n  enabled: true\n")
		f.git("add", "-A")
		f.git("commit", "-qm", "valid calc steps and config")
		f.setReport("PASSED", 0)
		correction := map[string]any{"files": []any{map[string]any{"path": ".kogen/intents/is-even/intent.md",
			"content": strings.Replace(shpIntentMD, k26cAnchor, k26cAnchor+k26cCover+"\n", 1)}}}
		x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){result(k26cAudit()), result(k26cFiles("")), result(correction)}}
		f.newSession()
		exit, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: k26cAuditRequest, Client: f.Client, Tools: tools, External: x.external()})
		out["exit"] = exit
		if err != nil {
			out["error_text"] = fail(err)
		}
		finish(f, exit, err)
		write()
		return
	}

	switch mode {
	case "unsupported", "contradicts", "bounded":
	default:
		t.Fatalf("unknown mode %q", mode)
	}
	f := newShpFx(t, shpSubmit("c1", k26cFiles(k26cZero)), shpSubmit("c2", k26cFiles(k26cZero)), shpSubmit("c3", k26cFiles(k26cZero)))
	f.write("features/steps/calc_steps.js", "const { Given } = require('@cucumber/cucumber');\nGiven('a calculator', function () {});\n")
	f.write(".kogen/project.yaml", f.read(".kogen/project.yaml")+"shape_decision_check:\n  enabled: true\n")
	f.git("add", "-A")
	f.git("commit", "-qm", "valid calc steps and config")
	f.setReport("PASSED", 0)
	f.Prov.route = func(req map[string]any) *shpStep {
		if names := shpToolNames(req); len(names) == 1 && names[0] == k26cTool {
			return k26cCheck(mode, req)
		}
		return nil
	}
	f.newSession()
	exit, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: k26cRequest, Client: f.Client, Tools: tools})
	out["exit"] = exit
	if err != nil {
		out["error_text"] = fail(err)
	}
	var shaper []map[string]any
	checks := 0
	for _, r := range f.Prov.requests() {
		if names := shpToolNames(r); len(names) == 1 && names[0] == k26cTool {
			checks++
			continue
		}
		shaper = append(shaper, r)
	}
	out["decision_checks"] = checks
	if len(shaper) > 1 {
		out["feedback1"] = shpOutputs(shaper[1])["c1"]
	}
	finish(f, exit, err)
	write()
}

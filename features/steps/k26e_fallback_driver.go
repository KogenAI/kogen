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
// drives the real Shape path (native with a scripted provider and a scripted decision check),
// then the real approval card.
const (
	k26eRequest = "Add calc.is_even(n). Example: is_even(0) returns True. Non-integers raise TypeError."
	k26eRule    = "Non-integers raise TypeError."
	k26eBase    = "- Non-integers raise TypeError. (source: request)"
	k26eD1      = "- Zero counts as even. (source: request)"
	k26eD2      = "- Negative numbers are even by parity. (source: request)"
	k26eP1      = "Input --5 stays invalid."
	k26eP2raw   = "(a zero result  is plain 0)"
	k26eMissing = "- Odd numbers return False. (source: request)"
	k26eTool    = "submit_decision_check"
	old         = "calc.is_even(n) returns True for even integers.\n"
	k26eProse   = "calc.is_even(n) returns True for even integers. Input --5 stays invalid. Zero is handled (a zero result\nis plain 0).\n"
)

func k26eIntent() string {
	intent := strings.Replace(shpIntentMD, old, k26eProse, 1)
	anchor := k26eBase + "\n"
	return strings.Replace(intent, anchor, anchor+k26eD1+"\n"+k26eD2+"\n", 1)
}

func k26eFiles() map[string]any {
	return map[string]any{"files": []any{
		map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": k26eIntent()},
		map[string]any{"path": ".kogen/intents/is-even/acceptance.feature", "content": shpFeature},
		map[string]any{"path": "features/steps/is_even_steps.js", "content": shpSteps},
	}}
}

func k26eCheck(mode string) *shpStep {
	un := func(statement, why string) map[string]any {
		return map[string]any{"statement": statement, "request_quotes": []any{}, "verdict": "unsupported", "why": why}
	}
	d1 := un(k26eD1, "the request is silent on zero")
	if mode == "contradicts" {
		d1 = map[string]any{"statement": k26eD1, "request_quotes": []any{"Example: is_even(0) returns True."}, "verdict": "contradicts", "why": "the request says otherwise"}
	}
	items := []any{
		map[string]any{"statement": k26eBase, "request_quotes": []any{k26eRule}, "verdict": "follows", "why": "the request states it"},
		d1,
		un(k26eD2, "the request is silent on negatives"),
		un(k26eP1, " the request\n is silent on input syntax "),
		un(k26eP2raw, "the request is silent on zero results"),
	}
	if mode == "missing" {
		items = append(items, un(k26eMissing, "the request is silent on odd numbers"))
	}
	st := shpAnswer(shpCall("check-1", k26eTool, map[string]any{"items": items}))
	return &st
}

func TestK26eFallbackObservation(t *testing.T) {
	mode := os.Getenv("KOGEN_K26E_MODE")
	switch mode {
	case "mixed", "missing", "contradicts":
	default:
		t.Fatalf("unknown mode %q", mode)
	}
	out := map[string]any{"mode": mode, "exit": 0, "error_text": "", "published": false, "intent": "", "intent_disk": "",
		"decision_checks": 0, "refused": []any{}, "marked": []any{}, "card_exit": -1, "card": ""}
	tools := verify.Tools{Node: os.Getenv("KOGEN_NODE"), Quint: os.Getenv("KOGEN_QUINT"), Cucumber: os.Getenv("KOGEN_CUCUMBER")}
	f := newShpFx(t, shpSubmit("c1", k26eFiles()), shpSubmit("c2", k26eFiles()), shpSubmit("c3", k26eFiles()))
	f.write("features/steps/calc_steps.js", "const { Given } = require('@cucumber/cucumber');\nGiven('a calculator', function () {});\n")
	f.write(".kogen/project.yaml", f.read(".kogen/project.yaml")+"shape_decision_check:\n  enabled: true\n")
	f.git("add", "-A")
	f.git("commit", "-qm", "valid calc steps and config")
	f.setReport("PASSED", 0)
	f.Prov.route = func(req map[string]any) *shpStep {
		if names := shpToolNames(req); len(names) == 1 && names[0] == k26eTool {
			return k26eCheck(mode)
		}
		return nil
	}
	f.newSession()
	exit, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: k26eRequest, Client: f.Client, Tools: tools})
	out["exit"] = exit
	if err != nil {
		text := err.Error()
		if e, ok := sys.AsError(err); ok {
			text += "\n" + strings.Join(e.Lines, "\n")
		}
		out["error_text"] = text
	}
	checks := 0
	for _, r := range f.Prov.requests() {
		if names := shpToolNames(r); len(names) == 1 && names[0] == k26eTool {
			checks++
		}
	}
	out["decision_checks"] = checks
	out["published"] = err == nil && exit == 0 && f.exists(".kogen/intents/is-even/intent.md")
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
	raw, _ := json.Marshal(out)
	if err := os.WriteFile(os.Getenv("KOGEN_K26E_OUTPUT"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
}

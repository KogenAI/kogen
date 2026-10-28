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
// drives the real native Shape path against a scripted provider (audit answer plus shaper),
// then the real approval card.
const (
	k25cRequest = "Add calc.is_even(n). Example: is_even(0) returns True. Rule A: even numbers return True. Rule B: zero returns False."
	k25cQuoteA  = "Example: is_even(0) returns True."
	k25cQuoteB  = "Rule B: zero returns False."
	k25cExpose  = "is_even(0)"
	k25cAnchor  = "- Non-integers raise TypeError. (source: request)\n"
)

func k25cFiles(decision string) map[string]any {
	intent := shpIntentMD
	if decision != "" {
		intent = strings.Replace(shpIntentMD, k25cAnchor, k25cAnchor+decision+"\n", 1)
	}
	return map[string]any{"files": []any{
		map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": intent},
		map[string]any{"path": ".kogen/intents/is-even/acceptance.feature", "content": shpFeature},
		map[string]any{"path": "features/steps/is_even_steps.js", "content": shpSteps},
	}}
}

func k25cAudit() map[string]any {
	return map[string]any{
		"examples": []any{map[string]any{"quote": k25cQuoteA}},
		"rules":    []any{map[string]any{"quote": "Rule A: even numbers return True."}, map[string]any{"quote": k25cQuoteB}},
		"cells": []any{map[string]any{"example": 0, "rule": 0, "result": "agrees"},
			map[string]any{"example": 0, "rule": 1, "result": "conflicts"}},
		"defects": []any{map[string]any{"kind": "conflict", "quote_a": k25cQuoteA, "quote_b": k25cQuoteB,
			"exposing_input": k25cExpose, "result_a": "True", "result_b": "False"}},
	}
}

func TestK25cGateObservation(t *testing.T) {
	mode := os.Getenv("KOGEN_K25C_MODE")
	out := map[string]any{"mode": mode, "exit": 0, "error_text": "", "published": false, "requests": 0, "audit_requests": 0,
		"feedback1": "", "feedback2": "", "selfchecks": 0, "audits": []any{}, "card_exit": -1, "card": "", "intent": ""}
	write := func() {
		raw, _ := json.Marshal(out)
		if err := os.WriteFile(os.Getenv("KOGEN_K25C_OUTPUT"), raw, 0o600); err != nil {
			t.Fatal(err)
		}
	}

	if mode == "undefined_template" {
		sh := &shaping{slug: "s", proposed: map[string]string{}, auditResult: &auditResult{defects: []map[string]any{
			{"kind": "undefined", "quote_a": "makes a gadget", "quote_b": "Widget", "exposing_input": "any", "result_a": "", "result_b": ""}}}}
		out["feedback1"] = strings.Join(sh.auditGate(submission{questions: []map[string]any{{"question": "x"}}}), "\n")
		write()
		return
	}

	var steps []shpStep
	switch mode {
	case "never":
		steps = []shpStep{shpSubmit("c1", k25cFiles("")), shpSubmit("c2", k25cFiles("")), shpSubmit("c3", k25cFiles(""))}
	case "paste":
		steps = []shpStep{shpSubmit("c1", k25cFiles(""))}
	default:
		t.Fatalf("unknown mode %q", mode)
	}
	f := newShpFx(t, steps...)
	f.write("features/steps/calc_steps.js", "const { Given } = require('@cucumber/cucumber');\nGiven('a calculator', function () {});\n")
	f.write(".kogen/project.yaml", f.read(".kogen/project.yaml")+"shape_audit:\n  enabled: true\n")
	f.git("add", "-A")
	f.git("commit", "-qm", "valid calc steps and config")
	f.setReport("PASSED", 0)
	pasted := ""
	f.Prov.route = func(req map[string]any) *shpStep {
		if names := shpToolNames(req); len(names) == 1 && names[0] == "submit_audit" {
			st := shpAnswer(shpCall("audit-1", "submit_audit", k25cAudit()))
			return &st
		}
		if mode == "paste" {
			o := shpOutputs(req)
			if _, second := o["c2"]; !second && o["c1"] != "" {
				for _, l := range strings.Split(o["c1"], "\n") {
					if strings.HasPrefix(l, "- Decision: ") {
						pasted = l
						break
					}
				}
				st := shpSubmit("c2", k25cFiles(pasted))
				return &st
			}
		}
		return nil
	}
	tools := verify.Tools{Node: os.Getenv("KOGEN_NODE"), Quint: os.Getenv("KOGEN_QUINT"), Cucumber: os.Getenv("KOGEN_CUCUMBER")}
	in := ShapeInput{Project: f.Root, Slug: shpSlug, Request: k25cRequest, Client: f.Client, Tools: tools}
	f.newSession()
	exit, err := Shape(context.Background(), f.S, in)
	out["exit"] = exit
	if err != nil {
		text := err.Error()
		if e, ok := sys.AsError(err); ok {
			text += "\n" + strings.Join(e.Lines, "\n")
		}
		out["error_text"] = text
	}
	out["published"] = f.exists(".kogen/intents/is-even/intent.md")
	if out["published"] == true {
		out["intent"] = f.read(".kogen/intents/is-even/intent.md")
	}
	reqs := f.Prov.requests()
	var shaper []map[string]any
	for _, r := range reqs {
		if names := shpToolNames(r); len(names) == 1 && names[0] == "submit_audit" {
			out["audit_requests"] = out["audit_requests"].(int) + 1
			continue
		}
		shaper = append(shaper, r)
	}
	out["requests"] = len(reqs)
	if len(shaper) > 1 {
		out["feedback1"] = shpOutputs(shaper[1])["c1"]
	}
	if len(shaper) > 2 {
		out["feedback2"] = shpOutputs(shaper[2])["c2"]
	}
	if f.exists(".kogen/local/shaping/is-even/events.ndjson") {
		events := f.events()
		var audits []any
		for _, ev := range shpNamed(events, "request_audit") {
			audits = append(audits, ev)
		}
		if audits != nil {
			out["audits"] = audits
		}
		out["selfchecks"] = len(shpNamed(events, "step_selfcheck"))
	}
	if out["published"] == true && err == nil {
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

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
// drives the real native Shape path (with the request audit) against a scripted provider.
const (
	k9Request = "Add calc.is_even(n). Example: is_even(0) returns True. Rule A: even numbers return True. Rule B: zero returns False."
	k9QuoteA  = "Example: is_even(0) returns True."
	k9QuoteB  = "Rule B: zero returns False."
	k9Anchor  = "- Non-integers raise TypeError. (source: request)\n"
)

func k9Files(decision string) map[string]any {
	intent := shpIntentMD
	if decision != "" {
		intent = strings.Replace(shpIntentMD, k9Anchor, k9Anchor+decision+"\n", 1)
	}
	return map[string]any{"files": []any{
		map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": intent},
		map[string]any{"path": ".kogen/intents/is-even/acceptance.feature", "content": shpFeature},
		map[string]any{"path": "features/steps/is_even_steps.js", "content": shpSteps},
	}}
}

func k9Audit() map[string]any {
	return map[string]any{
		"examples": []any{map[string]any{"quote": k9QuoteA}},
		"rules":    []any{map[string]any{"quote": "Rule A: even numbers return True."}, map[string]any{"quote": k9QuoteB}},
		"cells": []any{map[string]any{"example": 0, "rule": 0, "result": "agrees"},
			map[string]any{"example": 0, "rule": 1, "result": "conflicts"}},
		"defects": []any{map[string]any{"kind": "conflict", "quote_a": k9QuoteA, "quote_b": k9QuoteB,
			"exposing_input": "is_even(0)", "result_a": "True", "result_b": "False"}},
	}
}

func TestK9ShapeRecordObservation(t *testing.T) {
	f := newShpFx(t, shpSubmit("c1", k9Files("")), shpSubmit("c2", k9Files("- is_even(0) returns True. (source: request)")))
	f.write("features/steps/calc_steps.js", "const { Given } = require('@cucumber/cucumber');\nGiven('a calculator', function () {});\n")
	f.write(".kogen/project.yaml", f.read(".kogen/project.yaml")+"shape_audit:\n  enabled: true\n")
	f.git("add", "-A")
	f.git("commit", "-qm", "valid calc steps and config")
	f.setReport("PASSED", 0)
	f.Prov.route = func(req map[string]any) *shpStep {
		if names := shpToolNames(req); len(names) == 1 && names[0] == "submit_audit" {
			st := shpAnswer(shpCall("audit-1", "submit_audit", k9Audit()))
			return &st
		}
		return nil
	}
	in := ShapeInput{Project: f.Root, Slug: shpSlug, Request: k9Request, Client: f.Client,
		Tools: verify.Tools{Node: os.Getenv("KOGEN_NODE"), Quint: os.Getenv("KOGEN_QUINT"), Cucumber: os.Getenv("KOGEN_CUCUMBER")}}
	f.newSession()
	exit, err := Shape(context.Background(), f.S, in)
	text := ""
	if err != nil {
		text = err.Error()
		if e, ok := sys.AsError(err); ok {
			text += "\n" + strings.Join(e.Lines, "\n")
		}
	}
	var sizes []int
	var audit []bool
	for _, req := range f.Prov.requests() {
		raw, _ := json.Marshal(req)
		sizes = append(sizes, len(raw))
		names := shpToolNames(req)
		audit = append(audit, len(names) == 1 && names[0] == "submit_audit")
	}
	out := map[string]any{"exit": exit, "error_text": text, "published": f.exists(".kogen/intents/is-even/intent.md"),
		"provider_calls": shpNamed(f.events(), "provider_call"), "provider_sizes": sizes, "audit_requests": audit}
	raw, _ := json.Marshal(out)
	if werr := os.WriteFile(os.Getenv("KOGEN_K9_OUTPUT"), raw, 0o600); werr != nil {
		t.Fatal(werr)
	}
}

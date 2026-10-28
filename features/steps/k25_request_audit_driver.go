package shape

import (
	"context"
	"encoding/json"
	"os"
	"slices"
	"strings"
	"testing"

	"kogen-loop/sys"
	"kogen/verify"
)

// Observation only: it mounts as a test with go -overlay, changes no production source and
// drives the real native Shape path against a scripted provider that answers the request
// audit (the one call whose only tool is submit_audit) and the shaper.
const (
	k25Request = "Add calc.is_even(n). Example: is_even(0) returns True. Rule A: even numbers return True. Rule B: zero returns False."
	k25QuoteA  = "Example: is_even(0) returns True."
	k25QuoteB  = "Rule B: zero returns False."
	k25Expose  = "is_even(0)"
	k25Anchor  = "- Non-integers raise TypeError. (source: request)\n"
)

func k25Files(decision string) map[string]any {
	intent := shpIntentMD
	if decision != "" {
		intent = strings.Replace(shpIntentMD, k25Anchor, k25Anchor+decision+"\n", 1)
	}
	return map[string]any{"files": []any{
		map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": intent},
		map[string]any{"path": ".kogen/intents/is-even/acceptance.feature", "content": shpFeature},
		map[string]any{"path": "features/steps/is_even_steps.js", "content": shpSteps},
	}}
}

func k25Question(text string) map[string]any {
	return map[string]any{"questions": []any{map[string]any{"question": text,
		"options": []any{map[string]any{"label": "True", "recommended": true}, map[string]any{"label": "False"}}}}}
}

func k25Audit(conflict bool) map[string]any {
	result, defects := "agrees", []any{}
	if conflict {
		result = "conflicts"
		defects = []any{map[string]any{"kind": "conflict", "quote_a": k25QuoteA, "quote_b": k25QuoteB,
			"exposing_input": k25Expose, "result_a": "True", "result_b": "False"}}
	}
	return map[string]any{
		"examples": []any{map[string]any{"quote": k25QuoteA}},
		"rules":    []any{map[string]any{"quote": "Rule A: even numbers return True."}, map[string]any{"quote": k25QuoteB}},
		"cells": []any{map[string]any{"example": 0, "rule": 0, "result": "agrees"},
			map[string]any{"example": 0, "rule": 1, "result": result}},
		"defects": defects,
	}
}

func k25Mentions(body string, parts ...string) bool {
	for _, p := range parts {
		if !strings.Contains(body, p) {
			return false
		}
	}
	return true
}

func TestK25RequestAuditObservation(t *testing.T) {
	mode := os.Getenv("KOGEN_K25_MODE")
	decision := "- is_even(0) returns True. (source: request)"
	both := k25Question("Your request says \"" + k25QuoteA + "\" but also \"" + k25QuoteB + "\". Which result is right?")
	var steps []shpStep
	switch mode {
	case "clean", "off":
		steps = []shpStep{shpSubmit("c1", k25Files(""))}
	case "decision":
		steps = []shpStep{shpSubmit("c1", k25Files("")), shpSubmit("c2", k25Files(decision))}
	case "ambiguous":
		steps = []shpStep{shpSubmit("c1", k25Files("- is_even(0) returns True or False. (source: request)")), shpSubmit("c2", k25Files(decision))}
	case "question":
		steps = []shpStep{shpSubmit("c1", both)}
	case "partial":
		steps = []shpStep{shpSubmit("c1", k25Question("Your request says \""+k25QuoteA+"\". Which result is right?")), shpSubmit("c2", both)}
	}
	f := newShpFx(t, steps...)
	f.write("features/steps/calc_steps.js", "const { Given } = require('@cucumber/cucumber');\nGiven('a calculator', function () {});\n")
	switch mode {
	case "off":
	case "badkey":
		f.write(".kogen/project.yaml", f.read(".kogen/project.yaml")+"shape_audit:\n  enabled: true\n  extra: 1\n")
	default:
		f.write(".kogen/project.yaml", f.read(".kogen/project.yaml")+"shape_audit:\n  enabled: true\n")
	}
	f.git("add", "-A")
	f.git("commit", "-qm", "valid calc steps and config")
	f.setReport("PASSED", 0)
	f.Prov.route = func(req map[string]any) *shpStep {
		if names := shpToolNames(req); len(names) == 1 && names[0] == "submit_audit" {
			st := shpAnswer(shpCall("audit-1", "submit_audit", k25Audit(mode != "clean")))
			return &st
		}
		return nil
	}
	in := ShapeInput{Project: f.Root, Slug: shpSlug, Request: k25Request, Client: f.Client,
		Tools: verify.Tools{Node: os.Getenv("KOGEN_NODE"), Quint: os.Getenv("KOGEN_QUINT"), Cucumber: os.Getenv("KOGEN_CUCUMBER")}}
	f.newSession()
	exit, err := Shape(context.Background(), f.S, in)

	out := map[string]any{"mode": mode, "exit": exit, "error_text": "", "published": f.exists(".kogen/intents/is-even/intent.md"),
		"feedback": "", "stdout": f.Stdout.String(), "intent": "", "audits": []any{}, "selfchecks": 0, "audit_before_selfcheck": true}
	if err != nil {
		text := err.Error()
		if e, ok := sys.AsError(err); ok {
			text += "\n" + strings.Join(e.Lines, "\n")
		}
		out["error_text"] = text
	}
	if out["published"] == true {
		out["intent"] = f.read(".kogen/intents/is-even/intent.md")
	}
	reqs := f.Prov.requests()
	var shaper []map[string]any
	auditCount, auditIdx := 0, -1
	var audit map[string]any
	out["shaper_tools_have_audit"], out["shaper_mentions_audit"], out["shaper_first_has_defect"] = false, false, false
	for i, r := range reqs {
		if names := shpToolNames(r); len(names) == 1 && names[0] == "submit_audit" {
			auditCount++
			if auditIdx < 0 {
				auditIdx, audit = i, r
			}
			continue
		}
		if slices.Contains(shpToolNames(r), "submit_audit") {
			out["shaper_tools_have_audit"] = true
		}
		if strings.Contains(shpBody(r), "Request audit") {
			out["shaper_mentions_audit"] = true
		}
		shaper = append(shaper, r)
	}
	out["requests"], out["audit_requests"], out["audit_first"] = len(reqs), auditCount, auditIdx == 0
	out["audit_has_request"], out["audit_leak"] = false, false
	if audit != nil {
		body := shpBody(audit)
		out["audit_has_request"] = strings.Contains(body, k25Request)
		out["audit_leak"] = strings.Contains(body, "Context navigation") || strings.Contains(body, "A tiny calculator")
	}
	if len(shaper) > 0 {
		out["shaper_first_has_defect"] = k25Mentions(shpBody(shaper[0]), k25QuoteA, k25QuoteB, k25Expose)
	}
	if len(shaper) > 1 {
		out["feedback"] = shpOutputs(shaper[1])["c1"]
	}
	if f.exists(".kogen/local/shaping/is-even/events.ndjson") {
		events := f.events()
		var audits []any
		firstAudit, firstCheck := -1, -1
		for i, ev := range events {
			switch ev["event"] {
			case "request_audit":
				audits = append(audits, ev)
				if firstAudit < 0 {
					firstAudit = i
				}
			case "step_selfcheck":
				if firstCheck < 0 {
					firstCheck = i
				}
			}
		}
		if audits != nil {
			out["audits"] = audits
		}
		out["selfchecks"] = len(shpNamed(events, "step_selfcheck"))
		out["audit_before_selfcheck"] = firstCheck < 0 || (firstAudit >= 0 && firstAudit < firstCheck)
	}
	raw, _ := json.Marshal(out)
	if werr := os.WriteFile(os.Getenv("KOGEN_K25_OUTPUT"), raw, 0o600); werr != nil {
		t.Fatal(werr)
	}
}

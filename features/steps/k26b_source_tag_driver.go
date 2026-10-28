package shape

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"kogen-loop/sys"
	"kogen/verify"
)

// Observation only: it mounts as a test with go -overlay, changes no production source and
// drives the real native Shape path against a scripted provider (shaper, decision check and
// audit), then the real approval card.
const (
	k26bRequest = "Add calc.is_even(n). Example: is_even(0) returns True. Non-integers raise TypeError."
	k26bRule    = "Non-integers raise TypeError."
	k26bBase    = "- Non-integers raise TypeError. (source: request)"
	k26bZero    = "- Zero counts as even. (source: request)"
	k26bAnchor  = "- Non-integers raise TypeError. (source: request)\n"
	k26bTool    = "submit_decision_check"

	k26bAuditRequest = "Add calc.is_even(n). Example: is_even(0) returns True. Rule A: even numbers return True. Rule B: zero returns False."
	k26bQuoteA       = "Example: is_even(0) returns True."
	k26bQuoteB       = "Rule B: zero returns False."
)

func k26bFiles(decision string) map[string]any {
	intent := shpIntentMD
	if decision != "" {
		intent = strings.Replace(shpIntentMD, k26bAnchor, k26bAnchor+decision+"\n", 1)
	}
	return map[string]any{"files": []any{
		map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": intent},
		map[string]any{"path": ".kogen/intents/is-even/acceptance.feature", "content": shpFeature},
		map[string]any{"path": "features/steps/is_even_steps.js", "content": shpSteps},
	}}
}

func k26bAudit() map[string]any {
	return map[string]any{
		"examples": []any{map[string]any{"quote": k26bQuoteA}},
		"rules":    []any{map[string]any{"quote": "Rule A: even numbers return True."}, map[string]any{"quote": k26bQuoteB}},
		"cells": []any{map[string]any{"example": 0, "rule": 0, "result": "agrees"},
			map[string]any{"example": 0, "rule": 1, "result": "conflicts"}},
		"defects": []any{map[string]any{"kind": "conflict", "quote_a": k26bQuoteA, "quote_b": k26bQuoteB,
			"exposing_input": "is_even(0)", "result_a": "True", "result_b": "False"}},
	}
}

var k26bTemplate = regexp.MustCompile(`e\.g\. (- <decision> \(assumption: <what the user must confirm>\) \(source: request\))`)

// k26bFollow applies the K26 feedback literally: it takes the example line the feedback gives
// and fills its two placeholders. Without such a line it falls back to the line a shaper wrote
// when the feedback said only "mark the decision as an assumption".
func k26bFollow(feedback string) string {
	line := "- Zero counts as even. (assumption: the request is silent on zero)"
	if m := k26bTemplate.FindStringSubmatch(feedback); m != nil {
		line = strings.Replace(m[1], "<decision>", "Zero counts as even.", 1)
		line = strings.Replace(line, "<what the user must confirm>", "the request is silent on zero", 1)
	}
	return line
}

func k26bCheckAnswer(req map[string]any) *shpStep {
	zero := k26bZero
	for _, l := range strings.Split(shpBody(req), "\n") {
		if strings.HasPrefix(l, "- Zero counts as even.") {
			zero = strings.TrimSpace(l)
		}
	}
	st := shpAnswer(shpCall("check-1", k26bTool, map[string]any{"items": []any{
		map[string]any{"statement": k26bBase, "request_quotes": []any{k26bRule}, "verdict": "follows", "why": "the request states it"},
		map[string]any{"statement": zero, "request_quotes": []any{}, "verdict": "unsupported", "why": "the request is silent on zero"},
	}}))
	return &st
}

func TestK26bSourceTagObservation(t *testing.T) {
	mode := os.Getenv("KOGEN_K26B_MODE")
	out := map[string]any{"mode": mode, "exit": 0, "error_text": "", "published": false, "intent": "", "feedback": "",
		"pasted": "", "card_exit": -1, "card": "", "card2_exit": -1, "card2": "", "second_exit": -1, "second_error": ""}
	write := func() {
		raw, _ := json.Marshal(out)
		if err := os.WriteFile(os.Getenv("KOGEN_K26B_OUTPUT"), raw, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	var steps []shpStep
	switch mode {
	case "assume":
		steps = []shpStep{shpSubmit("c1", k26bFiles(k26bZero))}
	case "paste":
		steps = []shpStep{shpSubmit("c1", k26bFiles(""))}
	case "stale", "stale_covered":
		steps = []shpStep{shpSubmit("c1", k26bFiles("")), shpSubmit("c2", k26bFiles("")), shpSubmit("c3", k26bFiles(""))}
	default:
		t.Fatalf("unknown mode %q", mode)
	}
	request := k26bAuditRequest
	if mode == "assume" {
		request = k26bRequest
	}
	f := newShpFx(t, steps...)
	f.write("features/steps/calc_steps.js", "const { Given } = require('@cucumber/cucumber');\nGiven('a calculator', function () {});\n")
	base := f.read(".kogen/project.yaml")
	audit := "shape_audit:\n  enabled: true\n"
	if mode == "assume" {
		f.write(".kogen/project.yaml", base+"shape_decision_check:\n  enabled: true\n")
	} else {
		f.write(".kogen/project.yaml", base+audit)
	}
	f.git("add", "-A")
	f.git("commit", "-qm", "valid calc steps and config")
	f.setReport("PASSED", 0)
	f.Prov.route = func(req map[string]any) *shpStep {
		names := shpToolNames(req)
		if len(names) == 1 && names[0] == k26bTool {
			return k26bCheckAnswer(req)
		}
		if len(names) == 1 && names[0] == "submit_audit" {
			st := shpAnswer(shpCall("audit-1", "submit_audit", k26bAudit()))
			return &st
		}
		o := shpOutputs(req)
		switch mode {
		case "assume":
			if _, second := o["c2"]; !second && o["c1"] != "" {
				st := shpSubmit("c2", k26bFiles(k26bFollow(o["c1"])))
				return &st
			}
		case "paste":
			if _, second := o["c2"]; !second && o["c1"] != "" {
				st := shpSubmit("c2", k26bFiles(k26bFirstDecision(o["c1"])))
				return &st
			}
		case "stale_covered":
			if len(o) == 0 && out["second_exit"] != -1 {
				st := shpSubmit("d1", k26bFiles(""))
				return &st
			}
			if _, ok := o["d1"]; ok {
				if _, second := o["d2"]; !second {
					st := shpSubmit("d2", k26bFiles(k26bFirstDecision(o["d1"])))
					return &st
				}
			}
		case "stale":
			if len(o) == 0 && out["second_exit"] != -1 {
				st := shpSubmit("d1", k26bFiles(""))
				return &st
			}
		}
		return nil
	}
	tools := verify.Tools{Node: os.Getenv("KOGEN_NODE"), Quint: os.Getenv("KOGEN_QUINT"), Cucumber: os.Getenv("KOGEN_CUCUMBER")}
	fail := func(err error) string {
		text := err.Error()
		if e, ok := sys.AsError(err); ok {
			text += "\n" + strings.Join(e.Lines, "\n")
		}
		return text
	}
	card := func() (int, string) {
		f.newSession()
		code, cerr := Approve(context.Background(), f.S, ApproveInput{Project: f.Root, Slug: shpSlug, Tools: tools})
		text := f.Stdout.String()
		if cerr != nil {
			text += "\nERROR: " + cerr.Error()
		}
		return code, text
	}
	f.newSession()
	exit, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: request, Client: f.Client, Tools: tools})
	out["exit"] = exit
	if err != nil {
		out["error_text"] = fail(err)
	}
	out["published"] = f.exists(".kogen/intents/is-even/intent.md")
	if out["published"] == true {
		out["intent"] = f.read(".kogen/intents/is-even/intent.md")
	}
	var shaper []map[string]any
	for _, r := range f.Prov.requests() {
		if names := shpToolNames(r); len(names) == 1 && (names[0] == k26bTool || names[0] == "submit_audit") {
			continue
		}
		shaper = append(shaper, r)
	}
	if len(shaper) > 1 {
		out["feedback"] = shpOutputs(shaper[1])["c1"]
	}
	if mode == "paste" {
		out["pasted"] = k26bFirstDecision(out["feedback"].(string))
	}
	if out["published"] == true && err == nil {
		out["card_exit"], out["card"] = card()
	}
	if (mode == "stale" || mode == "stale_covered") && out["published"] == true {
		// Reshape the same slug: delete the Intent and its owned step file, drop the audit unless
		// every defect is to be covered, and shape again with a fresh conversation.
		os.RemoveAll(filepath.Join(f.Root, ".kogen/intents/is-even"))
		os.Remove(filepath.Join(f.Root, "features/steps/is_even_steps.js"))
		if mode == "stale" {
			f.write(".kogen/project.yaml", base)
		}
		f.git("add", "-A")
		f.git("commit", "-qm", "reshape", "--allow-empty")
		out["second_exit"] = 0
		f.newSession()
		exit2, err2 := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: request, Client: f.Client, Tools: tools})
		out["second_exit"] = exit2
		if err2 != nil {
			out["second_error"] = fail(err2)
		} else {
			out["card2_exit"], out["card2"] = card()
		}
	}
	write()
}

func k26bFirstDecision(feedback string) string {
	for _, l := range strings.Split(feedback, "\n") {
		if strings.HasPrefix(l, "- Decision: ") {
			return l
		}
	}
	return ""
}

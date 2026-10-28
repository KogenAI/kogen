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
// drives the real native Shape path against a scripted provider that answers the decision
// check (the one call whose only tool is submit_decision_check) and the shaper, then the real
// approval card.
const (
	k26Request = "Add calc.is_even(n). Example: is_even(0) returns True. Non-integers raise TypeError."
	k26Example = "Example: is_even(0) returns True."
	k26Rule    = "Non-integers raise TypeError."
	k26Fake    = "Example: is_even(0) always returns True."
	k26Anchor  = "- Non-integers raise TypeError. (source: request)\n"
	k26Base    = "- Non-integers raise TypeError. (source: request)"
	k26Wrong   = "- is_even(0) returns False. (source: request)"
	k26Right   = "- is_even(0) returns True. (source: request)"
	k26Assume  = "- Zero counts as even. (assumption: the request is silent on zero) (source: request)"
	k26Tool    = "submit_decision_check"
)

func k26Files(decision string) map[string]any {
	intent := strings.Replace(shpIntentMD, k26Anchor, k26Anchor+decision+"\n", 1)
	return map[string]any{"files": []any{
		map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": intent},
		map[string]any{"path": ".kogen/intents/is-even/acceptance.feature", "content": shpFeature},
		map[string]any{"path": "features/steps/is_even_steps.js", "content": shpSteps},
	}}
}

func k26Item(statement string, quotes []any, verdict, why string) any {
	return map[string]any{"statement": statement, "request_quotes": quotes, "verdict": verdict, "why": why}
}

func k26Base1() any {
	return k26Item(k26Base, []any{k26Rule}, "follows", "the request states it")
}

func k26Answer(items ...any) map[string]any { return map[string]any{"items": items} }

func k26Script(mode string) []map[string]any {
	switch mode {
	case "contradict":
		return []map[string]any{
			k26Answer(k26Base1(), k26Item(k26Wrong, []any{k26Example}, "contradicts", "the request example says True")),
			k26Answer(k26Base1(), k26Item(k26Right, []any{k26Example}, "follows", "the request example says True")),
		}
	case "unsupported":
		return []map[string]any{
			k26Answer(k26Base1(), k26Item(k26Right, []any{k26Fake}, "follows", "the request says so")),
			k26Answer(k26Base1(), k26Item(k26Right, []any{k26Example}, "follows", "the request example says True")),
		}
	case "assumption":
		return []map[string]any{
			k26Answer(k26Base1(), k26Item(k26Assume, []any{}, "unsupported", "the request is silent on zero")),
		}
	}
	return nil
}

func TestK26DecisionCheckObservation(t *testing.T) {
	mode := os.Getenv("KOGEN_K26_MODE")
	first := k26Right
	var steps []shpStep
	switch mode {
	case "contradict":
		first = k26Wrong
		steps = []shpStep{shpSubmit("c1", k26Files(k26Wrong)), shpSubmit("c2", k26Files(k26Right))}
	case "unsupported":
		steps = []shpStep{shpSubmit("c1", k26Files(k26Right)), shpSubmit("c2", k26Files(k26Right))}
	case "assumption", "off":
		first = k26Assume
		steps = []shpStep{shpSubmit("c1", k26Files(k26Assume))}
	}
	f := newShpFx(t, steps...)
	f.write("features/steps/calc_steps.js", "const { Given } = require('@cucumber/cucumber');\nGiven('a calculator', function () {});\n")
	switch mode {
	case "off":
	case "badkey":
		f.write(".kogen/project.yaml", f.read(".kogen/project.yaml")+"shape_decision_check:\n  enabled: true\n  extra: 1\n")
	default:
		f.write(".kogen/project.yaml", f.read(".kogen/project.yaml")+"shape_decision_check:\n  enabled: true\n")
	}
	f.git("add", "-A")
	f.git("commit", "-qm", "valid calc steps and config")
	f.setReport("PASSED", 0)
	script := k26Script(mode)
	calls := 0
	f.Prov.route = func(req map[string]any) *shpStep {
		if names := shpToolNames(req); len(names) == 1 && names[0] == k26Tool {
			n := calls
			calls++
			if n >= len(script) {
				n = len(script) - 1
			}
			st := shpAnswer(shpCall("check-1", k26Tool, script[n]))
			return &st
		}
		return nil
	}
	tools := verify.Tools{Node: os.Getenv("KOGEN_NODE"), Quint: os.Getenv("KOGEN_QUINT"), Cucumber: os.Getenv("KOGEN_CUCUMBER")}
	in := ShapeInput{Project: f.Root, Slug: shpSlug, Request: k26Request, Client: f.Client, Tools: tools}
	f.newSession()
	exit, err := Shape(context.Background(), f.S, in)
	shapeStdout := f.Stdout.String()

	out := map[string]any{"mode": mode, "exit": exit, "error_text": "", "published": f.exists(".kogen/intents/is-even/intent.md"),
		"feedback": "", "stdout": shapeStdout, "intent": "", "checks": []any{}, "selfchecks": 0, "check_before_selfcheck": true,
		"card": "", "card_exit": -1}
	if err != nil {
		text := err.Error()
		if e, ok := sys.AsError(err); ok {
			text += "\n" + strings.Join(e.Lines, "\n")
		}
		out["error_text"] = text
	}
	if out["published"] == true {
		out["intent"] = f.read(".kogen/intents/is-even/intent.md")
		f.newSession()
		cardExit, cardErr := Approve(context.Background(), f.S, ApproveInput{Project: f.Root, Slug: shpSlug, Tools: tools})
		out["card_exit"], out["card"] = cardExit, f.Stdout.String()
		if cardErr != nil {
			out["card"] = out["card"].(string) + "\nERROR: " + cardErr.Error()
		}
	}
	reqs := f.Prov.requests()
	var shaper []map[string]any
	checkCount, checkIdx, shaperIdx := 0, -1, -1
	var check map[string]any
	out["shaper_tools_have_check"], out["shaper_mentions_check"] = false, false
	for i, r := range reqs {
		if names := shpToolNames(r); len(names) == 1 && names[0] == k26Tool {
			checkCount++
			if checkIdx < 0 {
				checkIdx, check = i, r
			}
			continue
		}
		if shaperIdx < 0 {
			shaperIdx = i
		}
		if slices.Contains(shpToolNames(r), k26Tool) {
			out["shaper_tools_have_check"] = true
		}
		if strings.Contains(shpBody(r), "Decision check") {
			out["shaper_mentions_check"] = true
		}
		shaper = append(shaper, r)
	}
	out["requests"], out["check_requests"] = len(reqs), checkCount
	out["check_after_shaper"] = checkIdx > shaperIdx && shaperIdx >= 0
	out["check_input_ok"], out["check_leak"] = false, false
	if check != nil {
		body := shpBody(check)
		out["check_input_ok"] = strings.Contains(body, k26Request) && strings.Contains(body, "Slug: is-even") && strings.Contains(body, first)
		out["check_leak"] = strings.Contains(body, "Context navigation") || strings.Contains(body, "A tiny calculator")
	}
	if len(shaper) > 1 {
		out["feedback"] = shpOutputs(shaper[1])["c1"]
	}
	if f.exists(".kogen/local/shaping/is-even/events.ndjson") {
		events := f.events()
		var checks []any
		firstCheck, firstSelf := -1, -1
		for i, ev := range events {
			switch ev["event"] {
			case "decision_check":
				checks = append(checks, ev)
				if firstCheck < 0 {
					firstCheck = i
				}
			case "step_selfcheck":
				if firstSelf < 0 {
					firstSelf = i
				}
			}
		}
		if checks != nil {
			out["checks"] = checks
		}
		out["selfchecks"] = len(shpNamed(events, "step_selfcheck"))
		out["check_before_selfcheck"] = firstCheck < 0 || firstSelf < 0 || firstCheck < firstSelf
	}
	raw, _ := json.Marshal(out)
	if werr := os.WriteFile(os.Getenv("KOGEN_K26_OUTPUT"), raw, 0o600); werr != nil {
		t.Fatal(werr)
	}
}

package shape

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"kogen/executor"
	"kogen/verify"
)

// Observation only: it mounts as a test with go -overlay, changes no production source and
// drives the real Shape path (native scripted provider or scripted external session) with
// step files that are good or carry one defect.
const k20Header = "const assert = require('node:assert/strict');\nconst { Given, Then } = require('@cucumber/cucumber');\n"
const k20Spawn = "const { spawnSync } = require('node:child_process');\n"
const k20Given = "Given('the number {int}', function (n) { this.n = n; });\n"
const k20Even = "Then('it is even', function () { assert.equal(this.n % 2, 0); });\n"
const k20Odd = "Then('it is not even', function () { assert.equal(this.n % 2, 1); });\n"

func k20Steps(variant string) string {
	switch variant {
	case "syntax":
		return k20Header + "Given('the number {int}', function (n) {\n" + k20Even + k20Odd
	case "require":
		return "require('./is_even_missing_helper');\n" + k20Header + k20Given + k20Even + k20Odd
	case "undefined":
		return k20Header + k20Given + k20Even
	case "ambiguous":
		return k20Header + k20Given + k20Even + k20Even + k20Odd
	case "unused":
		return k20Header + k20Given + k20Even + k20Odd + "Then('it is prime', function () {});\n"
	case "gorun":
		return k20Header + k20Spawn + k20Given +
			"Then('it is even', function () { const r = spawnSync('sh', ['-c', 'go run ./cmd/evencheck 4']); assert.equal(r.status, 2); });\n" + k20Odd
	case "built":
		return k20Header + k20Spawn + k20Given +
			"Then('it is even', function () { const b = spawnSync('go', ['build', '-o', '/tmp/evencheck', './cmd/evencheck']); assert.equal(b.status, 0); const r = spawnSync('/tmp/evencheck', ['4']); assert.equal(r.status, 2); });\n" + k20Odd
	}
	return k20Header + k20Given + k20Even + k20Odd
}

func k20Files(variant string) map[string]any {
	bad := "exit 1"
	if variant == "observer" {
		bad = "true"
	}
	evidence := `- evidence: {"id":"even-observer","kind":"observer","inputs":["features/steps/is_even_steps.js"],"observers":["features/steps/is_even_steps.js"],"checks":[{"name":"good","command":"true","exit":0,"output":""},{"name":"bad","command":"` + bad + `","exit":1,"output":""}]}` + "\n"
	intent := strings.Replace(shpIntentMD, "## Feasibility\n- none\n", "## Feasibility\n"+evidence, 1)
	return map[string]any{"files": []any{
		map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": intent},
		map[string]any{"path": ".kogen/intents/is-even/acceptance.feature", "content": shpFeature},
		map[string]any{"path": "features/steps/is_even_steps.js", "content": k20Steps(variant)},
	}}
}

func TestK20StepSelfcheckObservation(t *testing.T) {
	mode := os.Getenv("KOGEN_K20_MODE")
	native := strings.HasPrefix(mode, "native-")
	variant := strings.TrimPrefix(mode, "native-")
	single := variant == "ok" || variant == "built"
	first, good := k20Files(variant), k20Files("ok")
	var steps []shpStep
	if native {
		steps = append(steps, shpSubmit("c1", first))
		if !single {
			steps = append(steps, shpSubmit("c2", good))
		}
	}
	f := newShpFx(t, steps...)
	f.write("features/steps/calc_steps.js", "const { Given } = require('@cucumber/cucumber');\nGiven('a calculator', function () {});\n")
	f.git("add", "-A")
	f.git("commit", "-qm", "valid calc steps")
	f.setReport("PASSED", 0)
	in := ShapeInput{Project: f.Root, Slug: shpSlug, Request: "Add calc.is_even(n).", Client: f.Client,
		Tools: verify.Tools{Node: os.Getenv("KOGEN_NODE"), Quint: os.Getenv("KOGEN_QUINT"), Cucumber: os.Getenv("KOGEN_CUCUMBER")}}
	x := &shapeExec{t: t}
	if !native {
		x.rounds = []func(int, string) (executor.RoundResult, error){result(first)}
		if !single {
			x.rounds = append(x.rounds, result(good))
		}
		f.useExternalShape(6)
		in.External = x.external()
	}
	f.newSession()
	exit, err := Shape(context.Background(), f.S, in)
	out := map[string]any{"mode": mode, "exit": exit, "error_text": "", "published": f.exists(".kogen/intents/is-even/intent.md"),
		"rounds": 0, "feedback": "", "selfchecks": []any{}}
	if err != nil {
		out["error_text"] = err.Error()
	}
	if native {
		reqs := f.Prov.requests()
		out["rounds"] = len(reqs)
		if len(reqs) > 1 {
			out["feedback"] = shpOutputs(reqs[1])["c1"]
		}
	} else {
		out["rounds"] = len(x.inputs)
		if len(x.inputs) > 1 {
			out["feedback"] = x.inputs[1].Feedback
		}
	}
	if f.exists(".kogen/local/shaping/is-even/events.ndjson") {
		var checks []any
		for _, ev := range shpNamed(f.events(), "step_selfcheck") {
			checks = append(checks, ev)
		}
		if checks != nil {
			out["selfchecks"] = checks
		}
	}
	raw, _ := json.Marshal(out)
	if werr := os.WriteFile(os.Getenv("KOGEN_K20_OUTPUT"), raw, 0o600); werr != nil {
		t.Fatal(werr)
	}
}

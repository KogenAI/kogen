package shape

import (
	"strings"
	"testing"
)

// K-UNUSEDSTEP-WARN in Shape: an unused step definition warns and never refuses publication;
// undefined and ambiguous steps, files that do not load and exit-code wrappers still refuse
// with the feedback they always had. These run the real Shape entry point with the scripted
// provider, the real Node and Cucumber, and no corrective second submission where the package
// must publish at once.

const (
	uswStepFile   = "features/steps/is_even_steps.js"
	uswReusedFile = "features/steps/shared_steps.js"
	uswHeader     = "const assert = require('node:assert/strict');\nconst { Given, Then } = require('@cucumber/cucumber');\n"
	uswGiven      = "Given('the number {int}', function (n) { this.n = n; });\n"
	uswEven       = "Then('it is even', function () { assert.equal(this.n % 2, 0); });\n"
	uswOdd        = "Then('it is not even', function () { assert.equal(this.n % 2, 1); });\n"
	uswDead       = "Then('it is prime', function () {});\n"
)

func uswPackage(steps string) map[string]any {
	return map[string]any{"files": []any{
		map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": shpIntentMD},
		map[string]any{"path": ".kogen/intents/is-even/acceptance.feature", "content": shpFeature},
		map[string]any{"path": uswStepFile, "content": steps},
	}}
}

// uswFx is a project whose existing step file loads, with an acceptance runner that passes.
func uswFx(t *testing.T, steps ...shpStep) *shpFx {
	t.Helper()
	f := newShpFx(t, steps...)
	f.write("features/steps/calc_steps.js", "const { Given } = require('@cucumber/cucumber');\nGiven('a calculator', function () {});\n")
	f.git("add", "-A")
	f.git("commit", "-qm", "valid calc steps")
	f.setReport("PASSED", 0)
	return f
}

func (f *shpFx) uswWarningLine(pattern, file string) string {
	return "warning: step definition " + pattern + " in " + file + ": unused definition"
}

func uswSelfchecks(f *shpFx) []map[string]any { return shpNamed(f.events(), "step_selfcheck") }

func uswWarnings(t *testing.T, ev map[string]any) []map[string]any {
	t.Helper()
	list, _ := ev["warnings"].([]any)
	var out []map[string]any
	for _, w := range list {
		m, ok := w.(map[string]any)
		if !ok {
			t.Fatalf("warning %v", w)
		}
		out = append(out, m)
	}
	return out
}

func TestUnusedStepWarnShape(t *testing.T) {
	parallel(t)
	steps := uswHeader + uswGiven + uswEven + uswOdd + uswDead
	f := uswFx(t, shpSubmit("c1", uswPackage(steps)))
	exit, err := f.shape("Add calc.is_even(n).")
	if err != nil || exit != 0 {
		t.Fatalf("an unused-only package must publish: exit %d, err %v\nstdout: %s\nstderr: %s", exit, err, f.Stdout, f.Stderr)
	}
	// Published once, from one submission, with the unused definition untouched.
	shpEq(t, "requests (no corrective second submission)", len(f.Prov.requests()), 1)
	shpEq(t, "published step file", f.read(uswStepFile), steps)
	if !f.exists(".kogen/intents/is-even/intent.md") || !f.exists(".kogen/local/readiness/is-even.json") {
		t.Fatal("the package and its readiness evidence are published")
	}
	// The result names the definition pattern and its file.
	shpContains(t, "the result", f.Stdout.String(), f.uswWarningLine("it is prime", uswStepFile))
	shpContains(t, "the result", f.Stdout.String(), "Next: kogen intent approve is-even")
	// The run log keeps one self-check, ok, with the same warning, and the readiness warning.
	checks := uswSelfchecks(f)
	shpEq(t, "step_selfcheck events", len(checks), 1)
	shpEq(t, "self-check ok", checks[0]["ok"], any(true))
	ws := uswWarnings(t, checks[0])
	if len(ws) != 1 || ws[0]["pattern"] != "it is prime" || ws[0]["file"] != uswStepFile || ws[0]["detail"] != "unused definition" {
		t.Fatalf("self-check warnings %v", ws)
	}
	ready := shpNamed(f.events(), "step_warning")
	if len(ready) != 1 || ready[0]["source"] != "readiness" || ready[0]["pattern"] != "it is prime" || ready[0]["file"] != uswStepFile {
		t.Fatalf("readiness warning events %v", ready)
	}
	// The retained readiness evidence keeps it too.
	shpContains(t, "readiness evidence", f.read(".kogen/local/readiness/is-even.json"), `"pattern":"it is prime"`)
}

func TestUnusedStepWarnReused(t *testing.T) {
	parallel(t)
	shared := uswHeader + uswGiven + uswDead
	f := uswFx(t, shpSubmit("c1", map[string]any{"files": []any{
		map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": strings.Replace(shpIntentMD,
			"- features/steps/is_even_steps.js\n", "- "+uswReusedFile+"\n- "+uswStepFile+"\n", 1)},
		map[string]any{"path": ".kogen/intents/is-even/acceptance.feature", "content": shpFeature},
		map[string]any{"path": uswStepFile, "content": uswHeader + uswEven + uswOdd},
	}}))
	// A reused file: one definition serves the feature, the other is dead.
	f.write(uswReusedFile, shared)
	f.git("add", "-A")
	f.git("commit", "-qm", "reused steps")
	exit, err := f.shape("Add calc.is_even(n).")
	if err != nil || exit != 0 {
		t.Fatalf("a reused file's unused definition must not block publication: exit %d, err %v\nstdout: %s\nstderr: %s", exit, err, f.Stdout, f.Stderr)
	}
	shpEq(t, "requests", len(f.Prov.requests()), 1)
	shpEq(t, "reused file is unchanged", f.read(uswReusedFile), shared)
	shpContains(t, "the result", f.Stdout.String(), f.uswWarningLine("it is prime", uswReusedFile))
	shpContains(t, "the result", f.Stdout.String(), uswReusedFile+" (unchanged)")
	checks := uswSelfchecks(f)
	shpEq(t, "step_selfcheck events", len(checks), 1)
	shpEq(t, "self-check ok", checks[0]["ok"], any(true))
	ws := uswWarnings(t, checks[0])
	if len(ws) != 1 || ws[0]["pattern"] != "it is prime" || ws[0]["file"] != uswReusedFile {
		t.Fatalf("self-check warnings %v", ws)
	}
	if got := strings.Count(f.Stdout.String(), "warning: step definition"); got != 1 {
		t.Fatalf("the result carries %d warnings, want 1:\n%s", got, f.Stdout)
	}
}

func TestUnusedStepWarnShapeRefusals(t *testing.T) {
	parallel(t)
	wrapper := uswHeader + "const { spawnSync } = require('node:child_process');\n" + uswGiven +
		"Then('it is even', function () { const r = spawnSync('sh', ['-c', 'go run ./cmd/evencheck 4']); assert.equal(r.status, 2); });\n" + uswOdd
	cases := []struct{ name, steps, line string }{
		{"undefined step", uswHeader + uswGiven + uswEven, "- steps it is not even: undefined step"},
		{"ambiguous step", uswHeader + uswGiven + uswEven + uswEven + uswOdd, "- steps it is even: ambiguous step (2 definitions)"},
		{"file that does not load", "throw new Error('boom at load');\n" + uswHeader + uswGiven + uswEven + uswOdd, "- load " + uswStepFile + ": Error: boom at load"},
		{"exit-code wrapper", wrapper, "- exit_code " + uswStepFile + ": step definition it is even asserts an exit code but obtains it through go run, " +
			"which changes exit codes; build the binary (go build) and run it instead"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			parallel(t)
			// The defect comes with an unused definition, which must neither hide it nor change
			// its feedback; the corrected package then publishes.
			f := uswFx(t, shpSubmit("c1", uswPackage(c.steps+uswDead)), shpSubmit("c2", shpFiles()))
			exit, err := f.shape("Add calc.is_even(n).")
			if err != nil || exit != 0 {
				t.Fatalf("exit %d, err %v\nstderr: %s", exit, err, f.Stderr)
			}
			reqs := f.Prov.requests()
			shpEq(t, "requests", len(reqs), 2)
			shpEq(t, "feedback", shpOutputs(reqs[1])["c1"], selfcheckHeadline+"\n"+c.line)
			checks := uswSelfchecks(f)
			shpEq(t, "step_selfcheck events", len(checks), 2)
			shpEq(t, "first self-check ok", checks[0]["ok"], any(false))
			shpEq(t, "second self-check ok", checks[1]["ok"], any(true))
			if w := uswWarnings(t, checks[1]); len(w) != 0 {
				t.Fatalf("the corrected package has warnings %v", w)
			}
			shpEq(t, "published step file", f.read(uswStepFile), shpSteps)
			if strings.Contains(f.Stdout.String(), "warning: step definition") {
				t.Fatalf("the corrected package published with a warning:\n%s", f.Stdout)
			}
		})
	}
}

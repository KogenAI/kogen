package build

import (
	"encoding/json"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"

	"kogen/project"
	"kogen/verify"
)

// namedFeedbackSteps is an acceptance helper of the kind the feedback is about: it requires a
// named Go test to have run exactly once and pass, and asserts without the test's own name.
const namedFeedbackSteps = `const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { Then } = require('@cucumber/cucumber');

Then('the required test {string} runs exactly once and passes in {string}', function (name, pkg) {
  const r = spawnSync('go', ['test', '-json', '-count=1', pkg, '-run', '^' + name + '$'], { encoding: 'utf8', cwd: process.cwd() });
  const rows = (r.stdout || '').split('\n').filter(s => s.startsWith('{')).map(s => JSON.parse(s));
  const runs = rows.filter(x => x.Test === name && x.Action === 'run').length;
  const ends = rows.filter(x => x.Test === name && x.Action === 'pass').length;
  assert.ok(runs === 1 && ends === 1, 'a required test did not run\n' + r.stdout);
});
`

const namedFeedbackFeature = `Feature: Named tests
  Scenario: The widget behaves
    Then the required test "TestWidgetBehaves" runs exactly once and passes in "./widget"
`

// realBuildTools are the repository's own Node and Cucumber, or a skip when npm ci has not
// installed them.
func realBuildTools(t *testing.T) verify.Tools {
	t.Helper()
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node is not available")
	}
	_, file, _, _ := runtime.Caller(0)
	root := filepath.Join(filepath.Dir(file), "..", "..")
	tools := verify.Tools{Node: node, Cucumber: filepath.Join(root, "test/acceptance/node_modules")}
	if _, err := os.Stat(filepath.Join(tools.Cucumber, "@cucumber/cucumber/bin/cucumber.js")); err != nil {
		t.Skip("run npm ci in test/acceptance for the real Cucumber")
	}
	return tools
}

func goCache(t *testing.T) string {
	t.Helper()
	out, err := exec.Command("go", "env", "GOCACHE").Output()
	if err != nil {
		t.Skip("go is not available")
	}
	return strings.TrimSpace(string(out))
}

// namedFeedbackEnv is a project whose acceptance is the real Cucumber over namedFeedbackFeature
// and namedFeedbackSteps, in a Go module.
func namedFeedbackEnv(t *testing.T) (*env, verify.Tools) {
	t.Helper()
	tools := realBuildTools(t)
	cache := goCache(t)
	e := newEnv(t, func(c *project.Config) {
		c.Acceptance = &project.Acceptance{
			Run: `GOCACHE=` + cache + ` GOTOOLCHAIN=local GOWORK=off NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" ` +
				`--strict --require 'features/steps/*.js' --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"`,
			StepsDir: "features/steps",
		}
	})
	e.write("go.mod", "module nfwidget\n\ngo 1.21\n")
	e.write("widget/widget.go", "package widget\n\nfunc Name() string { return \"widget\" }\n")
	e.run("git", "add", "go.mod", "widget/widget.go")
	e.run("git", "commit", "-qm", "go module")
	e.write(project.FeaturePath(testSlug), namedFeedbackFeature)
	e.write(stepsFile, namedFeedbackSteps)
	e.approve()
	return e, tools
}

func TestNamedFeedbackBuilderRepair(t *testing.T) {
	t.Parallel()
	e, tools := namedFeedbackEnv(t)
	wrong := "package widget\n\nimport \"testing\"\n\nfunc TestWidgetBehaviour(t *testing.T) {\n\tif Name() != \"widget\" {\n\t\tt.Fatal(Name())\n\t}\n}\n"
	missing := regexp.MustCompile(`\n\s+(Test\w+): did not run`)
	e.prov.then(
		e.prov.calls("write_file", map[string]any{"path": "widget/widget_test.go", "content": wrong}, "finish", map[string]any{"summary": "first"}),
		// The correction is chosen from the feedback the first round received.
		func(w http.ResponseWriter, r *http.Request) {
			reqs := e.prov.requests()
			var feedback string
			for _, o := range toolOutputsOf(reqs[len(reqs)-1]) {
				if strings.HasPrefix(o, "Verification pass 1 is not green.") {
					feedback = o
				}
			}
			m := missing.FindStringSubmatch(feedback)
			if m == nil {
				t.Errorf("the feedback names no missing test:\n%s", feedback)
				refused()(w, r)
				return
			}
			fixed := strings.Replace(wrong, "TestWidgetBehaviour", m[1], 1)
			e.prov.calls("write_file", map[string]any{"path": "widget/widget_test.go", "content": fixed}, "finish", map[string]any{"summary": "second"})(w, r)
		},
	)
	a := e.build(func(in *Input) { in.Deps.Tools = tools })
	if a.exit != 0 || a.err != nil {
		t.Fatalf("exit %d err %v\n%s", a.exit, a.err, a.shown())
	}
	res := e.result(e.onlyRun())
	eq(t, "passes", res["passes"], any(float64(2)))
	eq(t, "repairs", res["repairs"], any(float64(1)))
	var feedback string
	for _, o := range e.prov.toolOutputs() {
		if strings.HasPrefix(o, "Verification pass 1 is not green.") {
			feedback = o
		}
	}
	for _, part := range []string{
		"required tests that did not run",
		"TestWidgetBehaves: did not run (no tests to run)",
		"acceptance ran them in: ./widget; package nfwidget/widget",
		"step definition: " + stepsFile + " line 5",
	} {
		contains(t, "feedback", feedback, part)
	}
	if got := e.read("widget/widget_test.go"); !strings.Contains(got, "func TestWidgetBehaves(") {
		t.Fatalf("the repaired test:\n%s", got)
	}
	eq(t, "landed test", strings.Contains(e.gitOut("show", "HEAD:widget/widget_test.go"), "TestWidgetBehaves"), true)
}

func toolOutputsOf(req map[string]any) []string {
	var out []string
	items, _ := req["input"].([]any)
	for _, it := range items {
		if m, _ := it.(map[string]any); m["type"] == "function_call_output" {
			out = append(out, m["output"].(string))
		}
	}
	return out
}

// compatCapture is the first rendered request of a passing Build and the feedback of a red
// pass with an ordinary assertion failure, with this run's paths and cache identity replaced.
func compatCapture(t *testing.T) (map[string]any, string) {
	t.Helper()
	pass := newEnv(t)
	pass.prov.then(landScript(pass.prov)...)
	if a := pass.build(); a.exit != 0 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	red := newEnv(t)
	red.prov.then(
		red.prov.calls("write_file", map[string]any{"path": "app.txt", "content": "red\n"}, "finish", map[string]any{"summary": "first"}),
		red.prov.calls("write_file", map[string]any{"path": "app.txt", "content": "green\n"}, "finish", map[string]any{"summary": "second"}),
	)
	if a := red.build(); a.exit != 0 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	eq(t, "red build passes", red.result(red.onlyRun())["passes"], any(float64(2)))
	var feedback string
	for _, o := range red.prov.toolOutputs() {
		if strings.HasPrefix(o, "Verification pass 1 is not green.") {
			feedback = o
		}
	}
	req := pass.prov.requests()[0]
	delete(req, "prompt_cache_key")
	raw, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	text := strings.NewReplacer(pass.aux, "<aux>", pass.root, "<root>").Replace(string(raw))
	var normalized map[string]any
	if err := json.Unmarshal([]byte(text), &normalized); err != nil {
		t.Fatal(err)
	}
	return normalized, strings.ReplaceAll(feedback, red.aux, "<aux>")
}

func TestNamedFeedbackCompatibility(t *testing.T) {
	t.Parallel()
	// Ordinary assertion feedback and the requests of a passing Build are exactly what they
	// were before named-test feedback existed: testdata/named-feedback-compat.json holds them.
	request, feedback := compatCapture(t)
	raw, err := os.ReadFile("testdata/named-feedback-compat.json")
	if err != nil {
		t.Fatal(err)
	}
	var want struct {
		Feedback string         `json:"feedback"`
		Request  map[string]any `json:"request"`
	}
	if err := json.Unmarshal(raw, &want); err != nil {
		t.Fatal(err)
	}
	eq(t, "ordinary assertion feedback", feedback, want.Feedback)
	got, _ := json.Marshal(request)
	exp, _ := json.Marshal(want.Request)
	if string(got) != string(exp) {
		t.Fatalf("the passing Build's first request changed:\n got %s\nwant %s", got, exp)
	}

	// Verdicts are unchanged: a wrongly named test keeps the pass red until the right one
	// exists, and only the red pass's feedback carries the names.
	e, tools := namedFeedbackEnv(t)
	test := func(name string) string {
		return "package widget\n\nimport \"testing\"\n\nfunc " + name + "(t *testing.T) {}\n"
	}
	e.prov.then(
		e.prov.calls("write_file", map[string]any{"path": "widget/widget_test.go", "content": test("TestElsewhere")}, "finish", map[string]any{"summary": "wrong name"}),
		e.prov.calls("write_file", map[string]any{"path": "widget/widget_test.go", "content": test("TestWidgetBehaves")}, "finish", map[string]any{"summary": "right"}),
	)
	a := e.build(func(in *Input) { in.Deps.Tools = tools })
	eq(t, "named-test build exit", a.exit, 0)
	res := e.result(e.onlyRun())
	eq(t, "named-test build passes", res["passes"], any(float64(2)))
	for _, o := range e.prov.toolOutputs() {
		if !strings.HasPrefix(o, "Verification pass 1 is not green.") {
			lacks(t, "a tool output", o, "required tests that did not run")
		}
	}
}

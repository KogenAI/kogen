package verify

import (
	"context"
	"path/filepath"
	"strings"
	"testing"

	"kogen/project"
)

// namedSteps are acceptance helpers of the kind that require named Go tests to have run:
// one asserts generically ("0 !== 1"), one shows the go test -json rows in its failure, and
// one echoes the command with its -run selector without naming the tests in the step.
const namedSteps = `const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { Then } = require('@cucumber/cucumber');

function rows(args) {
  const r = spawnSync('go', ['test', '-json', '-count=1', ...args], { encoding: 'utf8' });
  const all = (r.stdout || '').split('\n').filter(s => s.startsWith('{')).map(s => JSON.parse(s));
  return { r, all };
}
function ran(all, name) { return all.filter(x => x.Test === name && x.Action === 'run').length; }
function passed(all, name) { return all.filter(x => x.Test === name && x.Action === 'pass').length; }

Then('the generic helper requires {string} in {string}', function (name, pkg) {
  const { all } = rows([pkg, '-run', '^' + name + '$']);
  assert.strictEqual(ran(all, name), 1);
});

Then('the verbose helper requires {string} in {string}', function (name, pkg) {
  const { r, all } = rows([pkg, '-run', '^' + name + '$']);
  assert.ok(ran(all, name) === 1 && passed(all, name) === 1, 'required test must pass\n' + r.stdout);
});

Then('the verbose helper requires {string} and {string} in {string}', function (a, b, pkg) {
  const { r, all } = rows([pkg, '-run', '^(' + a + '|' + b + ')$']);
  assert.ok([a, b].every(n => ran(all, n) === 1 && passed(all, n) === 1), 'required tests must pass\n' + r.stdout);
});

Then('the selector helper checks the alpha suite', function () {
  const { r, all } = rows(['./pkga', '-run', '^(TestAlphaOne|TestAlphaTwo)$']);
  assert.ok(ran(all, 'TestAlphaOne') === 1 && ran(all, 'TestAlphaTwo') === 1,
    'go test -json -count=1 ./pkga -run ^(TestAlphaOne|TestAlphaTwo)$ is incomplete\n' + r.stdout);
});

Then('an unrelated check fails', function () {
  assert.fail('unrelated failure');
});

Then('the heading reads {string}', function (heading) {
  assert.strictEqual('Welcome', heading);
});
`

const namedFeature = `Feature: Named tests
  Scenario: Wrong name behind a generic assertion
    Then the generic helper requires "TestWanted" in "./pkga"
  Scenario: Wrong name with go test output
    Then the verbose helper requires "TestWantedVerbose" in "./pkga"
  Scenario: Skipped
    Then the verbose helper requires "TestSkipped" in "./pkga"
  Scenario: Package without tests
    Then the generic helper requires "TestNowhere" in "./pkgb"
  Scenario: One of two required tests is missing
    Then the verbose helper requires "TestPresent" and "TestMissingSecond" in "./pkga"
  Scenario: The test ran and failed
    Then the verbose helper requires "TestFails" in "./pkga"
  Scenario: Selector only
    Then the selector helper checks the alpha suite
  Scenario: Not about tests
    Then an unrelated check fails
  Scenario: A test-like argument without a test run
    Then the heading reads "Example"
`

const namedPkgA = `package pkga

import "testing"

func TestPresent(t *testing.T) {}
func TestOther(t *testing.T)   {}
func TestSkipped(t *testing.T) { t.Skip("not today") }
func TestFails(t *testing.T)   { t.Fatal("boom") }
func TestAlphaOne(t *testing.T) {}
`

func TestNamedFeedbackMissingTests(t *testing.T) {
	isolateTmp(t)
	tools := realTools(t)
	p := newProj(t)
	feature := project.FeaturePath(fixtureSlug)
	p.write("go.mod", "module nf\n\ngo 1.21\n")
	p.write("pkga/a_test.go", namedPkgA)
	p.write("pkgb/b.go", "package pkgb\n")
	p.write("features/steps/fixture_steps.js", namedSteps)
	p.write(feature, namedFeature)
	p.commit("named steps")
	expected, err := project.ParseGherkin(namedFeature)
	if err != nil {
		t.Fatal(err)
	}
	runner := cucumberRun("features/steps")
	p.Config.Acceptance = &project.Acceptance{Run: runner, StepsDir: "features/steps"}
	s, _ := p.session()
	s.Env = append(p.Env, "GOWORK=off", "GOFLAGS=")
	got, err := RunAcceptance(context.Background(), s, p.Root, tools, fixtureSlug, runner, filepath.Join(p.Aux, "messages.ndjson"), nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Problems) != len(expected) {
		t.Fatalf("problems = %d, want %d:\n%s", len(got.Problems), len(expected), strings.Join(got.Problems, "\n--\n"))
	}
	definition := func(prefix string) string {
		for i, l := range strings.Split(namedSteps, "\n") {
			if strings.HasPrefix(l, "Then('"+prefix) {
				return "step definition: features/steps/fixture_steps.js line " + itoa(i+1)
			}
		}
		t.Fatalf("no step definition %q", prefix)
		return ""
	}
	problem := func(scenario string) string {
		for _, pr := range got.Problems {
			if strings.Contains(pr, "failed: "+scenario+" (line") {
				return pr
			}
		}
		t.Fatalf("no problem for %q in:\n%s", scenario, strings.Join(got.Problems, "\n--\n"))
		return ""
	}
	const heading = "required tests that did not run"

	generic := problem("Wrong name behind a generic assertion")
	contains(t, "generic", generic, heading)
	contains(t, "generic", generic, "TestWanted: did not run")
	contains(t, "generic", generic, "acceptance ran them in: ./pkga")
	contains(t, "generic", generic, definition("the generic helper requires {string} in"))
	contains(t, "generic", generic, "0 !== 1")

	verbose := problem("Wrong name with go test output")
	contains(t, "verbose", verbose, "TestWantedVerbose: did not run (no tests to run)")
	contains(t, "verbose", verbose, "acceptance ran them in: ./pkga; package nf/pkga")
	contains(t, "verbose", verbose, "package nf/pkga")
	contains(t, "verbose", verbose, definition("the verbose helper requires {string} in {string}"))

	skipped := problem("Skipped")
	contains(t, "skipped", skipped, "TestSkipped: skipped")
	contains(t, "skipped", skipped, "package nf/pkga")

	nowhere := problem("Package without tests")
	contains(t, "no test files", nowhere, "TestNowhere: did not run")
	contains(t, "no test files", nowhere, "acceptance ran them in: ./pkgb")
	contains(t, "no test files", nowhere, definition("the generic helper requires {string} in"))

	two := problem("One of two required tests is missing")
	contains(t, "two ids", two, "TestMissingSecond: did not run")
	lacks(t, "two ids", two, "TestPresent: ")
	contains(t, "two ids", two, definition("the verbose helper requires {string} and {string} in"))

	selector := problem("Selector only")
	contains(t, "selector", selector, "TestAlphaTwo: did not run")
	lacks(t, "selector", selector, "TestAlphaOne: ")
	contains(t, "selector", selector, "acceptance ran them in: go test -json -count=1 ./pkga -run ^(TestAlphaOne|TestAlphaTwo)$")
	contains(t, "selector", selector, definition("the selector helper"))

	// A test that ran and failed, and a step about something else, keep their ordinary
	// feedback exactly: the detail of the failed step and nothing more.
	for _, scenario := range []string{"The test ran and failed", "Not about tests", "A test-like argument without a test run"} {
		pr := problem(scenario)
		lacks(t, scenario, pr, heading)
		lacks(t, scenario, pr, "step definition:")
		var detail *string
		for _, sc := range got.Scenarios {
			if sc.Name == scenario {
				detail = sc.Detail
			}
		}
		if detail == nil || !strings.HasSuffix(pr, "\n"+*detail) {
			t.Fatalf("%s: problem %q does not end with the report's detail", scenario, pr)
		}
	}

	// The enriched problems are what Pass.Feedback hands to the repair owner, with every
	// required id of every failed step.
	feedback := Pass{N: 1, Acceptance: &got}.Feedback(runner, "finish")
	for _, part := range []string{"TestWanted: ", "TestWantedVerbose: ", "TestSkipped: ", "TestNowhere: ", "TestMissingSecond: ", "TestAlphaTwo: "} {
		contains(t, "feedback", feedback, part)
	}
	if n := strings.Count(feedback, "step definition: features/steps/fixture_steps.js line "); n != 6 {
		t.Fatalf("feedback names %d step definitions, want 6:\n%s", n, feedback)
	}

	// Recorded passes keep the enrichment: it is part of the problem text.
	raw, err := Pass{N: 1, Clean: true, Tree: "t", Acceptance: &got, Model: ModelResult{State: "none"}}.MarshalJSON()
	if err != nil {
		t.Fatal(err)
	}
	var back Pass
	if err := back.UnmarshalJSON(raw); err != nil {
		t.Fatal(err)
	}
	eq(t, "feedback after a record round trip", back.Feedback(runner, "finish"), feedback)
}

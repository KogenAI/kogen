package verify

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"

	"kogen/project"
)

// K-UNUSEDSTEP-WARN in readiness: the Intent's own step files are loaded with the real Cucumber
// and an unused definition is a warning kept with the evidence; undefined and ambiguous steps,
// files that do not load and exit-code wrappers still refuse.

const (
	warnStepFile   = "features/steps/fixture_steps.js"
	warnReusedFile = "features/steps/shared_steps.js"
	warnDeadStep   = "Then('never used {int}', () => {});\n"
)

// warnProject is realProject for tests that need only the real Cucumber: Quint plays no part
// in what these tests establish, so it must not decide whether they run.
func warnProject(t *testing.T) (*proj, Tools) {
	t.Helper()
	cucumber := os.Getenv("KOGEN_CUCUMBER")
	if !isRegular(filepath.Join(cucumber, "@cucumber/cucumber/bin/cucumber.js")) {
		// Relative to the package folder, which go test runs in (a module-relative caller path
		// under -trimpath cannot locate the repository).
		abs, err := filepath.Abs(filepath.Join("..", "..", "test", "acceptance", "node_modules"))
		if err != nil {
			t.Fatal(err)
		}
		cucumber = abs
	}
	tools := Tools{Node: findNode(t), Cucumber: cucumber}
	if !isRegular(filepath.Join(tools.Cucumber, "@cucumber/cucumber/bin/cucumber.js")) {
		t.Fatal("run npm ci in test/acceptance for the real Cucumber, or set KOGEN_CUCUMBER")
	}
	p := newProj(t)
	p.Env = append(p.Env, "CASE_TRACE="+p.trace("cases"))
	p.write(warnStepFile, realSteps)
	p.commit("real steps")
	p.Config.Acceptance = &project.Acceptance{Run: cucumberRun("features/steps"), StepsDir: "features/steps"}
	return p, tools
}

// warnReadiness checks readiness of the fixture Intent against the real Cucumber, with no
// Shape in front of it.
func warnReadiness(t *testing.T, p *proj, tools Tools) (*Ready, *memEvidence, error) {
	t.Helper()
	ev := newEvidence()
	r := &Readiness{Root: p.Root, Repo: p.Repo, Config: p.Config, Tools: tools, Evidence: ev}
	s, _ := p.session()
	s.Env = p.Env
	ready, err := r.Check(context.Background(), s, fixtureSlug)
	return ready, ev, err
}

func warningEvents(ev *memEvidence) []map[string]any {
	var out []map[string]any
	for _, e := range ev.events {
		if e["event"] == "step_warning" {
			out = append(out, e)
		}
	}
	return out
}

func TestUnusedStepWarnReadiness(t *testing.T) {
	dead := StepWarning{Pattern: "never used {int}", File: warnStepFile, Detail: UnusedDefinition}
	for _, c := range []struct {
		name, candidate string
	}{{"green", "green\n"}, {"legitimate red", "red\n"}} {
		t.Run("own step file, "+c.name, func(t *testing.T) {
			tmp := isolateTmp(t)
			p, tools := warnProject(t)
			p.write(warnStepFile, realSteps+warnDeadStep)
			p.write("app.txt", c.candidate)
			ready, ev, err := warnReadiness(t, p, tools)
			if err != nil {
				t.Fatalf("an unused-only candidate must be ready: %v", err)
			}
			eq(t, "failures", ready.Failures(), c.candidate == "red\n")
			if len(ready.StepWarnings) != 1 || ready.StepWarnings[0] != dead {
				t.Fatalf("warnings %+v, want %+v", ready.StepWarnings, dead)
			}
			// The run log names the definition pattern and its file.
			ws := warningEvents(ev)
			if len(ws) != 1 || ws[0]["pattern"] != dead.Pattern || ws[0]["file"] != dead.File || ws[0]["detail"] != UnusedDefinition {
				t.Fatalf("warning events %v", ws)
			}
			// The retained evidence keeps them, and a later cached check returns them.
			rec, ok := p.readinessRecord()
			if !ok {
				t.Fatal("a ready candidate keeps its evidence")
			}
			raw, _ := json.Marshal(rec["step_warnings"])
			eq(t, "recorded warnings", string(raw), `[{"detail":"unused definition","file":"`+warnStepFile+`","pattern":"never used {int}"}]`)
			s, _ := p.session()
			cached := (&Readiness{Root: p.Root, Repo: p.Repo, Config: p.Config}).Cached(s, fixtureSlug)
			if cached == nil || len(cached.StepWarnings) != 1 || cached.StepWarnings[0] != dead {
				t.Fatalf("cached readiness %+v", cached)
			}
			delete(rec, "step_warnings")
			old, _ := json.Marshal(rec)
			if err := os.WriteFile(readinessPath(p.Root, fixtureSlug), old, 0600); err != nil {
				t.Fatal(err)
			}
			if (&Readiness{Root: p.Root, Repo: p.Repo, Config: p.Config}).Cached(s, fixtureSlug) != nil {
				t.Fatal("pre-step-analysis evidence must not be reused")
			}
			requireNoLeftovers(t, tmp)
		})
	}

	t.Run("reused step file", func(t *testing.T) {
		isolateTmp(t)
		p, tools := warnProject(t)
		// The Intent reuses an existing step file: its used definition serves the feature, its
		// other one is dead. A step file the Intent does not list is not judged.
		p.write(warnStepFile, "// the Intent's own file\n")
		p.write(warnReusedFile, realSteps+warnDeadStep)
		p.write("features/steps/foreign_steps.js", "const {Then} = require('@cucumber/cucumber');\nThen('somebody else {int}', () => {});\n")
		p.write(project.IntentMDPath(fixtureSlug), strings.Replace(intentMD("not applicable — nothing to model", ""),
			"- "+warnStepFile+"\n", "- "+warnStepFile+"\n- "+warnReusedFile+"\n", 1))
		p.commit("reused steps")
		ready, ev, err := warnReadiness(t, p, tools)
		if err != nil {
			t.Fatalf("a reused file's unused definition must not refuse readiness: %v", err)
		}
		want := StepWarning{Pattern: "never used {int}", File: warnReusedFile, Detail: UnusedDefinition}
		if len(ready.StepWarnings) != 1 || ready.StepWarnings[0] != want {
			t.Fatalf("warnings %+v, want only %+v", ready.StepWarnings, want)
		}
		eq(t, "warning events", len(warningEvents(ev)), 1)
	})

	t.Run("no unused definition, no warning", func(t *testing.T) {
		isolateTmp(t)
		p, tools := warnProject(t)
		ready, ev, err := warnReadiness(t, p, tools)
		if err != nil {
			t.Fatal(err)
		}
		eq(t, "warnings", len(ready.StepWarnings), 0)
		eq(t, "warning events", len(warningEvents(ev)), 0)
		if rec, _ := p.readinessRecord(); len(rec["step_warnings"].([]any)) != 0 {
			t.Fatalf("a record without warnings retains an empty list: %v", rec["step_warnings"])
		}
	})
}

const (
	warnWrapperSteps = `const {Then} = require('@cucumber/cucumber');
const fs = require('node:fs');
const assert = require('node:assert/strict');
Then('the candidate succeeds', () => {
  fs.appendFileSync(process.env.CASE_TRACE, 'executed\n');
  const run = { cmd: 'go run ./cmd/check', status: 0 };
  assert.equal(run.status, 0);
});
`
	warnAmbiguousSteps = realSteps + "Then('the candidate succeeds', () => {});\n"
	warnBrokenSteps    = "throw new Error('boom at load');\n" + realSteps
)

var scratchName = regexp.MustCompile(`kogen-readiness-[0-9a-f]+`)

func TestUnusedStepWarnReadinessRefusals(t *testing.T) {
	undefinedFeature := fixtureFeature + "  Scenario: Third\n    Then the candidate is undefined\n"
	wrapperLine := "exit_code " + warnStepFile + ": step definition the candidate succeeds asserts an exit code but obtains it through go run, " +
		"which changes exit codes; build the binary (go build) and run it instead"
	cases := []struct {
		name, steps, feature string
		want                 func(t *testing.T, lines []string)
	}{
		{"undefined step", realSteps, undefinedFeature, func(t *testing.T, lines []string) {
			contains(t, "lines", strings.Join(lines, "\n"), "undefined step: Then the candidate is undefined")
		}},
		{"ambiguous step", warnAmbiguousSteps, fixtureFeature, func(t *testing.T, lines []string) {
			contains(t, "lines", strings.Join(lines, "\n"), "ambiguous")
		}},
		{"file that does not load", warnBrokenSteps, fixtureFeature, func(t *testing.T, lines []string) {
			contains(t, "lines", strings.Join(lines, "\n"), "boom at load")
		}},
		{"exit-code wrapper", warnWrapperSteps, fixtureFeature, func(t *testing.T, lines []string) {
			eqSlice(t, "lines", lines, []string{wrapperLine})
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			tmp := isolateTmp(t)
			refuse := func(steps string) []string {
				p, tools := warnProject(t)
				p.write(warnStepFile, steps)
				p.write(project.FeaturePath(fixtureSlug), c.feature)
				ready, _, err := warnReadiness(t, p, tools)
				if ready != nil {
					t.Fatal("the candidate must be refused")
				}
				e := failWith(t, err, "intent", "not_ready")
				eq(t, "detail", e.Detail, "the Intent is not ready to build")
				if _, ok := p.readinessRecord(); ok {
					t.Fatal("a refused check leaves no readiness record")
				}
				// The scratch folder's name differs per check, and a report lists the ambiguous
				// locations in no fixed order.
				lines := make([]string, len(e.Lines))
				for i, l := range e.Lines {
					lines[i] = scratchName.ReplaceAllString(l, "kogen-readiness-SCRATCH")
				}
				sort.Strings(lines)
				return lines
			}
			alone := refuse(c.steps)
			c.want(t, alone)
			// An unused definition beside the defect neither hides it nor changes its feedback.
			withDead := refuse(c.steps + warnDeadStep)
			eqSlice(t, "feedback with an unused definition beside it", withDead, alone)
			lacks(t, "feedback", strings.Join(withDead, "\n"), "never used")
			requireNoLeftovers(t, tmp)
		})
	}
}

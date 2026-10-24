package verify

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"

	"kogen/project"
)

// The tests here run the repository's own Cucumber 13.3.0 and Quint 0.33.0 on tiny
// fixtures (npm ci in test/acceptance and spec installs them).

const realSteps = `const {Then} = require('@cucumber/cucumber');
const fs = require('node:fs');
Then('the candidate succeeds', () => {
  fs.appendFileSync(process.env.CASE_TRACE, 'executed\n');
  if (fs.readFileSync('app.txt', 'utf8').trim() === 'red') throw new Error('actual-case-red');
});
`

const realModel = `module model {
  var n: int
  action init = n' = 0
  action step = n' = (n + 1) % 5
  val Safe = n >= 0 and n < 5
  val Broken = n < 3
  run PassTest = init.then(step).then(step).expect(n == 2)
}
`

// realProject is the fixture Intent with its own step file and the Cucumber runner Kogen's
// init writes, for a Config whose acceptance command is that runner plus flags.
func realProject(t *testing.T, flags string) (*proj, Tools) {
	t.Helper()
	tools := realTools(t)
	p := newProj(t)
	p.Env = append(p.Env, "CASE_TRACE="+p.trace("cases"))
	p.write("features/steps/fixture_steps.js", realSteps)
	p.commit("real steps")
	p.Config.Acceptance = &project.Acceptance{Run: cucumberRun("features/steps") + flags, StepsDir: "features/steps"}
	return p, tools
}

func (p *proj) cases() int { return len(p.ran("cases")) }

// ExUnit: fail_fast_verification_test.exs, real declared Cucumber fail-fast.
func TestRealDeclaredCucumberFailFastKeepsFailedAndSkippedCasesRedWhileCompleteExitZeroIsGreen(t *testing.T) {
	p, tools := realProject(t, "")
	feature := project.FeaturePath(fixtureSlug)
	expected := mustScenarios(t)
	runner := p.Config.Acceptance.Run
	for _, c := range []struct {
		candidate, flags string
		count            int
	}{{"red", " --fail-fast", 1}, {"red", "", 2}, {"green", " --fail-fast", 2}} {
		p.write("app.txt", c.candidate)
		os.WriteFile(p.trace("cases"), nil, 0o644)
		report := filepath.Join(p.Aux, "messages.ndjson")
		s, _ := p.session()
		s.Env = p.Env
		got, err := RunAcceptance(context.Background(), s, p.Root, tools, fixtureSlug, runner+c.flags, report, nil, nil)
		if err != nil {
			t.Fatal(err)
		}
		eq(t, c.candidate+c.flags+" executed cases", p.cases(), c.count)
		if c.candidate == "green" {
			eq(t, "exit", got.Status, 0)
			eqSlice(t, "problems", got.Problems, nil)
			eq(t, "passed", got.Passed, 2)
			continue
		}
		if got.Status == 0 {
			t.Fatal("a red candidate must exit nonzero")
		}
		eq(t, "first", got.Scenarios[0].Status, "failed")
		contains(t, "first problem", got.Problems[0], "actual-case-red")
		eq(t, "passed", got.Passed, 0)
		want := "skipped"
		if c.flags == "" {
			want = "failed"
		}
		eq(t, "last scenario "+c.flags, got.Scenarios[len(got.Scenarios)-1].Status, want)
		b, _ := os.ReadFile(report)
		contains(t, "report", string(b), "actual-case-red")
		_ = feature
		_ = expected
	}
}

func TestRealCucumberAndQuintPassGreenThenModelRedStopsTheChecks(t *testing.T) {
	isolateTmp(t)
	p, tools := realProject(t, " --fail-fast")
	modelPath := project.ModelPath(fixtureSlug)
	line := func(invs string) string {
		return fmt.Sprintf("%s invariants=%s seed=7 samples=40 steps=12", modelPath, invs)
	}
	p.setModel(line("Safe"), map[string]string{modelPath: realModel})
	p.commit("model")
	p.Config.Checks = []project.Check{{Name: "after", Run: appendTo(p.trace("after"), "ran")}}
	s, _ := p.session()
	s.Env = p.Env
	log, ev := &memLog{}, newEvidence()
	in := p.input(1)
	in.Tools, in.Log, in.Evidence = tools, log, ev
	pass, err := Verify(context.Background(), s, in)
	if err != nil {
		t.Fatal(err)
	}
	if !pass.Green || pass.Model.State != "ok" || pass.Acceptance.Passed != 2 {
		t.Fatalf("pass = %s", encode(generic(pass)))
	}
	eqSlice(t, "after check", p.ran("after"), []string{"ran"})
	eq(t, "quint runs: typecheck, test, one invariant", ev.counts["quint"], 3)
	var quint []string
	for _, e := range log.named("command") {
		if e["name"] == "model" {
			quint = append(quint, e["command"].(string))
		}
	}
	eqSlice(t, "quint commands", quint, []string{
		"quint typecheck " + modelPath,
		"quint test " + modelPath + " --backend typescript --match Test",
		"quint run " + modelPath + " --backend typescript --invariant Safe --seed 7 --max-samples 40 --max-steps 12",
	})

	// A violated invariant fails the model with Quint's counterexample; checks do not run.
	p.setModel(line("Safe,Broken"), map[string]string{modelPath: realModel})
	os.Remove(p.trace("after"))
	s, _ = p.session()
	s.Env = p.Env
	in.Evidence, in.Log, in.Intent = nil, nil, p.Intent
	pass, err = Verify(context.Background(), s, in)
	if err != nil {
		t.Fatal(err)
	}
	if pass.Green || !pass.Model.Failed() || len(pass.Model.Problems) != 1 {
		t.Fatalf("pass = %s", encode(generic(pass)))
	}
	contains(t, "model problem", pass.Model.Problems[0], "model.qnt: invariant Broken violated (seed 7)\n")
	contains(t, "model problem", pass.Model.Problems[0], "[violation]")
	eq(t, "acceptance still ran first", pass.Acceptance.Passed, 2)
	eqSlice(t, "failing", pass.Failing, []string{"model"})
	eqSlice(t, "not run", pass.NotRun, []string{"after"})
	eqSlice(t, "after check", p.ran("after"), nil)
	contains(t, "feedback", pass.Feedback("x", ""), "model: failed\n  model.qnt: invariant Broken violated (seed 7)")
}

func TestRealQuintTypecheckFailureIsNamedWithItsStatusAndOutput(t *testing.T) {
	tools := realTools(t)
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "model.qnt"), []byte("module model {\n  val X = 1 + true\n}\n"), 0o644)
	s := sessionFor(dir)
	got, err := CheckModel(context.Background(), s, dir, tools, &project.ModelSpec{Path: "model.qnt", Invariants: []string{"X"}, Seed: "1", Samples: "5", Steps: "5"}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !got.Failed() || len(got.Problems) != 2 {
		t.Fatalf("model = %+v", got)
	}
	if !strings.HasPrefix(got.Problems[0], "model.qnt: quint typecheck failed (status 1)\n") {
		t.Fatalf("problem = %q", got.Problems[0])
	}
	if !strings.HasPrefix(got.Problems[1], "model.qnt: quint run failed (status 1)\n") {
		t.Fatalf("problem = %q", got.Problems[1])
	}
}

func TestRealReadinessChecksTheModelWithQuintAndRecordsItsOutcome(t *testing.T) {
	isolateTmp(t)
	p, tools := realProject(t, "")
	modelPath := project.ModelPath(fixtureSlug)
	line := func(invs string) string {
		return fmt.Sprintf("%s invariants=%s seed=7 samples=40 steps=12", modelPath, invs)
	}
	p.setModel(line("Safe"), map[string]string{modelPath: realModel})
	p.commit("model")
	r := p.readiness()
	r.Tools = tools
	s, _ := p.session()
	s.Env = p.Env
	ready, err := r.Check(context.Background(), s, fixtureSlug)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "model outcome", modelOutcome(ready.Model), "passed")
	rec, _ := p.readinessRecord()
	eq(t, "recorded outcome", rec["model_outcome"].(string), "passed")
	eq(t, "recorded seed", rec["model"].(map[string]any)["seed"].(string), "7")

	p.setModel(line("Safe,Broken"), map[string]string{modelPath: realModel})
	_, err = r.Check(context.Background(), s, fixtureSlug)
	e := failWith(t, err, "intent", "not_ready")
	eq(t, "detail", e.Detail, "the Intent is not ready to build")
	contains(t, "lines", strings.Join(e.Lines, "\n"), "model.qnt: invariant Broken violated (seed 7)")
	if fileExists(readinessPath(p.Root, fixtureSlug)) {
		t.Fatal("no record for a violated invariant")
	}

	// Without Kogen's own Node and Quint the check refuses before running anything.
	r.Tools = Tools{Node: filepath.Join(p.Aux, "no-node"), Quint: tools.Quint}
	_, err = r.Check(context.Background(), s, fixtureSlug)
	e = failWith(t, err, "environment", "tool_missing")
	eq(t, "detail", e.Detail, "node is not available at "+filepath.Join(p.Aux, "no-node")+"; reinstall Kogen")
}

// ExUnit: readiness_observations_test.exs, hook locations and explicit UTF-8 truncation.
func TestRealHookLocationsAndExplicitUTF8TruncationReachTheObservations(t *testing.T) {
	isolateTmp(t)
	p, tools := realProject(t, "")
	message, _ := json.Marshal(strings.Repeat("é", 11000))
	p.write("features/steps/fixture_steps.js", realSteps+"\nconst { Before } = require('@cucumber/cucumber');\nBefore(function () { throw new Error("+string(message)+"); });\n")
	p.commit("hook")
	r := p.readiness()
	r.Tools = tools
	s, _ := p.session()
	s.Env = p.Env
	ready, err := r.Check(context.Background(), s, fixtureSlug)
	if err != nil {
		t.Fatal(err)
	}
	if !ready.Failures() {
		t.Fatal("a failing hook is accounted red")
	}
	obs := Observations(fixtureSlug, ready, "")
	if !utf8.ValidString(obs) || len(obs) > 16384 {
		t.Fatalf("observations: %d bytes, valid %v", len(obs), utf8.ValidString(obs))
	}
	contains(t, "observations", obs, "a hook at features/steps/fixture_steps.js line ")
	contains(t, "observations", obs, "bytes omitted")
	ack := Acknowledgment(fixtureSlug, ready, "")
	if !utf8.ValidString(ack) || len(ack) > 16384 {
		t.Fatalf("acknowledgment: %d bytes", len(ack))
	}
	contains(t, "acknowledgment", ack, "a hook at")
	eq(t, "the same card on a later request", Observations(fixtureSlug, r.Cached(s, fixtureSlug), ""), obs)
}

// ExUnit: release_behavior_test.exs, both generated runners with paths that hold spaces.
func TestRealBothGeneratedRunnersPreserveFeatureAndReportPathsWithSpaces(t *testing.T) {
	tools := realTools(t)
	p := newProjIn(t, "repo with space")
	p.Env = append(p.Env, "CASE_TRACE="+p.trace("cases"))
	p.write("features/steps/fixture_steps.js", realSteps)
	if err := os.Symlink(tools.Cucumber, filepath.Join(p.Root, "node_modules")); err != nil {
		t.Fatal(err)
	}
	for name, runner := range map[string]project.Runner{"project": project.ProjectRunner, "kogen": project.KogenRunner} {
		report := filepath.Join(p.Root, ".kogen/local/report "+name+".ndjson")
		s, _ := p.session()
		s.Env = p.Env
		got, err := RunAcceptance(context.Background(), s, p.Root, tools, fixtureSlug, project.AcceptanceCommand("features/steps", runner), report, nil, nil)
		if err != nil {
			t.Fatal(err)
		}
		eq(t, name+" exit", got.Status, 0)
		eqSlice(t, name+" problems", got.Problems, nil)
		eq(t, name+" passed", got.Passed, 2)
		b, err := os.ReadFile(report)
		if err != nil {
			t.Fatal(err)
		}
		contains(t, name+" report", string(b), "testCaseFinished")
	}
}

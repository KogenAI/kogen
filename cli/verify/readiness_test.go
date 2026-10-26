package verify

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"unicode/utf8"

	"kogen-loop/sys"
	"kogen/project"
)

func (p *proj) readiness() *Readiness {
	return &Readiness{Root: p.Root, Repo: p.Repo, Config: p.Config, Evidence: nil}
}

func failWith(t *testing.T, err error, class, reason string) *sys.Error {
	t.Helper()
	e, ok := sys.AsError(err)
	if !ok || e.Class != class || e.Reason != reason {
		t.Fatalf("err = %v, want %s/%s", err, class, reason)
	}
	return e
}

func (p *proj) readinessRecord() (map[string]any, bool) {
	b, err := os.ReadFile(readinessPath(p.Root, fixtureSlug))
	if err != nil {
		return nil, false
	}
	var rec map[string]any
	json.Unmarshal(b, &rec)
	return rec, true
}

func TestReadinessChecksTheCleanCandidateAndKeepsCompleteEvidence(t *testing.T) {
	tmp := isolateTmp(t)
	p := newProj(t)
	p.Config.Setup = []string{appendTo(p.trace("setup"), "setup-1"), appendTo(p.trace("setup"), "setup-2")}
	r := p.readiness()
	ev := newEvidence()
	r.Evidence = ev
	s, stderr := p.session()
	ready, err := r.Check(context.Background(), s, fixtureSlug)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "exit", ready.AcceptanceExit, 0)
	eq(t, "failures", ready.Failures(), false)
	eq(t, "scenarios", len(ready.Scenarios), 2)
	eq(t, "first", ready.Scenarios[0].Status, "passed")
	eqSlice(t, "setup ran in the scratch folder, once each", p.ran("setup"), []string{"setup-1", "setup-2"})
	eq(t, "setup evidence", ev.counts["setup"], 2)
	eq(t, "acceptance evidence", ev.counts["acceptance"], 1)
	contains(t, "progress", stderr.String(), "kogen: running setup-1: ")
	rec, ok := p.readinessRecord()
	if !ok || rec["outcome"] != "ready" || rec["head"] != p.head() || rec["acceptance_exit"].(float64) != 0 {
		t.Fatalf("record = %v", rec)
	}
	eq(t, "no stamp in the checkout", fileExists(filepath.Join(p.Root, ".kogen/local/setup.json")), false)
	if !fileExists(filepath.Join(p.Root, ".kogen/local/packages/fixture.json")) {
		t.Fatal("package facts are refreshed after the record is published")
	}
	cached := r.Cached(s, fixtureSlug)
	if cached == nil || !r.Current(s, fixtureSlug, cached) || cached.CandidateTree != ready.CandidateTree {
		t.Fatalf("cached = %+v", cached)
	}
	requireNoLeftovers(t, tmp)
	eq(t, "checkout status", p.git("status", "--porcelain"), "")

	// Any change to the candidate makes the evidence stale.
	p.write("extra.txt", "x")
	if r.Cached(s, fixtureSlug) != nil || r.Current(s, fixtureSlug, cached) {
		t.Fatal("a changed candidate is a normal miss")
	}
}

func fileExists(path string) bool { _, err := os.Stat(path); return err == nil }

func TestReadinessAcceptsLegitimateRedAndRetainsObservations(t *testing.T) {
	isolateTmp(t)
	p := newProj(t)
	p.write("app.txt", "red\n")
	r := p.readiness()
	s, _ := p.session()
	ready, err := r.Check(context.Background(), s, fixtureSlug)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "exit", ready.AcceptanceExit, 1)
	eq(t, "failures", ready.Failures(), true)
	rec, _ := p.readinessRecord()
	eq(t, "outcome", rec["outcome"], "ready")
	cached := r.Cached(s, fixtureSlug)
	if cached == nil || !cached.Failures() {
		t.Fatal("unchanged red is reused without another check")
	}
	obs := Observations(fixtureSlug, cached, "")
	contains(t, "observations", obs, "Readiness observations\nChecked baseline: "+cached.SHA256+"\nHEAD: "+p.head()+"\nAcceptance exit: 1\nEvidence: .kogen/local/readiness/fixture.json\n")
	contains(t, "observations", obs, "Scenario: First (acceptance.feature line 2)\nacceptance.feature line 3: Then the candidate succeeds")
	ack := Acknowledgment(fixtureSlug, cached, "")
	contains(t, "acknowledgment", ack, "Inspect whether fixtures, inputs and commands reached the intended behavior")
	contains(t, "acknowledgment", ack, AcknowledgmentGuidance)
	contains(t, "acknowledgment", ack, obs)
	eq(t, "no observations when green", Observations(fixtureSlug, &Ready{}, ""), "")

	// HEAD moved: the earlier observations cannot be acknowledged.
	p.git("commit", "--allow-empty", "-qm", "External HEAD change")
	if r.Cached(s, fixtureSlug) != nil || r.Current(s, fixtureSlug, cached) {
		t.Fatal("changed HEAD must not acknowledge observations from an earlier check")
	}
}

func TestReadinessRefusals(t *testing.T) {
	type refusal struct {
		name   string
		setup  func(p *proj)
		class  string
		reason string
		detail string
		lines  func(t *testing.T, lines []string)
	}
	one := func(want string) func(*testing.T, []string) {
		return func(t *testing.T, lines []string) { eqSlice(t, "lines", lines, []string{want}) }
	}
	prefixed := func(want ...string) func(*testing.T, []string) {
		return func(t *testing.T, lines []string) {
			t.Helper()
			for _, w := range want {
				if !slices.ContainsFunc(lines, func(l string) bool { return strings.Contains(l, w) }) {
					t.Fatalf("lines %q lack %q", lines, w)
				}
			}
		}
	}
	runner := func(p *proj, script string) { p.Config.Acceptance.Run = script }
	cases := []refusal{
		{"undefined steps", func(p *proj) {
			ex := mustScenarios(t)
			rep := writeReport(t, p.Aux, "undef.ndjson", simpleMessages(project.FeaturePath(fixtureSlug), ex, reportOpts{results: statuses("UNDEFINED")}))
			runner(p, "cp '"+rep+"' \"$KOGEN_ACCEPTANCE_REPORT\"; exit 1")
		}, "intent", "not_ready", "the Intent is not ready to build", prefixed("acceptance.feature line 3: undefined step: Then the candidate succeeds")},
		{"missing report", func(p *proj) { runner(p, "echo boom; exit 2") }, "intent", "not_ready", "the Intent is not ready to build",
			prefixed("report_missing: the acceptance command exited 2; its output:", "boom")},
		{"invalid report", func(p *proj) { runner(p, `echo not-json > "$KOGEN_ACCEPTANCE_REPORT"`) }, "intent", "not_ready", "the Intent is not ready to build",
			prefixed("report_invalid: the acceptance command exited 0; its output:")},
		{"exit with every scenario passed", func(p *proj) { runner(p, p.Config.Acceptance.Run+"; echo wrapper-noise; exit 3") }, "intent", "not_ready", "the Intent is not ready to build",
			prefixed("exit 3 with all scenarios passed; its output:", "wrapper-noise")},
		{"scenario skipped", func(p *proj) {
			ex := mustScenarios(t)
			rep := writeReport(t, p.Aux, "skipped.ndjson", simpleMessages(project.FeaturePath(fixtureSlug), ex, reportOpts{results: statuses("SKIPPED")}))
			runner(p, "cp '"+rep+"' \"$KOGEN_ACCEPTANCE_REPORT\"")
		}, "intent", "not_ready", "the Intent is not ready to build", prefixed("skipped: First (line 2)", "skipped: Later (line 4)")},
		{"setup fails", func(p *proj) { p.Config.Setup = []string{"echo before; echo setup-bad; exit 3"} }, "environment", "setup_failed", "Setup setup-1 failed (status=3).", one2("before", "setup-bad")},
		{"setup changes the candidate", func(p *proj) { p.Config.Setup = []string{"echo changed > app.txt; echo added > added.txt"} }, "intent", "not_ready", "readiness changed candidate files", func(t *testing.T, l []string) {
			slices.Sort(l)
			eqSlice(t, "mutations", l, []string{"added.txt", "app.txt"})
		}},
		{"intent cannot be read", func(p *proj) {
			p.write(project.FeaturePath(fixtureSlug), "nonsense\n")
		}, "intent", "parse", "the Intent cannot be read", one("acceptance.feature line 1: expected Feature:, got: nonsense")},
		{"intent needs changes", func(p *proj) {
			p.write(project.FeaturePath(fixtureSlug), "Feature: x\n  Scenario: y\n    Given z\n")
		}, "intent", "lint", "the Intent needs changes", one("acceptance: scenario y has no Then step")},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			tmp := isolateTmp(t)
			p := newProj(t)
			// An earlier record does not survive a check that fails.
			os.MkdirAll(filepath.Dir(readinessPath(p.Root, fixtureSlug)), 0o755)
			os.WriteFile(readinessPath(p.Root, fixtureSlug), []byte(`{"version":3}`), 0o644)
			c.setup(p)
			s, _ := p.session()
			_, err := p.readiness().Check(context.Background(), s, fixtureSlug)
			e := failWith(t, err, c.class, c.reason)
			eq(t, "detail", e.Detail, c.detail)
			eq(t, "exit", e.Exit, map[bool]int{true: 3, false: 1}[c.class == "environment"])
			c.lines(t, e.Lines)
			if _, ok := p.readinessRecord(); ok {
				t.Fatal("a refused check leaves no readiness record")
			}
			requireNoLeftovers(t, tmp)
		})
	}
}

func one2(want ...string) func(*testing.T, []string) {
	return func(t *testing.T, lines []string) { eqSlice(t, "lines", lines, want) }
}

func TestReadinessRecordIsRefusedWhenItsInputsChangedDuringChecking(t *testing.T) {
	isolateTmp(t)
	p := newProj(t)
	r := p.readiness()
	s, _ := p.session()
	ready, err := r.Check(context.Background(), s, fixtureSlug)
	if err != nil {
		t.Fatal(err)
	}
	os.Remove(readinessPath(p.Root, fixtureSlug))
	p.write(project.FeaturePath(fixtureSlug), fixtureFeature+"  Scenario: Third\n    Then the candidate succeeds\n")
	e := failWith(t, r.RecordPass(s, fixtureSlug, ready), "intent", "not_ready")
	eq(t, "detail", e.Detail, "the Intent is not ready to build")
	eqSlice(t, "lines", e.Lines, []string{"readiness inputs changed during checking or publication"})
	if _, ok := p.readinessRecord(); ok {
		t.Fatal("no record is published for changed inputs")
	}
}

func TestReadinessCachedMissesAreNormal(t *testing.T) {
	isolateTmp(t)
	p := newProj(t)
	r := p.readiness()
	s, _ := p.session()
	if _, err := r.Check(context.Background(), s, fixtureSlug); err != nil {
		t.Fatal(err)
	}
	path := readinessPath(p.Root, fixtureSlug)
	good, _ := os.ReadFile(path)
	if r.Cached(s, fixtureSlug) == nil {
		t.Fatal("setup: the record must be reusable")
	}
	mutate := func(f func(rec map[string]any)) {
		var rec map[string]any
		d := json.NewDecoder(strings.NewReader(string(good)))
		d.UseNumber()
		d.Decode(&rec)
		f(rec)
		b, _ := json.Marshal(rec)
		os.WriteFile(path, b, 0o644)
	}
	for name, f := range map[string]func(rec map[string]any){
		"no skipped metadata":       func(rec map[string]any) { delete(rec["scenarios"].([]any)[0].(map[string]any), "unexercised_steps") },
		"null skipped metadata":     func(rec map[string]any) { rec["scenarios"].([]any)[0].(map[string]any)["unexercised_steps"] = nil },
		"nonarray skipped metadata": func(rec map[string]any) { rec["scenarios"].([]any)[0].(map[string]any)["unexercised_steps"] = "[]" },
		"bad skipped object": func(rec map[string]any) {
			rec["scenarios"].([]any)[0].(map[string]any)["unexercised_steps"] = []any{map[string]any{"keyword": "Then ", "text": "not a step", "line": json.Number("3")}}
		},
		"wrong version":               func(rec map[string]any) { rec["version"] = 2 },
		"not ready":                   func(rec map[string]any) { rec["outcome"] = "failed" },
		"exit not integer":            func(rec map[string]any) { rec["acceptance_exit"] = "0" },
		"other head":                  func(rec map[string]any) { rec["head"] = strings.Repeat("0", 40) },
		"other hash":                  func(rec map[string]any) { rec["sha256"] = strings.Repeat("0", 64) },
		"other tree":                  func(rec map[string]any) { rec["candidate_tree"] = strings.Repeat("0", 40) },
		"other baseline":              func(rec map[string]any) { rec["baseline"] = []any{"x"} },
		"other title":                 func(rec map[string]any) { rec["title"] = "Another" },
		"other model":                 func(rec map[string]any) { rec["model"] = "none-ish" },
		"other model result":          func(rec map[string]any) { rec["model_outcome"] = "passed" },
		"scenario count":              func(rec map[string]any) { rec["scenarios"] = rec["scenarios"].([]any)[:1] },
		"scenario status":             func(rec map[string]any) { rec["scenarios"].([]any)[0].(map[string]any)["status"] = "skipped" },
		"scenario shape":              func(rec map[string]any) { rec["scenarios"].([]any)[0].(map[string]any)["name"] = "Renamed" },
		"scenario no detail":          func(rec map[string]any) { delete(rec["scenarios"].([]any)[0].(map[string]any), "detail") },
		"exit nonzero but all passed": func(rec map[string]any) { rec["acceptance_exit"] = json.Number("1") },
		"unproven feasibility":        func(rec map[string]any) { rec["feasibility"] = []any{map[string]any{"id": "x"}} },
	} {
		mutate(f)
		if r.Cached(s, fixtureSlug) != nil {
			t.Fatalf("%s: a mismatching record must be a miss", name)
		}
	}
	for name, text := range map[string]string{
		"legacy record": `{"head":"` + p.head() + `","sha256":"x"}`,
		"malformed":     "{",
		"not an object": "[]",
		"empty":         "",
	} {
		os.WriteFile(path, []byte(text), 0o644)
		if r.Cached(s, fixtureSlug) != nil {
			t.Fatalf("%s must be a miss", name)
		}
	}
	os.Remove(path)
	if r.Cached(s, fixtureSlug) != nil {
		t.Fatal("no record is a miss")
	}
	os.WriteFile(path, good, 0o644)
	if r.Cached(s, fixtureSlug) == nil {
		t.Fatal("the original record is reusable again")
	}
}

func TestSetupRunsInOrderAndWarmPreparationReusesItsStamp(t *testing.T) {
	isolateTmp(t)
	p := newProj(t)
	p.Config.Setup = []string{appendTo(p.trace("setup"), "one"), appendTo(p.trace("setup"), "two")}
	p.Config.Acceptance.StepsDir = "features/steps"
	r := p.readiness()
	s, stderr := p.session()
	ctx := context.Background()
	if err := r.Setup(ctx, s, p.Root, true); err != nil {
		t.Fatal(err)
	}
	eqSlice(t, "first run", p.ran("setup"), []string{"one", "two"})
	stamp := must(os.ReadFile(filepath.Join(p.Root, ".kogen/local/setup.json")))
	var key map[string]any
	if err := json.Unmarshal(stamp, &key); err != nil || key["head"] != p.head() || len(key["changes"].(string)) != 64 || len(key["setup"].([]any)) != 2 {
		t.Fatalf("stamp = %s", stamp)
	}
	stderr.Reset()
	if err := r.Setup(ctx, s, p.Root, true); err != nil {
		t.Fatal(err)
	}
	eqSlice(t, "reused", p.ran("setup"), []string{"one", "two"})
	eq(t, "notice", stderr.String(), "kogen: setup already ran for this checkout state\n")
	// Intent files and the steps folder do not count as checkout changes; other files do.
	p.write(".kogen/intents/fixture/extra.md", "x")
	p.write("features/steps/new_steps.js", "x")
	if err := r.Setup(ctx, s, p.Root, true); err != nil {
		t.Fatal(err)
	}
	eq(t, "still reused", len(p.ran("setup")), 2)
	p.write("src.txt", "changed")
	if err := r.Setup(ctx, s, p.Root, true); err != nil {
		t.Fatal(err)
	}
	eq(t, "changed checkout runs again", len(p.ran("setup")), 4)
	// A Build never reuses it.
	if err := r.Setup(ctx, s, p.Root, false); err != nil {
		t.Fatal(err)
	}
	eq(t, "without reuse", len(p.ran("setup")), 6)
}

func TestSetupFailureStopsAtTheFirstFailedCommandWithItsLastLines(t *testing.T) {
	isolateTmp(t)
	p := newProj(t)
	p.Config.Setup = []string{"seq 1 30; exit 9", appendTo(p.trace("later"), "later")}
	s, _ := p.session()
	err := p.readiness().Setup(context.Background(), s, p.Root, true)
	e := failWith(t, err, "environment", "setup_failed")
	eq(t, "detail", e.Detail, "Setup setup-1 failed (status=9).")
	eq(t, "exit", e.Exit, 3)
	eq(t, "lines", len(e.Lines), 20)
	eq(t, "last line", e.Lines[19], "30")
	eq(t, "first line", e.Lines[0], "11")
	eqSlice(t, "later setup", p.ran("later"), nil)
	if fileExists(filepath.Join(p.Root, ".kogen/local/setup.json")) {
		t.Fatal("a failed setup leaves no stamp")
	}
}

// ExUnit: refinement_test.exs, a runner failure after passing scenarios.
func TestRunnerFailureAfterPassingScenariosNeverSuppliesReusableReadiness(t *testing.T) {
	isolateTmp(t)
	p := newProj(t)
	p.Config.Acceptance.Run = appendTo(p.trace("executions"), "run") + "; " + p.Config.Acceptance.Run + "; echo fresh runner failure; exit 17"
	r := p.readiness()
	s, _ := p.session()
	for n := 1; n <= 2; n++ {
		_, err := r.Check(context.Background(), s, fixtureSlug)
		e := failWith(t, err, "intent", "not_ready")
		joined := strings.Join(e.Lines, "\n")
		contains(t, "lines", joined, "exit 17 with all scenarios passed; its output:")
		contains(t, "lines", joined, "fresh runner failure")
		eq(t, "executions", len(p.ran("executions")), n)
		if fileExists(readinessPath(p.Root, fixtureSlug)) {
			t.Fatal("no record")
		}
	}
}

// ExUnit: refinement_test.exs, readiness mutations cannot certify the changed baseline.
func TestReadinessMutationsCannotCertifyTheChangedBaselineEvenOnRepeatedChecks(t *testing.T) {
	for name, mutation := range map[string]string{
		"intent file":   "printf '\\n' >> .kogen/intents/fixture/intent.md",
		"staged input":  "printf new > staged-input.txt; git add staged-input.txt",
		"mode":          "chmod 755 app.txt",
		"deleted input": "rm app.txt",
	} {
		t.Run(name, func(t *testing.T) {
			isolateTmp(t)
			p := newProj(t)
			p.Config.Acceptance.Run = mutation + "; " + p.Config.Acceptance.Run
			before := p.git("status", "--porcelain")
			index := p.git("ls-files", "--stage")
			baselineHash := project.Hash(p.Root, must(project.Baseline(p.Root, fixtureSlug, p.Config)))
			r := p.readiness()
			s, _ := p.session()
			for i := 0; i < 2; i++ {
				_, err := r.Check(context.Background(), s, fixtureSlug)
				e := failWith(t, err, "intent", "not_ready")
				eq(t, "detail", e.Detail, "readiness changed candidate files")
				if len(e.Lines) == 0 {
					t.Fatal("the changed files are named")
				}
				eq(t, "checkout status", p.git("status", "--porcelain"), before)
				eq(t, "index", p.git("ls-files", "--stage"), index)
				eq(t, "app.txt", p.read("app.txt"), "green\n")
				eq(t, "baseline hash", project.Hash(p.Root, must(project.Baseline(p.Root, fixtureSlug, p.Config))), baselineHash)
				if fileExists(readinessPath(p.Root, fixtureSlug)) {
					t.Fatal("no record for a mutating check")
				}
			}
		})
	}
}

// ExUnit: refinement_test.exs, local ignored warmth stays available to probes but out of final proof.
func TestLocallyIgnoredWarmthIsAvailableToProbesButOutOfFinalProof(t *testing.T) {
	for _, mode := range []string{"info exclude", "local excludes file"} {
		t.Run(mode, func(t *testing.T) {
			isolateTmp(t)
			p := newProj(t)
			if mode == "info exclude" {
				os.WriteFile(filepath.Join(p.Root, ".git/info/exclude"), []byte("local-cache/\n"), 0o644)
			} else {
				exclude := filepath.Join(p.Aux, "local-excludes")
				os.WriteFile(exclude, []byte("local-cache/\n"), 0o644)
				p.git("config", "core.excludesFile", exclude)
			}
			p.write("local-cache/warm.txt", "workspace only\n")
			s, _ := p.session()
			probe, err := RunProbe(context.Background(), s, p.Root, "cat local-cache/warm.txt", nil)
			if err != nil {
				t.Fatal(err)
			}
			eq(t, "the probe sees the warm file", probe.Output, "workspace only\n")
			p.Config.Acceptance.Run = "test ! -e local-cache/warm.txt && " + p.Config.Acceptance.Run
			r := p.readiness()
			ready, err := r.Check(context.Background(), s, fixtureSlug)
			if err != nil {
				t.Fatal(err)
			}
			eq(t, "exit", ready.AcceptanceExit, 0)
			eq(t, "the checkout keeps its warmth", p.read("local-cache/warm.txt"), "workspace only\n")
			record := must(os.ReadFile(readinessPath(p.Root, fixtureSlug)))
			cached := r.Cached(s, fixtureSlug)
			if cached == nil {
				t.Fatal("the unchanged package reuses its record")
			}
			eq(t, "record untouched by the reuse", string(must(os.ReadFile(readinessPath(p.Root, fixtureSlug)))), string(record))
		})
	}
}

// Ports the `before_record` argument of Readiness.check!/4: a conversation validates its
// private custody after the checks passed and before anything is recorded.
func TestReadinessBeforeRecordRunsAfterTheChecksAndCanStopTheRecord(t *testing.T) {
	isolateTmp(t)
	p := newProj(t)
	r := p.readiness()
	calls := 0
	r.BeforeRecord = func() error {
		calls++
		if _, ok := p.readinessRecord(); ok {
			t.Error("the record exists before BeforeRecord ran")
		}
		return nil
	}
	s, _ := p.session()
	if _, err := r.Check(context.Background(), s, fixtureSlug); err != nil {
		t.Fatal(err)
	}
	eq(t, "calls", calls, 1)
	if _, ok := p.readinessRecord(); !ok {
		t.Fatal("no record after a passing check")
	}

	stop := sys.Fail("candidate", "context_custody_invalid", "custody damaged", 1)
	r.BeforeRecord = func() error { return stop }
	if _, err := r.Check(context.Background(), s, fixtureSlug); err != stop {
		t.Fatalf("err = %v, want the BeforeRecord error", err)
	}
	if _, ok := p.readinessRecord(); ok {
		t.Fatal("a stopped check left a record")
	}
	if r.Cached(s, fixtureSlug) != nil {
		t.Fatal("a stopped check left reusable evidence")
	}
}

func TestCachedUnexercisedRequiresExactOrderedSourceSubset(t *testing.T) {
	_, scenarios := featureWithSteps(t, "cache", 3)
	steps := ScenarioRecord(scenarios[0]).Steps
	for name, records := range map[string]any{
		"empty": []StepRecord{}, "subset": []StepRecord{steps[0], steps[2]},
		"duplicate": []StepRecord{steps[0], steps[0]}, "reversed": []StepRecord{steps[2], steps[0]},
		"wrong keyword":   []StepRecord{{Keyword: "Then ", Text: steps[0].Text, Line: steps[0].Line}},
		"wrong text":      []StepRecord{{Keyword: steps[0].Keyword, Text: "other", Line: steps[0].Line}},
		"wrong line":      []StepRecord{{Keyword: steps[0].Keyword, Text: steps[0].Text, Line: 99}},
		"bad types":       []any{map[string]any{"keyword": 1, "text": "step 1", "line": 3}},
		"fractional line": []any{map[string]any{"keyword": "Given ", "text": "step 1", "line": 3.5}},
		"extra field":     []any{map[string]any{"keyword": "Given ", "text": "step 1", "line": 3, "extra": true}},
	} {
		t.Run(name, func(t *testing.T) {
			got, ok := cachedUnexercised(generic(records), scenarios[0])
			want := name == "empty" || name == "subset"
			if ok != want {
				t.Fatalf("valid = %v want %v", ok, want)
			}
			if want && encode(got) != encode(records) {
				t.Fatalf("round trip: %s", encode(got))
			}
		})
	}
}

func TestObservationsKeepFirstFailureBeforeLongSkippedListings(t *testing.T) {
	where := "a hook at features/steps/fixture_steps.js line 8"
	detail := Cut(where + "\nhook-red: " + strings.Repeat("é", 11000))
	skipped := []StepRecord{}
	for line := 3; line < 103; line++ {
		skipped = append(skipped, StepRecord{Keyword: "Then ", Text: strings.Repeat("é", 100), Line: line})
	}
	ready := &Ready{AcceptanceExit: 1, Scenarios: []ScenarioResult{{
		Name: "Long skipped tail", Line: 2, Status: "failed", Detail: &detail, UnexercisedSteps: skipped,
	}}}
	for name, text := range map[string]string{
		"observations":   Observations(fixtureSlug, ready, ""),
		"acknowledgment": Acknowledgment(fixtureSlug, ready, ""),
	} {
		if len(text) > 16384 || !utf8.ValidString(text) {
			t.Fatalf("%s: %d bytes, valid UTF-8 %v", name, len(text), utf8.ValidString(text))
		}
		contains(t, name, text, "Unexercised acceptance steps: 100")
		contains(t, name, text, "Skipped steps are unexercised; readiness does not prove their behavior or fixture validity.")
		contains(t, name, text, "Scenario: Long skipped tail (acceptance.feature line 2)")
		contains(t, name, text, where+"\nhook-red:")
		contains(t, name, text, "bytes omitted")
	}
}

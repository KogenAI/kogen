package verify

import (
	"encoding/json"
	"strings"
	"testing"
	"unicode/utf8"

	"kogen/project"
)

type passGolden struct {
	Feedback []struct {
		Name          string          `json:"name"`
		Pass          json.RawMessage `json:"pass"`
		AcceptanceRun string          `json:"acceptance_run"`
		Completion    string          `json:"completion"`
		Feedback      string          `json:"feedback"`
	} `json:"feedback"`
	Complete []struct {
		Name    string          `json:"name"`
		Pass    json.RawMessage `json:"pass"`
		Feature string          `json:"feature"`
		Setup   []string        `json:"setup"`
		Checks  []project.Check `json:"checks"`
		Model   string          `json:"model"`
		Done    bool            `json:"complete"`
	} `json:"complete"`
}

func readPass(t *testing.T, raw json.RawMessage) Pass {
	t.Helper()
	var p Pass
	if err := json.Unmarshal(raw, &p); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestPassFeedbackEqualsTheElixirFeedback(t *testing.T) {
	var g passGolden
	readGolden(t, "passes.json", &g)
	if len(g.Feedback) < 10 {
		t.Fatal("missing reference cases")
	}
	for _, c := range g.Feedback {
		t.Run(c.Name, func(t *testing.T) {
			p := readPass(t, c.Pass)
			if got := p.Feedback(c.AcceptanceRun, c.Completion); got != c.Feedback {
				t.Fatalf("feedback differs\n got: %q\nwant: %q", got, c.Feedback)
			}
			// What Kogen writes reads back to the same pass.
			again, err := json.Marshal(p)
			if err != nil {
				t.Fatal(err)
			}
			sameJSON(t, "pass record", p, c.Pass)
			if q := readPass(t, again); q.Feedback(c.AcceptanceRun, c.Completion) != c.Feedback {
				t.Fatal("a pass read back from its own record gives other feedback")
			}
		})
	}
}

func TestPassCompleteEqualsTheElixirVerdictOnEveryReference(t *testing.T) {
	var g passGolden
	readGolden(t, "passes.json", &g)
	for _, c := range g.Complete {
		t.Run(c.Name, func(t *testing.T) {
			expected, err := project.ParseGherkin(c.Feature)
			if err != nil {
				t.Fatal(err)
			}
			cfg := &project.Config{Setup: c.Setup, Checks: c.Checks}
			var model *project.ModelSpec
			if c.Model == "none" {
				model = &project.ModelSpec{None: true}
			} else {
				model = &project.ModelSpec{Path: "m.qnt", Invariants: []string{"Safe"}, Seed: "1", Samples: "1", Steps: "1"}
			}
			p := readPass(t, c.Pass)
			if got := p.Complete(cfg, expected, model); got != c.Done {
				t.Fatalf("Complete = %v, want %v", got, c.Done)
			}
			// A pass written by Kogen and read back keeps its verdict, except that a record
			// from before `setup` and `not_run` existed stays what it was.
			again, err := json.Marshal(p)
			if err != nil {
				t.Fatal(err)
			}
			q := readPass(t, again)
			if p.Legacy {
				return
			}
			if got := q.Complete(cfg, expected, model); got != c.Done {
				t.Fatalf("Complete after a round trip = %v, want %v", got, c.Done)
			}
		})
	}
}

func TestPassRecordHasExactlyTheFieldsKogenRecords(t *testing.T) {
	p := Pass{N: 3, Clean: true, Tree: "abc", Model: ModelNone}
	b, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	var keys []string
	for k := range m {
		keys = append(keys, k)
	}
	want := []string{"n", "clean", "green", "tree", "setup", "acceptance", "model", "checks", "not_run", "moved", "failing"}
	if len(keys) != len(want) {
		t.Fatalf("keys = %v, want %v", keys, want)
	}
	for _, k := range want {
		if _, ok := m[k]; !ok {
			t.Fatalf("record lacks %q: %s", k, b)
		}
	}
	for _, k := range []string{"setup", "checks", "not_run", "moved", "failing"} {
		if string(m[k]) != "[]" {
			t.Fatalf("%s = %s, want []", k, m[k])
		}
	}
	if string(m["acceptance"]) != `"not_run"` || string(m["model"]) != `"none"` {
		t.Fatalf("acceptance %s, model %s", m["acceptance"], m["model"])
	}
	for _, c := range []struct {
		m    ModelResult
		want string
	}{
		{ModelNone, `"none"`}, {ModelNotRun, `"not_run"`},
		{ModelResult{State: "ok", Problems: []string{}}, `{"ok":[]}`},
		{ModelResult{State: "failed", Problems: []string{"x"}}, `{"failed":["x"]}`},
	} {
		b, _ := json.Marshal(Pass{Model: c.m})
		if !strings.Contains(string(b), `"model":`+c.want) {
			t.Fatalf("model %v encodes as %s, want %s", c.m, b, c.want)
		}
	}
}

func TestPassSummaryProgressLine(t *testing.T) {
	for _, c := range []struct {
		p    Pass
		want string
	}{
		{Pass{N: 1, Green: true}, "kogen: pass 1: all checks passed"},
		{Pass{N: 2, Failing: []string{"acceptance", "lint"}, NotRun: []string{"test"}}, "kogen: pass 2: acceptance, lint failed; not run because an earlier item failed: test"},
		{Pass{N: 3, Moved: []string{"a", "b"}}, "kogen: pass 3: files changed while the checks ran: a, b"},
		{Pass{N: 4, Failing: []string{"setup-1"}, NotRun: []string{"setup-2", "acceptance", "z-first", "a-later"}},
			"kogen: pass 4: setup-1 failed; not run because an earlier item failed: setup-2, acceptance, z-first, a-later"},
	} {
		eq(t, "summary", c.p.Summary(), c.want)
	}
	eq(t, "notice", NotRunNotice([]string{"a", "b"}), "not run because an earlier item failed: a, b")
	eq(t, "empty notice", NotRunNotice(nil), "")
}

func TestPassChecksLineAndResults(t *testing.T) {
	acc := &Acceptance{Passed: 2, Scenarios: []ScenarioResult{{}, {}}}
	p := Pass{Acceptance: acc, Model: ModelResult{State: "ok"}, Checks: []CommandResult{{Name: "lint"}, {Name: "test"}}}
	eq(t, "checks line", p.ChecksLine(), "acceptance 2/2, model passed, lint passed, test passed")
	eq(t, "results", p.Results(), "acceptance: passed (2 scenarios)\nmodel: passed\ncheck lint: passed\ncheck test: passed")
	p.Model = ModelNone
	eq(t, "checks line none", p.ChecksLine(), "acceptance 2/2, model not applicable, lint passed, test passed")
	eq(t, "results none", p.Results(), "acceptance: passed (2 scenarios)\nmodel: not applicable\ncheck lint: passed\ncheck test: passed")
}

func TestPassValidIsTheShapeAResumedRecordMustHave(t *testing.T) {
	var g passGolden
	readGolden(t, "passes.json", &g)
	good := readPass(t, g.Complete[0].Pass)
	if !good.Valid() {
		t.Fatal("a recorded complete pass is valid")
	}
	for name, mutate := range map[string]func(p *Pass){
		"not clean":          func(p *Pass) { p.Clean = false },
		"no tree":            func(p *Pass) { p.Tree = "" },
		"no model":           func(p *Pass) { p.Model = ModelResult{} },
		"acceptance no list": func(p *Pass) { a := *p.Acceptance; a.Scenarios = nil; p.Acceptance = &a },
	} {
		p := good
		mutate(&p)
		if p.Valid() {
			t.Errorf("%s: must not be valid", name)
		}
	}
	p := good
	p.Acceptance = nil // not run
	if !p.Valid() {
		t.Error("a pass whose acceptance did not run is valid")
	}
}

func TestPassRecordsThatCannotBeReadAreRejected(t *testing.T) {
	var p Pass
	for name, text := range map[string]string{
		"not an object":      `[]`,
		"no model":           `{"n":1,"clean":true,"green":false,"tree":"t","acceptance":"not_run","checks":[],"moved":[],"failing":[]}`,
		"unknown model":      `{"n":1,"acceptance":"not_run","model":{"weird":[]},"checks":[]}`,
		"two model keys":     `{"n":1,"acceptance":"not_run","model":{"ok":[],"failed":[]},"checks":[]}`,
		"acceptance garbage": `{"n":1,"acceptance":7,"model":"none","checks":[]}`,
		"check garbage":      `{"n":1,"acceptance":"not_run","model":"none","checks":[1]}`,
	} {
		if err := json.Unmarshal([]byte(text), &p); err == nil {
			t.Errorf("%s: record was accepted", name)
		}
	}
}

// ExUnit: run_test.exs, completeness of green evidence (the checkpoint-decoder half of that
// test belongs to the build package).
func TestCompleteRequiresRequiredCleanEvidenceNotAStoredBoolean(t *testing.T) {
	expected, err := project.ParseGherkin("Feature: Example\n  Scenario: Complete\n    Given a gate\n")
	if err != nil {
		t.Fatal(err)
	}
	cfg := &project.Config{Setup: []string{"true"}, Checks: []project.Check{{Name: "z-first", Run: "true"}, {Name: "a-last", Run: "true"}}}
	none := &project.ModelSpec{None: true}
	scenario := func(status string) ScenarioResult { return ScenarioResult{Name: "Complete", Line: 2, Status: status} }
	acc := func() *Acceptance {
		return &Acceptance{Status: 0, Passed: 1, Scenarios: []ScenarioResult{scenario("passed")}, Problems: []string{}}
	}
	checks := func() []CommandResult {
		return []CommandResult{{Name: "z-first", Command: "true"}, {Name: "a-last", Command: "true"}}
	}
	// An old clean record: no setup, no not_run.
	old := Pass{Green: true, Clean: true, Legacy: true, Acceptance: acc(), Model: ModelNone, Checks: checks()}
	if !old.Complete(cfg, expected, none) {
		t.Fatal("old complete clean evidence stays reusable")
	}
	current := old
	current.Legacy, current.NotRun, current.Setup = false, []string{}, []CommandResult{{Name: "setup-1", Command: "true"}}
	if !current.Complete(cfg, expected, none) {
		t.Fatal("current complete evidence is reusable")
	}
	noSetup := current
	noSetup.Setup = nil
	if noSetup.Complete(cfg, expected, none) {
		t.Fatal("a current record without its setup is incomplete")
	}
	mut := func(f func(p *Pass)) Pass { p := old; p.Acceptance, p.Checks = acc(), checks(); f(&p); return p }
	for name, p := range map[string]Pass{
		"not clean":         mut(func(p *Pass) { p.Clean = false }),
		"not green":         mut(func(p *Pass) { p.Green = false }),
		"acceptance absent": mut(func(p *Pass) { p.Acceptance = nil }),
		"exit status":       mut(func(p *Pass) { p.Acceptance.Status = 1 }),
		"problems":          mut(func(p *Pass) { p.Acceptance.Problems = []string{"report_invalid"} }),
		"duplicated":        mut(func(p *Pass) { p.Acceptance.Scenarios = append(p.Acceptance.Scenarios, scenario("passed")) }),
		"no checks":         mut(func(p *Pass) { p.Checks = nil }),
		"checks reversed":   mut(func(p *Pass) { p.Checks = []CommandResult{p.Checks[1], p.Checks[0]} }),
		"no scenarios":      mut(func(p *Pass) { p.Acceptance.Scenarios = nil }),
		"skipped":           mut(func(p *Pass) { p.Acceptance.Scenarios = []ScenarioResult{scenario("skipped")} }),
		"not run":           mut(func(p *Pass) { p.NotRun = []string{"a-last"} }),
		"empty setup":       mut(func(p *Pass) { p.Legacy, p.Setup = false, []CommandResult{} }),
	} {
		if p.Complete(cfg, expected, none) {
			t.Errorf("%s: must be incomplete", name)
		}
	}
	model := &project.ModelSpec{Path: "model.qnt"}
	if old.Complete(cfg, expected, model) {
		t.Error("an Intent with a model needs the model passed")
	}
	withModel := old
	withModel.Model = ModelResult{State: "ok", Problems: []string{}}
	if !withModel.Complete(cfg, expected, model) {
		t.Error("a passed model completes the evidence")
	}
}

// ExUnit: run_test.exs, the run log cap.
func TestCapPreservesUTF8AndFitsInAMebibyteIncludingItsMarker(t *testing.T) {
	for _, size := range []int{1048575, 1048576} {
		text := strings.Repeat("x", size)
		eq(t, "short enough", Cap(text) == text, true)
	}
	for _, text := range []string{strings.Repeat("x", 1048577), strings.Repeat("€", 400000), strings.Repeat("🌍", 300000)} {
		capped := Cap(text)
		if len(capped) > 1048576 || !utf8.ValidString(capped) {
			t.Fatalf("cap: %d bytes, valid %v", len(capped), utf8.ValidString(capped))
		}
		parts := strings.Split(capped, "\n[... cut in the run log ...]\n")
		if len(parts) != 2 || !strings.HasPrefix(text, parts[0]) || !strings.HasSuffix(text, parts[1]) {
			t.Fatal("the cap keeps the start and the end of the output")
		}
		var round struct{ Output string }
		if err := json.Unmarshal([]byte(encode(map[string]any{"output": capped})), &round); err != nil || round.Output != capped {
			t.Fatal("a capped output survives JSON")
		}
	}
}

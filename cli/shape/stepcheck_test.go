package shape

import (
	"encoding/json"
	"slices"
	"testing"

	"kogen/project"
	"kogen/verify"
)

func TestSelfcheckFeedbackNamesDefectsNotWarnings(t *testing.T) {
	parallel(t)
	const own = "features/steps/a_steps.js"
	var raw verify.StepRaw
	err := json.Unmarshal([]byte(`{"loads":[{"file":"`+own+`","error":""}],
	 "defs":[{"file":"`+own+`","pattern":"x","body":"","used":true},{"file":"`+own+`","pattern":"dead","body":"","used":false},
	         {"file":"features/steps/other.js","pattern":"o","body":"","used":false}],
	 "steps":[{"text":"x","count":1},{"text":"y","count":0},{"text":"z","count":2}]}`), &raw)
	if err != nil {
		t.Fatal(err)
	}
	items := verify.StepItems([]string{own}, raw)
	scenarios := []project.Scenario{{Steps: []project.Step{{Keyword: "Then ", Text: "y", Line: 3}}}}
	want := selfcheckHeadline + "\nacceptance.feature line 3: undefined step: Then y\n- steps z: ambiguous step (2 definitions)"
	if got := selfcheckScenarioFeedback(items, scenarios); got != want {
		t.Errorf("feedback %q, want %q", got, want)
	}
	raw.Loads[0].Error = "SyntaxError: boom"
	items = verify.StepItems([]string{own}, raw)
	if f := selfcheckScenarioFeedback(items, scenarios); f != selfcheckHeadline+"\n- load "+own+": SyntaxError: boom" {
		t.Errorf("feedback %q", f)
	}
}

func TestOwnStepFilesAreTheJavaScriptStepFiles(t *testing.T) {
	parallel(t)
	intent := &project.Intent{Slug: "k", Acceptance: []string{project.FeaturePath("k"),
		"features/steps/k_steps.js", "features/steps/k_driver.go", "test/k_helper.js"}}
	if got := verify.OwnStepFiles(intent); !slices.Equal(got, []string{"features/steps/k_steps.js"}) {
		t.Errorf("own step files %v", got)
	}
}

func TestSelfcheckUndefinedLocations(t *testing.T) {
	items := []verify.StepItem{{Check: "steps", Target: "the caller doubles 4", Detail: "undefined step"}}
	scenarios := []project.Scenario{{Steps: []project.Step{{Keyword: "When ", Text: "the caller doubles 4", Line: 14}}}, {Steps: []project.Step{{Keyword: "When ", Text: "the caller doubles 4", Line: 14}}}}
	want := selfcheckHeadline + "\nacceptance.feature line 14: undefined step: When the caller doubles 4"
	if got := selfcheckScenarioFeedback(items, scenarios); got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestSelfcheckUndefinedOutlineRows(t *testing.T) {
	items := []verify.StepItem{{Check: "steps", Target: "value 1", Detail: "undefined step"}, {Check: "steps", Target: "value 2", Detail: "undefined step"}}
	scenarios := []project.Scenario{{Steps: []project.Step{{Keyword: "When ", Text: "value 1", Line: 4}}}, {Steps: []project.Step{{Keyword: "When ", Text: "value 2", Line: 4}}}}
	want := selfcheckHeadline + "\nacceptance.feature line 4: undefined step: When value 1\nacceptance.feature line 4: undefined step: When value 2"
	if got := selfcheckScenarioFeedback(items, scenarios); got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

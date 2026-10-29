package shape

import (
	"encoding/json"
	"slices"
	"testing"

	"kogen/project"
	"kogen/verify"
)

func TestSelfcheckFeedbackNamesDefectsNotWarnings(t *testing.T) {
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
	want := selfcheckHeadline + "\n- steps y: undefined step\n- steps z: ambiguous step (2 definitions)"
	if got := selfcheckFeedback(items); got != want {
		t.Errorf("feedback %q, want %q", got, want)
	}
	raw.Loads[0].Error = "SyntaxError: boom"
	items = verify.StepItems([]string{own}, raw)
	if f := selfcheckFeedback(items); f != selfcheckHeadline+"\n- load "+own+": SyntaxError: boom" {
		t.Errorf("feedback %q", f)
	}
}

func TestOwnStepFilesAreTheJavaScriptStepFiles(t *testing.T) {
	intent := &project.Intent{Slug: "k", Acceptance: []string{project.FeaturePath("k"),
		"features/steps/k_steps.js", "features/steps/k_driver.go", "test/k_helper.js"}}
	if got := verify.OwnStepFiles(intent); !slices.Equal(got, []string{"features/steps/k_steps.js"}) {
		t.Errorf("own step files %v", got)
	}
}

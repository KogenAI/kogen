package shape

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"

	"kogen/project"
)

func TestExitWrapper(t *testing.T) {
	cases := []struct{ body, want string }{
		{"spawnSync('sh',['-c','go run ./x']); assert.equal(r.status, 2)", "go run"},
		{"sh('npm run t'); assert.equal(r.status, 2)", "npm run"},
		{"run('npx foo'); assert.equal(r.exitCode, 2)", "npx"},
		{"run('npm run t -- 4'); assert.equal(r.status, 2)", ""},
		{"run('npx foo -- 4'); assert.equal(r.status, 2)", ""},
		{"spawnSync('go',['build']); spawnSync('./bin'); assert.equal(r.status, 2)", ""},
		{"spawnSync('sh',['-c','go run ./x']); assert.ok(r.stdout)", ""},
	}
	for _, c := range cases {
		if got := exitWrapper(c.body); got != c.want {
			t.Errorf("%q: got %q want %q", c.body, got, c.want)
		}
	}
}

func TestScItems(t *testing.T) {
	const own = "features/steps/a_steps.js"
	var raw scRaw
	err := json.Unmarshal([]byte(`{"loads":[{"file":"`+own+`","error":""}],
	 "defs":[{"file":"`+own+`","pattern":"x","body":"","used":true},{"file":"`+own+`","pattern":"dead","body":"","used":false},
	         {"file":"features/steps/other.js","pattern":"o","body":"","used":false}],
	 "steps":[{"text":"x","count":1},{"text":"y","count":0},{"text":"z","count":2}]}`), &raw)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, it := range scItems([]string{own}, raw) {
		if !it.OK {
			got = append(got, it.Check+" "+it.Target+": "+it.Detail)
		}
	}
	want := "steps y: undefined step|steps z: ambiguous step (2 definitions)|definitions dead: unused definition"
	if strings.Join(got, "|") != want {
		t.Errorf("got %q", got)
	}
	raw.Loads[0].Error = "SyntaxError: boom"
	items := scItems([]string{own}, raw)
	if len(items) != 1 || items[0].OK || items[0].Detail != "SyntaxError: boom" {
		t.Errorf("load failure: %+v", items)
	}
	if f := selfcheckFeedback(items); f != selfcheckHeadline+"\n- load "+own+": SyntaxError: boom" {
		t.Errorf("feedback %q", f)
	}
}

func TestOwnStepFilesAreTheJavaScriptStepFiles(t *testing.T) {
	intent := &project.Intent{Slug: "k", Acceptance: []string{project.FeaturePath("k"),
		"features/steps/k_steps.js", "features/steps/k_driver.go", "test/k_helper.js"}}
	if got := ownStepFiles(intent); !slices.Equal(got, []string{"features/steps/k_steps.js"}) {
		t.Errorf("own step files %v", got)
	}
}

package verify

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"
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
		if got := ExitWrapper(c.body); got != c.want {
			t.Errorf("%q: got %q want %q", c.body, got, c.want)
		}
	}
}

func TestStepItems(t *testing.T) {
	const own = "features/steps/a_steps.js"
	var raw StepRaw
	err := json.Unmarshal([]byte(`{"loads":[{"file":"`+own+`","error":""}],
	 "defs":[{"file":"`+own+`","pattern":"x","body":"","used":true},{"file":"`+own+`","pattern":"dead","body":"","used":false},
	         {"file":"features/steps/other.js","pattern":"o","body":"","used":false}],
	 "steps":[{"text":"x","count":1},{"text":"y","count":0},{"text":"z","count":2}]}`), &raw)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	items := StepItems([]string{own}, raw)
	for _, it := range items {
		if !it.OK {
			got = append(got, it.Check+" "+it.Target+": "+it.Detail)
		}
	}
	if want := "steps y: undefined step|steps z: ambiguous step (2 definitions)"; strings.Join(got, "|") != want {
		t.Errorf("defects %q, want %q", got, want)
	}
	// An unused definition of an own file is an ok item that warns; other files' are not judged.
	if w := StepWarnings(items); !slices.Equal(w, []StepWarning{{Pattern: "dead", File: own, Detail: UnusedDefinition}}) {
		t.Errorf("warnings %+v", w)
	}
	raw.Loads[0].Error = "SyntaxError: boom"
	items = StepItems([]string{own}, raw)
	if len(items) != 1 || items[0].OK || items[0].Detail != "SyntaxError: boom" || len(StepWarnings(items)) != 0 {
		t.Errorf("load failure: %+v", items)
	}
}

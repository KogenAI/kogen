package project

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func stagePlan() map[string]any {
	return map[string]any{
		"version": 1,
		"stages": []any{
			map[string]any{"id": "foundation", "title": "Foundation", "goal": "First runnable section", "checks": []any{"first", "second"}},
			map[string]any{"id": "surface", "title": "Surface", "goal": "Integrate", "checks": []any{"third"}},
		},
	}
}

func stageSection(t *testing.T, plan any) string {
	t.Helper()
	b, err := json.Marshal(plan)
	if err != nil {
		t.Fatal(err)
	}
	return "## Stages\n```json\n" + string(b) + "\n```\n"
}

func clonePlan(t *testing.T) map[string]any {
	t.Helper()
	var out map[string]any
	b, _ := json.Marshal(stagePlan())
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

// Ports test/kogen/stages_test.exs "absent plan is unchanged; explicit plan retains ordered
// literals" (the parse part).
func TestAnAbsentPlanIsUnchangedAndAnExplicitPlanRetainsOrderedLiterals(t *testing.T) {
	section := stageSection(t, stagePlan())
	for _, text := range []string{
		"## Foundation\nSome stages in prose.\n",
		"````markdown\n" + section + "````\n",
		"~~~markdown\n" + section + "~~~\n",
	} {
		if stages, err := ParseStages(text); stages != nil || err != nil {
			t.Errorf("ParseStages(%q) = %v, %v; want absent", text, stages, err)
		}
	}
	got, err := ParseStages(section)
	if err != nil {
		t.Fatal(err)
	}
	want := []Stage{
		{ID: "foundation", Title: "Foundation", Goal: "First runnable section", Checks: []string{"first", "second"}},
		{ID: "surface", Title: "Surface", Goal: "Integrate", Checks: []string{"third"}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("stages = %#v, want %#v", got, want)
	}
}

// Ports "all specified schema errors name stages rather than silently ignoring metadata".
func TestEverySpecifiedSchemaErrorNamesStages(t *testing.T) {
	p := clonePlan(t)
	stages := p["stages"].([]any)
	first, last := stages[0].(map[string]any), stages[1]
	with := func(mutate func(map[string]any)) map[string]any {
		m := map[string]any{}
		for k, v := range first {
			m[k] = v
		}
		mutate(m)
		return m
	}
	plan := func(mutate func(map[string]any)) map[string]any {
		m := map[string]any{}
		for k, v := range p {
			m[k] = v
		}
		mutate(m)
		return m
	}
	invalid := []any{
		nil, []any{}, map[string]any{},
		plan(func(m map[string]any) { delete(m, "version") }),
		plan(func(m map[string]any) { m["extra"] = true }),
		plan(func(m map[string]any) { m["version"] = 2 }),
		plan(func(m map[string]any) { m["version"] = json.Number("1.0") }),
		plan(func(m map[string]any) { m["version"] = "1" }),
		plan(func(m map[string]any) { m["stages"] = []any{} }),
		plan(func(m map[string]any) { m["stages"] = []any{first} }),
		plan(func(m map[string]any) { m["stages"] = "stages" }),
		plan(func(m map[string]any) { m["stages"] = []any{first, first} }),
	}
	entries := []any{nil, "stage", with(func(m map[string]any) { m["extra"] = true })}
	for k := range first {
		k := k
		entries = append(entries, with(func(m map[string]any) { delete(m, k) }))
	}
	for _, id := range []any{"", "Foundation", "bad_id", "-bad", "bad-", 1} {
		id := id
		entries = append(entries, with(func(m map[string]any) { m["id"] = id }))
	}
	for _, key := range []string{"title", "goal"} {
		for _, value := range []any{"", " \n", 2, []any{}, nil} {
			key, value := key, value
			entries = append(entries, with(func(m map[string]any) { m[key] = value }))
		}
	}
	for _, checks := range []any{[]any{}, "true", []any{""}, []any{" \n"}, []any{1}, []any{"true", nil}} {
		checks := checks
		entries = append(entries, with(func(m map[string]any) { m["checks"] = checks }))
	}
	for _, entry := range entries {
		entry := entry
		invalid = append(invalid, plan(func(m map[string]any) { m["stages"] = []any{entry, last} }))
	}
	for _, value := range invalid {
		b, _ := json.Marshal(value)
		_, err := ParseStages(stageSection(t, value))
		if err == nil || !strings.HasPrefix(err.Error(), "stages:") {
			t.Errorf("%s: err = %v, want a stages: error", b, err)
		}
	}

	good := stageSection(t, p)
	for _, text := range []string{
		"## Stages\nnot json\n",
		"## Stages\n```json\n{\n```\n",
		good + good,
		good + "```json\n{}\n```\n",
		"## Stages\n```json\n" + strings.TrimSuffix(strings.TrimPrefix(good, "## Stages\n```json\n"), "\n```\n") + "\n```\nextra\n",
	} {
		if _, err := ParseStages(text); err == nil || !strings.HasPrefix(err.Error(), "stages:") {
			t.Errorf("%q: err = %v, want a stages: error", text, err)
		}
	}
}

func TestAMalformedPlanIsAnIntentLintProblem(t *testing.T) {
	if p := stagesProblem("## Stages\nnot json\n"); !strings.HasPrefix(p, "stages:") {
		t.Errorf("problem = %q", p)
	}
	if p := stagesProblem(stageSection(t, stagePlan())); p != "" {
		t.Errorf("a valid plan has the problem %q", p)
	}
	if p := stagesProblem("no plan here"); p != "" {
		t.Errorf("no plan has the problem %q", p)
	}
}

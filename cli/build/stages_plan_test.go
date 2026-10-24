package build

import (
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"kogen/project"
)

// The `## Stages` plan of an approved Intent, as a staged Build reads it (the parser is
// project.ParseStages; a Build refuses what it would silently ignore).

func planValue() map[string]any {
	return map[string]any{"version": 1, "stages": []any{
		map[string]any{"id": "foundation", "title": "Foundation", "goal": "First runnable section", "checks": []any{"first", "second"}},
		map[string]any{"id": "surface", "title": "Surface", "goal": "Integrate", "checks": []any{"third"}},
	}}
}

func sectionOf(plan any) string {
	b, _ := json.Marshal(plan)
	return "## Stages\n```json\n" + string(b) + "\n```\n"
}

func clone(v any) any {
	b, _ := json.Marshal(v)
	var out any
	json.Unmarshal(b, &out)
	return out
}

func TestAnAbsentPlanIsUnchangedAndAnExplicitPlanRetainsOrderedLiterals(t *testing.T) {
	// ExUnit: test/kogen/stages_test.exs: absent plan is unchanged; explicit plan retains ordered literals
	for _, text := range []string{
		"## Foundation\nSome stages in prose.\n",
		"````markdown\n" + sectionOf(planValue()) + "````\n",
		"~~~markdown\n" + sectionOf(planValue()) + "~~~\n",
	} {
		plan, err := project.ParseStages(text)
		if plan != nil || err != nil {
			t.Fatalf("%q: %v %v", text, plan, err)
		}
	}
	plan, err := project.ParseStages(sectionOf(planValue()))
	if err != nil {
		t.Fatal(err)
	}
	defs := stageDefs(plan)
	want := []stageDef{
		{ID: "foundation", Title: "Foundation", Goal: "First runnable section", Checks: []string{"first", "second"}},
		{ID: "surface", Title: "Surface", Goal: "Integrate", Checks: []string{"third"}},
	}
	if !reflect.DeepEqual(defs, want) {
		t.Fatalf("plan %+v", defs)
	}
	if initialProgress(nil) != nil {
		t.Fatal("progress without a plan")
	}
	eq(t, "initial", canonical(initialProgress(defs).value()), `{"active":"foundation","completed":[],"phase":"stage","total":2}`)
}

func TestEverySpecifiedPlanSchemaErrorNamesStages(t *testing.T) {
	// ExUnit: test/kogen/stages_test.exs: all specified schema errors name stages rather than silently ignoring metadata
	base := planValue()
	stages := func(p map[string]any) []any { return p["stages"].([]any) }
	with := func(mutate func(p map[string]any)) any {
		p := clone(base).(map[string]any)
		mutate(p)
		return p
	}
	entry := func(i int) map[string]any { return clone(stages(base)[i]).(map[string]any) }
	withStages := func(list ...any) any { return with(func(p map[string]any) { p["stages"] = list }) }
	var invalid []any
	invalid = append(invalid,
		nil, []any{}, map[string]any{},
		with(func(p map[string]any) { delete(p, "version") }),
		with(func(p map[string]any) { p["extra"] = true }),
		with(func(p map[string]any) { p["version"] = 2 }),
		with(func(p map[string]any) { p["version"] = "1" }),
		with(func(p map[string]any) { p["stages"] = []any{} }),
		with(func(p map[string]any) { p["stages"] = []any{entry(0)} }),
		with(func(p map[string]any) { p["stages"] = "stages" }),
		withStages(entry(0), entry(0)),
	)
	bad := []any{nil, "stage", func() any { e := entry(0); e["extra"] = true; return e }()}
	for k := range entry(0) {
		e := entry(0)
		delete(e, k)
		bad = append(bad, e)
	}
	for _, id := range []any{"", "Foundation", "bad_id", "-bad", "bad-", 1} {
		e := entry(0)
		e["id"] = id
		bad = append(bad, e)
	}
	for _, key := range []string{"title", "goal"} {
		for _, value := range []any{"", " \n", 2, []any{}, nil} {
			e := entry(0)
			e[key] = value
			bad = append(bad, e)
		}
	}
	for _, checks := range []any{[]any{}, "true", []any{""}, []any{" \n"}, []any{1}, []any{"true", nil}} {
		e := entry(0)
		e["checks"] = checks
		bad = append(bad, e)
	}
	for _, e := range bad {
		invalid = append(invalid, withStages(e, stages(base)[1]))
	}
	for i, value := range invalid {
		if _, err := project.ParseStages(sectionOf(value)); err == nil || !strings.HasPrefix(err.Error(), "stages:") {
			t.Fatalf("%d %v: %v", i, value, err)
		}
	}
	good := sectionOf(base)
	for _, text := range []string{
		"## Stages\nnot json\n",
		"## Stages\n```json\n{\n```\n",
		good + good,
		good + "```json\n{}\n```\n",
		"## Stages\n```json\n" + jsonText(base) + "\n```\nextra\n",
		// Elixir's encoder writes the float 1.0: not the integer version 1.
		strings.Replace(good, `"version":1`, `"version":1.0`, 1),
	} {
		if _, err := project.ParseStages(text); err == nil || !strings.HasPrefix(err.Error(), "stages:") {
			t.Fatalf("%q: %v", text, err)
		}
	}
	// The error text is the one the Intent's lint gives.
	if _, err := project.ParseStages("## Stages\nnot json\n"); err.Error() != fmt.Sprint("stages: expected one JSON fence with version 1 and at least two unique stages (id, title, goal, nonempty checks); no extra fields") {
		t.Fatal(err)
	}
}

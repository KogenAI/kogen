package shape

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"kogen/project"
	"kogen/verify"
)

// shapeAs runs `kogen intent shape <slug>` with a fresh session.
func (f *shpFx) shapeAs(slug, request string) (int, error) {
	f.t.Helper()
	f.newSession()
	return Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: slug, Request: request, Client: f.Client})
}

func (f *shpFx) allToolOutputs() []string {
	var out []string
	for _, req := range f.Prov.requests() {
		input, _ := req["input"].([]any)
		for _, it := range input {
			m, _ := it.(map[string]any)
			if m["type"] == "function_call_output" {
				s, _ := m["output"].(string)
				out = append(out, s)
			}
		}
	}
	return out
}

func anyContains(texts []string, part string) bool {
	for _, s := range texts {
		if strings.Contains(s, part) {
			return true
		}
	}
	return false
}

func TestShapeInvalidQuestionOptionsGetCorrectionFeedbackAndAreNeverPersisted(t *testing.T) {
	parallel(t)
	// ExUnit: test/integration/contract_regressions_test.exs: SHP-4 invalid question options receive correction feedback and are never persisted
	malformed := []any{
		"malformed array",
		map[string]any{},
		nil,
		[]any{"option"},
		[]any{map[string]any{}},
		[]any{map[string]any{"label": 1}},
		[]any{map[string]any{"label": "One", "recommended": "yes"}},
	}
	valid := []any{
		map[string]any{"question": "Any preference?"},
		map[string]any{"question": "Which display?", "options": []any{}},
		map[string]any{"question": "Which order?", "options": []any{
			map[string]any{"label": "Newest", "recommended": true},
			map[string]any{"label": "Oldest", "recommended": false},
			map[string]any{"label": "Other"},
		}},
	}
	var steps []shpStep
	n := 0
	for _, options := range malformed {
		for i := 0; i < 3; i++ {
			n++
			steps = append(steps, shpSubmit("bad"+string(rune('a'+n)), map[string]any{"questions": []any{map[string]any{"question": "Which display?", "options": options}}}))
		}
	}
	steps = append(steps, shpSubmit("good", map[string]any{"questions": valid}))
	f := newShpFx(t, steps...)
	const slug = "options"
	state := filepath.Join(f.Root, ".kogen/local/shaping/options/state.json")
	request := "Add a display choice."

	for range malformed {
		exit, err := f.shapeAs(slug, request)
		shpWantError(t, err, "shape", "invalid_output", "", 1)
		shpEq(t, "exit", exit, 1)
		if _, err := os.Stat(state); err == nil {
			t.Fatal("an invalid question list is never persisted")
		}
	}
	exit, err := f.shapeAs(slug, request)
	if err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	shpContains(t, "stdout", f.Stdout.String(), "Newest (recommended)")

	b, err := os.ReadFile(state)
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Rounds []map[string]any `json:"rounds"`
	}
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatal(err)
	}
	want := []map[string]any{{"questions": valid, "answers": map[string]any{}}}
	if !reflect.DeepEqual(doc.Rounds, want) {
		t.Fatalf("rounds = %v, want %v", doc.Rounds, want)
	}
	// Seven malformed lists, three attempts each, then the valid one.
	requests := len(f.Prov.requests())
	shpEq(t, "requests", requests, 22)
	if !anyContains(f.allToolOutputs(), "options") {
		t.Fatal("the correction feedback does not mention options")
	}
	// The request text again is no answer (SHP-6): refused without a model request.
	exit, err = f.shapeAs(slug, request)
	shpWantError(t, err, "intent", "answers_invalid", "", 2)
	shpEq(t, "exit", exit, 2)
	shpEq(t, "requests after the refusal", len(f.Prov.requests()), requests)
}

func TestShapeBlockedSubmissionsNeedAnActualProtectedPathAndAReason(t *testing.T) {
	parallel(t)
	// ExUnit: test/integration/contract_regressions_test.exs: SHP-4 blocked submissions require an actual protected path and a reason
	invalid := []any{
		map[string]any{"blocked": map[string]any{"paths": []any{}, "reason": "required edit"}},
		map[string]any{"blocked": map[string]any{"paths": []any{"README.md"}, "reason": "  "}},
		map[string]any{"blocked": map[string]any{"paths": []any{"app.txt"}, "reason": "required edit"}},
	}
	var steps []shpStep
	for i, submission := range invalid {
		id := string(rune('a' + i))
		steps = append(steps, shpSubmit("blocked-"+id, submission), shpSubmit("ask-"+id, map[string]any{"questions": []any{map[string]any{"question": "Continue?"}}}))
	}
	f := newShpFx(t, steps...)
	for i, tc := range []struct{ slug, expected string }{
		{"bad-paths", "blocked.paths must be a non-empty list"},
		{"bad-reason", "blocked.reason must be non-empty text"},
		{"unprotected", "blocked path app.txt is not protected by the current contract"},
	} {
		exit, err := f.shapeAs(tc.slug, "Make a protected change.")
		if err != nil || exit != 5 {
			t.Fatalf("%s: exit %d, err %v", tc.slug, exit, err)
		}
		shpContains(t, tc.slug+" stdout", f.Stdout.String(), "Continue?")
		id := string(rune('a' + i))
		reqs := f.Prov.requests()
		shpContains(t, tc.slug+" feedback", shpOutputs(reqs[len(reqs)-1])["blocked-"+id], tc.expected)
		if f.exists(".kogen/intents/"+tc.slug+"/intent.md") || f.exists(".kogen/local/approvals/"+tc.slug+".json") {
			t.Fatalf("%s: a rejected blocked report leaves no Intent and no approval", tc.slug)
		}
	}
}

func TestShapeBlockedReportRecognizesProtectedPathsMatchedByAGlob(t *testing.T) {
	parallel(t)
	// ExUnit: test/integration/contract_regressions_test.exs: SHP-4 blocked reports recognize protected paths matched by a glob
	f := newShpFx(t, shpSubmit("c1", map[string]any{"blocked": map[string]any{
		"paths":  []any{"settings/check.cfg"},
		"reason": "the requested verification definition cannot be changed in Build",
	}}))
	f.write("settings/check.cfg", "strict=true\n")
	f.write(".kogen/project.yaml", "version: 1\ncommands:\n  checks: [{name: unit, run: 'true'}]\n  acceptance: {run: ./accept.sh, steps_dir: features/steps}\nprotect: ['settings/*.cfg']\n")
	f.git("add", "settings/check.cfg", ".kogen/project.yaml")
	f.git("commit", "-qm", "Configure protected glob")

	exit, err := f.shapeAs("glob-conflict", "Change the protected check definition.")
	if err != nil || exit != 1 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	shpEq(t, "stdout", f.Stdout.String(), "shape/protected_conflict: required edits touch protected files: settings/check.cfg\n"+
		"the requested verification definition cannot be changed in Build\n"+
		"Next: revise the request, or review and commit .kogen/project.yaml outside Build, then shape again; preserve checks and actual check configuration. There is no protected-edit override.\n")
	shpEq(t, "requests", len(f.Prov.requests()), 1)
	if f.exists(".kogen/intents/glob-conflict/intent.md") || f.exists(".kogen/local/approvals/glob-conflict.json") || f.exists(".kogen/local/runs") {
		t.Fatal("a blocked report writes no Intent, no approval and starts no run")
	}
}

// ---- corrections keep what was already submitted (readiness observations) ----

const shpModel = "module is_even {\n var count: int\n action init = count' = 0\n action step = count' = count + 1\n val Safety = count >= 0\n}\n"

// realTools are Node, Quint and Cucumber from the repository's node_modules, or a skip.
func realQuintTools(t *testing.T) verify.Tools {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	node := os.Getenv("KOGEN_NODE")
	tools := verify.Tools{
		Node:     node,
		Quint:    filepath.Join(root, "spec/node_modules/@informalsystems/quint/dist/src/cli.js"),
		Cucumber: filepath.Join(root, "test/acceptance/node_modules"),
	}
	if _, err := os.Stat(tools.Quint); err != nil {
		t.Skip("run npm ci in spec for the real Quint")
	}
	return tools
}

func TestShapeNarrowCorrectionsRetainTheModelAndStepFilesAlreadySubmitted(t *testing.T) {
	parallel(t)
	// ExUnit: test/integration/readiness_observations_test.exs: SHP-4 narrow shaping corrections retain the model and step files already submitted
	tools := realQuintTools(t)
	modelPath := project.ModelPath(shpSlug)
	intent := strings.Replace(shpIntentMD, "Model: not applicable — a pure function without state",
		"Model: "+modelPath+" invariants=Safety seed=7 samples=2 steps=2", 1)
	files := shpFiles()["files"].([]any)
	files[0] = map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": intent}
	proposed := append(files, map[string]any{"path": modelPath, "content": shpModel})
	narrow := map[string]any{"files": proposed[:2]}
	f := newShpFx(t, shpSubmit("c1", map[string]any{"files": proposed}), shpSubmit("c2", narrow), shpSubmit("c3", narrow), shpSubmit("c4", narrow))
	f.newSession()
	exit, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: "Add calc.is_even(n).", Client: f.Client, Tools: tools})
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s\n%s", exit, err, f.Stdout, f.Stderr)
	}
	shpContains(t, "stdout", f.Stdout.String(), "2 fail now")
	shpEq(t, "model", f.read(modelPath), shpModel)
	shpEq(t, "step file", f.read("features/steps/is_even_steps.js"), shpSteps)
	shpEq(t, "acceptance executions (runner check plus one readiness run)", f.runs(), 2)
	if f.exists(".kogen/local/approvals/is-even.json") {
		t.Fatal("shaping approves nothing")
	}
}

func TestShapeLintCorrectionsKeepEarlierArtifactsAndMalformedMixedPayloadsContributeNothing(t *testing.T) {
	parallel(t)
	// ExUnit: test/integration/readiness_observations_test.exs: SHP-4 lint corrections keep earlier artifacts and malformed mixed payloads contribute nothing
	for _, kind := range []string{"unsafe", "duplicate"} {
		t.Run(kind, func(t *testing.T) {
			parallel(t)
			intentPath := ".kogen/intents/is-even/intent.md"
			stepPath := "features/steps/is_even_steps.js"
			unsourced := strings.Replace(shpIntentMD, "- Non-integers raise TypeError. (source: request)\n", "- Non-integers raise TypeError.\n", 1)
			step := map[string]any{"path": stepPath, "content": shpSteps}
			poisoned := map[string]any{"path": stepPath, "content": shpSteps + "\nthrow new Error('unsafe payload leaked');\n"}
			var mixed []any
			if kind == "unsafe" {
				mixed = []any{poisoned, map[string]any{"path": "../outside", "content": "unsafe"}}
			} else {
				mixed = []any{poisoned, step}
			}
			first := shpFiles()
			first["files"].([]any)[0] = map[string]any{"path": intentPath, "content": unsourced}
			fixed := map[string]any{"files": []any{map[string]any{"path": intentPath, "content": shpIntentMD}}}
			f := newShpFx(t, shpSubmit("c1", first), shpSubmit("c2", map[string]any{"files": mixed}), shpSubmit("c3", fixed))
			f.setReport("PASSED", 0)
			exit, err := f.shape("Add calc.is_even(n).")
			if err != nil || exit != 0 {
				t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
			}
			shpContains(t, "stdout", f.Stdout.String(), "2 pass now")
			shpEq(t, "step", f.read(stepPath), shpSteps)
			shpEq(t, "intent", f.read(intentPath), shpIntentMD)
			if _, err := os.Stat(filepath.Join(filepath.Dir(f.Root), "outside")); err == nil {
				t.Fatal("an unsafe path leaked outside the project")
			}
			if !anyContains(f.allToolOutputs(), "decision has no source") {
				t.Fatal("the lint correction was not returned to the shaper")
			}
			// The runner check plus the one readiness execution for the final package.
			shpEq(t, "acceptance executions", f.runs(), 2)
		})
	}
}

func TestShapeAnEarlierStepCannotBeSilentlyAbandonedOutsideTheApprovalBaseline(t *testing.T) {
	parallel(t)
	// ExUnit: test/integration/readiness_observations_test.exs: SHP-4 an earlier step cannot be silently abandoned outside the approval baseline
	oldStep := "features/steps/is_even_steps.js"
	replacement := "features/steps/replacement.js"
	changedIntent := strings.Replace(shpIntentMD, oldStep, replacement, 1)
	changed := map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": changedIntent}
	bothFiles := map[string]any{"files": []any{changed, map[string]any{"path": replacement, "content": shpSteps}}}
	onlyIntent := map[string]any{"files": []any{changed}}
	f := newShpFx(t, shpSubmit("c1", shpFiles()), shpSubmit("c2", bothFiles), shpSubmit("c3", onlyIntent), shpSubmit("c4", onlyIntent))
	exit, err := f.shape("Add calc.is_even(n).")
	e := shpWantError(t, err, "intent", "not_ready", "", 1)
	shpEq(t, "exit", exit, 1)
	lines := strings.Join(e.Lines, "\n")
	shpContains(t, "problems", lines, "proposed artifacts must remain declared")
	shpContains(t, "problems", lines, "same slug or a new one")
	shpEq(t, "old step stays", f.read(oldStep), shpSteps)
	if f.exists(replacement) || f.exists(".kogen/local/approvals/is-even.json") {
		t.Fatal("the replacement step and an approval must not exist")
	}
	// The runner check plus the one readiness execution of the first package.
	shpEq(t, "acceptance executions", f.runs(), 2)
}

func TestShapeFormattingCannotAbandonARetainedExecutableStepOutsideTheBaseline(t *testing.T) {
	parallel(t)
	// ExUnit: test/integration/readiness_observations_test.exs: SHP-4 formatting cannot abandon a retained executable step outside the baseline
	f := newShpFx(t, shpSubmit("c1", shpFiles()), shpSubmit("c2", shpFiles()), shpSubmit("c3", shpFiles()))
	const intent = ".kogen/intents/is-even/intent.md"
	fixer := "grep -v '^- features/steps/is_even_steps.js$' " + intent + " > fix.tmp && mv fix.tmp " + intent
	f.write(".kogen/project.yaml", "version: 1\ncommands:\n  fix: ["+quoteYAML(fixer)+"]\n  acceptance: {run: ./accept.sh, steps_dir: features/steps}\n")
	f.git("add", "-A")
	f.git("commit", "-qm", "fixer abandons the step")
	exit, err := f.shape("Add calc.is_even(n).")
	e := shpWantError(t, err, "intent", "not_ready", "", 1)
	shpEq(t, "exit", exit, 1)
	shpContains(t, "problems", strings.Join(e.Lines, "\n"), "proposed artifacts must remain declared")
	shpEq(t, "step stays", f.read("features/steps/is_even_steps.js"), shpSteps)
	if f.exists(".kogen/local/readiness/is-even.json") || f.exists(".kogen/local/approvals/is-even.json") {
		t.Fatal("no readiness record and no approval")
	}
	// Only the runner check ran; no readiness execution happened for the broken package.
	shpEq(t, "acceptance executions", f.runs(), 1)
}

func quoteYAML(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

func TestShapeReturnsMissingAndOversizedSourceComparisonsForCorrectionBeforeReadiness(t *testing.T) {
	parallel(t)
	// ExUnit: test/integration/readiness_observations_test.exs: native Shape returns missing and oversized source comparisons for correction before readiness
	intent := strings.Replace(shpIntentMD, "- The request asks for is_even; the feature covers it.", "- addressed: source request is_even; contract Tests and acceptance.feature.", 1)
	files := shpFiles()["files"].([]any)
	intentFile := map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": intent}
	missing := strings.Replace(intent, "## Source comparison\n- addressed: source request is_even; contract Tests and acceptance.feature.\n\n", "", 1)
	if missing == intent {
		t.Fatal("the fixture's comparison was not removed")
	}
	oversized := strings.Replace(intent, "## Source comparison\n", "## Source comparison\n"+strings.Repeat("x", 8193), 1)
	files[0] = map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": missing}
	f := newShpFx(t,
		shpSubmit("c1", map[string]any{"files": files}),
		shpSubmit("c2", map[string]any{"files": []any{map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": oversized}}}),
		shpSubmit("c3", map[string]any{"files": []any{intentFile}}))
	f.setReport("PASSED", 0)
	exit, err := f.shape("Add calc.is_even(n).")
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	shpContains(t, "stdout", f.Stdout.String(), "2 pass now")
	shpEq(t, "acceptance executions (runner check plus one readiness run)", f.runs(), 2)
	count := 0
	for _, s := range f.allToolOutputs() {
		if strings.Contains(s, "Source comparison") {
			count++
		}
	}
	if count < 2 {
		t.Fatalf("source comparison feedback returned %d times, want at least 2", count)
	}
	b, err := os.ReadFile(project.SourcePath(f.Root, shpSlug))
	if err != nil {
		t.Fatal(err)
	}
	var receipt map[string]any
	if err := json.Unmarshal(b, &receipt); err != nil {
		t.Fatal(err)
	}
	want, err := project.SourceComparison(f.Root, shpSlug)
	if err != nil {
		t.Fatal(err)
	}
	shpEq(t, "receipt comparison", receipt["comparison"], any(want))
	shpContains(t, "receipt comparison", want, "addressed:")
}

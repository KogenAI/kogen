package shape

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	stdpng "image/png"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen-loop/sys"
	"kogen/project"
	"kogen/verify"
)

func TestShapeOneShotWritesThePackageAndPrintsTheLines(t *testing.T) {
	f := newShpFx(t, shpSubmit("c1", shpFiles()), shpAck("c2"))
	head := f.head()
	exit, err := f.shape("Add calc.is_even(n). Non-integers raise TypeError.")
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\nstdout: %s\nstderr: %s", exit, err, f.Stdout, f.Stderr)
	}
	lines := strings.Split(strings.TrimSuffix(f.Stdout.String(), "\n"), "\n")
	if len(lines) != 7 {
		t.Fatalf("stdout:\n%s", f.Stdout)
	}
	shpEq(t, "intent line", lines[0], "Intent: "+filepath.Join(f.Root, ".kogen/intents/is-even/intent.md"))
	shpEq(t, "feature line", lines[1], "Acceptance test: "+filepath.Join(f.Root, ".kogen/intents/is-even/acceptance.feature"))
	shpEq(t, "steps line", lines[2], "Step files: features/steps/is_even_steps.js (new)")
	shpEq(t, "model line", lines[3], "Model: not applicable — a pure function without state")
	shpEq(t, "scenarios line", lines[4], "Scenarios: 2 (2 fail now, 0 pass now)")
	shpMatch(t, "usage line", lines[5], `^shape gpt-6\.1-sol/high input=\d+ cached=\d+ output=\d+ reasoning=\d+ wall_ms=\d+$`)
	shpEq(t, "next line", lines[6], "Next: kogen intent approve is-even")
	shpMatch(t, "progress", f.Stderr.String(), `kogen: shaping \(request 1, \d+ s\)`)
	shpMatch(t, "progress", f.Stderr.String(), `kogen: shaping \(request 2, \d+ s\)`)
	shpMatch(t, "progress", f.Stderr.String(), `kogen: shape response input=\d+ cached=40 output=30 reasoning=10 wall_ms=\d+ \(\d+ s\)`)
	shpContains(t, "progress", f.Stderr.String(), "kogen: checking readiness (")

	shpEq(t, "feature file", f.read(".kogen/intents/is-even/acceptance.feature"), shpFeature)
	shpEq(t, "step file", f.read("features/steps/is_even_steps.js"), shpSteps)
	shpEq(t, "intent file", f.read(".kogen/intents/is-even/intent.md"), shpIntentMD)
	if f.exists(".kogen/local/approvals/is-even.json") {
		t.Fatal("shaping approves nothing")
	}
	shpEq(t, "HEAD", f.head(), head)
	if !f.exists(".kogen/local/readiness/is-even.json") || !f.exists(".kogen/local/provenance/is-even/current.json") {
		t.Fatal("readiness and source receipts are published")
	}
	if f.exists(".kogen/local/shaping/is-even/state.json") {
		t.Fatal("the pending state is gone")
	}

	reqs := f.Prov.requests()
	shpEq(t, "requests", len(reqs), 2)
	shpContains(t, "request 2", shpOutputs(reqs[1])["c1"], "Readiness observations\nChecked baseline: ")
	shpContains(t, "request 2", shpOutputs(reqs[1])["c1"], "Scenario: Even numbers (acceptance.feature line 2)")
	body := shpBody(reqs[0])
	shpContains(t, "request 1", body, "Add calc.is_even(n). Non-integers raise TypeError.")
	shpContains(t, "request 1", body, "Use the narrowest test that exercises the rule")
	shpContains(t, "request 1", body, "Existing code and tests are evidence of current behavior")
	shpContains(t, "request 1", body, `Context navigation: {"retrieval":"read_file exact bytes and line ranges; list_files directories; search_text exact signatures","revision":{"head":"`+f.head()+`"`)
	if strings.Contains(body, "Context index: ") || strings.Contains(body, "features/steps/calc_steps.js") {
		t.Fatalf("the shaper navigates the checkout through its tools; no index is supplied:\n%s", body)
	}
	shpContains(t, "request 1", body, "Cumulative proposal manifest: ")
	shpContains(t, "request 1", body, "Use focused scratch probes")
	shpEq(t, "tools", strings.Join(shpToolNames(reqs[0]), ", "), "read_file, view_image, list_files, search_text, probe, documentation, submit")
	shpEq(t, "provider request model", reqs[0]["model"], any("gpt-6.1-sol"))
}

func TestShapeWritesEvidenceAndUsageRecords(t *testing.T) {
	f := newShpFx(t, shpSubmit("c1", shpFiles()), shpAck("c2"))
	if exit, err := f.shape("Add calc.is_even(n)."); err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	events := f.events()
	calls := shpNamed(events, "provider_call")
	shpEq(t, "provider calls", len(calls), 2)
	call := calls[0]
	shpEq(t, "status", call["status"], any("completed"))
	shpEq(t, "role", call["role"], any("shape"))
	shpEq(t, "scope", call["scope"], any("main shaping"))
	shpEq(t, "configured model", call["configured_model"], any("gpt-6.1-sol"))
	usage := call["usage"].(map[string]any)
	shpEq(t, "input", usage["input"], any(float64(100)))
	shpEq(t, "cached", usage["cached"], any(float64(40)))
	attempt := call["provider"].(map[string]any)
	shpEq(t, "attempt outcome", attempt["outcome"], any("completed"))
	shpEq(t, "effective model", attempt["effective_model"], any("gpt-6.1-sol"))
	shpEq(t, "attempt provider", attempt["provider"], any("chatgpt"))

	selection := shpNamed(events, "context_selection")
	shpEq(t, "context selections", len(selection), 2)
	// The shaper receives navigation, not an index: nothing is selected or included by Kogen.
	shpEq(t, "included bytes", selection[0]["included_body_bytes"], any(float64(0)))
	shpEq(t, "omitted bytes", selection[0]["omitted_body_bytes"], any(float64(0)))
	shpEq(t, "selection", len(selection[0]["selection"].([]any)), 0)
	totals := shpNamed(events, "usage_totals")
	shpEq(t, "usage totals", len(totals), 1)
	shpEq(t, "total input", totals[0]["known"].(map[string]any)["input"], any(float64(201)))
	shpEq(t, "total output", totals[0]["known"].(map[string]any)["output"], any(float64(60)))
	shpEq(t, "unknown calls", totals[0]["unknown_calls"], any(float64(0)))
	phases := map[string]bool{}
	for _, p := range shpNamed(events, "phase_duration") {
		phases[p["phase"].(string)] = true
	}
	for _, want := range []string{"setup", "preparation", "model", "probe", "readiness", "shape"} {
		if !phases[want] {
			t.Errorf("no phase_duration for %s", want)
		}
	}
	end := shpNamed(events, "session_end")
	shpEq(t, "session ends", len(end), 1)
	shpEq(t, "provider calls recorded", end[0]["provider_calls"], any(float64(2)))
	shpEq(t, "acceptance executions", end[0]["acceptance_executions"], any(float64(1)))

	// The manifest keeps proposals and originals under the shaping folder.
	b, err := os.ReadFile(filepath.Join(f.Root, ".kogen/local/shaping/is-even/proposed/features/steps/is_even_steps.js"))
	if err != nil || string(b) != shpSteps {
		t.Fatalf("proposal copy = %q, %v", b, err)
	}
}

func TestShapeSourceReceiptRecordsRequestAndRounds(t *testing.T) {
	f := newShpFx(t, shpSubmit("c1", shpFiles()), shpAck("c2"))
	if exit, err := f.shapeFrom("Add calc.is_even(n).", filepath.Join(f.Root, "request.md")); err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	b, err := os.ReadFile(filepath.Join(f.Root, ".kogen/local/provenance/is-even/current.json"))
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatal(err)
	}
	request := doc["request"].(map[string]any)
	shpEq(t, "request text", request["text"], any("Add calc.is_even(n)."))
	shpEq(t, "request path", request["source_path"], any(filepath.Join(f.Root, "request.md")))
	shpEq(t, "comparison", doc["comparison"], any("- The request asks for is_even; the feature covers it."))
	origin := doc["origin"].(map[string]any)
	shpEq(t, "origin head", origin["head"], any(f.head()))
}

func TestShapeRefusesWhatItCannotShape(t *testing.T) {
	t.Run("not initialized", func(t *testing.T) {
		f := newShpFx(t)
		os.Remove(filepath.Join(f.Root, ".kogen/project.yaml"))
		exit, err := f.shape("x")
		shpWantError(t, err, "environment", "not_initialized", "has no .kogen/project.yaml; run kogen init", 3)
		shpEq(t, "exit", exit, 3)
	})
	t.Run("acceptance unconfigured", func(t *testing.T) {
		f := newShpFx(t)
		f.write(".kogen/project.yaml", "version: 1\ncommands:\n  acceptance: {run: ./accept.sh, steps_dir: null}\n")
		_, err := f.shape("x")
		shpWantError(t, err, "environment", "acceptance_unconfigured", "set commands.acceptance in .kogen/project.yaml", 3)
		f.write(".kogen/project.yaml", "version: 1\ncommands:\n  acceptance: {run: null, steps_dir: features/steps}\n")
		_, err = f.shape("x")
		shpWantError(t, err, "environment", "acceptance_unconfigured", "", 3)
		shpEq(t, "requests", len(f.Prov.requests()), 0)
	})
	t.Run("not signed in", func(t *testing.T) {
		f := newShpFx(t)
		os.Remove(filepath.Join(f.Home, ".kogen/credentials/chatgpt.json"))
		_, err := f.shape("x")
		shpWantError(t, err, "provider", "login", "not signed in", 4)
		shpEq(t, "requests", len(f.Prov.requests()), 0)
	})
	t.Run("already shaped", func(t *testing.T) {
		f := newShpFx(t)
		f.write(".kogen/intents/is-even/intent.md", shpIntentMD)
		exit, err := f.shape("x")
		shpWantError(t, err, "intent", "exists", "is-even is already shaped; edit its files, or delete .kogen/intents/is-even/ and shape again", 5)
		shpEq(t, "exit", exit, 5)
		shpEq(t, "requests", len(f.Prov.requests()), 0)
	})
	t.Run("a failing setup stops before any request", func(t *testing.T) {
		f := newShpFx(t)
		f.write(".kogen/project.yaml", "version: 1\ncommands:\n  setup: ['echo broken; exit 9']\n  acceptance: {run: ./accept.sh, steps_dir: features/steps}\n")
		f.git("add", "-A")
		f.git("commit", "-qm", "setup")
		_, err := f.shape("x")
		e := shpWantError(t, err, "environment", "setup_failed", "Setup setup-1 failed (status=9).", 3)
		shpContains(t, "setup output", strings.Join(e.Lines, "\n"), "broken")
		shpEq(t, "requests", len(f.Prov.requests()), 0)
	})
	t.Run("an acceptance command that does not start", func(t *testing.T) {
		f := newShpFx(t)
		f.write(".kogen/project.yaml", "version: 1\ncommands:\n  acceptance: {run: 'exit 7', steps_dir: features/steps}\n")
		f.git("add", "-A")
		f.git("commit", "-qm", "broken runner")
		_, err := f.shape("x")
		shpWantError(t, err, "environment", "acceptance_unavailable", "the runner check failed with status 7; fix commands.acceptance.run in .kogen/project.yaml", 3)
		shpEq(t, "requests", len(f.Prov.requests()), 0)
	})
	t.Run("not a git repository", func(t *testing.T) {
		f := newShpFx(t)
		dir := t.TempDir()
		f.newSession()
		_, err := Shape(t.Context(), f.S, ShapeInput{Project: dir, Slug: shpSlug, Request: "x"})
		shpWantError(t, err, "environment", "not_a_git_repo", "", 3)
	})
}

func TestShapeCallsOutAnUntrackedRequestFileAndWarnsAboutEmptyChecks(t *testing.T) {
	f := newShpFx(t, shpSubmit("c1", shpFiles()), shpAck("c2"))
	f.write(".kogen/project.yaml", "version: 1\ncommands:\n  acceptance: {run: ./accept.sh, steps_dir: features/steps}\n")
	f.git("add", "-A")
	f.git("commit", "-qm", "no checks")
	f.write("request.md", "Add calc.is_even(n).")
	exit, err := f.shapeFrom("Add calc.is_even(n).", filepath.Join(f.Root, "request.md"))
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	shpContains(t, "stdout", f.Stdout.String(), "note: request.md is untracked; commit or move it before kogen intent build\n")
	shpContains(t, "stderr", f.Stderr.String(), "warning: commands.checks is empty; Builds will not run your tests\n")

	// A tracked request file, or one outside the project, is not called out.
	if got := untrackedRequestPath(f.Repo.At(f.Root), f.Root, filepath.Join(t.TempDir(), "x.md")); got != "" {
		t.Fatalf("outside request path = %q", got)
	}
	f.git("add", "request.md")
	if got := untrackedRequestPath(f.Repo.At(f.Root), f.Root, filepath.Join(f.Root, "request.md")); got != "" {
		t.Fatalf("staged request path = %q", got)
	}
}

func TestShapeFormatsItsFilesWithTheFixersAndLeavesOthersAlone(t *testing.T) {
	f := newShpFx(t, shpSubmit("c1", shpFiles()), shpAck("c2"))
	f.write(".kogen/project.yaml", "version: 1\ncommands:\n  fix: ['f=features/steps/is_even_steps.js; if [ -f $f ]; then grep -q formatted $f || echo // formatted >> $f; fi; grep -q formatted README.md || echo formatted >> README.md; echo junk > calc.js']\n  acceptance: {run: ./accept.sh, steps_dir: features/steps}\n")
	f.git("add", "-A")
	f.git("commit", "-qm", "fixer")
	readme, calc := f.read("README.md"), f.read("calc.js")
	if exit, err := f.shape("Add calc.is_even(n)."); err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	shpContains(t, "stderr", f.Stderr.String(), "kogen: running fix-1: ")
	shpContains(t, "step file", f.read("features/steps/is_even_steps.js"), "// formatted")
	shpEq(t, "README", f.read("README.md"), readme)
	shpEq(t, "calc.js", f.read("calc.js"), calc)
}

func TestShapeStepFileStates(t *testing.T) {
	// Editing an existing step file shows as edited; the Intent's own steps are new.
	files := shpFiles()
	list := files["files"].([]any)
	list = append(list, map[string]any{"path": "features/steps/calc_steps.js", "content": "Given('a calculator', function () {});\nGiven('the number {int}', function () {});\n"})
	files["files"] = list
	intent := strings.Replace(shpIntentMD, "- features/steps/is_even_steps.js\n", "- features/steps/is_even_steps.js\n- features/steps/calc_steps.js\n", 1)
	list[0] = map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": intent}
	f := newShpFx(t, shpSubmit("c1", files), shpAck("c2"))
	if exit, err := f.shape("Add calc.is_even(n)."); err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stdout)
	}
	shpContains(t, "stdout", f.Stdout.String(), "Step files: features/steps/is_even_steps.js (new), features/steps/calc_steps.js (edited)\n")
	if !strings.Contains(f.git("status", "--porcelain"), "features/steps/calc_steps.js") {
		t.Fatal("the existing step file has uncommitted changes")
	}
}

func TestShapeProviderFailureWritesNoFilesAndExplainsTheRerun(t *testing.T) {
	f := newShpFx(t, shpStep{status: 429, code: "subscription_sharing_usage_limit_exceeded", resets: 1893456000})
	exit, err := f.shapeFrom("Add calc.is_even(n).", "")
	e := shpWantError(t, err, "shape", "provider_failed", "shaping stopped on a provider error that retrying cannot fix; the failed request wrote no files. Fix the account, then rerun kogen intent shape is-even - with the original request on stdin (or the same answers if questions are pending).", 4)
	shpEq(t, "exit", exit, 4)
	_ = e
	shpContains(t, "stdout", f.Stdout.String(), "provider/usage_limit: ChatGPT usage limit reached; it resets at 2030-01-01T00:00:00Z\n  provider failure: ")
	if f.exists(".kogen/intents/is-even") {
		t.Fatal("the failed request wrote no files")
	}

	// A provider error after its retries names the request file, quoted.
	g := newShpFx(t, shpStep{status: 400, code: "invalid_request_error"})
	_, err = g.shapeFrom("Add calc.is_even(n).", filepath.Join(g.Root, "it's.md"))
	got, _ := sys.AsError(err)
	if got == nil || got.Reason != "provider_failed" || !strings.Contains(got.Detail, "after its retries; the failed request wrote no files. Rerun kogen intent shape is-even '"+filepath.Join(g.Root, "it'\\''s.md")+"' with that request file (or the same answers file if questions are pending), or write the Intent yourself.") {
		t.Fatalf("err = %v", err)
	}
}

func TestShapeInterruptEndsWithTheSignalAndKeepsEvidence(t *testing.T) {
	var f *shpFx
	opened := make(chan struct{})
	f = newShpFx(t, shpStep{handler: func(w http.ResponseWriter, r *http.Request) {
		close(opened)
		<-r.Context().Done()
	}})
	go func() {
		<-opened
		f.S.Interrupt("SIGINT")
	}()
	f.newSession()
	exit, err := Shape(t.Context(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: "Add calc.is_even(n).", Client: f.Client})
	var i *sys.Interrupted
	if !shpAsInterrupted(err, &i) || i.Signal != "SIGINT" || exit != 130 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	calls := shpNamed(f.events(), "provider_call")
	if len(calls) != 1 || calls[0]["status"] != "cancelled" {
		t.Fatalf("provider calls = %v", calls)
	}
	shpEq(t, "session ends", len(shpNamed(f.events(), "session_end")), 1)
	if f.exists(".kogen/intents/is-even") {
		t.Fatal("an interrupted shaping writes no Intent")
	}
	_ = project.IntentDir
}

func shpAsInterrupted(err error, target **sys.Interrupted) bool { return errors.As(err, target) }

// ---- questions ----

func shpQuestion(text string, options ...string) map[string]any {
	q := map[string]any{"question": text}
	if len(options) > 0 {
		var list []any
		for i, o := range options {
			opt := map[string]any{"label": o}
			if i == 0 {
				opt["recommended"] = true
			}
			list = append(list, opt)
		}
		q["options"] = list
	}
	return q
}

func shpFilesWithDecisions(decisions ...string) map[string]any {
	intent := strings.Replace(shpIntentMD, "- Non-integers raise TypeError. (source: request)\n", strings.Join(decisions, "\n")+"\n", 1)
	files := shpFiles()
	files["files"].([]any)[0] = map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": intent}
	return files
}

func TestShapeQuestionsPathPrintsNumberedQuestionsAndWritesNothing(t *testing.T) {
	f := newShpFx(t, shpSubmit("q1", map[string]any{"questions": []any{
		shpQuestion("What should is_even do with a non-integer?", "raise TypeError", "return False"),
		shpQuestion("How should it be named?"),
	}}))
	exit, err := f.shape("Add calc.is_even(n).")
	if err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	shpEq(t, "stdout", f.Stdout.String(), "Questions for is-even:\n"+
		"1. What should is_even do with a non-integer?\n"+
		"   a) raise TypeError (recommended)\n"+
		"   b) return False\n"+
		"2. How should it be named?\n"+
		`Answer one per line as <n>: <letter or your words>, e.g. printf '1: a\n2: your words\n' | kogen intent shape is-even -`+"\n"+
		"Or enter all: recommended to use every question's recommended option.\n")
	if f.exists(".kogen/intents/is-even") {
		t.Fatal("questions write no Intent")
	}
	st, err := os.Stat(filepath.Join(f.Root, ".kogen/local/shaping/is-even/state.json"))
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("state file: %v, %v", st, err)
	}
	dir, _ := os.Stat(filepath.Join(f.Root, ".kogen/local/shaping/is-even"))
	shpEq(t, "state dir mode", dir.Mode().Perm(), os.FileMode(0o700))
	var doc map[string]any
	b, _ := os.ReadFile(filepath.Join(f.Root, ".kogen/local/shaping/is-even/state.json"))
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatal(err)
	}
	shpEq(t, "state request", doc["request"], any("Add calc.is_even(n)."))
	shpEq(t, "state source path", doc["source_path"], any("-"))
	shpEq(t, "rounds", len(doc["rounds"].([]any)), 1)
	shpMatch(t, "request 1", shpBody(f.Prov.requests()[0]), `material UI/UX`)
}

func TestShapeAnswersContinueShapingAndTheDecisionRecordsItsSource(t *testing.T) {
	f := newShpFx(t,
		shpSubmit("q1", map[string]any{"questions": []any{shpQuestion("What should is_even do with a non-integer?", "raise TypeError", "return False")}}),
		shpSubmit("c1", shpFilesWithDecisions("- Non-integers raise TypeError. (source: answer 1)")),
		shpAck("c2"))
	if exit, err := f.shape("Add calc.is_even(n)."); err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	exit, err := f.shape("1: a")
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stdout)
	}
	reqs := f.Prov.requests()
	shpEq(t, "requests", len(reqs), 3)
	body := shpBody(reqs[1])
	shpContains(t, "request 2", body, "What should is_even do with a non-integer?")
	shpContains(t, "request 2", body, "answer: 1: a")
	shpContains(t, "request 2", body, "Add calc.is_even(n).")
	shpContains(t, "intent", f.read(".kogen/intents/is-even/intent.md"), "(source: answer 1)")
	if f.exists(".kogen/local/approvals/is-even.json") || f.exists(".kogen/local/shaping/is-even/state.json") {
		t.Fatal("no approval, no pending state")
	}
	receipt, _ := os.ReadFile(filepath.Join(f.Root, ".kogen/local/provenance/is-even/current.json"))
	var doc map[string]any
	if err := json.Unmarshal(receipt, &doc); err != nil {
		t.Fatal(err)
	}
	round := doc["rounds"].([]any)[0].(map[string]any)
	shpEq(t, "answer", round["answers"].(map[string]any)["1"], any("a"))
	shpEq(t, "resolved answer", round["resolved_answers"].(map[string]any)["1"], any("raise TypeError"))
	shpEq(t, "round input", round["input"], any("1: a"))
	shpEq(t, "request recorded is the first request", doc["request"].(map[string]any)["text"], any("Add calc.is_even(n)."))
}

func TestShapeAllRecommendedAnswersEveryQuestion(t *testing.T) {
	f := newShpFx(t,
		shpSubmit("q1", map[string]any{"questions": []any{shpQuestion("First?", "yes", "no"), shpQuestion("Second?", "left", "right")}}),
		shpSubmit("c1", shpFilesWithDecisions("- First. (source: answer 1)", "- Second. (source: answer 2)")),
		shpAck("c2"))
	if exit, err := f.shape("Add calc.is_even(n)."); err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	if exit, err := f.shape("all: recommended"); err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stdout)
	}
	body := shpBody(f.Prov.requests()[1])
	shpContains(t, "request 2", body, "answer: 1: a")
	shpContains(t, "request 2", body, "answer: 2: a")
}

func TestShapePendingQuestionsRejectInputeTheCallerCannotUse(t *testing.T) {
	f := newShpFx(t, shpSubmit("q1", map[string]any{"questions": []any{shpQuestion("First?", "yes", "no"), shpQuestion("Second?", "left", "right")}}))
	if _, err := f.shape("Add calc.is_even(n)."); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ input, reason, detail string }{
		{"not an answer", "answers_invalid", "expected one or more lines as <n>: <letter or your words> (or all: recommended)"},
		{"1: c", "answer_option_invalid", "question 1 has no option c"},
		{"2: z", "answer_option_invalid", "question 2 has no option z"},
	} {
		exit, err := f.shape(tc.input)
		shpWantError(t, err, "intent", tc.reason, tc.detail, 2)
		shpEq(t, "exit for "+tc.input, exit, 2)
	}
	shpEq(t, "requests", len(f.Prov.requests()), 1)

	// Missing answers are asked again, without a model request; free text answers a question.
	exit, err := f.shape("1: a")
	if err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	shpContains(t, "stdout", f.Stdout.String(), "2. Second?\n")
	if strings.Contains(f.Stdout.String(), "1. First?") {
		t.Fatalf("only unanswered questions are printed:\n%s", f.Stdout)
	}
	shpEq(t, "requests", len(f.Prov.requests()), 1)
	// Answers that name a question out of range are dropped; the pending one stays pending.
	exit, err = f.shape("9: whatever")
	if err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	shpContains(t, "stdout", f.Stdout.String(), "2. Second?\n")
	shpEq(t, "requests", len(f.Prov.requests()), 1)
}

func TestShapeAllRecommendedNeedsARecommendedOptionForEveryQuestion(t *testing.T) {
	f := newShpFx(t, shpSubmit("q1", map[string]any{"questions": []any{shpQuestion("First?", "yes", "no"), shpQuestion("Free text?")}}))
	if _, err := f.shape("Add calc.is_even(n)."); err != nil {
		t.Fatal(err)
	}
	_, err := f.shape("all: recommended")
	shpWantError(t, err, "intent", "answers_invalid", "question 2 has no recommended option", 2)
}

// ---- invalid submissions and feedback ----

func TestShapeInvalidSubmitIsRetriedWithFeedbackAndKeepsEarlierProposals(t *testing.T) {
	unsourced := shpFilesWithDecisions("- Non-integers raise TypeError.")
	fixed := map[string]any{"files": []any{
		map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": shpIntentMD},
	}}
	f := newShpFx(t, shpSubmit("c1", unsourced), shpSubmit("c2", fixed), shpAck("c3"))
	exit, err := f.shape("Add calc.is_even(n).")
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	reqs := f.Prov.requests()
	shpEq(t, "requests", len(reqs), 3)
	shpEq(t, "feedback", shpOutputs(reqs[1])["c1"], "invalid submission:\ndecisions: a decision has no source\nEarlier well-formed proposals are retained; submit only corrections.")
	// The corrected intent.md alone completed the package: the earlier feature and steps stayed.
	shpContains(t, "manifest", shpBody(reqs[1]), "features/steps/is_even_steps.js")
	shpEq(t, "feature", f.read(".kogen/intents/is-even/acceptance.feature"), shpFeature)
	shpEq(t, "intent", f.read(".kogen/intents/is-even/intent.md"), shpIntentMD)
	shpContains(t, "readiness feedback", shpOutputs(reqs[2])["c2"], "Readiness observations")
	shpContains(t, "acknowledgment guidance", shpOutputs(reqs[2])["c2"], "After inspecting legitimate missing-feature red")
}

func TestShapeThreeInvalidSubmissionsStopShapingAndWriteNothing(t *testing.T) {
	both := map[string]any{"questions": []any{shpQuestion("Q?")}, "files": shpFiles()["files"]}
	f := newShpFx(t, shpSubmit("c1", both), shpSubmit("c2", both), shpSubmit("c3", both))
	exit, err := f.shape("Add calc.is_even(n).")
	e := shpWantError(t, err, "shape", "invalid_output", "the shaper's output was not a valid Intent after 3 attempts", 1)
	shpEq(t, "exit", exit, 1)
	shpEq(t, "lines", strings.Join(e.Lines, "\n"), "submit takes exactly one of a non-empty questions list, a non-empty files list, or a blocked report")
	shpEq(t, "requests", len(f.Prov.requests()), 3)
	shpEq(t, "feedback", shpOutputs(f.Prov.requests()[1])["c1"],
		"invalid submission:\nsubmit takes exactly one of a non-empty questions list, a non-empty files list, or a blocked report\nNo proposals from this submission were retained; earlier proposals are unchanged.")
	if f.exists(".kogen/intents/is-even") || f.exists("features/steps/is_even_steps.js") {
		t.Fatal("nothing is written before a valid submission")
	}
}

func TestShapeSubmissionEnvelopeProblems(t *testing.T) {
	file := func(path, content any) any { return map[string]any{"path": path, "content": content} }
	for _, tc := range []struct {
		name string
		args any
		want string
	}{
		{"a file outside the Intent and the steps folder", map[string]any{"files": []any{file("calc.js", "x")}},
			"calc.js: shaping may write only .kogen/intents/is-even/{intent.md,acceptance.feature,model.qnt} and step files under features/steps/"},
		{"a path that is not normal", map[string]any{"files": []any{file("features/steps/../steps/a.js", "x")}}, "features/steps/../steps/a.js: paths must be relative and normal"},
		{"an absolute path", map[string]any{"files": []any{file("/etc/passwd", "x")}}, "/etc/passwd: paths must be relative and normal"},
		{"a missing content", map[string]any{"files": []any{map[string]any{"path": "features/steps/a.js"}}}, "every file needs a path and a content string"},
		{"duplicate paths", map[string]any{"files": []any{file("features/steps/a.js", "x"), file("features/steps/a.js", "y")}}, "file paths must be unique; no proposals from this submission were retained"},
		{"empty questions", map[string]any{"questions": []any{}}, "submit takes exactly one of a non-empty questions list, a non-empty files list, or a blocked report"},
		{"a question without text", map[string]any{"questions": []any{map[string]any{"question": " "}}}, "every question needs question text and optional options with string labels and boolean recommended values"},
		{"an option without a label", map[string]any{"questions": []any{map[string]any{"question": "Q?", "options": []any{map[string]any{"recommended": true}}}}}, "every question needs question text and optional options with string labels and boolean recommended values"},
		{"a recommended that is not boolean", map[string]any{"questions": []any{map[string]any{"question": "Q?", "options": []any{map[string]any{"label": "a", "recommended": "yes"}}}}}, "every question needs question text and optional options with string labels and boolean recommended values"},
		{"blocked paths that are not protected", map[string]any{"blocked": map[string]any{"paths": []any{"calc.js"}, "reason": "needed"}}, "blocked path calc.js is not protected by the current contract"},
		{"blocked without reason", map[string]any{"blocked": map[string]any{"paths": []any{".kogen/project.yaml"}}}, "blocked.reason must be non-empty text"},
		{"blocked without paths", map[string]any{"blocked": map[string]any{"paths": []any{}, "reason": "x"}}, "blocked.paths must be a non-empty list"},
		{"blocked with a blank path", map[string]any{"blocked": map[string]any{"paths": []any{" "}, "reason": "x"}}, "blocked.paths must contain non-empty paths"},
		{"blocked beside files", map[string]any{"blocked": map[string]any{"paths": []any{".kogen/project.yaml"}, "reason": "x"}, "files": []any{file("features/steps/a.js", "x")}}, "submit takes exactly one of"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newShpFx(t, shpSubmit("c1", tc.args), shpSubmit("c2", tc.args), shpSubmit("c3", tc.args))
			_, err := f.shape("Add calc.is_even(n).")
			e := shpWantError(t, err, "shape", "invalid_output", "", 1)
			shpContains(t, "problems", strings.Join(e.Lines, "\n"), tc.want)
			if f.exists("features/steps/a.js") || f.exists(".kogen/intents/is-even") {
				t.Fatal("a rejected submission writes nothing")
			}
		})
	}
}

func TestShapeWithoutSubmitIsAskedToEndWithSubmit(t *testing.T) {
	text := shpAnswer(map[string]any{"type": "message", "id": "m", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": "done"}}})
	f := newShpFx(t, text, text, text)
	_, err := f.shape("Add calc.is_even(n).")
	e := shpWantError(t, err, "shape", "invalid_output", "", 1)
	shpEq(t, "lines", strings.Join(e.Lines, "\n"), "the shaper ended without calling submit")
	reqs := f.Prov.requests()
	shpEq(t, "requests", len(reqs), 3)
	shpContains(t, "request 2", shpBody(reqs[1]), "End by calling submit with either questions or files.")
	shpContains(t, "replayed message", shpBody(reqs[1]), "\ndone\n")
}

func TestShapeOnlyOneSubmitCountsPerResponse(t *testing.T) {
	f := newShpFx(t,
		shpAnswer(shpCall("s1", "submit", map[string]any{"questions": []any{shpQuestion("First?", "yes")}}), shpCall("s2", "submit", shpFiles())))
	exit, err := f.shape("Add calc.is_even(n).")
	if err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	if f.exists(".kogen/intents/is-even") {
		t.Fatal("the second submit is ignored")
	}
}

// ---- blocked ----

func TestShapeBlockedReportIsPrintedAndWritesNothing(t *testing.T) {
	f := newShpFx(t, shpSubmit("c1", map[string]any{"blocked": map[string]any{
		"paths": []any{".kogen/project.yaml"}, "reason": "the requested check definition must change"}}))
	exit, err := f.shape("Change the protected check definition.")
	if err != nil || exit != 1 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	shpEq(t, "stdout", f.Stdout.String(), "shape/protected_conflict: required edits touch protected files: .kogen/project.yaml\n"+
		"the requested check definition must change\n"+
		"Next: revise the request, or review and commit .kogen/project.yaml outside Build, then shape again; preserve checks and actual check configuration. There is no protected-edit override.\n")
	if f.exists(".kogen/intents/is-even") || f.exists(".kogen/local/approvals/is-even.json") {
		t.Fatal("a blocked report writes no Intent and no approval")
	}
	body := shpBody(f.Prov.requests()[0])
	for _, want := range []string{"configured protect patterns", "paths currently matched by those patterns", "automatic baseline", "Approval freezes this baseline"} {
		shpContains(t, "request 1", body, want)
	}
	shpEq(t, "tools", strings.Join(shpToolNames(f.Prov.requests()[0]), ", "), "read_file, view_image, list_files, search_text, probe, documentation, submit")
}

func TestShapeBlockedPathsMayBeConfiguredGlobs(t *testing.T) {
	f := newShpFx(t, shpSubmit("c1", map[string]any{"blocked": map[string]any{"paths": []any{"calc.js", "README.md"}, "reason": "needs both"}}))
	f.write(".kogen/project.yaml", "version: 1\ncommands:\n  acceptance: {run: ./accept.sh, steps_dir: features/steps}\nprotect: ['*.js', README.md]\n")
	f.git("add", "-A")
	f.git("commit", "-qm", "protect")
	exit, err := f.shape("Change both.")
	if err != nil || exit != 1 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	shpContains(t, "stdout", f.Stdout.String(), "required edits touch protected files: calc.js, README.md\nneeds both\n")
	body := shpBody(f.Prov.requests()[0])
	shpContains(t, "request", body, `configured protect patterns: ["*.js", "README.md"]`)
	shpContains(t, "request", body, `paths currently matched by those patterns: ["README.md", "calc.js"`)
}

// ---- readiness ----

func TestShapeGreenReadinessNeedsNoAcknowledgment(t *testing.T) {
	f := newShpFx(t, shpSubmit("c1", shpFiles()))
	f.setReport("PASSED", 0)
	exit, err := f.shape("Add calc.is_even(n).")
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stdout)
	}
	shpContains(t, "stdout", f.Stdout.String(), "Scenarios: 2 (0 fail now, 2 pass now)\n")
	shpEq(t, "requests", len(f.Prov.requests()), 1)
}

func TestShapeRedReadinessReturnsObservationsAndAcknowledgmentReusesThem(t *testing.T) {
	f := newShpFx(t, shpSubmit("c1", shpFiles()), shpAck("c2"))
	if exit, err := f.shape("Add calc.is_even(n)."); err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	reqs := f.Prov.requests()
	feedback := shpOutputs(reqs[1])["c1"]
	shpContains(t, "feedback", feedback, "Inspect whether fixtures, inputs and commands reached the intended behavior")
	shpContains(t, "feedback", feedback, "Acceptance exit: 1\n")
	shpContains(t, "skipped feedback", feedback, "Unexercised acceptance steps: 2")
	shpContains(t, "skipped feedback", feedback, "acceptance.feature line 4: Then it is even")
	shpContains(t, "skipped feedback", feedback, "Skipped steps are unexercised; readiness does not prove their behavior or fixture validity.")
	obsPath := filepath.Join(f.Root, ".kogen/local/shaping/is-even/observations-1.txt")
	shpContains(t, "feedback", feedback, "Evidence: "+obsPath)
	b, err := os.ReadFile(obsPath)
	if err != nil || !strings.HasPrefix(string(b), "Readiness observations\nChecked baseline: ") {
		t.Fatalf("observations file: %q, %v", b, err)
	}
	// The acknowledgment reused the checked readiness: the runner ran once for the package.
	shpEq(t, "acceptance runs (runner check, one dry run)", f.runs(), 2)
	shpContains(t, "stdout", f.Stdout.String(), "Scenarios: 2 (2 fail now, 0 pass now)\n")
}

func TestShapeAChangedPackageAfterRedGetsFreshChecks(t *testing.T) {
	changed := map[string]any{"files": []any{map[string]any{"path": "features/steps/is_even_steps.js", "content": shpSteps + "// changed\n"}}}
	f := newShpFx(t, shpSubmit("c1", shpFiles()), shpSubmit("c2", changed), shpAck("c3"))
	if exit, err := f.shape("Add calc.is_even(n)."); err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stdout)
	}
	shpEq(t, "requests", len(f.Prov.requests()), 3)
	shpContains(t, "second feedback", shpOutputs(f.Prov.requests()[2])["c2"], "Readiness observations")
	shpEq(t, "runner check plus two dry runs", f.runs(), 3)
	shpContains(t, "step file", f.read("features/steps/is_even_steps.js"), "// changed")
}

func TestShapeUndefinedStepGoesBackToTheShaperAndStaysNotReady(t *testing.T) {
	f := newShpFx(t, shpSubmit("c1", shpFiles()), shpAck("c2"), shpAck("c3"))
	f.setReport("UNDEFINED", 1)
	exit, err := f.shape("Add calc.is_even(n).")
	e := shpWantError(t, err, "intent", "not_ready", "the Intent is not ready to build", 1)
	shpEq(t, "exit", exit, 1)
	shpEq(t, "lines", strings.Join(e.Lines, "\n"), "acceptance.feature line 3: undefined step: Given the number 4\nacceptance.feature line 4: undefined step: Then it is even\nacceptance.feature line 6: undefined step: Given the number 3\nacceptance.feature line 7: undefined step: Then it is not even")
	reqs := f.Prov.requests()
	shpEq(t, "requests", len(reqs), 3)
	shpEq(t, "feedback", shpOutputs(reqs[1])["c1"], "not ready:\n"+strings.Join(e.Lines, "\n"))
	// The files of the last attempt stay for the caller.
	if !f.exists(".kogen/intents/is-even/acceptance.feature") {
		t.Fatal("the files of a not-ready attempt stay")
	}
	if f.exists(".kogen/local/readiness/is-even.json") {
		t.Fatal("failed readiness is never recorded")
	}
}

func TestShapeAfterANotReadyAttemptTheShaperMayAskQuestions(t *testing.T) {
	f := newShpFx(t, shpSubmit("c1", shpFiles()), shpSubmit("q1", map[string]any{"questions": []any{shpQuestion("Which way?", "this", "that")}}),
		shpSubmit("c2", shpFilesWithDecisions("- Non-integers raise TypeError. (source: answer 1)")), shpAck("c3"))
	f.setReport("UNDEFINED", 1)
	exit, err := f.shape("Add calc.is_even(n).")
	if err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	shpContains(t, "stdout", f.Stdout.String(), "Questions for is-even:\n1. Which way?\n")
	if !f.exists(".kogen/intents/is-even/acceptance.feature") {
		t.Fatal("the files of the not-ready attempt stay")
	}
	// Pending questions are answered before anything else, even though files exist (the
	// already-shaped refusal does not apply); the new conversation starts without proposals.
	f.setReport("FAILED", 1)
	exit, err = f.shape("1: a")
	if err != nil || exit != 0 {
		t.Fatalf("answering with files present: exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	shpContains(t, "intent", f.read(".kogen/intents/is-even/intent.md"), "(source: answer 1)")
	shpContains(t, "manifest names the files of the earlier attempt as originals", shpBody(f.Prov.requests()[2]), "features/steps/is_even_steps.js")
}

func TestShapeRejectsAnAbandonedDeclaredStep(t *testing.T) {
	noSteps := strings.Replace(shpIntentMD, "- features/steps/is_even_steps.js\n", "", 1)
	dropped := map[string]any{"files": []any{map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": noSteps}}}
	restored := map[string]any{"files": []any{map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": shpIntentMD}}}
	f := newShpFx(t, shpSubmit("c1", shpFiles()), shpSubmit("c2", dropped), shpSubmit("c3", restored))
	if exit, err := f.shape("Add calc.is_even(n)."); err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stdout)
	}
	feedback := shpOutputs(f.Prov.requests()[2])["c2"]
	shpContains(t, "feedback", feedback, "proposed artifacts must remain declared: features/steps/is_even_steps.js. Omission cannot delete proposals")
}

// ---- tools and probes ----

func TestShapeProbeRunsOutsideTheProjectAndItsResultIsRecorded(t *testing.T) {
	probe := shpCall("p1", "probe", map[string]any{
		"command": "printf focused; pwd; cat extra.txt",
		"files":   []any{map[string]any{"path": "extra.txt", "content": " scratch\n"}},
	})
	f := newShpFx(t, shpAnswer(probe), shpSubmit("c1", shpFiles()), shpAck("c2"))
	exit, err := f.shape("Add calc.is_even(n).")
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	reqs := f.Prov.requests()
	out := shpOutputs(reqs[1])["p1"]
	shpMatch(t, "probe result", out, `^exit status: 0\ntimed_out: false\nwall: \d+\.\d s\nfocused`)
	shpContains(t, "probe result", out, "kogen-probe-")
	shpContains(t, "probe result", out, " scratch\n")
	if strings.Contains(out, f.Root) {
		t.Fatal("the probe ran outside the project folder")
	}
	shpMatch(t, "progress", f.Stderr.String(), `kogen: probe: printf focused; pwd; cat extra.txt \(\d+ s\)`)
	shpMatch(t, "progress", f.Stderr.String(), `kogen: probe result: exit status: 0; timed_out: false; wall: \d+\.\d s \(\d+ s\)`)
	if f.exists("extra.txt") {
		t.Fatal("the project stays untouched")
	}
	entries, _ := os.ReadDir(f.Tmp)
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), "kogen-probe") {
			t.Fatalf("probe scratch folder left behind: %s", e.Name())
		}
	}
	probes := shpNamed(f.events(), "probe_result")
	shpEq(t, "probe events", len(probes), 1)
	shpEq(t, "status", probes[0]["status"], any("completed"))
	shpEq(t, "timeout", probes[0]["timeout"], any(false))
	shpContains(t, "detail", probes[0]["detail"].(string), "exit status: 0")
	end := shpNamed(f.events(), "session_end")[0]
	shpEq(t, "probe count", end["probe_count"], any(float64(1)))
}

func TestShapeProbeFailuresAreFindingsNotErrors(t *testing.T) {
	f := newShpFx(t, shpAnswer(
		shpCall("p1", "probe", map[string]any{"command": "echo nope; exit 3"}),
		shpCall("p2", "probe", map[string]any{"command": "true", "files": []any{map[string]any{"path": "../escape.txt", "content": "x"}}}),
		shpCall("p3", "probe", map[string]any{"command": "true", "files": []any{map[string]any{"path": "x"}}}),
		shpCall("p4", "probe", map[string]any{}),
	), shpSubmit("q", map[string]any{"questions": []any{shpQuestion("Q?")}}))
	if exit, err := f.shape("Add calc.is_even(n)."); err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	out := shpOutputs(f.Prov.requests()[1])
	shpMatch(t, "failing probe", out["p1"], `^exit status: 3\ntimed_out: false\nwall: \d+\.\d s\nnope\n`)
	shpEq(t, "outside the scratch copy", out["p2"], "error: ../escape.txt is outside the scratch copy")
	shpEq(t, "bad file", out["p3"], "error: every file needs a path and a content string")
	shpEq(t, "no command", out["p4"], "error: argument command must be a string")
	statuses := ""
	for _, p := range shpNamed(f.events(), "probe_result") {
		statuses += p["status"].(string) + ","
	}
	shpEq(t, "probe statuses", statuses, "failed,failed,failed,failed,")
	shpContains(t, "progress", f.Stderr.String(), "kogen: probe result: exit status: 3; timed_out: false; wall: ")
	shpContains(t, "progress", f.Stderr.String(), "kogen: probe result: tool error (")
}

func TestShapeReadOnlyToolsAnswerAsTheModelExpects(t *testing.T) {
	f := newShpFx(t, shpAnswer(
		shpCall("r1", "read_file", map[string]any{"path": "README.md"}),
		shpCall("r2", "list_files", map[string]any{"path": "features"}),
		shpCall("r3", "search_text", map[string]any{"pattern": "function add"}),
		shpCall("r4", "write_file", map[string]any{"path": "x.txt", "content": "x"}),
		shpCall("r5", "shell", map[string]any{"command": "true"}),
		shpCall("r6", "shape_batch", map[string]any{}),
	), shpSubmit("q", map[string]any{"questions": []any{shpQuestion("Q?")}}))
	if exit, err := f.shape("Add calc.is_even(n)."); err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	out := shpOutputs(f.Prov.requests()[1])
	shpEq(t, "read_file", out["r1"], "1\t# Calc\n2\t\n3\tA tiny calculator.")
	shpEq(t, "list_files", out["r2"], "features/steps/calc_steps.js")
	shpEq(t, "search_text", out["r3"], "calc.js:1:function add(a, b) { return a + b }")
	shpEq(t, "write_file is not offered", out["r4"], "error: unknown tool write_file")
	shpEq(t, "shell is not offered", out["r5"], "error: unknown tool shell")
	shpEq(t, "shape_batch is not offered without workers", out["r6"], "error: unknown tool shape_batch")
	if f.exists("x.txt") {
		t.Fatal("the shaper cannot write project files")
	}
}

// ---- images ----

func TestShapeViewImageDeliversPixelsAndRecordsReadAndDelivery(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 2, 2))
	for i := range img.Pix {
		img.Pix[i] = 255
	}
	var png bytes.Buffer
	if err := stdpng.Encode(&png, img); err != nil {
		t.Fatal(err)
	}
	f := newShpFx(t, shpAnswer(shpCall("i1", "view_image", map[string]any{"path": "shot.png"})),
		shpSubmit("q", map[string]any{"questions": []any{shpQuestion("Q?")}}))
	f.write("shot.png", png.String())
	if exit, err := f.shape("Look at shot.png."); err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	input := f.Prov.requests()[1]["input"].([]any)
	var parts []any
	for _, it := range input {
		if m, _ := it.(map[string]any); m["type"] == "function_call_output" {
			parts, _ = m["output"].([]any)
		}
	}
	if len(parts) != 2 || parts[1].(map[string]any)["type"] != "input_image" {
		t.Fatalf("the image output is typed parts: %v", parts)
	}
	events := f.events()
	read := shpNamed(events, "image_read")
	shpEq(t, "image_read events", len(read), 1)
	shpEq(t, "owner", read[0]["owner"], any("shape"))
	shpEq(t, "call", read[0]["call_id"], any("i1"))
	shpEq(t, "path", read[0]["path"], any("shot.png"))
	shpEq(t, "status", read[0]["status"], any("read"))
	delivered := shpNamed(events, "image_delivery")
	shpEq(t, "image_delivery events", len(delivered), 1)
	shpEq(t, "delivery status", delivered[0]["status"], any("completed"))
	shpEq(t, "delivery hash", delivered[0]["sha256"], read[0]["sha256"])
}

// A timeout whose whole-group absence cannot be proven fails the shaping run with a message
// naming it; it is neither a timed-out probe result nor tool feedback for the model.
func TestShapeProbeReportsTimeoutObservationFailure(t *testing.T) {
	restore := verify.ContractProbeRun(func(*sys.Session, string, string, sys.Options) (sys.Result, error) {
		return sys.Result{}, fmt.Errorf("%w: group query failed", sys.ErrTimeoutObservation)
	})
	defer restore()
	f := newShpFx(t, shpAnswer(shpCall("p1", "probe", map[string]any{"command": "sleep 600"})))
	exit, err := f.shape("Add calc.is_even(n).")
	if !errors.Is(err, sys.ErrTimeoutObservation) || exit == 0 {
		t.Fatalf("exit %d, err %v, want a failure wrapping sys.ErrTimeoutObservation", exit, err)
	}
	shpContains(t, "message", err.Error(), "timeout observation failed")
	if len(f.Prov.requests()) != 1 {
		t.Fatalf("the failure was fed back to the model: %d requests", len(f.Prov.requests()))
	}
	probes := shpNamed(f.events(), "probe_result")
	shpEq(t, "probe events", len(probes), 1)
	shpEq(t, "probe status", probes[0]["status"], any("failed"))
	shpEq(t, "timeout", probes[0]["timeout"], nil)
}

// shpAnthropic makes the fixture's shape role an Anthropic one, signed in with a saved key,
// whose Messages endpoint answers every request with a stream that is not a valid message.
func shpAnthropic(f *shpFx) shpStep {
	f.t.Helper()
	f.write(".kogen/project.yaml", f.read(".kogen/project.yaml")+"models:\n  shape: {provider: anthropic, model: claude-sonnet-5-5, effort: high}\n")
	f.git("add", ".kogen/project.yaml")
	f.git("commit", "-qm", "anthropic shape role")
	key, _ := json.Marshal(map[string]any{"provider": "anthropic", "api_key": "sk-ant-FIXTURE-KEY"})
	if err := os.WriteFile(filepath.Join(f.Home, ".kogen", "credentials", "anthropic.json"), key, 0o600); err != nil {
		f.t.Fatal(err)
	}
	return shpStep{handler: func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"PRIVATE-PAYLOAD-MARKER\"}}\n\n")
	}}
}

func TestShapeAnthropicInvalidProviderFailureReachesTheDiagnostic(t *testing.T) {
	f := newShpFx(t)
	step := shpAnthropic(f)
	f.Prov.route = func(map[string]any) *shpStep { return &step }
	exit, err := f.shape("Add calc.is_even(n).")
	shpWantError(t, err, "shape", "provider_failed", "", 4)
	shpEq(t, "exit", exit, 4)
	shpContains(t, "stdout", f.Stdout.String(), "provider/invalid_response: malformed Anthropic completion\n  provider failure: {\"anthropic_invalid\":\"ordering_or_shape\"}\n")
	if strings.Contains(f.Stdout.String()+f.Stderr.String()+err.Error(), "PRIVATE-PAYLOAD-MARKER") {
		t.Fatal("the raw payload leaked")
	}
}

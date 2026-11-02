package shape

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"kogen-loop/sys"
	"kogen/executor"
	"kogen/project"
)

// ---- unit: the mechanical rules and the formats ----

const (
	ccFeaturePath = ".kogen/intents/is-even/acceptance.feature"
	ccIntentPath  = ".kogen/intents/is-even/intent.md"
	ccStepsPath   = "features/steps/is_even_steps.js"
)

func ccEvidence() contractEvidence {
	return contractEvidence{
		scenarios:    []string{"Even numbers", "Outline name"},
		expectations: map[string]string{ccFeaturePath: shpFeature, ccStepsPath: shpSteps},
		intentPath:   ccIntentPath, intent: shpIntentMD,
		tracked: func(path string) (string, bool) {
			text, ok := map[string]string{"cli/code.go": "func Code() {\n\treturn 1\n}\n"}[path]
			return text, ok
		},
	}
}

func ccFinding() contractFinding {
	return contractFinding{
		scenario:    "Even numbers",
		expectation: contractQuote{ccFeaturePath, "Given the number 4"},
		contract:    contractQuote{ccIntentPath, "returns True for even integers"},
		why:         "because",
	}
}

func TestContractEvidenceRule(t *testing.T) {
	parallel(t)
	cases := []struct {
		name   string
		change func(f *contractFinding)
		want   bool
	}{
		{"intent contract", func(*contractFinding) {}, true},
		{"scenario name is normalized", func(f *contractFinding) { f.scenario = "  Even\n numbers " }, true},
		{"outline name", func(f *contractFinding) { f.scenario = "Outline name" }, true},
		{"unknown scenario", func(f *contractFinding) { f.scenario = "Odd" }, false},
		{"step file expectation", func(f *contractFinding) { f.expectation = contractQuote{ccStepsPath, "Given('the number {int}'"} }, true},
		{"expectation path outside the acceptance files", func(f *contractFinding) { f.expectation.path = "README.md" }, false},
		{"expectation quote spaces are normalized", func(f *contractFinding) { f.expectation.quote = "Given\tthe   number\n4" }, true},
		{"expectation quote missing", func(f *contractFinding) { f.expectation.quote = "Given the number 5" }, false},
		{"empty expectation quote", func(f *contractFinding) { f.expectation.quote = " \n" }, false},
		{"empty contract quote", func(f *contractFinding) { f.contract.quote = "" }, false},
		{"contract quote missing from intent.md", func(f *contractFinding) { f.contract.quote = "returns False" }, false},
		{"tracked file contract", func(f *contractFinding) { f.contract = contractQuote{"cli/code.go", "func Code() { return 1 }"} }, true},
		{"tracked file quote missing", func(f *contractFinding) { f.contract = contractQuote{"cli/code.go", "return 2"} }, false},
		{"untracked or package file contract", func(f *contractFinding) { f.contract = contractQuote{ccFeaturePath, "Given the number 4"} }, false},
		{"empty why", func(f *contractFinding) { f.why = " " }, false},
	}
	for _, c := range cases {
		f := ccFinding()
		c.change(&f)
		if got := ccEvidence().evidenced(f); got != c.want {
			t.Errorf("%s: evidenced = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestContractVerdictCounting(t *testing.T) {
	parallel(t)
	mk := func(scenario string, evidenced bool) contractItem {
		f := ccFinding()
		f.scenario = scenario
		return contractItem{finding: f, evidenced: evidenced}
	}
	items := []contractItem{mk("a", true), mk("unevidenced", false), mk("b", true), mk("c", true), mk("d", true)}
	lines := applyVerdicts(items, []contractVerdict{
		{1, "confirmed", "one  is\nconfirmed"}, {1, "refuted", "ignored second verdict"},
		{2, "refuted", "two refuted"}, {3, "confirmed", "three"}, {9, "confirmed", "out of range"}, {0, "confirmed", "zero"},
	})
	// Evidenced findings are numbered 1..4: a, b, c, d. Finding 4 has no counted verdict.
	want := []string{
		"- a | expectation: " + ccFeaturePath + ": Given the number 4 | contract: " + ccIntentPath + ": returns True for even integers | why: because | confirmed: one is confirmed",
		"- c | expectation: " + ccFeaturePath + ": Given the number 4 | contract: " + ccIntentPath + ": returns True for even integers | why: because | confirmed: three",
	}
	if !reflect.DeepEqual(lines, want) {
		t.Fatalf("lines\n%q\nwant\n%q", lines, want)
	}
	verdicts := []string{items[0].verdict, items[1].verdict, items[2].verdict, items[3].verdict, items[4].verdict}
	if !reflect.DeepEqual(verdicts, []string{"confirmed", "", "refuted", "confirmed", "refuted"}) {
		t.Fatalf("verdicts %q", verdicts)
	}
	if items[1].confirmation != nil || items[4].confirmation != nil || items[0].confirmation == nil || *items[0].confirmation != "one  is\nconfirmed" {
		t.Fatalf("confirmations %v %v", items[1].confirmation, items[4].confirmation)
	}
}

func TestContractFormats(t *testing.T) {
	parallel(t)
	f := ccFinding()
	f.scenario = " Even\nnumbers "
	f.expectation.quote = "Given  the number\n4"
	if got, want := contractFindingLine(2, f), "2. scenario: Even numbers | expectation: "+ccFeaturePath+": Given the number 4 | contract: "+ccIntentPath+": returns True for even integers | why: because"; got != want {
		t.Errorf("finding line %q", got)
	}
	wantHead := "Contract check: 2 acceptance expectation(s) contradict the Intent or code it keeps unchanged, so no correct implementation can pass them; nothing was published. " +
		"Correct each expectation, or the Intent where the Intent is what is wrong, so that a correct implementation passes; do not delete or weaken a scenario to pass this check. " +
		"Resubmitting this candidate unchanged is refused again."
	if got := contractHeadline(2); got != wantHead {
		t.Errorf("headline %q", got)
	}
	if got := contractFeedback([]string{"- x", "- y"}); got != wantHead+"\n- x\n- y" {
		t.Errorf("feedback %q", got)
	}
	why := "yes"
	event := contractEvent("abc", "refused", "", 2, 1, 1, []contractItem{
		{finding: f, evidenced: true, verdict: "confirmed", confirmation: &why},
		{finding: f},
	})
	b, _ := json.Marshal(event)
	var got map[string]any
	json.Unmarshal(b, &got)
	items := got["items"].([]any)
	first, second := items[0].(map[string]any), items[1].(map[string]any)
	if got["event"] != "contract_review" || got["package"] != "abc" || got["result"] != "refused" || got["findings"] != float64(2) || got["evidenced"] != float64(1) || got["confirmed"] != float64(1) {
		t.Errorf("event %v", got)
	}
	if _, has := got["reason"]; has {
		t.Errorf("reason on a review that completed: %v", got)
	}
	if first["evidenced"] != true || first["verdict"] != "confirmed" || first["confirmation"] != "yes" || second["evidenced"] != false || second["verdict"] != nil || second["confirmation"] != nil {
		t.Errorf("items %v", items)
	}
	if got := contractEvent("abc", "incomplete", "why", 0, 0, 0, nil); got["reason"] != "why" {
		t.Errorf("incomplete event %v", got)
	}
}

func TestContractPayloadValidation(t *testing.T) {
	parallel(t)
	decode := func(s string) map[string]any {
		var m map[string]any
		d := json.NewDecoder(strings.NewReader(s))
		d.UseNumber()
		if err := d.Decode(&m); err != nil {
			t.Fatal(err)
		}
		return m
	}
	const finding = `{"scenario":"s","expectation":{"path":"p","quote":"q"},"contract":{"path":"p2","quote":"q2"},"why":"w"}`
	for payload, valid := range map[string]bool{
		`{"findings":[]}`:                 true,
		`{"findings":[` + finding + `]}`:  true,
		`{}`:                              false,
		`{"findings":[],"extra":1}`:       false,
		`{"findings":{}}`:                 false,
		`{"findings":[{"scenario":"s"}]}`: false,
		`{"findings":["x"]}`:              false,
		`{"findings":[{"scenario":"s","expectation":{"path":"p"},"contract":{"path":"p","quote":"q"},"why":"w"}]}`:                   false,
		`{"findings":[{"scenario":"s","expectation":{"path":"p","quote":"q","x":1},"contract":{"path":"p","quote":"q"},"why":"w"}]}`: false,
		`{"findings":[{"scenario":1,"expectation":{"path":"p","quote":"q"},"contract":{"path":"p","quote":"q"},"why":"w"}]}`:         false,
		`{"findings":[{"scenario":"s","expectation":{"path":"p","quote":"q"},"contract":{"path":"p","quote":"q"},"why":"w","x":1}]}`: false,
	} {
		if _, why := parseContractReview(decode(payload)); (why == "") != valid {
			t.Errorf("review %s: reason %q, want valid=%v", payload, why, valid)
		}
	}
	for payload, valid := range map[string]bool{
		`{"verdicts":[]}`: true,
		`{"verdicts":[{"finding":1,"verdict":"confirmed","why":"w"}]}`:           true,
		`{"verdicts":[{"finding":2,"verdict":"refuted","why":"w"}]}`:             true,
		`{"verdicts":[{"finding":1.5,"verdict":"confirmed","why":"w"}]}`:         false,
		`{"verdicts":[{"finding":"1","verdict":"confirmed","why":"w"}]}`:         false,
		`{"verdicts":[{"finding":1,"verdict":"maybe","why":"w"}]}`:               false,
		`{"verdicts":[{"finding":1,"verdict":"confirmed"}]}`:                     false,
		`{"verdicts":[{"finding":1,"verdict":"confirmed","why":"w","extra":1}]}`: false,
		`{"verdicts":[],"extra":1}`:                                              false,
		`{"findings":[]}`:                                                        false,
	} {
		if _, why := parseContractConfirmation(decode(payload)); (why == "") != valid {
			t.Errorf("confirmation %s: reason %q, want valid=%v", payload, why, valid)
		}
	}
}

// ---- integration: native Shape with a scripted provider ----

// ccFinding is one finding the contract review returns.
func ccFindingArgs(scenario, expectationQuote, contractQuote string) map[string]any {
	return map[string]any{
		"scenario":    scenario,
		"expectation": map[string]any{"path": ccFeaturePath, "quote": expectationQuote},
		"contract":    map[string]any{"path": ccIntentPath, "quote": contractQuote},
		"why":         "four is even, so the scenario cannot fail for a correct implementation",
	}
}

func ccReview(id string, findings ...any) shpStep {
	if findings == nil {
		findings = []any{}
	}
	return shpAnswer(shpCall(id, SubmitContractReviewTool, map[string]any{"findings": findings}))
}

func ccConfirm(id string, verdicts ...any) shpStep {
	if verdicts == nil {
		verdicts = []any{}
	}
	return shpAnswer(shpCall(id, SubmitContractConfirmationTool, map[string]any{"verdicts": verdicts}))
}

func ccVerdict(n int, verdict, why string) map[string]any {
	return map[string]any{"finding": n, "verdict": verdict, "why": why}
}

func ccIntentOnly(id string) shpStep {
	return shpSubmit(id, map[string]any{"files": []any{map[string]any{"path": ccIntentPath, "content": shpIntentMD}}})
}

// ccCorrected is the whole package with the contradicting number corrected.
func ccCorrected(id string) shpStep {
	return shpSubmit(id, map[string]any{"files": []any{map[string]any{"path": ccFeaturePath, "content": ccCorrectedFeature}}})
}

var ccCorrectedFeature = strings.Replace(shpFeature, "Given the number 4", "Given the number 6", 1)

func ccContradiction() any {
	return ccFindingArgs("Even numbers", "Given  the number\t4", "calc.is_even(n)  returns True\nfor even integers.")
}

const ccRefusal = "Contract check: 1 acceptance expectation(s) contradict the Intent or code it keeps unchanged, so no correct implementation can pass them; nothing was published. " +
	"Correct each expectation, or the Intent where the Intent is what is wrong, so that a correct implementation passes; do not delete or weaken a scenario to pass this check. " +
	"Resubmitting this candidate unchanged is refused again.\n" +
	"- Even numbers | expectation: " + ccFeaturePath + ": Given the number 4 | contract: " + ccIntentPath + ": calc.is_even(n) returns True for even integers. | why: four is even, so the scenario cannot fail for a correct implementation | confirmed: four is even"

func ccInput(req map[string]any) string {
	var out strings.Builder
	input, _ := req["input"].([]any)
	for _, it := range input {
		m, _ := it.(map[string]any)
		if m["role"] == "user" {
			if s, ok := m["content"].(string); ok {
				out.WriteString(s)
			}
		}
	}
	return out.String()
}

func ccKinds(f *shpFx) []string {
	var kinds []string
	for _, r := range f.Prov.allRequests() {
		switch contractKind(r) {
		case SubmitContractReviewTool:
			kinds = append(kinds, "review")
		case SubmitContractConfirmationTool:
			kinds = append(kinds, "confirmation")
		default:
			kinds = append(kinds, "shaper")
		}
	}
	return kinds
}

func ccReviews(f *shpFx) []map[string]any { return shpNamed(f.events(), "contract_review") }

func ccRefused(f *shpFx) []map[string]any {
	var out []map[string]any
	for _, e := range shpNamed(f.events(), "submission_refused") {
		if e["gate"] == contractGate {
			out = append(out, e)
		}
	}
	return out
}

func TestContractCheckRefusesAConfirmedContradictionAndPublishesItsCorrection(t *testing.T) {
	parallel(t)
	f := newShpFx(t, shpSubmit("c1", shpFiles()), ccCorrected("c2"), ccIntentOnly("c3"))
	f.Prov.contract = []shpStep{
		ccReview("r1", ccContradiction()),
		ccConfirm("v1", ccVerdict(1, "confirmed", "four is even")),
	}
	exit, err := f.shape("Add calc.is_even(n).")
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	if got := strings.Join(ccKinds(f), ","); got != "shaper,review,confirmation,shaper,review,shaper" {
		t.Fatalf("requests %s", got)
	}
	shaper := f.Prov.requests()
	shpEq(t, "feedback to submission 1", shpOutputs(shaper[1])["c1"], ccRefusal)
	shpContains(t, "feedback to submission 2", shpOutputs(shaper[2])["c2"], "Readiness observations")
	if strings.Contains(shpOutputs(shaper[2])["c2"], "Contract check:") {
		t.Fatalf("the correction was refused: %s", shpOutputs(shaper[2])["c2"])
	}
	shpEq(t, "feature", f.read(ccFeaturePath), ccCorrectedFeature)
	reviews := ccReviews(f)
	if len(reviews) != 2 || reviews[0]["result"] != "refused" || reviews[1]["result"] != "clean" ||
		reviews[0]["findings"] != float64(1) || reviews[0]["evidenced"] != float64(1) || reviews[0]["confirmed"] != float64(1) || reviews[1]["findings"] != float64(0) {
		t.Fatalf("contract_review events %v", reviews)
	}
	if refused := ccRefused(f); len(refused) != 1 || refused[0]["problems"].([]any)[0] != strings.Split(ccRefusal, "\n")[1] {
		t.Fatalf("submission_refused events %v", refused)
	}
	shpContains(t, "progress", f.Stderr.String(), "kogen: checking the contract")
	shpContains(t, "progress", f.Stderr.String(), "kogen: confirming contract findings")
	if f.exists(".kogen/local/shaping/is-even/" + contractContradictionsFile) {
		t.Fatal("a contradictions record after a ready Shape")
	}
	// The review and the confirmation are their own conversations: offering exactly the read-only
	// tools and their submit tool, each with its own cache identity, instructions and input.
	reqs := f.Prov.contractRequests()
	for i, want := range []struct {
		tool, instructions string
	}{{SubmitContractReviewTool, contractReviewInstructions}, {SubmitContractConfirmationTool, contractConfirmationInstructions}, {SubmitContractReviewTool, contractReviewInstructions}} {
		names := shpToolNames(reqs[i])
		if len(names) != 4 || !reflect.DeepEqual(names[:3], []string{"read_file", "list_files", "search_text"}) || names[3] != want.tool {
			t.Fatalf("request %d tools %v", i, names)
		}
		shpEq(t, "instructions", reqs[i]["instructions"], any(want.instructions))
	}
	keys := cacheKeys(append(reqs, shaper[0]))
	if keys[0] == "" || keys[0] == keys[1] || keys[0] == keys[3] || keys[1] == keys[3] || keys[0] == keys[2] {
		t.Fatalf("cache keys %q", keys)
	}
	review := ccInput(reqs[0])
	for _, want := range []string{
		"Slug: is-even\n\n# Candidate intent.md\n\n" + strings.TrimRight(shpIntentMD, "\n") + "\n\n# Candidate acceptance.feature\n\n" + strings.TrimRight(shpFeature, "\n") +
			"\n\n# Candidate step file features/steps/is_even_steps.js\n\n" + strings.TrimRight(shpSteps, "\n") + "\n\n# Readiness observations\n\nReadiness observations\nChecked baseline: ",
		"Scenario: Even numbers (acceptance.feature line 2)",
	} {
		shpContains(t, "review input", review, want)
	}
	shpEq(t, "confirmation input", ccInput(reqs[1]), review+"\n\n# Findings to verify\n\n1. scenario: Even numbers | expectation: "+ccFeaturePath+
		": Given the number 4 | contract: "+ccIntentPath+": calc.is_even(n) returns True for even integers. | why: four is even, so the scenario cannot fail for a correct implementation")
	if !strings.HasPrefix(ccInput(reqs[2]), "Slug: is-even\n\n# Candidate intent.md") || strings.Contains(ccInput(reqs[2]), "Findings to verify") {
		t.Fatalf("second review input %q", ccInput(reqs[2])[:200])
	}
	// Their tokens join the usage total Shape prints.
	shpContains(t, "usage line", f.Stdout.String(), "shape gpt-6.1-sol/high input=615 cached=240 output=180 reasoning=60 wall_ms=")
}

func TestContractCheckUnevidencedAndRefutedFindingsNeverRefuse(t *testing.T) {
	parallel(t)
	t.Run("unevidenced findings are recorded only", func(t *testing.T) {
		parallel(t)
		f := newShpFx(t, shpSubmit("c1", shpFiles()), ccIntentOnly("c2"))
		f.Prov.contract = []shpStep{ccReview("r1",
			ccFindingArgs("Even numbers", "Given the number 5", "calc.is_even(n) returns True for even integers."),
			ccFindingArgs("No such scenario", "Given the number 4", "calc.is_even(n) returns True for even integers."),
			ccFindingArgs("Even numbers", "Given the number 4", "not in intent.md"))}
		exit, err := f.shape("Add calc.is_even(n).")
		if err != nil || exit != 0 {
			t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
		}
		if got := strings.Join(ccKinds(f), ","); got != "shaper,review,shaper" {
			t.Fatalf("requests %s", got)
		}
		reviews := ccReviews(f)
		if len(reviews) != 1 || reviews[0]["result"] != "clean" || reviews[0]["findings"] != float64(3) || reviews[0]["evidenced"] != float64(0) || reviews[0]["confirmed"] != float64(0) {
			t.Fatalf("events %v", reviews)
		}
		for _, it := range reviews[0]["items"].([]any) {
			if m := it.(map[string]any); m["evidenced"] != false || m["verdict"] != nil || m["confirmation"] != nil {
				t.Fatalf("item %v", m)
			}
		}
		if len(ccRefused(f)) != 0 {
			t.Fatal("an unevidenced finding refused the candidate")
		}
	})
	t.Run("a refuted finding and a finding without a counted verdict do not refuse", func(t *testing.T) {
		parallel(t)
		f := newShpFx(t, shpSubmit("c1", shpFiles()), ccIntentOnly("c2"))
		good := ccContradiction()
		f.Prov.contract = []shpStep{
			ccReview("r1", good, good, ccFindingArgs("Even numbers", "Given the number 4", "not in intent.md")),
			ccConfirm("v1", ccVerdict(1, "refuted", "a correct implementation can pass it"), ccVerdict(3, "confirmed", "no such finding"), ccVerdict(2, "refuted", "late")),
		}
		exit, err := f.shape("Add calc.is_even(n).")
		if err != nil || exit != 0 {
			t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
		}
		if got := strings.Join(ccKinds(f), ","); got != "shaper,review,confirmation,shaper" {
			t.Fatalf("requests %s", got)
		}
		// Only the two evidenced findings are sent to the confirmation, numbered from 1.
		shpContains(t, "confirmation", ccInput(f.Prov.contractRequests()[1]), "\n\n# Findings to verify\n\n1. scenario: Even numbers")
		shpContains(t, "confirmation", ccInput(f.Prov.contractRequests()[1]), "\n2. scenario: Even numbers")
		if strings.Contains(ccInput(f.Prov.contractRequests()[1]), "3. scenario") {
			t.Fatal("an unevidenced finding was sent to confirmation")
		}
		reviews := ccReviews(f)
		if len(reviews) != 1 || reviews[0]["result"] != "clean" || reviews[0]["findings"] != float64(3) || reviews[0]["evidenced"] != float64(2) || reviews[0]["confirmed"] != float64(0) {
			t.Fatalf("events %v", reviews)
		}
		items := reviews[0]["items"].([]any)
		if items[0].(map[string]any)["verdict"] != "refuted" || items[1].(map[string]any)["verdict"] != "refuted" || items[1].(map[string]any)["confirmation"] != "late" || items[2].(map[string]any)["verdict"] != nil {
			t.Fatalf("items %v", items)
		}
	})
}

func TestContractCheckReadOnlyToolRoundsAndIncompleteReviews(t *testing.T) {
	parallel(t)
	read := func(id string) map[string]any { return shpCall(id, "read_file", map[string]any{"path": "README.md"}) }
	text := shpAnswer(map[string]any{"type": "message", "id": "m", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": "No contradiction."}}})
	manyReads := func(prefix string, n int) shpStep {
		var calls []map[string]any
		for i := 0; i < n; i++ {
			calls = append(calls, read(fmt.Sprintf("%s-%d", prefix, i)))
		}
		return shpAnswer(calls...)
	}
	var eight, thirtyTwo []shpStep
	for i := 0; i < 9; i++ {
		eight = append(eight, manyReads(fmt.Sprintf("e%d", i), 1))
	}
	for i := 0; i < 8; i++ {
		thirtyTwo = append(thirtyTwo, manyReads(fmt.Sprintf("t%d", i), 5))
	}
	cases := []struct {
		name     string
		steps    []shpStep
		reason   string
		requests int // contract requests made
	}{
		{"a text-only answer", []shpStep{text}, "the answer called no tool", 1},
		{"an invalid payload", []shpStep{shpAnswer(shpCall("r1", SubmitContractReviewTool, map[string]any{"findings": []any{map[string]any{"scenario": "x"}}}))}, "invalid " + SubmitContractReviewTool + " payload", 1},
		{"an extra payload field", []shpStep{shpAnswer(shpCall("r1", SubmitContractReviewTool, map[string]any{"findings": []any{}, "note": "x"}))}, "invalid " + SubmitContractReviewTool + " payload", 1},
		{"the submit call beside another call", []shpStep{shpAnswer(read("a"), shpCall("r1", SubmitContractReviewTool, map[string]any{"findings": []any{}}))}, "the answer called other tools besides " + SubmitContractReviewTool, 1},
		{"the request bound", eight, "the 8 request bound was reached", 8},
		{"the tool call bound", thirtyTwo, "the 32 read-only tool call bound was reached", 7},
		{"an invalid confirmation", []shpStep{ccReview("r1", ccContradiction()), shpAnswer(shpCall("v1", SubmitContractConfirmationTool, map[string]any{"verdicts": []any{ccVerdict(1, "maybe", "x")}}))}, "invalid " + SubmitContractConfirmationTool + " payload", 2},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			parallel(t)
			f := newShpFx(t, shpSubmit("c1", shpFiles()), ccIntentOnly("c2"))
			f.Prov.contract = c.steps
			exit, err := f.shape("Add calc.is_even(n).")
			if err != nil || exit != 0 {
				t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
			}
			if n := len(f.Prov.contractRequests()); n != c.requests {
				t.Fatalf("%d contract requests, want %d", n, c.requests)
			}
			if got := strings.Join(ccKinds(f), ","); !strings.HasPrefix(got, "shaper,review") || !strings.HasSuffix(got, ",shaper") {
				t.Fatalf("requests %s", got)
			}
			reviews := ccReviews(f)
			if len(reviews) != 1 || reviews[0]["result"] != "incomplete" || !strings.Contains(reviews[0]["reason"].(string), c.reason) || reviews[0]["confirmed"] != float64(0) {
				t.Fatalf("events %v", reviews)
			}
			shpContains(t, "progress", f.Stderr.String(), "kogen: contract check incomplete ("+c.reason)
			shpContains(t, "progress", f.Stderr.String(), "); the candidate goes on")
			if len(ccRefused(f)) != 0 {
				t.Fatal("an incomplete review refused the candidate")
			}
			shpContains(t, "published", f.Stdout.String(), "Next: kogen intent approve is-even")
		})
	}

	t.Run("read-only tool rounds continue the same conversation", func(t *testing.T) {
		parallel(t)
		f := newShpFx(t, shpSubmit("c1", shpFiles()), ccIntentOnly("c2"))
		f.Prov.contract = []shpStep{
			shpAnswer(shpCall("t1", "read_file", map[string]any{"path": "README.md"}), shpCall("t2", "list_files", map[string]any{})),
			shpAnswer(shpCall("t3", "search_text", map[string]any{"pattern": "calc"})),
			ccReview("r1"),
		}
		if exit, err := f.shape("Add calc.is_even(n)."); err != nil || exit != 0 {
			t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
		}
		reqs := f.Prov.contractRequests()
		if len(reqs) != 3 {
			t.Fatalf("%d contract requests", len(reqs))
		}
		outputs := shpOutputs(reqs[2])
		shpContains(t, "read_file result", outputs["t1"], "A tiny calculator.")
		if outputs["t2"] == "" || outputs["t3"] == "" {
			t.Fatalf("tool results %v", outputs)
		}
		keys := cacheKeys(reqs)
		if keys[0] == "" || keys[0] != keys[1] || keys[1] != keys[2] {
			t.Fatalf("cache keys %q", keys)
		}
		if reviews := ccReviews(f); len(reviews) != 1 || reviews[0]["result"] != "clean" {
			t.Fatalf("events %v", reviews)
		}
	})

	t.Run("a request above the ceiling ends the review incomplete without a request", func(t *testing.T) {
		parallel(t)
		f := newShpFx(t)
		stateDir := filepath.Join(f.Root, ".kogen/local/shaping", shpSlug)
		ev, err := NewEvidence(stateDir, shpSlug)
		if err != nil {
			t.Fatal(err)
		}
		defer ev.Finish()
		sh := &shaping{s: f.S, repo: f.Repo, root: f.Root, slug: shpSlug, ev: ev, client: f.Client, role: ccRole(t, f), contractSessions: map[string]int{}}
		args, why, err := sh.contractCall(context.Background(), "review", strings.Repeat("x", 600000))
		if err != nil || args != nil || !strings.Contains(why, "is above the 524288-byte ceiling") {
			t.Fatalf("args %v, reason %q, err %v", args, why, err)
		}
		if n := len(f.Prov.allRequests()); n != 0 {
			t.Fatalf("%d provider requests", n)
		}
	})
}

// ---- integration: not ready, the record and approval ----

func TestContractCheckKeptContradictionEndsNotReadyAndApprovalRefusesIt(t *testing.T) {
	parallel(t)
	f := newShpFx(t, shpSubmit("c1", shpFiles()), ccIntentOnly("c2"), ccIntentOnly("c3"))
	f.Prov.contract = []shpStep{ccReview("r1", ccContradiction()), ccConfirm("v1", ccVerdict(1, "confirmed", "four is even"))}
	exit, err := f.shape("Add calc.is_even(n).")
	e := shpWantError(t, err, "intent", "not_ready", "the Intent is not ready to build", 1)
	if exit != 1 {
		t.Fatalf("exit %d", exit)
	}
	item := strings.Split(ccRefusal, "\n")[1]
	if !reflect.DeepEqual(e.Lines, []string{item}) {
		t.Fatalf("lines %q", e.Lines)
	}
	// The unchanged resubmissions are refused again with the same text: no new review, no new
	// readiness run, no new contract_review event, only their submission_refused events.
	if got := strings.Join(ccKinds(f), ","); got != "shaper,review,confirmation,shaper,shaper" {
		t.Fatalf("requests %s", got)
	}
	shaper := f.Prov.requests()
	shpEq(t, "feedback to submission 1", shpOutputs(shaper[1])["c1"], ccRefusal)
	shpEq(t, "feedback to submission 2", shpOutputs(shaper[2])["c2"], ccRefusal)
	if n := len(ccReviews(f)); n != 1 {
		t.Fatalf("%d contract_review events", n)
	}
	if n := len(ccRefused(f)); n != 3 {
		t.Fatalf("%d submission_refused events with the gate", n)
	}
	observations, _ := filepath.Glob(filepath.Join(f.Root, ".kogen/local/shaping/is-even/observations-*.txt"))
	if len(observations) != 1 {
		t.Fatalf("readiness wrote %v", observations)
	}
	// The files stay, and the record binds the lines to the hash of the package left on disk.
	if !f.exists(ccIntentPath) {
		t.Fatal("the package was not kept")
	}
	recordPath := filepath.Join(f.Root, ".kogen/local/shaping/is-even", contractContradictionsFile)
	info, err := os.Stat(recordPath)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("record %v %v", info, err)
	}
	var rec contractContradictions
	b, _ := os.ReadFile(recordPath)
	if err := json.Unmarshal(b, &rec); err != nil || rec.SHA256 != ccHash(t, f) || !reflect.DeepEqual(rec.Lines, []string{item}) || !strings.HasSuffix(string(b), "}\n") {
		t.Fatalf("record %q (%v)", b, err)
	}

	approve := func(hash string) (int, string, error) {
		s := sys.NewWith(f.Env, f.Root)
		var out strings.Builder
		s.Stdout, s.Stderr = &out, &out
		exit, err := Approve(context.Background(), s, ApproveInput{Project: f.Root, Slug: shpSlug, Hash: hash})
		return exit, out.String(), err
	}
	for _, hash := range []string{"", rec.SHA256} {
		exit, _, err := approve(hash)
		e := shpWantError(t, err, "intent", "contract_contradicts", "Shape's contract check found acceptance expectations that contradict the Intent or code it keeps unchanged; correct the Intent's files, or shape it again with kogen intent shape is-even <request-file>", 1)
		if exit != 1 || !reflect.DeepEqual(e.Lines, []string{item}) {
			t.Fatalf("approve %q: exit %d lines %q", hash, exit, e.Lines)
		}
		if f.exists(".kogen/local/approvals/is-even.json") {
			t.Fatal("an approval marker was written")
		}
	}

	// A record of another hash (the files were edited) or one that does not parse has no effect.
	f.write(ccIntentPath, shpIntentMD+"\nNothing else changes.\n")
	if exit, out, err := approve(""); err != nil || exit != 5 {
		t.Fatalf("hand-corrected card: exit %d, err %v\n%s", exit, err, out)
	}
	f.write(ccIntentPath, shpIntentMD)
	if err := os.WriteFile(recordPath, []byte("not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if exit, out, err := approve(""); err != nil || exit != 5 {
		t.Fatalf("unparseable record: exit %d, err %v\n%s", exit, err, out)
	}

	// A Shape of the slug that ends ready removes the record.
	if err := os.WriteFile(recordPath, b, 0o600); err != nil {
		t.Fatal(err)
	}
	os.RemoveAll(filepath.Join(f.Root, ".kogen/intents/is-even"))
	os.Remove(filepath.Join(f.Root, ccStepsPath))
	f.Prov.mu.Lock()
	f.Prov.seq = append(f.Prov.seq, shpSubmit("d1", shpFiles()), ccIntentOnly("d2"))
	f.Prov.mu.Unlock()
	if exit, err := f.shape("Add calc.is_even(n)."); err != nil || exit != 0 {
		t.Fatalf("ready shape: exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	if f.exists(".kogen/local/shaping/is-even/" + contractContradictionsFile) {
		t.Fatal("a ready Shape left the record")
	}
}

func TestContractCheckLastRefusalByAnotherGateWritesNoRecord(t *testing.T) {
	parallel(t)
	invalid := shpAnswer(shpCall("c3", "submit", map[string]any{"files": []any{}}))
	f := newShpFx(t, shpSubmit("c1", shpFiles()), ccIntentOnly("c2"), invalid)
	f.Prov.contract = []shpStep{ccReview("r1", ccContradiction()), ccConfirm("v1", ccVerdict(1, "confirmed", "four is even"))}
	_, err := f.shape("Add calc.is_even(n).")
	if _, ok := sys.AsError(err); !ok {
		t.Fatalf("err %v", err)
	}
	if f.exists(".kogen/local/shaping/is-even/" + contractContradictionsFile) {
		t.Fatal("a record although the last refusal was by another gate")
	}
}

func ccRole(t *testing.T, f *shpFx) project.Role {
	t.Helper()
	cfg, err := project.LoadConfig(f.Root)
	if err != nil {
		t.Fatal(err)
	}
	return cfg.Models["shape"]
}

func ccHash(t *testing.T, f *shpFx) string {
	t.Helper()
	sh := &shaping{root: f.Root, slug: shpSlug}
	cfg, err := project.LoadConfig(f.Root)
	if err != nil {
		t.Fatal(err)
	}
	sh.cfg = cfg
	hash, err := sh.packageHash()
	if err != nil {
		t.Fatal(err)
	}
	return hash
}

// ---- integration: external Shape ----

func TestContractCheckExternalShape(t *testing.T) {
	parallel(t)
	review := result(map[string]any{"findings": []any{ccContradiction()}})
	confirm := result(map[string]any{"verdicts": []any{ccVerdict(1, "confirmed", "four is even")}})
	clean := result(map[string]any{"findings": []any{}})
	correction := map[string]any{"files": []any{map[string]any{"path": ccFeaturePath, "content": ccCorrectedFeature}}}
	ack := map[string]any{"files": []any{map[string]any{"path": ccIntentPath, "content": shpIntentMD}}}

	t.Run("one read-only session per review and confirmation; the refusal is the next round's feedback", func(t *testing.T) {
		parallel(t)
		f := newShpFx(t)
		f.useExternalShape(6)
		x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){result(shpFiles()), result(correction), result(ack)},
			contract: []func(int, string) (executor.RoundResult, error){review, confirm, clean}}
		exit, err := f.shapeWith(x, "Add calc.is_even(n).")
		if err != nil || exit != 0 {
			t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
		}
		noNativeRequests(t, f)
		if len(x.contractStarts) != 3 || len(x.starts) != 1 {
			t.Fatalf("%d contract sessions, %d shaper sessions", len(x.contractStarts), len(x.starts))
		}
		for i, dir := range []string{"executor-contract-review-1", "executor-contract-confirm-1", "executor-contract-review-2"} {
			task := x.contractStarts[i]
			if filepath.Base(task.Dir) != dir || task.Role != executor.RoleShape {
				t.Fatalf("session %d: %s (%s)", i, task.Dir, task.Role)
			}
		}
		shpContains(t, "review schema", string(x.contractStarts[0].Schema), `"findings"`)
		shpContains(t, "confirmation schema", string(x.contractStarts[1].Schema), `"verdicts"`)
		shpContains(t, "review task", x.contractStarts[0].Brief.Stable, contractReviewInstructions+"\n\nSlug: is-even\n\n# Candidate intent.md")
		shpContains(t, "confirmation task", x.contractStarts[1].Brief.Stable, contractConfirmationInstructions+"\n\nSlug: is-even\n\n# Candidate intent.md")
		shpContains(t, "confirmation task", x.contractStarts[1].Brief.Stable, "\n\n# Findings to verify\n\n1. scenario: Even numbers")
		shpContains(t, "feedback", x.inputs[1].Feedback, ccRefusal)
		shpContains(t, "feedback", x.inputs[2].Feedback, "Readiness observations")
		reviews := ccReviews(f)
		if len(reviews) != 2 || reviews[0]["result"] != "refused" || reviews[1]["result"] != "clean" {
			t.Fatalf("events %v", reviews)
		}
		// The sessions' rounds count in the usage line.
		shpMatch(t, "usage line", f.Stdout.String(), `shape claude-opus-5-5/xhigh claude-code 6 round\(s\) wall_ms=\d+`)
	})

	t.Run("a session that ends without a result is incomplete and the candidate goes on", func(t *testing.T) {
		parallel(t)
		f := newShpFx(t)
		f.useExternalShape(6)
		x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){result(shpFiles()), result(ack)},
			contract: []func(int, string) (executor.RoundResult, error){func(int, string) (executor.RoundResult, error) {
				return executor.RoundResult{}, executor.Fail(executor.ReasonProtocol, "no structured result")
			}}}
		exit, err := f.shapeWith(x, "Add calc.is_even(n).")
		if err != nil || exit != 0 {
			t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
		}
		reviews := ccReviews(f)
		if len(reviews) != 1 || reviews[0]["result"] != "incomplete" || reviews[0]["reason"] != "the session ended without a result" {
			t.Fatalf("events %v", reviews)
		}
	})
}

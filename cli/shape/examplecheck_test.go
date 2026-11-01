package shape

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"kogen-loop/sys"
	"kogen/executor"
	"kogen/project"
)

const exampleHeadline = "Example check: %d acceptance example(s) contradict the Intent's rules; nothing was published. Correct the expected value, the input or the rule so that each expected value follows from its input under the Intent's rules; do not remove or weaken an example to pass this check."

const (
	exampleRule     = "calc.is_even(n) returns True for even integers."
	exampleScenario = "Even numbers"
)

// exampleItemFor is the check item of the shpFeature example, deriving what it is given.
func exampleItemFor(derived string) map[string]any {
	return map[string]any{"scenario": exampleScenario, "input": "the number 4", "expected": "it is even",
		"rule": exampleRule, "derived": derived, "why": "4 is divisible by 2"}
}

func exampleAnswer(items ...map[string]any) map[string]any {
	list := make([]any, len(items))
	for i, it := range items {
		list[i] = it
	}
	return map[string]any{"examples": list}
}

func exampleLine(derived string) string {
	return "- scenario: " + exampleScenario + " | input: the number 4 | expected: it is even | rule: " + exampleRule + " | derived: " + derived + " | why: 4 is divisible by 2"
}

// scriptChecks makes the provider answer the example check calls from answers in order (the
// last repeats).
func scriptChecks(f *shpFx, answers ...map[string]any) {
	var mu sync.Mutex
	n := 0
	f.Prov.route = func(req map[string]any) *shpStep {
		if !isExampleCheck(req) {
			return nil
		}
		mu.Lock()
		defer mu.Unlock()
		a := answers[min(n, len(answers)-1)]
		n++
		step := shpAnswer(shpCall(fmt.Sprintf("check-%d", n), SubmitExampleCheckTool, a))
		return &step
	}
}

func TestExampleOutcome(t *testing.T) {
	parallel(t)
	request := "Render  seconds\nas words."
	intent := "Rule:  H is seconds div 3600.\n"
	feature := "Scenario: 5430 seconds\n  Given the input '5430'\n  Then the output is '1 hour, 30 minutes'\n"
	item := func(mod func(*exampleItem)) exampleItem {
		it := exampleItem{scenario: "5430 seconds", input: "5430", expected: "1 hour,\n30 minutes", rule: "H is seconds   div 3600.", derived: " 1 hour, 30  minutes ", why: "w"}
		mod(&it)
		return it
	}
	cases := []struct {
		name   string
		item   exampleItem
		result string
	}{
		{"normalized quotes and derived follow", item(func(*exampleItem) {}), "follows"},
		{"the rule may come from the request", item(func(it *exampleItem) { it.rule = "Render seconds as words" }), "follows"},
		{"a different derived value contradicts", item(func(it *exampleItem) { it.derived = "1 hour, 1 minute" }), "contradicts"},
		{"empty scenario is unquoted", item(func(it *exampleItem) { it.scenario = " \n" }), "unquoted"},
		{"empty input is unquoted", item(func(it *exampleItem) { it.input = "" }), "unquoted"},
		{"input not in the feature is unquoted", item(func(it *exampleItem) { it.input = "5431" }), "unquoted"},
		{"expected not in the feature is unquoted", item(func(it *exampleItem) { it.expected = "2 hours"; it.derived = "1 hour" }), "unquoted"},
		{"scenario not in the feature is unquoted", item(func(it *exampleItem) { it.scenario = "other" }), "unquoted"},
		{"empty rule is unquoted", item(func(it *exampleItem) { it.rule = "" }), "unquoted"},
		{"rule in neither text is unquoted", item(func(it *exampleItem) { it.rule = "H is seconds div 60"; it.derived = "x" }), "unquoted"},
	}
	for _, c := range cases {
		event, lines := exampleOutcome([]exampleItem{c.item}, request, intent, feature)
		items := event["items"].([]any)
		if got := items[0].(map[string]any)["result"]; got != c.result {
			t.Errorf("%s: result %v, want %s", c.name, got, c.result)
		}
		if (lines != nil) != (c.result == "contradicts") {
			t.Errorf("%s: lines %q", c.name, lines)
		}
	}

	// Counts, order, headline N and the line format with the values as returned.
	a := item(func(it *exampleItem) { it.derived = "x"; it.why = "first" })
	b := item(func(*exampleItem) {})
	c := item(func(it *exampleItem) { it.input = "nope" })
	d := item(func(it *exampleItem) { it.derived = "y"; it.scenario = "5430   seconds" })
	event, lines := exampleOutcome([]exampleItem{a, b, c, d}, request, intent, feature)
	if event["event"] != "example_check" || event["follows"] != 1 || event["contradicts"] != 2 || event["unquoted"] != 1 {
		t.Errorf("event %v", event)
	}
	want := []string{
		fmt.Sprintf(exampleHeadline, 2),
		"- scenario: 5430 seconds | input: 5430 | expected: 1 hour,\n30 minutes | rule: H is seconds   div 3600. | derived: x | why: first",
		"- scenario: 5430   seconds | input: 5430 | expected: 1 hour,\n30 minutes | rule: H is seconds   div 3600. | derived: y | why: w",
	}
	if !slices.Equal(lines, want) {
		t.Errorf("lines %q\nwant %q", lines, want)
	}
	for i, r := range []string{"contradicts", "follows", "unquoted", "contradicts"} {
		if got := event["items"].([]any)[i].(map[string]any)["result"]; got != r {
			t.Errorf("item %d result %v, want %s", i, got, r)
		}
	}

	// No items: an event with zero counts and no feedback.
	event, lines = exampleOutcome(nil, request, intent, feature)
	if lines != nil || event["follows"] != 0 || event["contradicts"] != 0 || event["unquoted"] != 0 {
		t.Errorf("empty: %v %q", event, lines)
	}
}

func TestParseExampleCheck(t *testing.T) {
	parallel(t)
	ok := exampleItemFor("it is even")
	if items, err := parseExampleCheck(exampleAnswer(exampleItemFor("it is even"))); err != nil || len(items) != 1 || items[0].derived != "it is even" {
		t.Fatalf("valid payload: %v %v", items, err)
	}
	extra := map[string]any{"examples": []any{}, "other": 1}
	missing := map[string]any{"examples": []any{map[string]any{"scenario": "s"}}}
	notString := exampleItemFor("x")
	notString["why"] = 3
	withExtra := exampleItemFor("x")
	withExtra["extra"] = "y"
	for name, args := range map[string]map[string]any{
		"no examples":       {},
		"extra field":       extra,
		"not a list":        {"examples": "x"},
		"item not object":   {"examples": []any{"x"}},
		"missing field":     missing,
		"field not string":  exampleAnswer(notString),
		"extra item field":  exampleAnswer(withExtra),
		"null list":         {"examples": nil},
		"valid then broken": {"examples": []any{ok, 7}},
	} {
		_, err := parseExampleCheck(args)
		shpWantError(t, err, "shape", "example_check_invalid", "", 1)
		if err != nil && !strings.Contains(err.Error(), "the example check answer is not a valid submit_example_check payload (") {
			t.Errorf("%s: %v", name, err)
		}
	}
}

// TestShapeExampleCheckContradictionGoesBack: a contradicting candidate publishes nothing and
// goes back with the exact feedback; the corrected (here: re-derived) candidate is checked
// again and published. The check request carries only the request and the candidate files and
// offers only submit_example_check.
func TestShapeExampleCheckContradictionGoesBack(t *testing.T) {
	parallel(t)
	f := newShpFx(t, shpSubmit("c1", shpFiles()), shpAck("c2"))
	f.setReport("PASSED", 0)
	scriptChecks(f, exampleAnswer(exampleItemFor("it is not even")), exampleAnswer(exampleItemFor("it is even")))
	exit, err := f.shape("Add calc.is_even(n).")
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	reqs := f.Prov.requests()
	shpEq(t, "shaper requests", len(reqs), 2)
	shpEq(t, "feedback", shpOutputs(reqs[1])["c1"], fmt.Sprintf(exampleHeadline, 1)+"\n"+exampleLine("it is not even"))
	checks := f.Prov.checkRequests()
	shpEq(t, "check requests", len(checks), 2)
	for _, c := range checks {
		shpEq(t, "tools", strings.Join(shpToolNames(c), ","), SubmitExampleCheckTool)
		input, _ := c["input"].([]any)
		shpEq(t, "messages", len(input), 1)
		content := input[0].(map[string]any)["content"].(string)
		shpEq(t, "input", content, "Slug: is-even\n\n# Request\n\nAdd calc.is_even(n).\n\n# Candidate intent.md\n\n"+shpIntentMD+"\n\n# Candidate acceptance.feature\n\n"+shpFeature)
	}
	if !strings.Contains(f.Stderr.String(), "kogen: checking the acceptance examples") {
		t.Errorf("no progress line:\n%s", f.Stderr)
	}
	var results []string
	for _, e := range shpNamed(f.events(), "example_check") {
		results = append(results, fmt.Sprint(e["items"].([]any)[0].(map[string]any)["result"]))
	}
	shpEq(t, "results", strings.Join(results, ","), "contradicts,follows")
	refused := shpNamed(f.events(), "submission_refused")
	if len(refused) != 1 || refused[0]["gate"] != "example_check" {
		t.Fatalf("refusals %v", refused)
	}
	if !f.exists(".kogen/local/provenance/is-even/current.json") || f.exists(".kogen/local/shaping/is-even/"+exampleContradictionsFile) {
		t.Fatal("the published package has a receipt and no contradiction record")
	}
}

// TestShapeExampleCheckKeptContradictionStopsNotReady: three contradicting submissions end
// Shape not ready with the item lines (no last-attempt pass-through), publish nothing, and
// leave the contradiction record that approval honours only for the unchanged package; a Shape
// of that slug ending ready removes it.
func TestShapeExampleCheckKeptContradictionStopsNotReady(t *testing.T) {
	parallel(t)
	f := newShpFx(t, shpSubmit("c1", shpFiles()), shpAck("c2"), shpAck("c3"))
	f.setReport("PASSED", 0)
	scriptChecks(f, exampleAnswer(exampleItemFor("it is not even")))
	exit, err := f.shape("Add calc.is_even(n).")
	e := shpWantError(t, err, "intent", "not_ready", "the Intent is not ready to build", 1)
	shpEq(t, "exit", exit, 1)
	shpEq(t, "lines", strings.Join(e.Lines, "\n"), exampleLine("it is not even"))
	shpEq(t, "checks", len(f.Prov.checkRequests()), 3)
	if f.exists(".kogen/local/readiness/is-even.json") || f.exists(".kogen/local/provenance/is-even/current.json") {
		t.Fatal("a refused package has readiness evidence or a receipt")
	}
	if f.read(".kogen/intents/is-even/acceptance.feature") != shpFeature {
		t.Fatal("the files of the last attempt do not stay")
	}
	record := filepath.Join(f.Root, ".kogen/local/shaping/is-even", exampleContradictionsFile)
	if st, err := os.Stat(record); err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("record: %v %v", st, err)
	}
	raw, _ := os.ReadFile(record)
	cfg, err := project.LoadConfig(f.Root)
	if err != nil {
		t.Fatal(err)
	}
	baseline, err := project.Baseline(f.Root, shpSlug, cfg)
	if err != nil {
		t.Fatal(err)
	}
	want, _ := json.Marshal(exampleContradictions{SHA256: project.Hash(f.Root, baseline), Lines: []string{exampleLine("it is not even")}})
	shpEq(t, "record", string(raw), string(want)+"\n")

	// Approval refuses the unchanged package, on the card and with the hash, and writes no marker.
	for _, hash := range []string{"", project.Hash(f.Root, baseline)} {
		f.newSession()
		_, err := Approve(context.Background(), f.S, ApproveInput{Project: f.Root, Slug: shpSlug, Hash: hash})
		ae := shpWantError(t, err, "intent", "examples_contradict", "Shape's example check found acceptance examples that contradict the Intent's rules; correct the examples or the rules in the Intent's files, or delete .kogen/intents/is-even/ and shape again", 1)
		shpEq(t, "approval lines", strings.Join(ae.Lines, "\n"), exampleLine("it is not even"))
		if f.exists(".kogen/local/approvals/is-even.json") {
			t.Fatal("approval wrote a marker")
		}
	}

	// An edited package (another hash) is not affected by the record; a record that does not parse is not either.
	f.write(".kogen/intents/is-even/acceptance.feature", shpFeature+"\n")
	f.newSession()
	_, err = Approve(context.Background(), f.S, ApproveInput{Project: f.Root, Slug: shpSlug})
	if ae, ok := sys.AsError(err); ok && ae.Reason == "examples_contradict" {
		t.Fatalf("a record of another hash refused approval: %v", err)
	}
	f.write(".kogen/intents/is-even/acceptance.feature", shpFeature)
	f.write(".kogen/local/shaping/is-even/"+exampleContradictionsFile, "not json")
	f.newSession()
	_, err = Approve(context.Background(), f.S, ApproveInput{Project: f.Root, Slug: shpSlug})
	if ae, ok := sys.AsError(err); ok && ae.Reason == "examples_contradict" {
		t.Fatalf("an unparsable record refused approval: %v", err)
	}
	if err := os.WriteFile(record, raw, 0o600); err != nil {
		t.Fatal(err)
	}

	// A Shape of the slug that ends ready removes the record.
	f.Prov.route = nil
	f.Prov.seq, f.Prov.next = []shpStep{shpSubmit("d1", shpFiles())}, 0
	f.Repo.OK("clean", "-fdq", "--", ".kogen/intents", "features/steps/is_even_steps.js")
	if err := os.Remove(filepath.Join(f.Root, ".kogen/local/shaping/is-even/state.json")); err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	if exit, err := f.shape("Add calc.is_even(n)."); err != nil || exit != 0 {
		t.Fatalf("second shape: exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	if _, err := os.Stat(record); !os.IsNotExist(err) {
		t.Fatalf("the record stays after a ready Shape: %v", err)
	}
}

// TestShapeExampleCheckInvalidAnswerStops: an answer that is not one valid
// submit_example_check payload stops Shape and publishes nothing.
func TestShapeExampleCheckInvalidAnswerStops(t *testing.T) {
	parallel(t)
	answers := map[string]shpStep{
		"not a list":    shpAnswer(shpCall("k1", SubmitExampleCheckTool, map[string]any{"examples": "x"})),
		"other tool":    shpAnswer(shpCall("k1", "read_file", map[string]any{"path": "README.md"})),
		"no call":       shpAnswer(map[string]any{"type": "message", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": "fine"}}}),
		"two calls":     shpAnswer(shpCall("k1", SubmitExampleCheckTool, exampleAnswer()), shpCall("k2", SubmitExampleCheckTool, exampleAnswer())),
		"extra payload": shpAnswer(shpCall("k1", SubmitExampleCheckTool, map[string]any{"examples": []any{}, "verdict": "ok"})),
	}
	for name, answer := range answers {
		t.Run(name, func(t *testing.T) {
			parallel(t)
			f := newShpFx(t, shpSubmit("c1", shpFiles()))
			f.setReport("PASSED", 0)
			f.Prov.route = func(req map[string]any) *shpStep {
				if isExampleCheck(req) {
					return &answer
				}
				return nil
			}
			exit, err := f.shape("Add calc.is_even(n).")
			shpWantError(t, err, "shape", "example_check_invalid", "", 1)
			shpEq(t, "exit", exit, 1)
			if !strings.Contains(err.Error(), "the example check answer is not a valid submit_example_check payload (") || !strings.HasSuffix(err.Error(), "); nothing was published") {
				t.Fatalf("error: %v", err)
			}
			if f.exists(".kogen/local/provenance/is-even/current.json") || f.exists(".kogen/local/readiness/is-even.json") {
				t.Fatal("a receipt or readiness evidence was published")
			}
		})
	}
}

// TestShapeExampleCheckIdenticalCandidateIsNotCheckedAgain: an acknowledgment resubmission
// leaves the formatted files byte-identical to the candidate already checked, so it makes no
// request and no event; the usage total printed includes the check's tokens.
func TestShapeExampleCheckIdenticalCandidateIsNotCheckedAgain(t *testing.T) {
	parallel(t)
	f := newShpFx(t, shpSubmit("c1", shpFiles()), shpAck("c2"))
	scriptChecks(f, exampleAnswer(exampleItemFor("it is even")))
	exit, err := f.shape("Add calc.is_even(n).")
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	shpEq(t, "shaper requests", len(f.Prov.requests()), 2)
	shpEq(t, "check requests", len(f.Prov.checkRequests()), 1)
	events := shpNamed(f.events(), "example_check")
	shpEq(t, "events", len(events), 1)
	shpEq(t, "follows", events[0]["follows"], any(float64(1)))
	// Two shaper responses (input 100, 102) and the check (input 101): 303 input in all.
	shpContains(t, "usage line", f.Stdout.String(), "input=303 cached=120 output=90 reasoning=30 wall_ms=")

	// A changed candidate is checked again.
	changed := map[string]any{"files": []any{
		map[string]any{"path": ".kogen/intents/is-even/acceptance.feature", "content": shpFeature + "\n# changed\n"}}}
	g := newShpFx(t, shpSubmit("c1", shpFiles()), shpSubmit("c2", changed), shpSubmit("c3", changed))
	scriptChecks(g, exampleAnswer(exampleItemFor("it is even")))
	if exit, err := g.shape("Add calc.is_even(n)."); err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, g.Stderr)
	}
	shpEq(t, "check requests after a change", len(g.Prov.checkRequests()), 2)
}

// TestExternalShapeExampleCheck: an external shaper runs the check as one fresh read-only
// session per candidate with the check schema and the same input, applies the same rule, and its
// rounds count in the usage line.
func TestExternalShapeExampleCheck(t *testing.T) {
	parallel(t)
	f := newShpFx(t)
	f.useExternalShape(8)
	f.setReport("PASSED", 0)
	x := &shapeExec{t: t,
		rounds:   []func(int, string) (executor.RoundResult, error){result(shpFiles()), result(shpFiles())},
		examples: []func(int, string) (executor.RoundResult, error){result(exampleAnswer(exampleItemFor("it is not even"))), result(exampleAnswer(exampleItemFor("it is even")))}}
	exit, err := f.shapeWith(x, "Add calc.is_even(n).")
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	shpEq(t, "check sessions", len(x.exampleStarts), 2)
	shpEq(t, "shaper sessions", len(x.starts), 1)
	for i, s := range x.exampleStarts {
		shpContains(t, "schema", string(s.Schema), `"derived"`)
		shpContains(t, "task", s.Brief.Stable, "# Request\n\nAdd calc.is_even(n).\n\n# Candidate intent.md\n\n"+shpIntentMD+"\n\n# Candidate acceptance.feature\n\n"+shpFeature)
		if strings.Contains(s.Brief.Stable, "# Calc") {
			t.Error("the check saw repository context")
		}
		if want := fmt.Sprintf("executor-example-%d", i+1); !strings.HasSuffix(s.Dir, "/"+want) {
			t.Errorf("session dir %s, want %s", s.Dir, want)
		}
	}
	feedback := x.inputs[1].Feedback
	shpContains(t, "feedback", feedback, fmt.Sprintf(exampleHeadline, 1)+"\n"+exampleLine("it is not even"))
	shpMatch(t, "usage line", f.Stdout.String(), `shape claude-opus-5-5/xhigh claude-code 4 round\(s\) wall_ms=\d+`)
	shpEq(t, "events", len(shpNamed(f.events(), "example_check")), 2)
	noNativeRequests(t, f)
}

func TestExpandOutlines(t *testing.T) {
	parallel(t)
	cases := []struct{ name, in, want string }{
		{"no outline is unchanged",
			"@tag\nFeature: F\n  Background:\n    Given a\n\n  # note\n  Scenario: S\n    Given <x>\n",
			"@tag\nFeature: F\n  Background:\n    Given a\n\n  # note\n  Scenario: S\n    Given <x>\n"},
		{"name and steps are substituted, one scenario per row",
			"Feature: F\n  Scenario Outline: <n> items\n    Given the input '<n>'\n    Then the output is '<w>'\n\n    Examples:\n      | n | w   |\n      | 1 | one |\n      | 2 | two |\n",
			"Feature: F\n  Scenario: 1 items\n    Given the input '1'\n    Then the output is 'one'\n\n  Scenario: 2 items\n    Given the input '2'\n    Then the output is 'two'\n"},
		{"tags above, text around, comments and descriptions inside are handled; Template; several blocks; doc string and table",
			"Feature: F\n  Background:\n    Given b\n\n  @keep\n  Scenario Template: T <a>\n    A description line.\n    # a comment\n    When doc <a>\n      \"\"\"\n      line <a>\n\n      <b> and <zz>\n      \"\"\"\n    And table\n      | k   | v   |\n      | <a> | <b> |\n\n    @ex\n    Examples: first\n      Some description\n      | a | b |\n      # a comment\n      | 1 | x |\n    Scenarios: second\n      | b | a |\n      | y | 2 |\n\n  # after\n  Scenario: Plain\n    Then <a>\n",
			"Feature: F\n  Background:\n    Given b\n\n  @keep\n  Scenario: T 1\n    When doc 1\n      \"\"\"\n      line 1\n\n      x and <zz>\n      \"\"\"\n    And table\n      | k   | v   |\n      | 1 | x |\n\n  Scenario: T 2\n    When doc 2\n      \"\"\"\n      line 2\n\n      y and <zz>\n      \"\"\"\n    And table\n      | k   | v   |\n      | 2 | y |\n\n  # after\n  Scenario: Plain\n    Then <a>\n"},
		{"cells are trimmed and replaced in header order",
			"Feature: F\n Scenario Outline: o\n   Given <a><b>\n   Examples:\n     | a    | b |\n     |  <b> | z |\n",
			"Feature: F\n Scenario: o\n   Given zz\n"},
		{"an unreadable feature is unchanged",
			"Feature: F\n  Scenario Outline: o\n    Given <a>\n",
			"Feature: F\n  Scenario Outline: o\n    Given <a>\n"},
	}
	for _, c := range cases {
		if got := expandOutlines(c.in); got != c.want {
			t.Errorf("%s:\n got %q\nwant %q", c.name, got, c.want)
		}
	}
	dir := "../../features/steps/k_examples_outline/"
	for _, name := range []string{"yield-regressions", "durations-consistent", "durations-contradicting"} {
		raw, err1 := os.ReadFile(dir + name + ".feature")
		want, err2 := os.ReadFile(dir + name + ".expanded.feature")
		if err1 != nil || err2 != nil {
			t.Fatal(err1, err2)
		}
		if got := expandOutlines(string(raw)); got != string(want) {
			t.Errorf("%s:\n got %q\nwant %q", name, got, want)
		}
	}
}

func TestExampleOutcomeChecksQuotesAgainstTheExpandedOutline(t *testing.T) {
	parallel(t)
	raw := "Feature: F\n  Scenario Outline: <s> seconds render\n    Given the input '<s>'\n    Then the output is '<w>'\n\n    Examples:\n      | s    | w                          |\n      | 3725 | 1 hour, 2 minutes, 5 seconds |\n      | 5430 | 1 hour, 1 minute, 30 seconds |\n"
	feature := expandOutlines(raw)
	intent := "H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60"
	item := func(scenario, input, expected, derived string) exampleItem {
		return exampleItem{scenario: scenario, input: input, expected: expected, rule: intent, derived: derived, why: "w"}
	}
	items := []exampleItem{
		item("3725 seconds render", "3725", "1 hour, 2 minutes, 5 seconds", "1 hour, 2 minutes, 5 seconds"),
		item("5430 seconds render", "5430", "1 hour, 1 minute, 30 seconds", "1 hour, 30 minutes, 30 seconds"),
		item("<s> seconds render", "<s>", "the output is '<w>'", "the output is '1 hour'"),
		item("3725 seconds render", "| 3725 |", "1 hour, 2 minutes, 5 seconds", "x"),
	}
	event, lines := exampleOutcome(items, "", intent, feature)
	for i, want := range []string{"follows", "contradicts", "unquoted", "unquoted"} {
		if got := event["items"].([]any)[i].(map[string]any)["result"]; got != want {
			t.Errorf("item %d: %v, want %s", i, got, want)
		}
	}
	wantLines := []string{fmt.Sprintf(exampleHeadline, 1),
		"- scenario: 5430 seconds render | input: 5430 | expected: 1 hour, 1 minute, 30 seconds | rule: " + intent + " | derived: 1 hour, 30 minutes, 30 seconds | why: w"}
	if !slices.Equal(lines, wantLines) {
		t.Errorf("lines %q\nwant %q", lines, wantLines)
	}
}

// TestShapeExampleCheckGivesTheExpandedOutline: the check request carries the feature with the
// outline expanded, and the already-checked key stays on the raw bytes.
func TestShapeExampleCheckGivesTheExpandedOutline(t *testing.T) {
	parallel(t)
	feature := "Feature: Is even\n  Scenario Outline: Even <n>\n    Given the number <n>\n    Then it is even\n\n    Examples:\n      | n |\n      | 4 |\n      | 6 |\n"
	files := shpFiles()
	files["files"].([]any)[1] = map[string]any{"path": ".kogen/intents/is-even/acceptance.feature", "content": feature}
	f := newShpFx(t, shpSubmit("c1", files), shpAck("c2"))
	f.setReport("PASSED", 0)
	scriptChecks(f, exampleAnswer(map[string]any{"scenario": "Even <n>", "input": "<n>", "expected": "it is even",
		"rule": exampleRule, "derived": "it is odd", "why": "w"}))
	exit, err := f.shape("Add calc.is_even(n).")
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, f.Stderr)
	}
	checks := f.Prov.checkRequests()
	if len(checks) == 0 {
		t.Fatalf("no check request\n%s", f.Stderr)
	}
	content := checks[0]["input"].([]any)[0].(map[string]any)["content"].(string)
	expanded := "Feature: Is even\n  Scenario: Even 4\n    Given the number 4\n    Then it is even\n\n  Scenario: Even 6\n    Given the number 6\n    Then it is even\n"
	shpEq(t, "input", content, "Slug: is-even\n\n# Request\n\nAdd calc.is_even(n).\n\n# Candidate intent.md\n\n"+shpIntentMD+"\n\n# Candidate acceptance.feature\n\n"+expanded)
	results := shpNamed(f.events(), "example_check")
	shpEq(t, "results", fmt.Sprint(results[0]["items"].([]any)[0].(map[string]any)["result"]), "unquoted")
}

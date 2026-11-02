package shape

import (
	"fmt"
	"strings"
	"testing"

	"kogen/executor"
)

// dataStoresFx is the fixture project whose account data lives in a CSV, an export file and a
// writer of export files, all referencing account_id; lib/my.js only references other words.
func dataStoresFx(t *testing.T, steps ...shpStep) *shpFx {
	t.Helper()
	f := newShpFx(t, steps...)
	f.write("db/accounts.csv", "account_id,name\n")
	f.write("exports/1.json", "{\"account_id\": 1}\n")
	f.write("lib/exports.js", "// account_id\nconst a = 1;\nconst b = 2;\nwrite(account_id);\n")
	f.write("lib/my.js", "my_account_id account_ids\n")
	f.git("add", "-A")
	f.git("commit", "-qm", "account data")
	return f
}

// storesFiles is the is-even package with a second Decision and a ## Data stores section of
// the key account_id and these items.
func storesFiles(items ...string) map[string]any {
	files := shpFiles()
	entry := files["files"].([]any)[0].(map[string]any)
	text := strings.Replace(shpIntentMD, "(source: request)\n", "(source: request)\n- Keep exports/ as they are. (source: request)\n", 1)
	entry["content"] = strings.Replace(text, "## Tests", "## Data stores\n\n- key `account_id`\n"+strings.Join(items, "")+"\n## Tests", 1)
	return files
}

const (
	storesCSV     = "- `db/accounts.csv`: in scope, observed by `the number 4`\n"
	storesExports = "- `exports/`: excluded by decision 2\n"
	storesWriter  = "- `lib/exports.js`: in scope, observed by `Then it is even`\n"
)

const dataStoresFeed = "Data stores: 2 problem(s) with where the data of the declared keys lives; nothing was published. " +
	"Every file tracked at HEAD that references a key declared under ## Data stores needs an item that covers it: in scope, observed by text that acceptance.feature or a listed step file contains, or excluded by a numbered Decision that names it. " +
	"Resubmitting this candidate unchanged is refused again.\n" +
	"- exports/1.json references account_id (line 1); no ## Data stores item covers it\n" +
	"- lib/exports.js references account_id (lines 1, 4); no ## Data stores item covers it"

func TestDataStoresGateRefusesUncoveredFilesBeforeReadinessAndPublishesTheCoveringPackage(t *testing.T) {
	parallel(t)
	f := dataStoresFx(t,
		shpSubmit("c1", storesFiles(storesCSV)),
		shpSubmit("c2", storesFiles(storesCSV)),
		shpSubmit("c3", storesFiles(storesCSV, storesExports, storesWriter)),
		shpAck("c4"),
	)
	exit, err := f.shape("Purge a cancelled account's data.")
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\nstderr: %s", exit, err, f.Stderr)
	}
	reqs := f.Prov.requests()
	shpEq(t, "requests", len(reqs), 4)
	shpEq(t, "feedback 1", unwrittenOutput(t, reqs[1], "c1"), dataStoresFeed)
	shpEq(t, "feedback 2", unwrittenOutput(t, reqs[2], "c2"), dataStoresFeed)
	shpContains(t, "feedback 3", unwrittenOutput(t, reqs[3], "c3"), "Readiness observations")
	refused := shpNamed(f.events(), "submission_refused")
	shpEq(t, "refused events", len(refused), 2)
	for _, e := range refused {
		shpEq(t, "gate", e["gate"], any("data_stores"))
		shpEq(t, "problems", len(e["problems"].([]any)), 2)
	}
	// Only the covering candidate (the third request) reached readiness.
	shpEq(t, "observations of the refused", f.exists(".kogen/local/shaping/is-even/observations-2.txt"), false)
	shpEq(t, "observations of the covering", f.exists(".kogen/local/shaping/is-even/observations-3.txt"), true)
	shpContains(t, "published intent", f.read(".kogen/intents/is-even/intent.md"), storesWriter)
}

func TestDataStoresGateThreeRefusalsEndNotReadyWithTheProblemLinesAndNoReadiness(t *testing.T) {
	parallel(t)
	f := dataStoresFx(t,
		shpSubmit("c1", storesFiles(storesCSV)),
		shpSubmit("c2", storesFiles(storesCSV)),
		shpSubmit("c3", storesFiles(storesCSV)),
	)
	exit, err := f.shape("Purge a cancelled account's data.")
	e := shpWantError(t, err, "intent", "not_ready", "the Intent is not ready to build", 1)
	shpEq(t, "exit", exit, 1)
	shpEq(t, "lines", strings.Join(e.Lines, "\n"),
		"- exports/1.json references account_id (line 1); no ## Data stores item covers it\n- lib/exports.js references account_id (lines 1, 4); no ## Data stores item covers it")
	shpEq(t, "requests", len(f.Prov.requests()), 3)
	shpEq(t, "refused events", len(shpNamed(f.events(), "submission_refused")), 3)
	for n := 1; n <= 3; n++ {
		if f.exists(fmt.Sprintf(".kogen/local/shaping/is-even/observations-%d.txt", n)) {
			t.Fatalf("a candidate refused by the data stores gate reached readiness (request %d)", n)
		}
	}
	if f.exists(".kogen/local/readiness/is-even.json") {
		t.Fatal("a refused candidate left readiness evidence")
	}
}

func TestDataStoresGateProblemOrderCoversSectionKeyItemsAndReferences(t *testing.T) {
	parallel(t)
	files := storesFiles(storesCSV)
	entry := files["files"].([]any)[0].(map[string]any)
	entry["content"] = strings.Replace(entry["content"].(string), "- key `account_id`\n", "", 1) +
		"" // no key: the section declares none
	text := strings.Replace(entry["content"].(string), "## Tests", "- not an item\n- `nope/`: in scope, observed by `x`\n- `db/accounts.csv`: in scope, observed by `absent text`\n- `lib/my.js`: excluded by decision 9\n- `lib/exports.js`: excluded by decision 1\n\n## Tests", 1)
	entry["content"] = text
	f := dataStoresFx(t, shpSubmit("c1", files), shpSubmit("c2", files), shpSubmit("c3", files))
	_, err := f.shape("Purge a cancelled account's data.")
	e := shpWantError(t, err, "intent", "not_ready", "the Intent is not ready to build", 1)
	shpEq(t, "lines", strings.Join(e.Lines, "\n"), strings.Join([]string{
		"- ## Data stores declares no key",
		"- not a ## Data stores item: - not an item",
		"- nope/: no file tracked at HEAD has this path",
		"- db/accounts.csv: acceptance.feature and the step files listed under Acceptance do not contain absent text",
		"- lib/my.js: ## Decisions has no line 9",
		"- lib/exports.js: decision 1 does not name lib/exports.js",
	}, "\n"))
}

func TestExternalShapeReceivesTheDataStoresRefusalAsFeedback(t *testing.T) {
	parallel(t)
	f := dataStoresFx(t)
	f.useExternalShape(6)
	x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){
		result(storesFiles(storesCSV)), result(storesFiles(storesCSV)), result(storesFiles(storesCSV)),
	}}
	exit, err := f.shapeWith(x, "Purge a cancelled account's data.")
	shpWantError(t, err, "intent", "not_ready", "the Intent is not ready to build", 1)
	shpEq(t, "exit", exit, 1)
	shpEq(t, "rounds", x.calls, 3)
	for _, in := range x.inputs[1:] {
		if !strings.HasPrefix(in.Feedback, dataStoresFeed+"\n\nCumulative proposal manifest: ") {
			t.Fatalf("feedback = %q", in.Feedback)
		}
	}
	for _, e := range shpNamed(f.events(), "submission_refused") {
		shpEq(t, "gate", e["gate"], any("data_stores"))
	}
}

func TestACandidateWithoutADataStoresSectionIsNotGated(t *testing.T) {
	parallel(t)
	f := dataStoresFx(t, shpSubmit("c1", shpFiles()), shpAck("c2"))
	exit, err := f.shape("Add calc.is_even(n).")
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\nstderr: %s", exit, err, f.Stderr)
	}
	shpEq(t, "refused events", len(shpNamed(f.events(), "submission_refused")), 0)
}

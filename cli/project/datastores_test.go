package project

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	kgit "kogen/git"
)

// storesRepo is a repository whose account data lives in a model, a CSV the model reaches and
// export files it does not, committed with the Intent's acceptance files.
func storesRepo(t *testing.T) (string, *kgit.Repo) {
	t.Helper()
	root := gitRepo(t)
	files := map[string]string{
		"lib/account.js":                "const key = 'account_id';\n",
		"lib/exports.js":                "// account_id\nconst x = 1;\nconst y = 2;\nwrite(account_id);\n",
		"db/memberships.csv":            "account_id,team\n",
		"exports/1.json":                "{\"account_id\": 1}\n",
		"exports/2.json":                "{\"account_id\": 2}\n",
		"lib/other.js":                  "my_account_id; account_ids; xaccount_id\n",
		"exports/<account_id>.json.txt": "x\n",
		"notes.md":                      "see exports/<account_id>.json\n",
		"bin.dat":                       "account_id\x00binary",
		".kogen/local/x":                "account_id\n",
		"cases.js":                      "AccountId accountId account.id\n",
		"acceptance.txt":                "observed by marker\n",
	}
	for p, c := range files {
		writeFile(t, root, p, c)
	}
	writeFile(t, root, FeaturePath(demoSlug), "Feature: F\n  Scenario: s\n    Then db/memberships.csv is purged\n")
	writeFile(t, root, "features/steps/purge_steps.js", "// step marker-text\n")
	git(t, root, "add", "-A")
	git(t, root, "commit", "-q", "-m", "init")
	return root, kgit.New(root, nil)
}

func storesIntent(t *testing.T, root string, section string) *Intent {
	t.Helper()
	acc := "Acceptance:\n- " + FeaturePath(demoSlug) + "\n- features/steps/purge_steps.js"
	dec := "## Decisions\n\n- Purge the models (source: request)\n- Keep lib/account.js as it is (source: request)\n- Keep exports/ as they are (source: answer 1)\n"
	text := demoMD(demoParts{acc: &acc, dec: &dec}) + "\n" + section
	writeFile(t, root, IntentMDPath(demoSlug), text)
	intent, err := ReadIntent(root, demoSlug, nil)
	if err != nil {
		t.Fatal(err)
	}
	return intent
}

func TestIntentWithoutADataStoresSectionHasNoScan(t *testing.T) {
	root, repo := storesRepo(t)
	intent := storesIntent(t, root, "")
	if report, declared, err := ScanDataStores(repo, "HEAD", intent); err != nil || declared || report != nil {
		t.Fatalf("scan = %v, %v, %v; want none", report, declared, err)
	}
}

func TestDataStoresScanReferencesWordsOnlyOrderedWithLines(t *testing.T) {
	root, repo := storesRepo(t)
	intent := storesIntent(t, root, "## Data stores\n\n- key `account_id`\n- key `accountId`\n- key `account_id`\n- key `account.id`\n")
	report, declared, err := ScanDataStores(repo, "HEAD", intent)
	if err != nil || !declared {
		t.Fatalf("scan: %v %v", declared, err)
	}
	if want := []string{"account_id", "accountId", "account.id"}; !slices.Equal(report.Keys, want) {
		t.Fatalf("keys = %v, want %v", report.Keys, want)
	}
	got := strings.Join(report.ReferenceLines(), "\n")
	want := strings.Join([]string{
		"- cases.js references accountId (line 1): not covered",
		"- cases.js references account.id (line 1): not covered",
		"- db/memberships.csv references account_id (line 1): not covered",
		"- exports/1.json references account_id (line 1): not covered",
		"- exports/2.json references account_id (line 1): not covered",
		"- lib/account.js references account_id (line 1): not covered",
		"- lib/exports.js references account_id (lines 1, 4): not covered",
		"- notes.md references account_id (line 1): not covered",
	}, "\n")
	if got != want {
		t.Fatalf("references:\n%s\nwant:\n%s", got, want)
	}
}

func TestDataStoresItemsAreCheckedInOrderAndCoverByFirstValidItem(t *testing.T) {
	root, repo := storesRepo(t)
	section := strings.Join([]string{
		"## Data stores",
		"",
		"prose is ignored",
		"- key `account_id`",
		"- `db/memberships.csv`: in scope, observed by `db/memberships.csv`",
		"- `nowhere.txt`: in scope, observed by `x`",
		"- `exports/`: in scope, observed by `not in acceptance`",
		"- `lib/account.js`: excluded by decision 9",
		"- `lib/exports.js`: excluded by decision 1",
		"- `lib/account.js`: excluded by decision 2",
		"- `exports/`: excluded by decision 3",
		"- `notes.md`: excluded by decision 03",
		"- something else",
		"- key ``",
		"- `lib/` : in scope, observed by `x`",
		"",
		"## Tests",
		"- key `ignored_after_the_section`",
	}, "\n")
	report, _, err := ScanDataStores(repo, "HEAD", storesIntent(t, root, section))
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"account_id"}; !slices.Equal(report.Keys, want) {
		t.Fatalf("keys = %v", report.Keys)
	}
	wantNot := []string{
		"- not a ## Data stores item: - `notes.md`: excluded by decision 03",
		"- not a ## Data stores item: - something else",
		"- not a ## Data stores item: - key ``",
		"- not a ## Data stores item: - `lib/` : in scope, observed by `x`",
	}
	if !slices.Equal(report.NotItems, wantNot) {
		t.Fatalf("not items:\n%v", report.NotItems)
	}
	wantItems := []string{
		"- nowhere.txt: no file tracked at HEAD has this path",
		"- exports/: acceptance.feature and the step files listed under Acceptance do not contain not in acceptance",
		"- lib/account.js: ## Decisions has no line 9",
		"- lib/exports.js: decision 1 does not name lib/exports.js",
	}
	if !slices.Equal(report.ItemProblems, wantItems) {
		t.Fatalf("item problems:\n%v", report.ItemProblems)
	}
	if got := strings.Join(report.ReferenceLines(), "\n"); got != strings.Join([]string{
		"- db/memberships.csv references account_id (line 1): covered by `db/memberships.csv`: in scope, observed by `db/memberships.csv`",
		"- exports/1.json references account_id (line 1): covered by `exports/`: excluded by decision 3",
		"- exports/2.json references account_id (line 1): covered by `exports/`: excluded by decision 3",
		"- lib/account.js references account_id (line 1): covered by `lib/account.js`: excluded by decision 2",
		"- lib/exports.js references account_id (lines 1, 4): not covered",
		"- notes.md references account_id (line 1): not covered",
	}, "\n") {
		t.Fatalf("references:\n%s", got)
	}
	wantProblems := append(append(append([]string{}, wantNot...), wantItems...),
		"- lib/exports.js references account_id (lines 1, 4); no ## Data stores item covers it",
		"- notes.md references account_id (line 1); no ## Data stores item covers it")
	if got := report.Problems(); !slices.Equal(got, wantProblems) {
		t.Fatalf("problems:\n%v", got)
	}
	if got := report.UncoveredFiles(); !slices.Equal(got, []string{"lib/exports.js", "notes.md"}) {
		t.Fatalf("uncovered = %v", got)
	}
}

func TestDataStoresInScopeObservedByTheStepFilesToo(t *testing.T) {
	root, repo := storesRepo(t)
	report, _, err := ScanDataStores(repo, "HEAD", storesIntent(t, root,
		"## Data stores\n- key `account_id`\n- `exports/`: in scope, observed by `marker-text`\n"))
	if err != nil || len(report.ItemProblems) != 0 {
		t.Fatalf("%v %v", err, report.ItemProblems)
	}
	if !strings.Contains(strings.Join(report.ReferenceLines(), "\n"), "- exports/1.json references account_id (line 1): covered by `exports/`: in scope, observed by `marker-text`") {
		t.Fatalf("exports/1.json not covered: %v", report.ReferenceLines())
	}
}

func TestDataStoresSectionWithoutAKeyHasNoReferences(t *testing.T) {
	root, repo := storesRepo(t)
	report, declared, err := ScanDataStores(repo, "HEAD", storesIntent(t, root, "## Data stores\n\n- `exports/`: excluded by decision 3\n"))
	if err != nil || !declared {
		t.Fatalf("%v %v", declared, err)
	}
	if got := report.Problems(); !slices.Equal(got, []string{"- ## Data stores declares no key"}) {
		t.Fatalf("problems = %v", got)
	}
	if report.DataStoresEvidence() != "" || len(report.UncoveredFiles()) != 0 {
		t.Fatal("a section without a key has evidence or uncovered files")
	}
	if got := report.ReferenceLines(); !slices.Equal(got, []string{"- none"}) {
		t.Fatalf("reference lines = %v", got)
	}
}

func TestDataStoresScanReadsTheCommitNotTheWorkTree(t *testing.T) {
	root, repo := storesRepo(t)
	writeFile(t, root, "lib/new.js", "account_id\n")
	if err := os.Remove(filepath.Join(root, "exports/1.json")); err != nil {
		t.Fatal(err)
	}
	report, _, err := ScanDataStores(repo, "HEAD", storesIntent(t, root, "## Data stores\n- key `account_id`\n"))
	if err != nil {
		t.Fatal(err)
	}
	got := strings.Join(report.ReferenceLines(), "\n")
	if strings.Contains(got, "lib/new.js") || !strings.Contains(got, "exports/1.json") {
		t.Fatalf("references: %s", got)
	}
}

func TestDataStoresEvidenceBlock(t *testing.T) {
	root, repo := storesRepo(t)
	report, _, err := ScanDataStores(repo, "HEAD", storesIntent(t, root,
		"## Data stores\n- key `account_id`\n- `exports/`: excluded by decision 3\n"))
	if err != nil {
		t.Fatal(err)
	}
	block := report.DataStoresEvidence()
	for _, want := range []string{
		"# Data stores\n\nKeys declared under the approved Intent's ## Data stores: account_id\n" +
			"Files tracked at the Build's start commit that reference a declared key, and the item that covers each:\n" +
			"- db/memberships.csv references account_id (line 1): not covered\n",
		"- exports/2.json references account_id (line 1): covered by `exports/`: excluded by decision 3\n",
		"A file that is not covered holds or reaches data the approved Intent neither scopes nor excludes by a Decision: report a blocking finding at its path. You cannot change the approved Intent; Kogen refuses a verdict without that finding.\n\n",
	} {
		if !strings.Contains(block, want) {
			t.Fatalf("block lacks %q:\n%s", want, block)
		}
	}
	if !strings.HasSuffix(block, "finding.\n\n") {
		t.Fatalf("block does not end with a blank line: %q", block[len(block)-20:])
	}
}

func TestDataStoresHeadline(t *testing.T) {
	want := "Data stores: 3 problem(s) with where the data of the declared keys lives; nothing was published. Every file tracked at HEAD that references a key declared under ## Data stores needs an item that covers it: in scope, observed by text that acceptance.feature or a listed step file contains, or excluded by a numbered Decision that names it. Resubmitting this candidate unchanged is refused again."
	if got := DataStoresHeadline(3); got != want {
		t.Fatalf("headline = %q", got)
	}
}

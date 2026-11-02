package build

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen/executor"
	"kogen/project"
)

// storesEnv is the fixture whose account data lives in a model, a CSV the model reaches and
// export files it does not, all referencing account_id, with an approved Intent that declares
// the key and these Data stores items.
func storesEnv(t *testing.T, items ...string) *env {
	t.Helper()
	e := newEnv(t)
	e.write("lib/account.js", "const memberships = 'account_id';\n")
	e.write("lib/exports.js", "// account_id\nconst a = 1;\nconst b = 2;\nwrite(account_id);\n")
	e.write("db/memberships.csv", "account_id,team\n")
	e.write("exports/1.json", "{\"account_id\": 1}\n")
	e.write("exports/2.json", "{\"account_id\": 2}\n")
	e.write("lib/other.js", "my_account_id account_ids\n")
	e.run("git", "add", "lib", "db", "exports")
	e.run("git", "commit", "-qm", "account data")
	md := filepath.Join(e.root, project.IntentMDPath(testSlug))
	text, err := os.ReadFile(md)
	if err != nil {
		t.Fatal(err)
	}
	section := "\n## Decisions\n\n- Purge a cancelled account's data (source: request)\n- Keep lib/account.js as it is (source: request)\n- Keep lib/exports.js as it is (source: request)\n\n## Data stores\n\n- key `account_id`\n" + strings.Join(items, "")
	if err := os.WriteFile(md, []byte(string(text)+section), 0o644); err != nil {
		t.Fatal(err)
	}
	e.approve()
	return e
}

const (
	storesCSV     = "- `db/memberships.csv`: in scope, observed by `the fixture is available`\n"
	storesAccount = "- `lib/account.js`: excluded by decision 2\n"
	storesWriter  = "- `lib/exports.js`: excluded by decision 3\n"
	storesDir     = "- `exports/`: in scope, observed by `Then the acceptance check passes`\n"
)

const storesBlockHead = "# Data stores\n\nKeys declared under the approved Intent's ## Data stores: account_id\n" +
	"Files tracked at the Build's start commit that reference a declared key, and the item that covers each:\n"

const storesBlockTail = "A file that is not covered holds or reaches data the approved Intent neither scopes nor excludes by a Decision: report a blocking finding at its path. You cannot change the approved Intent; Kogen refuses a verdict without that finding.\n\n"

const storesOmittedLines = "- db/memberships.csv references account_id (line 1): covered by `db/memberships.csv`: in scope, observed by `the fixture is available`\n" +
	"- exports/1.json references account_id (line 1): not covered\n" +
	"- exports/2.json references account_id (line 1): not covered\n" +
	"- lib/account.js references account_id (line 1): covered by `lib/account.js`: excluded by decision 2\n" +
	"- lib/exports.js references account_id (lines 1, 4): not covered\n"

const storesCoveredLines = "- db/memberships.csv references account_id (line 1): covered by `db/memberships.csv`: in scope, observed by `the fixture is available`\n" +
	"- exports/1.json references account_id (line 1): covered by `exports/`: in scope, observed by `Then the acceptance check passes`\n" +
	"- exports/2.json references account_id (line 1): covered by `exports/`: in scope, observed by `Then the acceptance check passes`\n" +
	"- lib/account.js references account_id (line 1): covered by `lib/account.js`: excluded by decision 2\n" +
	"- lib/exports.js references account_id (lines 1, 4): covered by `lib/exports.js`: excluded by decision 3\n"

func findingAt(path, message string) map[string]any {
	return map[string]any{"path": path, "line": 1, "severity": "blocking", "message": message}
}

// reviewAuthority is the authority text of a review request.
func reviewAuthority(t *testing.T, req map[string]any) string {
	t.Helper()
	blocks := requestInput(req)[0].(map[string]any)["content"].([]any)
	return blocks[0].(map[string]any)["text"].(string)
}

const storesProblem = "invalid verdict:\neach data store the approved Intent omits needs a blocking finding at its path; the Intent neither scopes it nor excludes it by a Decision: exports/1.json, exports/2.json, lib/exports.js"

func TestReviewAuthorityCarriesTheDataStoresBlockOnlyWithADeclaredKey(t *testing.T) {
	t.Parallel()
	t.Run("a declared key", func(t *testing.T) {
		t.Parallel()
		e := storesEnv(t, storesCSV, storesAccount)
		f := e.prov
		f.then(landScript(f)...)
		f.then(submit(f, "changes", findingAt("exports/1.json", "x"), findingAt("exports/2.json", "x"), findingAt("lib/exports.js", "x")))
		wantStop(t, e.reviewed(), "candidate/review_blocked")
		authority := reviewAuthority(t, f.reviewRequests()[0])
		acceptance := strings.Index(authority, "Acceptance: ")
		blockAt := strings.Index(authority, "\n# Data stores\n") + 1
		if acceptance < 0 || blockAt < acceptance || strings.Count(authority, "\n# Data stores\n") != 1 {
			t.Fatalf("authority has no Data stores block after the Acceptance line:\n%s", authority)
		}
		block := authority[blockAt:]
		eq(t, "block", block, storesBlockHead+storesOmittedLines+storesBlockTail)
		if line := authority[acceptance:blockAt]; !strings.HasSuffix(line, ".\n\n") || strings.Count(line, "\n") != 2 {
			t.Fatalf("the block does not follow the Acceptance line and its blank line: %q", line)
		}
	})
	t.Run("a section without a key", func(t *testing.T) {
		t.Parallel()
		e := storesEnv(t)
		md := filepath.Join(e.root, project.IntentMDPath(testSlug))
		text, _ := os.ReadFile(md)
		if err := os.WriteFile(md, []byte(strings.Replace(string(text), "- key `account_id`\n", "", 1)), 0o644); err != nil {
			t.Fatal(err)
		}
		e.approve()
		f := e.prov
		f.then(landScript(f)...)
		f.then(submit(f, "approve"))
		if a := e.reviewed(); a.exit != 0 {
			t.Fatalf("exit %d\n%s", a.exit, a.shown())
		}
		lacks(t, "authority", reviewAuthority(t, f.reviewRequests()[0]), "\n# Data stores\n")
	})
	t.Run("no section", func(t *testing.T) {
		t.Parallel()
		e := newEnv(t)
		f := e.prov
		f.then(landScript(f)...)
		f.then(submit(f, "approve"))
		if a := e.reviewed(); a.exit != 0 {
			t.Fatalf("exit %d\n%s", a.exit, a.shown())
		}
		lacks(t, "authority", reviewAuthority(t, f.reviewRequests()[0]), "\n# Data stores\n")
	})
}

func TestReviewRefusesAnApprovalWhileADataStoreIsUncoveredAndTheBlockingFindingsStopTheBuild(t *testing.T) {
	t.Parallel()
	e := storesEnv(t, storesCSV, storesAccount)
	f := e.prov
	start := e.head()
	f.then(landScript(f)...)
	f.then(submit(f, "approve"))
	f.then(submit(f, "changes",
		findingAt("exports/1.json", "holds account 1's export keyed by account_id"),
		findingAt("exports/2.json", "holds account 2's export keyed by account_id"),
		findingAt("lib/exports.js", "writes the export files keyed by account_id")))
	a := e.reviewed()
	shown := wantStop(t, a, "candidate/review_blocked")
	contains(t, "stdout", shown, "review: exports/1.json:1: holds account 1's export keyed by account_id\n")
	contains(t, "stdout", shown, "review: exports/2.json:1: holds account 2's export keyed by account_id\n")
	contains(t, "stdout", shown, "review: lib/exports.js:1: writes the export files keyed by account_id")
	reqs := f.reviewRequests()
	eq(t, "review requests", len(reqs), 2)
	eq(t, "verdict 1 feedback", toolOutputsOf(reqs[1]), []string{storesProblem})
	eq(t, "commits", e.commitsSince(start), "0")
	eq(t, "outcome", e.result(e.onlyRun())["outcome"], any("review_blocked"))
}

func TestReviewNeedsABlockingFindingAtEveryUncoveredFileAndAcceptsOnlyThat(t *testing.T) {
	t.Parallel()
	e := storesEnv(t, storesCSV, storesAccount)
	f := e.prov
	f.then(landScript(f)...)
	// A note at a path, a blocking finding at another path and a partial list do not satisfy the rule.
	f.then(submit(f, "changes", findingAt("exports/1.json", "x"), findingAt("exports/2.json", "x"),
		map[string]any{"path": "lib/exports.js", "line": 1, "severity": "note", "message": "only a note"}))
	f.then(submit(f, "changes", findingAt("exports/1.json", "x"), findingAt("exports/2.json", "x"), findingAt("lib/exports.js", "x")))
	wantStop(t, e.reviewed(), "candidate/review_blocked")
	reqs := f.reviewRequests()
	eq(t, "review requests", len(reqs), 2)
	eq(t, "feedback", toolOutputsOf(reqs[1]), []string{storesProblem})
}

func TestReviewApprovesAnIntentThatCoversEveryStoreAndLands(t *testing.T) {
	t.Parallel()
	e := storesEnv(t, storesCSV, storesDir, storesAccount, storesWriter)
	f := e.prov
	start := e.head()
	f.then(landScript(f)...)
	f.then(submit(f, "approve"))
	a := e.reviewed()
	if a.exit != 0 || a.err != nil {
		t.Fatalf("exit %d err %v\n%s", a.exit, a.err, a.shown())
	}
	contains(t, "stdout", a.out.String(), "review: approved")
	eq(t, "commits", e.commitsSince(start), "1")
	reqs := f.reviewRequests()
	eq(t, "review requests", len(reqs), 1)
	contains(t, "authority", reviewAuthority(t, reqs[0]), storesBlockHead+storesCoveredLines+storesBlockTail)
}

func TestExternalReviewerGetsTheEvidenceAndTheSameVerdictRule(t *testing.T) {
	t.Parallel()
	e := storesEnv(t, storesCSV, storesAccount)
	e.useLineup("")
	f := newLineupExec(t)
	f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
		if n == 1 {
			return executor.RoundResult{Structured: verdictJSON("approve"), Usage: harnessUsage(10, 5, 2, 0.01)}, nil
		}
		return executor.RoundResult{Structured: verdictJSON("changes",
			`{"path":"exports/1.json","line":1,"severity":"blocking","message":"export"}`,
			`{"path":"exports/2.json","line":1,"severity":"blocking","message":"export"}`,
			`{"path":"lib/exports.js","line":1,"severity":"blocking","message":"writer"}`), Usage: harnessUsage(10, 5, 2, 0.01)}, nil
	}
	start := e.head()
	a := e.build(withLineup(f))
	wantStop(t, a, "candidate/review_blocked")
	eq(t, "commits", e.commitsSince(start), "0")
	tasks := f.starts[executor.RoleReview]
	if len(tasks) != 1 {
		t.Fatalf("review tasks %d", len(tasks))
	}
	contains(t, "brief", tasks[0].Brief.Stable+tasks[0].Brief.Dynamic, storesBlockHead+storesOmittedLines+storesBlockTail)
	inputs := f.rounds(executor.RoleReview)
	eq(t, "review rounds", len(inputs), 2)
	contains(t, "second round", inputs[1].Feedback, "Not a valid verdict: "+strings.TrimPrefix(storesProblem, "invalid verdict:\n"))
}

package build

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen/project"
)

// failingSigner makes every signed commit fail, until fixSigner turns signing off.
func (e *env) failingSigner() {
	e.t.Helper()
	gpg := filepath.Join(e.t.TempDir(), "failing-gpg")
	os.WriteFile(gpg, []byte("#!/bin/sh\ncat >/dev/null\necho 'no secret key' >&2\nexit 2\n"), 0o755)
	e.run("git", "config", "gpg.program", gpg)
	e.run("git", "config", "user.signingkey", "TESTKEY")
	e.run("git", "config", "commit.gpgsign", "true")
}

func (e *env) fixSigner() { e.run("git", "config", "commit.gpgsign", "false") }

// commitFailedBuild runs a Build that passes verification and review and fails at its commit.
func (e *env) commitFailedBuild() (id string, requests int) {
	e.t.Helper()
	e.failingSigner()
	e.prov.then(landScript(e.prov)...)
	a := e.build()
	eq(e.t, "exit", a.exit, 3)
	id = e.onlyRun()
	hint := "  commit checkpoint kept: kogen intent resume " + id + " --project " + shellQuote(e.root) +
		" commits this verified and reviewed candidate once the commit environment is fixed\n" +
		"  kogen intent inspect " + id + " --project " + shellQuote(e.root) + "\n"
	contains(e.t, "stdout", a.out.String(), hint)
	return id, e.prov.count()
}

func TestADefinitelyFailedCommitIsCheckpointedAsResumableAndResumeCommitsOnly(t *testing.T) {
	t.Parallel()
	// regression: K-COMMIT-FAIL-RESUME rules 1, 3 and 5
	e := newEnv(t)
	start := e.head()
	id, requests := e.commitFailedBuild()
	eq(t, "head", e.head(), start)
	cp := e.jsonFile(e.runPath(id, "checkpoint.json"))
	cont := cp["state"].(map[string]any)["continuation"].(map[string]any)
	eq(t, "stage", cont["stage"], any("commit_failed"))
	tree := cont["tree"].(string)
	if tree == "" {
		t.Fatal("no reviewed tree")
	}
	facts := e.jsonFile(filepath.Join(e.root, ".kogen/local/facts", id+".json"))
	eq(t, "resume_status", facts["resume_status"], any("potentially_available"))
	blockers := facts["blockers"].([]any)
	if len(blockers) != 1 {
		t.Fatalf("blockers %v", blockers)
	}
	blocker := blockers[0].(map[string]any)
	eq(t, "class", blocker["class"], any("environment"))
	eq(t, "reason", blocker["reason"], any("commit_failed"))
	eq(t, "detail", blocker["detail"], any("git commit failed (status 128); the verified changes are left uncommitted"))

	e.fixSigner()
	r := e.resume(id)
	if r.exit != 0 || r.err != nil {
		t.Fatalf("exit %d err %v\n%s", r.exit, r.err, r.shown())
	}
	out := r.out.String()
	child := ""
	for _, c := range e.runIDs() {
		if c != id {
			child = c
		}
	}
	contains(t, "stdout", out, "resuming Build "+id+" as "+child+" (root "+id+")\n"+
		"finishing the commit of the candidate verified in pass 1 and approved in review 1, "+
		"with no builder round, no review and no rerun of its checks\n")
	contains(t, "stdout", out, "landed fixture ")
	eq(t, "requests", e.prov.count(), requests)
	eq(t, "commits", e.gitOut("rev-list", "--count", start+"..HEAD"), "1")
	eq(t, "committed tree", e.gitOut("rev-parse", "HEAD^{tree}"), strings.TrimSpace(e.gitOut("rev-parse", tree+"^{tree}")))
	res := e.result(child)
	eq(t, "outcome", res["outcome"], any("landed"))
	eq(t, "resumed_from", res["resumed_from"], any(id))
	eq(t, "passes", res["passes"], any(float64(1)))
	eq(t, "reviews", res["reviews"], any(float64(1)))
	if _, err := os.Stat(project.ApprovalPath(e.root, testSlug)); err == nil {
		t.Fatal("the approval must be consumed by the landing")
	}
}

func TestResumeOfAFailedCommitIsRefusedAfterAnEditOrAMovedHeadOrAChangedApproval(t *testing.T) {
	t.Parallel()
	// integration: K-COMMIT-FAIL-RESUME rule 4
	for _, tc := range []struct {
		name, want string
		change     func(e *env)
	}{
		{"edit", "candidate contents/modes or unrelated paths changed: app.txt", func(e *env) { e.write("app.txt", "edited\n") }},
		{"head", "HEAD moved or uncertain commit; inspect git log", func(e *env) {
			e.run("git", "commit", "-q", "--allow-empty", "-m", "someone else")
		}},
		{"approval", "approval changed", func(e *env) {
			p := project.ApprovalPath(e.root, testSlug)
			raw, _ := os.ReadFile(p)
			os.WriteFile(p, append(raw, ' '), 0o644)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			e := newEnv(t)
			id, requests := e.commitFailedBuild()
			e.fixSigner()
			tc.change(e)
			head, runs := e.head(), len(e.runIDs())
			r := e.resume(id)
			eq(t, "exit", r.exit, 1)
			contains(t, "stdout", r.shown(), "candidate/resume_refused: Build "+id+": "+tc.want)
			eq(t, "head", e.head(), head)
			eq(t, "runs", len(e.runIDs()), runs)
			eq(t, "requests", e.prov.count(), requests)
		})
	}
}

func TestASecondCommitFailureOnResumeLeavesAResumableCheckpointAgain(t *testing.T) {
	t.Parallel()
	// integration: K-COMMIT-FAIL-RESUME rule 5
	e := newEnv(t)
	start := e.head()
	id, requests := e.commitFailedBuild()
	r := e.resume(id)
	eq(t, "exit", r.exit, 3)
	out := r.out.String()
	contains(t, "stdout", out, "finishing the commit of the candidate verified in pass 1 and approved in review 1, ")
	contains(t, "stdout", out, "environment/commit_failed: git commit failed (status 128)")
	child := ""
	for _, c := range e.runIDs() {
		if c != id {
			child = c
		}
	}
	contains(t, "stdout", out, "  commit checkpoint kept: kogen intent resume "+child+" --project "+shellQuote(e.root))
	eq(t, "head", e.head(), start)
	eq(t, "requests", e.prov.count(), requests)
	cont := e.jsonFile(e.runPath(child, "checkpoint.json"))["state"].(map[string]any)["continuation"].(map[string]any)
	eq(t, "stage", cont["stage"], any("commit_failed"))

	e.fixSigner()
	again := e.resume(child)
	if again.exit != 0 {
		t.Fatalf("exit %d\n%s", again.exit, again.shown())
	}
	eq(t, "commits", e.gitOut("rev-list", "--count", start+"..HEAD"), "1")
}

func TestAHookUndoneCommitStaysAnUncertainBoundary(t *testing.T) {
	t.Parallel()
	// existing behavior kept: K-COMMIT-FAIL-RESUME rule 1
	e := newEnv(t)
	e.hook("pre-commit", "printf hooked >> app.txt\ngit add app.txt\n")
	e.prov.then(landScript(e.prov)...)
	a := e.build()
	eq(t, "exit", a.exit, 1)
	id := e.onlyRun()
	lacks(t, "stdout", a.out.String(), "commit checkpoint kept")
	cont := e.jsonFile(e.runPath(id, "checkpoint.json"))["state"].(map[string]any)["continuation"].(map[string]any)
	eq(t, "stage", cont["stage"], any("commit"))
	r := e.resume(id)
	eq(t, "exit", r.exit, 1)
	contains(t, "stdout", r.shown(), "uncertain commit boundary")
}

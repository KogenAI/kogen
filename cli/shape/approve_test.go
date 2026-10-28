package shape

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"kogen-loop/sys"
	"kogen/git"
	"kogen/project"
	"kogen/verify"
)

const approveSlug = "fixture"

const approveFeature = "Feature: Fixture\n  Scenario: First\n    Then the candidate succeeds\n  Scenario: Later\n    Then the candidate succeeds\n"

const approveIntentMD = "# Fixture intent\n\nSlug: fixture\nModel: not applicable — nothing to model\nAcceptance:\n" +
	"- .kogen/intents/fixture/acceptance.feature\n- features/steps/fixture_steps.js\n\nThe fixture.\n\n" +
	"## Decisions\n- Fixture decision. (source: request)\n\n## Tests\n- none: fixture\n\n## Feasibility\n- none\n"

// approveFx is a temporary repository with one committed Intent `fixture` whose acceptance
// command is a script reading a prepared Cucumber Messages report: red unless app.txt holds
// `green`.
type approveFx struct {
	t     *testing.T
	Root  string
	Aux   string // outside the repository: reports, trace, flags
	Env   []string
	Repo  *git.Repo
	Start string
}

func approveTestEnv() []string {
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "GIT_") {
			env = append(env, kv)
		}
	}
	return append(env, "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1", "GIT_TERMINAL_PROMPT=0", "HOME="+os.TempDir())
}

type approveMsg = map[string]any

func approveReport(t *testing.T, status string) string {
	t.Helper()
	scenarios, err := project.ParseGherkin(approveFeature)
	if err != nil {
		t.Fatal(err)
	}
	var children []any
	events := []approveMsg{}
	for i, sc := range scenarios {
		n := i + 1
		var astSteps []any
		for j, st := range sc.Steps {
			astSteps = append(astSteps, approveMsg{"id": fmt.Sprintf("ast-step-%d-%d", n, j+1), "location": approveMsg{"line": st.Line}, "keyword": st.Keyword})
		}
		children = append(children, approveMsg{"scenario": approveMsg{"id": fmt.Sprintf("ast-sc-%d", n), "location": approveMsg{"line": sc.Line}, "steps": astSteps, "examples": []any{}}})
	}
	events = append(events, approveMsg{"gherkinDocument": approveMsg{"uri": project.FeaturePath(approveSlug), "feature": approveMsg{"children": children}}})
	for i, sc := range scenarios {
		n := i + 1
		var pickleSteps, testSteps, finished []any
		for j, st := range sc.Steps {
			pid, tid := fmt.Sprintf("p-%d-%d", n, j+1), fmt.Sprintf("t-%d-%d", n, j+1)
			pickleSteps = append(pickleSteps, approveMsg{"id": pid, "astNodeIds": []any{fmt.Sprintf("ast-step-%d-%d", n, j+1)}, "text": st.Text})
			testSteps = append(testSteps, approveMsg{"id": tid, "pickleStepId": pid})
			finished = append(finished, approveMsg{"testStepFinished": approveMsg{"testCaseStartedId": fmt.Sprintf("s-%d", n), "testStepId": tid, "testStepResult": approveMsg{"status": status}}})
		}
		events = append(events,
			approveMsg{"pickle": approveMsg{"id": fmt.Sprintf("pk-%d", n), "uri": project.FeaturePath(approveSlug), "name": sc.Name, "astNodeIds": []any{fmt.Sprintf("ast-sc-%d", n)}, "steps": pickleSteps}},
			approveMsg{"testCase": approveMsg{"id": fmt.Sprintf("c-%d", n), "pickleId": fmt.Sprintf("pk-%d", n), "testSteps": testSteps}},
			approveMsg{"testCaseStarted": approveMsg{"id": fmt.Sprintf("s-%d", n), "testCaseId": fmt.Sprintf("c-%d", n)}})
		for _, f := range finished {
			events = append(events, f.(approveMsg))
		}
		events = append(events, approveMsg{"testCaseFinished": approveMsg{"testCaseStartedId": fmt.Sprintf("s-%d", n), "willBeRetried": false}})
	}
	var b strings.Builder
	for _, e := range events {
		line, err := json.Marshal(e)
		if err != nil {
			t.Fatal(err)
		}
		b.Write(line)
		b.WriteByte('\n')
	}
	return b.String()
}

func newApproveFx(t *testing.T) *approveFx {
	t.Helper()
	f := &approveFx{t: t, Root: t.TempDir(), Aux: t.TempDir(), Env: approveTestEnv()}
	f.Repo = git.New(f.Root, f.Env)
	f.git("init", "-q")
	f.git("config", "user.name", "Fixture")
	f.git("config", "user.email", "fixture@example.invalid")
	f.git("config", "core.hooksPath", t.TempDir())
	f.git("config", "commit.gpgsign", "false")
	f.write(".gitignore", ".kogen/local/\n")
	f.write("app.txt", "red\n")
	f.write(".kogen/project.yaml", "version: 1\ncommands:\n  acceptance:\n    run: ./accept.sh\n")
	f.write(project.IntentMDPath(approveSlug), approveIntentMD)
	f.write(project.FeaturePath(approveSlug), approveFeature)
	f.write("features/steps/fixture_steps.js", "// steps\n")
	red, green := filepath.Join(f.Aux, "red.ndjson"), filepath.Join(f.Aux, "green.ndjson")
	os.WriteFile(red, []byte(approveReport(t, "FAILED")), 0o644)
	os.WriteFile(green, []byte(approveReport(t, "PASSED")), 0o644)
	script := fmt.Sprintf(`#!/bin/sh
echo run >> '%[1]s/trace'
if [ -f '%[1]s/tamper-source' ]; then printf ' ' >> '%[2]s/.kogen/local/provenance/fixture/current.json'; fi
if grep -qx red app.txt; then cp '%[3]s' "$KOGEN_ACCEPTANCE_REPORT"; echo actual-case-red; code=1; else cp '%[4]s' "$KOGEN_ACCEPTANCE_REPORT"; code=0; fi
if [ -f '%[1]s/mutate' ]; then chmod 755 app.txt; fi
if [ -f '%[1]s/fail17' ]; then echo fresh runner failure; code=17; fi
exit $code
`, f.Aux, f.Root, red, green)
	f.write("accept.sh", script)
	os.Chmod(filepath.Join(f.Root, "accept.sh"), 0o755)
	f.git("add", "-A")
	f.git("commit", "-qm", "fixture project")
	return f
}

func (f *approveFx) git(args ...string) string {
	f.t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = f.Root
	cmd.Env = f.Env
	out, err := cmd.CombinedOutput()
	if err != nil {
		f.t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return string(out)
}

func (f *approveFx) write(rel, content string) {
	f.t.Helper()
	path := filepath.Join(f.Root, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

func (f *approveFx) read(rel string) string {
	f.t.Helper()
	b, err := os.ReadFile(filepath.Join(f.Root, rel))
	if err != nil {
		f.t.Fatal(err)
	}
	return string(b)
}

func (f *approveFx) exists(rel string) bool {
	_, err := os.Stat(filepath.Join(f.Root, rel))
	return err == nil
}

// runs is how often the acceptance command ran.
func (f *approveFx) runs() int {
	b, _ := os.ReadFile(filepath.Join(f.Aux, "trace"))
	return strings.Count(string(b), "run\n")
}

func (f *approveFx) session() (*sys.Session, *strings.Builder, *strings.Builder) {
	s := sys.NewWith(f.Env, f.Root)
	var out, errOut strings.Builder
	s.Stdout, s.Stderr = &out, &errOut
	return s, &out, &errOut
}

func (f *approveFx) approve(in ApproveInput) (int, string, error) {
	f.t.Helper()
	s, out, _ := f.session()
	in.Project, in.Slug = f.Root, approveSlug
	exit, err := Approve(context.Background(), s, in)
	return exit, out.String(), err
}

func (f *approveFx) sha() string {
	f.t.Helper()
	cfg, err := project.LoadConfig(f.Root)
	if err != nil {
		f.t.Fatal(err)
	}
	baseline, err := project.Baseline(f.Root, approveSlug, cfg)
	if err != nil {
		f.t.Fatal(err)
	}
	return project.Hash(f.Root, baseline)
}

func approveWantError(t *testing.T, err error, class, reason, detail string, exit int) *sys.Error {
	t.Helper()
	e, ok := sys.AsError(err)
	if !ok {
		t.Fatalf("error = %v, want %s/%s", err, class, reason)
	}
	if e.Class != class || e.Reason != reason || e.Exit != exit || (detail != "" && e.Detail != detail) {
		t.Fatalf("error = %s (exit %d), want %s/%s: %s (exit %d)", e.Error(), e.Exit, class, reason, detail, exit)
	}
	return e
}

// flag creates a marker file that switches a behaviour of the acceptance script on.
func (f *approveFx) flag(name string) {
	f.t.Helper()
	if err := os.WriteFile(filepath.Join(f.Aux, name), nil, 0o644); err != nil {
		f.t.Fatal(err)
	}
}

func (f *approveFx) readApproval() map[string]any {
	f.t.Helper()
	var m map[string]any
	if err := json.Unmarshal([]byte(f.read(".kogen/local/approvals/fixture.json")), &m); err != nil {
		f.t.Fatal(err)
	}
	return m
}

var approveShaRe = regexp.MustCompile(`[0-9a-f]{64}`)

func TestApproveCardOutput(t *testing.T) {
	f := newApproveFx(t)
	exit, out, err := f.approve(ApproveInput{})
	if err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, out)
	}
	sha := f.sha()
	head := strings.TrimSpace(f.git("rev-parse", "HEAD"))
	want := "Source provenance: unavailable (legacy)\n" +
		"Intent: fixture — Fixture intent\n" +
		"SHA-256: " + sha + "\n" +
		"Approver: Fixture <fixture@example.invalid>\n" +
		"\n" +
		"Acceptance\n" +
		"  - First (fails now)\n" +
		"  - Later (fails now)\n" +
		"\n" +
		"Readiness observations\n" +
		"Checked baseline: " + sha + "\n" +
		"HEAD: " + head + "\n" +
		"Acceptance exit: 1\n" +
		"Evidence: .kogen/local/readiness/fixture.json\n" +
		"Scenario: First (acceptance.feature line 2)\n" +
		"acceptance.feature line 3: Then the candidate succeeds\n" +
		"\n" +
		"Scenario: Later (acceptance.feature line 4)\n" +
		"acceptance.feature line 5: Then the candidate succeeds\n" +
		"\n" +
		"Files\n" +
		"  - .kogen/intents/fixture/intent.md\n" +
		"  - .kogen/intents/fixture/acceptance.feature\n" +
		"  - features/steps/fixture_steps.js\n" +
		"  - .kogen/project.yaml\n" +
		"Approve with:\n" +
		"  kogen intent approve fixture " + sha + "\n"
	if out != want {
		t.Fatalf("card:\n%s\nwant:\n%s", out, want)
	}
	if f.exists(".kogen/local/approvals/fixture.json") {
		t.Fatal("the card must not approve")
	}
	if !f.exists(".kogen/local/readiness/fixture.json") {
		t.Fatal("the card records readiness evidence")
	}
	if f.exists(".kogen/local/build.lock") {
		t.Fatal("the Build lock was not released")
	}
}

func TestApproveCardPassesNow(t *testing.T) {
	f := newApproveFx(t)
	f.write("app.txt", "green\n")
	f.git("add", "-A")
	f.git("commit", "-qm", "green")
	exit, out, err := f.approve(ApproveInput{By: "Someone Else"})
	if err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, out)
	}
	for _, line := range []string{"Approver: Someone Else\n", "  - First (passes now)\n", "  - Later (passes now)\n"} {
		if !strings.Contains(out, line) {
			t.Fatalf("missing %q in\n%s", line, out)
		}
	}
	if strings.Contains(out, "Readiness observations") {
		t.Fatalf("green readiness has no observations:\n%s", out)
	}
}

func TestApproveWithFullAndPrefixHash(t *testing.T) {
	for _, prefixLen := range []int{64, 8, 6} {
		t.Run(fmt.Sprint(prefixLen), func(t *testing.T) {
			f := newApproveFx(t)
			if exit, _, err := f.approve(ApproveInput{}); err != nil || exit != 5 {
				t.Fatalf("card: exit %d, err %v", exit, err)
			}
			sha := f.sha()
			runs := f.runs()
			start := time.Now().UTC().Add(-2 * time.Second)
			exit, out, err := f.approve(ApproveInput{Hash: sha[:prefixLen]})
			if err != nil || exit != 0 {
				t.Fatalf("exit %d, err %v\n%s", exit, err, out)
			}
			if want := "approved fixture " + sha[:8] + "\nNext: kogen intent build fixture\n"; out != want {
				t.Fatalf("output %q, want %q", out, want)
			}
			if got := f.runs(); got != runs {
				t.Fatalf("cached readiness must not run acceptance again: %d runs, had %d", got, runs)
			}
			a := f.readApproval()
			at, err := time.Parse(time.RFC3339, fmt.Sprint(a["approved_at"]))
			if err != nil || at.Before(start) || at.After(time.Now().Add(time.Second)) || !strings.HasSuffix(fmt.Sprint(a["approved_at"]), "Z") {
				t.Fatalf("approved_at %v (%v)", a["approved_at"], err)
			}
			wantKeys := map[string]any{"slug": "fixture", "sha256": sha, "approver": "Fixture <fixture@example.invalid>", "approved_at": a["approved_at"], "source_provenance": nil}
			if len(a) != len(wantKeys) {
				t.Fatalf("approval %v", a)
			}
			for k, v := range wantKeys {
				if got, ok := a[k]; !ok || got != v {
					t.Fatalf("approval[%s] = %v, want %v", k, got, v)
				}
			}
			if !f.exists(".kogen/local/packages/fixture.json") {
				t.Fatal("package facts were not written")
			}
			if f.exists(".kogen/local/build.lock") {
				t.Fatal("the Build lock was not released")
			}
		})
	}
}

func TestApproveWithoutCachedEvidenceRunsReadiness(t *testing.T) {
	f := newApproveFx(t)
	exit, out, err := f.approve(ApproveInput{Hash: f.sha()[:10]})
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, out)
	}
	if f.runs() != 1 {
		t.Fatalf("acceptance ran %d times, want 1", f.runs())
	}
}

func TestApproveHashMismatch(t *testing.T) {
	f := newApproveFx(t)
	sha := f.sha()
	prefix := "abcdef"
	if strings.HasPrefix(sha, prefix) {
		prefix = "012345"
	}
	exit, out, err := f.approve(ApproveInput{Hash: prefix})
	approveWantError(t, err, "intent", "hash_mismatch",
		"fixture is now "+sha+", not "+prefix+"; review it again with kogen intent approve fixture", 1)
	if exit != 1 || out != "" {
		t.Fatalf("exit %d, output %q", exit, out)
	}
	if f.runs() != 0 {
		t.Fatal("a mismatching prefix is refused before readiness")
	}
	if f.exists(".kogen/local/approvals/fixture.json") {
		t.Fatal("no approval may be written")
	}
}

func TestApproveQuestionsPending(t *testing.T) {
	f := newApproveFx(t)
	f.write(".kogen/local/shaping/fixture/state.json",
		`{"rounds":[{"questions":[{"text":"a"}],"answers":{"1":"x"}},{"questions":[{"text":"a"},{"text":"b"},{"text":"c"}],"answers":{"1":"x"}}]}`)
	exit, _, err := f.approve(ApproveInput{})
	approveWantError(t, err, "intent", "questions_pending",
		"fixture has 2 unanswered question(s); answer them with kogen intent shape fixture <file|->", 5)
	if exit != 5 {
		t.Fatalf("exit %d", exit)
	}
	// All answered: the card is shown.
	f.write(".kogen/local/shaping/fixture/state.json", `{"rounds":[{"questions":[{"text":"a"}],"answers":{"1":"x"}}]}`)
	if exit, _, err := f.approve(ApproveInput{}); err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
}

func TestApproveMissingIntent(t *testing.T) {
	f := newApproveFx(t)
	s, _, _ := f.session()
	exit, err := Approve(context.Background(), s, ApproveInput{Project: f.Root, Slug: "unknown"})
	approveWantError(t, err, "intent", "not_found", "Intent does not exist", 2)
	if exit != 2 {
		t.Fatalf("exit %d", exit)
	}
}

func TestApproveNotAGitRepository(t *testing.T) {
	f := newApproveFx(t)
	dir := t.TempDir()
	s, _, _ := f.session()
	exit, err := Approve(context.Background(), s, ApproveInput{Project: dir, Slug: approveSlug})
	approveWantError(t, err, "environment", "not_a_git_repo", dir+"; run git init first", 3)
	if exit != 3 {
		t.Fatalf("exit %d", exit)
	}
}

func TestApproveBuildRunning(t *testing.T) {
	f := newApproveFx(t)
	lock := git.NewLock(git.BuildLockPath(f.Root))
	if _, err := lock.Acquire(); err != nil {
		t.Fatal(err)
	}
	defer lock.Release()
	_, _, err := f.approve(ApproveInput{})
	e := approveWantError(t, err, "environment", "build_running", "", 3)
	if !strings.HasPrefix(e.Detail, "a Build is running in this repository (pid ") {
		t.Fatalf("detail %q", e.Detail)
	}
}

func TestApproveWithoutGitIdentityAndBy(t *testing.T) {
	f := newApproveFx(t)
	f.git("config", "--unset", "user.name")
	f.git("config", "--unset", "user.email")
	exit, _, err := f.approve(ApproveInput{})
	approveWantError(t, err, "intent", "approval_identity_unavailable", "no Git identity names the approver; run git config user.name \"<name>\" and git config user.email \"<email>\" (global or repository), or run kogen intent approve <slug> <sha> --by <name>", 2)
	if exit != 2 {
		t.Fatalf("exit %d", exit)
	}
	if f.runs() != 0 {
		t.Fatal("the identity is checked before readiness")
	}
	exit, out, err := f.approve(ApproveInput{By: "Release Manager"})
	if err != nil || exit != 5 || !strings.Contains(out, "Approver: Release Manager\n") {
		t.Fatalf("card with --by: exit %d, err %v\n%s", exit, err, out)
	}
	exit, _, err = f.approve(ApproveInput{By: "Release Manager", Hash: f.sha()[:8]})
	if err != nil || exit != 0 {
		t.Fatalf("approve with --by: exit %d, err %v", exit, err)
	}
	if got := f.readApproval()["approver"]; got != "Release Manager" {
		t.Fatalf("approver %v", got)
	}
}

func TestApproveReadinessInputsChangeDuringApproval(t *testing.T) {
	for _, prior := range []bool{false, true} {
		t.Run(fmt.Sprint("prior approval ", prior), func(t *testing.T) {
			f := newApproveFx(t)
			const raw = "{\"custody\":\"original\"}\n"
			if prior {
				f.write(".kogen/local/approvals/fixture.json", raw)
			}
			if exit, _, err := f.approve(ApproveInput{}); err != nil || exit != 5 {
				t.Fatalf("card: exit %d, err %v", exit, err)
			}
			sha := f.sha()
			published := false
			exit, out, err := f.approve(ApproveInput{Hash: sha[:8], approveAfterWrite: func() {
				published = f.exists(".kogen/local/approvals/fixture.json") && !strings.Contains(f.read(".kogen/local/approvals/fixture.json"), "custody")
				f.write("features/steps/fixture_steps.js", "// changed during publication\n")
			}})
			approveWantError(t, err, "intent", "not_ready", "readiness inputs changed during approval publication", 1)
			if exit != 1 || !published || !retainedLineOnly(out, prior) {
				t.Fatalf("exit %d, output %q, published %v", exit, out, published)
			}
			if prior {
				if got := f.read(".kogen/local/approvals/fixture.json"); got != raw {
					t.Fatalf("the previous approval was not restored: %q", got)
				}
			} else if f.exists(".kogen/local/approvals/fixture.json") {
				t.Fatal("the new approval was not removed")
			}
			if got := f.read("features/steps/fixture_steps.js"); got != "// changed during publication\n" {
				t.Fatal("the caller's edit must stay")
			}
			if f.exists(".kogen/local/build.lock") {
				t.Fatal("the Build lock was not released")
			}
		})
	}
}

func TestApproveInterruptDuringPublication(t *testing.T) {
	for _, prior := range []bool{false, true} {
		t.Run(fmt.Sprint("prior approval ", prior), func(t *testing.T) {
			f := newApproveFx(t)
			const raw = "{\"custody\":\"original\"}\n"
			if prior {
				f.write(".kogen/local/approvals/fixture.json", raw)
			}
			s, out, _ := f.session()
			in := ApproveInput{Project: f.Root, Slug: approveSlug, Hash: f.sha()[:8]}
			in.approveAfterWrite = func() { s.Interrupt("SIGINT") }
			exit, err := Approve(context.Background(), s, in)
			var interrupted *sys.Interrupted
			if !asInterrupted(err, &interrupted) || interrupted.Signal != "SIGINT" || exit != 130 {
				t.Fatalf("exit %d, err %v", exit, err)
			}
			if !retainedLineOnly(out.String(), prior) {
				t.Fatalf("output %q", out.String())
			}
			if prior {
				if got := f.read(".kogen/local/approvals/fixture.json"); got != raw {
					t.Fatalf("the previous approval was not restored: %q", got)
				}
			} else if f.exists(".kogen/local/approvals/fixture.json") {
				t.Fatal("the new approval was not removed")
			}
			if f.exists(".kogen/local/build.lock") {
				t.Fatal("the Build lock was not released")
			}
		})
	}
}

// retainedLineOnly: a stale prior marker is kept in the approval history and that is the only
// output of a failed publication; with no prior marker there is none.
func retainedLineOnly(out string, prior bool) bool {
	if !prior {
		return out == ""
	}
	return strings.HasPrefix(out, "Retained stale approval: ") && strings.Count(out, "\n") == 1
}

func asInterrupted(err error, target **sys.Interrupted) bool {
	i, ok := err.(*sys.Interrupted) // not wrapped: callers read the exit code from it
	*target = i
	return ok
}

// approveReceipt publishes a source receipt bound to the current baseline hash.
func (f *approveFx) approveReceipt(sha string) {
	f.t.Helper()
	err := project.PublishSource(f.Root, approveSlug, map[string]any{
		"version":         json.Number("1"),
		"request":         project.NewSourceRequest("frozen original", ""),
		"rounds":          []any{},
		"corrections":     []any{},
		"contract_sha256": sha,
		"comparison":      "The Intent covers the frozen original.",
	})
	if err != nil {
		f.t.Fatal(err)
	}
}

func TestApproveBindsSourceProvenance(t *testing.T) {
	f := newApproveFx(t)
	f.approveReceipt(f.sha())
	exit, out, err := f.approve(ApproveInput{})
	if err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, out)
	}
	receipt := filepath.Join(f.Root, ".kogen/local/provenance/fixture/current.json")
	if !strings.HasPrefix(out, "Diagnostic source provenance (not authority): "+receipt+"\n") ||
		!strings.Contains(out, "\nSource comparison:\nThe Intent covers the frozen original.\nIntent: fixture") {
		t.Fatalf("card:\n%s", out)
	}
	if exit, _, err := f.approve(ApproveInput{Hash: f.sha()[:8]}); err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	ref, ok := f.readApproval()["source_provenance"].(map[string]any)
	if !ok || ref["path"] != receipt || ref["contract_sha256"] != f.sha() || fmt.Sprint(ref["sha256"]) == "" {
		t.Fatalf("source_provenance %v", f.readApproval()["source_provenance"])
	}
}

func TestApproveSourceProvenanceChangedDuringReadiness(t *testing.T) {
	f := newApproveFx(t)
	f.approveReceipt(f.sha())
	receipt := filepath.Join(f.Root, ".kogen/local/provenance/fixture/current.json")
	original, err := os.ReadFile(receipt)
	if err != nil {
		t.Fatal(err)
	}
	f.flag("tamper-source")
	exit, out, err := f.approve(ApproveInput{Hash: f.sha()[:8]})
	e := approveWantError(t, err, "candidate", "source_provenance_changed", "", 1)
	if !strings.Contains(e.Detail, "source provenance custody missing, changed or unsafe: "+receipt) || exit != 1 || out != "" {
		t.Fatalf("exit %d, output %q, error %s", exit, out, e.Error())
	}
	if got := f.read(".kogen/local/provenance/fixture/current.json"); got != string(original)+" " {
		t.Fatal("the receipt must be left as found")
	}
	if f.exists(".kogen/local/approvals/fixture.json") {
		t.Fatal("no approval may be written")
	}
}

func TestApproveRefusesBrokenBoundSourceOfExistingApproval(t *testing.T) {
	f := newApproveFx(t)
	f.write(".kogen/local/approvals/fixture.json",
		`{"slug":"fixture","sha256":"x","approver":"a","approved_at":"t","source_provenance":{"path":"`+filepath.Join(f.Root, "gone", "current.json")+`","sha256":"abc"}}`)
	_, _, err := f.approve(ApproveInput{})
	approveWantError(t, err, "candidate", "source_provenance_changed", "", 1)
	if f.runs() != 0 {
		t.Fatal("refused before readiness")
	}
}

func TestApproveSourceReceiptBoundToAnotherContract(t *testing.T) {
	// A receipt bound to an earlier contract is historical: the card says so, and an exact
	// approval refreshes it to the current contract, keeping the predecessor.
	f := newApproveFx(t)
	prior := strings.Repeat("0", 64)
	f.approveReceipt(prior)
	original := f.read(".kogen/local/provenance/fixture/current.json")
	exit, out, err := f.approve(ApproveInput{})
	if err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, out)
	}
	sha := f.sha()
	if !strings.Contains(out, "Historical source receipt contract: "+prior+"; current contract: "+sha+". Shape has not run again.\n") {
		t.Fatalf("card:\n%s", out)
	}
	if strings.Contains(out, "Stale approval") {
		t.Fatalf("there is no approval to be stale:\n%s", out)
	}
	if exit, _, err := f.approve(ApproveInput{Hash: sha}); err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v", exit, err)
	}
	var current map[string]any
	if err := json.Unmarshal([]byte(f.read(".kogen/local/provenance/fixture/current.json")), &current); err != nil {
		t.Fatal(err)
	}
	previous, _ := current["previous_receipt"].(map[string]any)
	if current["contract_sha256"] != sha || current["prior_contract_sha256"] != prior ||
		previous["sha256"] != ContentHash([]byte(original)) || f.read(strings.TrimPrefix(fmt.Sprint(previous["path"]), f.Root+"/")) != original {
		t.Fatalf("refreshed receipt %v", current)
	}
	ref, _ := f.readApproval()["source_provenance"].(map[string]any)
	if ref["contract_sha256"] != sha || ref["sha256"] != ContentHash([]byte(f.read(".kogen/local/provenance/fixture/current.json"))) {
		t.Fatalf("the approval binds %v", ref)
	}
}

func TestApproveRetainsAStaleApprovalAndNamesItOnTheCard(t *testing.T) {
	f := newApproveFx(t)
	f.approveReceipt(f.sha())
	if exit, _, err := f.approve(ApproveInput{Hash: f.sha()}); err != nil || exit != 0 {
		t.Fatalf("first approval: exit %d, err %v", exit, err)
	}
	marker := f.read(".kogen/local/approvals/fixture.json")
	staleSHA := f.sha()
	f.write(project.IntentMDPath(approveSlug), approveIntentMD+"\nA later clarification.\n")
	f.git("add", "-A")
	f.git("commit", "-qm", "clarify")
	sha := f.sha()
	if sha == staleSHA {
		t.Fatal("the edit must change the contract")
	}
	exit, out, err := f.approve(ApproveInput{})
	if err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, out)
	}
	if !strings.Contains(out, "Stale approval: "+staleSHA+"; it does not authorize the current package "+sha+".\n") ||
		!strings.Contains(out, "Historical source receipt contract: "+staleSHA+"; current contract: "+sha+". Shape has not run again.\n") {
		t.Fatalf("card:\n%s", out)
	}
	if f.read(".kogen/local/approvals/fixture.json") != marker {
		t.Fatal("the card must leave the stale marker as found")
	}
	exit, out, err = f.approve(ApproveInput{Hash: sha})
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, out)
	}
	archive := filepath.Join(f.Root, ".kogen/local/approvals/history/fixture", ContentHash([]byte(marker))+".json")
	if !strings.HasPrefix(out, "Retained stale approval: "+archive+"\n") || f.read(strings.TrimPrefix(archive, f.Root+"/")) != marker {
		t.Fatalf("output %q: the stale marker is not retained at %s", out, archive)
	}
	for _, dir := range []string{".kogen/local/approvals/history", ".kogen/local/approvals/history/fixture"} {
		if fi, err := os.Stat(filepath.Join(f.Root, dir)); err != nil || fi.Mode().Perm() != 0o700 {
			t.Errorf("%s: %v, %v", dir, fi, err)
		}
	}
	if fi, err := os.Stat(archive); err != nil || fi.Mode().Perm() != 0o600 {
		t.Errorf("archive: %v, %v", fi, err)
	}
	if f.readApproval()["sha256"] != sha {
		t.Fatalf("approval %v", f.readApproval())
	}
}

func TestApproveRefusesAnUnsafeApprovalHistory(t *testing.T) {
	f := newApproveFx(t)
	f.approveReceipt(f.sha())
	if exit, _, err := f.approve(ApproveInput{Hash: f.sha()}); err != nil || exit != 0 {
		t.Fatalf("first approval: exit %d, err %v", exit, err)
	}
	f.write(project.IntentMDPath(approveSlug), approveIntentMD+"\nA later clarification.\n")
	f.git("add", "-A")
	f.git("commit", "-qm", "clarify")
	outside := t.TempDir()
	if err := os.MkdirAll(filepath.Join(f.Root, ".kogen/local/approvals"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(f.Root, ".kogen/local/approvals/history")); err != nil {
		t.Fatal(err)
	}
	marker := f.read(".kogen/local/approvals/fixture.json")
	_, _, err := f.approve(ApproveInput{Hash: f.sha()})
	e := approveWantError(t, err, "candidate", "source_provenance_changed", "", 1)
	if !strings.Contains(e.Detail, "unsafe approval history: ") {
		t.Fatalf("error %s", e.Error())
	}
	if f.read(".kogen/local/approvals/fixture.json") != marker {
		t.Fatal("the stale marker must stay")
	}
	if entries, _ := os.ReadDir(outside); len(entries) != 0 {
		t.Fatalf("history written through a symlink: %v", entries)
	}
}

func TestApproveCardPrintsTheStagedPlanOfTheIntent(t *testing.T) {
	line1, line2 := 1, 2
	_ = line1
	_ = line2
	plan := "## Stages\n```json\n" + `{"version":1,"stages":[{"id":"foundation","title":"Foundation","goal":"First runnable section","checks":["make first","make second"]},{"id":"surface","title":"Surface","goal":"Integrate","checks":["make third"]}]}` + "\n```\n"
	s := sys.NewWith(nil, "")
	var out strings.Builder
	s.Stdout = &out
	ready := &verify.Ready{Intent: &project.Intent{Title: "Staged", Text: "# Staged\n\n" + plan}, AcceptanceExit: 0,
		SHA256: strings.Repeat("b", 64), Head: strings.Repeat("c", 40)}
	approveCard(s, "demo", strings.Repeat("a", 64), "Me", ready, []string{"x.md"})
	want := "Staged plan\n  1. Foundation (foundation): First runnable section\n    - make first\n    - make second\n  2. Surface (surface): Integrate\n    - make third\nFiles\n"
	if !strings.Contains(out.String(), want) {
		t.Fatalf("card:\n%s", out.String())
	}
	var plain strings.Builder
	s.Stdout = &plain
	approveCard(s, "demo", strings.Repeat("a", 64), "Me", &verify.Ready{Intent: &project.Intent{Title: "Plain", Text: "# Plain\n"}}, []string{"x.md"})
	if strings.Contains(plain.String(), "Staged plan") {
		t.Fatalf("an Intent without a plan prints none:\n%s", plain.String())
	}
}

func TestApproveCardGroupsOutlineRows(t *testing.T) {
	line1, line2 := 3, 7
	two, one := 2, 1
	name1, name2 := "Even numbers", "Odd"
	scenarios := []verify.ScenarioResult{
		{Name: "Even numbers", Line: 5, OutlineName: &name1, OutlineLine: &line1, OutlineExamples: &two, Status: "passed"},
		{Name: "Even numbers", Line: 6, OutlineName: &name1, OutlineLine: &line1, OutlineExamples: &two, Status: "failed"},
		{Name: "Single", Line: 9, Status: "passed"},
		{Name: "Odd", Line: 12, OutlineName: &name2, OutlineLine: &line2, OutlineExamples: &one, Status: "passed"},
	}
	s := sys.NewWith(nil, "")
	var out strings.Builder
	s.Stdout = &out
	ready := &verify.Ready{Intent: &project.Intent{Title: "An intent"}, Scenarios: scenarios, AcceptanceExit: 1,
		SHA256: strings.Repeat("b", 64), Head: strings.Repeat("c", 40)}
	approveCard(s, "demo", strings.Repeat("a", 64), "Me", ready, []string{"x.md", "y.feature"})
	want := "Intent: demo — An intent\nSHA-256: " + strings.Repeat("a", 64) + "\nApprover: Me\n\nAcceptance\n" +
		"  - Even numbers (2 examples) (fails now)\n  - Single (passes now)\n  - Odd (1 examples) (passes now)\n" +
		"\nReadiness observations\nChecked baseline: " + strings.Repeat("b", 64) + "\nHEAD: " + strings.Repeat("c", 40) +
		"\nAcceptance exit: 1\nEvidence: .kogen/local/readiness/demo.json\n" +
		"Scenario: Even numbers (acceptance.feature line 6)\nThe runner supplied no failure detail.\n\n" +
		"Files\n  - x.md\n  - y.feature\nApprove with:\n  kogen intent approve demo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"
	if out.String() != want {
		t.Fatalf("card:\n%s\nwant:\n%s", out.String(), want)
	}
}

func TestApproveRepeatedCardsReuseReadinessWithoutExecution(t *testing.T) {
	f := newApproveFx(t)
	_, first, err := f.approve(ApproveInput{})
	if err != nil {
		t.Fatal(err)
	}
	exit, second, err := f.approve(ApproveInput{})
	if err != nil || exit != 5 || first != second || f.runs() != 1 {
		t.Fatalf("exit %d, err %v, runs %d, same card %v", exit, err, f.runs(), first == second)
	}
	// A new HEAD is a cache miss: readiness runs again.
	f.write("README.md", "changed\n")
	f.git("add", "-A")
	f.git("commit", "-qm", "readme")
	if _, _, err := f.approve(ApproveInput{}); err != nil || f.runs() != 2 {
		t.Fatalf("err %v, runs %d", err, f.runs())
	}
}

func TestApproveRunnerFailureAfterPassingScenariosNeverSuppliesReadiness(t *testing.T) {
	f := newApproveFx(t)
	f.write("app.txt", "green\n")
	f.git("add", "-A")
	f.git("commit", "-qm", "green")
	f.flag("fail17")
	for n := 1; n <= 2; n++ {
		exit, out, err := f.approve(ApproveInput{})
		e := approveWantError(t, err, "intent", "not_ready", "the Intent is not ready to build", 1)
		if exit != 1 || out != "" || !strings.Contains(strings.Join(e.Lines, "\n"), "exit 17 with all scenarios passed") ||
			!strings.Contains(strings.Join(e.Lines, "\n"), "fresh runner failure") {
			t.Fatalf("exit %d, output %q, lines %q", exit, out, e.Lines)
		}
		if f.exists(".kogen/local/readiness/fixture.json") || f.exists(".kogen/local/approvals/fixture.json") || f.runs() != n {
			t.Fatalf("run %d: readiness or approval written, or readiness reused (%d runs)", n, f.runs())
		}
	}
}

func TestApproveReadinessMutationsCannotCertifyTheCandidate(t *testing.T) {
	f := newApproveFx(t)
	f.flag("mutate")
	for n := 1; n <= 2; n++ {
		exit, out, err := f.approve(ApproveInput{})
		e := approveWantError(t, err, "intent", "not_ready", "readiness changed candidate files", 1)
		if exit != 1 || out != "" || len(e.Lines) == 0 {
			t.Fatalf("exit %d, output %q, lines %q", exit, out, e.Lines)
		}
		if f.exists(".kogen/local/readiness/fixture.json") || f.exists(".kogen/local/approvals/fixture.json") || f.runs() != n {
			t.Fatalf("run %d: evidence written or reused (%d runs)", n, f.runs())
		}
		if f.read("app.txt") != "red\n" {
			t.Fatal("the checkout must be untouched")
		}
	}
}

// publishedApprovalWithReceipt approves the fixture with a receipt bound to its contract,
// then edits the contract so the receipt is historical, and gives the marker a custody tag so
// the test can tell the prior marker from a new one.
func publishedApprovalWithReceipt(t *testing.T) (f *approveFx, receipt, originalReceipt, rawMarker string) {
	t.Helper()
	f = newApproveFx(t)
	f.approveReceipt(f.sha())
	if exit, _, err := f.approve(ApproveInput{Hash: f.sha()}); err != nil || exit != 0 {
		t.Fatalf("first approval: exit %d, err %v", exit, err)
	}
	receipt = ".kogen/local/provenance/fixture/current.json"
	originalReceipt = f.read(receipt)
	f.write(project.IntentMDPath(approveSlug), approveIntentMD+"\nCurrent contract.\n")
	prior := f.readApproval()
	prior["custody"] = "original"
	b, _ := json.Marshal(prior)
	rawMarker = string(b) + "\n"
	f.write(".kogen/local/approvals/fixture.json", rawMarker)
	return f, receipt, originalReceipt, rawMarker
}

// Ports "approval publication drift restores exact prior approval without certifying changed
// inputs" (with a receipt bound to the earlier contract).
func TestApprovePublicationDriftRestoresThePriorApprovalAndTheOriginalReceiptWithItsArchive(t *testing.T) {
	f, receipt, original, raw := publishedApprovalWithReceipt(t)
	index, _ := os.ReadFile(filepath.Join(f.Root, ".git/index"))
	exit, out, err := f.approve(ApproveInput{Hash: f.sha(), approveAfterWrite: func() {
		f.write("app.txt", "external publication drift\n")
	}})
	approveWantError(t, err, "intent", "not_ready", "readiness inputs changed during approval publication", 1)
	if exit != 1 || strings.Contains(out, "approved fixture") {
		t.Fatalf("exit %d, output %q", exit, out)
	}
	if got := f.read(".kogen/local/approvals/fixture.json"); got != raw {
		t.Fatalf("the prior approval was not restored: %q", got)
	}
	if f.read("app.txt") != "external publication drift\n" {
		t.Fatal("the external edit must stay")
	}
	if f.read(receipt) != original {
		t.Fatal("the receipt was not restored to its original bytes")
	}
	archive := ".kogen/local/provenance/fixture/" + ContentHash([]byte(original)) + ".json"
	if f.read(archive) != original {
		t.Fatal("the predecessor archive was not kept")
	}
	after, _ := os.ReadFile(filepath.Join(f.Root, ".git/index"))
	if string(after) != string(index) {
		t.Fatal("the index changed")
	}
}

// Ports "approval rollback preserves external receipt and marker edits during publication".
func TestApproveRollbackPreservesExternalReceiptAndMarkerEditsDuringPublication(t *testing.T) {
	for _, changed := range []string{"receipt", "marker"} {
		t.Run(changed, func(t *testing.T) {
			f, receipt, original, raw := publishedApprovalWithReceipt(t)
			head := strings.TrimSpace(f.git("rev-parse", "HEAD"))
			destination := receipt
			if changed == "marker" {
				destination = ".kogen/local/approvals/fixture.json"
			}
			_, _, err := f.approve(ApproveInput{Hash: f.sha(), approveAfterWrite: func() {
				f.write(destination, "external edit\n")
			}})
			if err == nil {
				t.Fatal("publication succeeded over an external edit")
			}
			if got := f.read(destination); got != "external edit\n" {
				t.Fatalf("the external edit was overwritten: %q", got)
			}
			if changed == "receipt" && f.read(".kogen/local/approvals/fixture.json") != raw {
				t.Fatal("the prior marker was not restored")
			}
			if changed == "marker" && f.read(receipt) != original {
				t.Fatal("the receipt was not restored")
			}
			if strings.TrimSpace(f.git("rev-parse", "HEAD")) != head {
				t.Fatal("HEAD moved")
			}
		})
	}
}

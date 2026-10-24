package build

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"kogen/project"
	"kogen/sys"
)

// landScript writes the candidate and finishes.
func landScript(f *fakeProvider) []handler {
	return []handler{f.calls("write_file", map[string]any{"path": "app.txt", "content": "candidate\n"}, "finish", map[string]any{"summary": "done"})}
}

func TestBuildLandsOneCommitWithTheIntentTrailer(t *testing.T) {
	// ExUnit: test/integration/release_behavior_test.exs: REV-4/REV-5 retries one invalid review verdict and lands after approval (builder side)
	e := newEnv(t)
	e.prov.then(landScript(e.prov)...)
	start := e.head()
	a := e.build()
	if a.exit != 0 || a.err != nil {
		t.Fatalf("exit %d err %v\n%s\n%s", a.exit, a.err, a.out, a.errs)
	}
	id := e.onlyRun()
	out := a.out.String()
	re := regexp.MustCompile(`^building fixture\nlanded fixture ([0-9a-f]{8}) \(Build ` + id + `\)\n  checks: acceptance 2/2, model not applicable\n  review: approved\n  repairs: 0 · tokens: 2 · time: \d+s\n$`)
	if !re.MatchString(out) {
		t.Fatalf("stdout %q", out)
	}
	if e.gitOut("rev-list", "--count", start+"..HEAD") != "1" {
		t.Fatal("not exactly one commit")
	}
	msg := e.gitOut("log", "-1", "--format=%B")
	eq(t, "message", msg, "Preserve the fixture\n\nKogen-Intent: fixture")
	if e.read("app.txt") != "candidate\n" || e.gitOut("show", "HEAD:app.txt") != "candidate" {
		t.Fatal("candidate is not committed")
	}
	for _, p := range []string{project.IntentMDPath(testSlug), project.FeaturePath(testSlug), stepsFile} {
		e.gitOut("show", "HEAD:"+p)
	}
	if e.gitOut("status", "--porcelain") != "" {
		t.Fatalf("checkout is not clean: %s", e.gitOut("status", "--porcelain"))
	}
	if _, err := os.Stat(project.ApprovalPath(e.root, testSlug)); !os.IsNotExist(err) {
		t.Fatal("the approval of a landed Build must be removed")
	}
	if a.errs.String() == "" || !strings.Contains(a.errs.String(), "kogen: building (round 1)") {
		t.Fatalf("progress %q", a.errs)
	}
}

func TestBuildRunRecords(t *testing.T) {
	// ExUnit: lib/kogen/run.ex (run records, result.json, checkpoint publication)
	e := newEnv(t)
	e.prov.then(landScript(e.prov)...)
	a := e.build()
	if a.exit != 0 {
		t.Fatalf("exit %d %s", a.exit, a.shown())
	}
	id := e.onlyRun()
	dir := e.runPath(id, "")
	if st, _ := os.Stat(dir); st.Mode().Perm() != 0o700 {
		t.Fatalf("run folder mode %v", st.Mode().Perm())
	}
	if st, _ := os.Stat(e.runPath(id, "checkpoint.json")); st.Mode().Perm() != 0o600 {
		t.Fatalf("checkpoint mode %v", st.Mode().Perm())
	}
	if _, err := os.Stat(e.runPath(id, "checkpoint.json.tmp")); !os.IsNotExist(err) {
		t.Fatal("a temporary checkpoint is left behind")
	}
	res := e.result(id)
	head := e.head()
	want := map[string]any{"slug": "fixture", "build": id, "outcome": "landed", "commit": head, "passes": float64(1), "reviews": float64(1),
		"repairs": float64(0), "unknown_requests": float64(0), "resumed_from": nil, "root_build": nil}
	for k, v := range want {
		if res[k] != v {
			t.Errorf("result %s = %#v, want %#v", k, res[k], v)
		}
	}
	for _, k := range []string{"start_head", "not_run", "usage", "model_active_ms", "attempt_usage"} {
		if _, ok := res[k]; !ok {
			t.Errorf("result lacks %s", k)
		}
	}
	usage := res["usage"].(map[string]any)
	if usage["input"] != float64(1) || usage["output"] != float64(1) || usage["cached"] != float64(0) || usage["reasoning"] != float64(0) {
		t.Fatalf("usage %v", usage)
	}
	events := e.events(id)
	for _, ev := range events {
		if at, _ := ev["at"].(string); !regexp.MustCompile(`^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$`).MatchString(at) {
			t.Fatalf("event %v has no timestamp", ev)
		}
	}
	names := []string{}
	for _, ev := range events {
		names = append(names, ev["event"].(string))
	}
	for _, n := range []string{"start", "request", "provider_attempt", "tool_call", "command", "command_result", "pass", "review", "commit", "outcome", "phase_duration"} {
		if len(eventsNamed(events, n)) == 0 {
			t.Errorf("no %s event in %v", n, names)
		}
	}
	start := eventsNamed(events, "start")[0]
	eq(t, "start slug", start["slug"], any("fixture"))
	call := eventsNamed(events, "tool_call")[0]
	args := call["arguments"].(map[string]any)
	if len(args["sha256"].(string)) != 64 || args["bytes"] == nil {
		t.Fatalf("tool_call arguments %v", args)
	}
	attempt := eventsNamed(events, "provider_attempt")[0]["provider"].(map[string]any)
	eq(t, "attempt phase", attempt["phase"], any("build"))
	eq(t, "attempt slug", attempt["slug"], any("fixture"))
	eq(t, "attempt outcome", attempt["outcome"], any("completed"))
	eq(t, "attempt provider", attempt["provider"], any("chatgpt"))
	if eventsNamed(events, "outcome")[0]["commit"] != head {
		t.Fatalf("outcome %v", eventsNamed(events, "outcome")[0])
	}
	doc, state := e.checkpoint(id)
	eq(t, "checkpoint version", doc["version"], any(float64(4)))
	for _, k := range []string{"identity", "candidate", "index", "approval", "state"} {
		if doc[k] == nil {
			t.Errorf("checkpoint lacks %s", k)
		}
	}
	cont := state["continuation"].(map[string]any)
	eq(t, "final stage", cont["stage"], any("landed"))
	eq(t, "final commit", cont["commit"], any(head))
	// The local facts of the run.
	facts := e.jsonFile(filepath.Join(e.root, ".kogen/local/facts", id+".json"))
	eq(t, "facts state", facts["state"], any("landed"))
	eq(t, "facts commit", facts["commit"], any(head))
	eq(t, "facts resume_status", facts["resume_status"], any("potentially_available"))
	owner := facts["owner"].(map[string]any)
	if _, isString := owner["pid"].(string); !isString || owner["birth"] == "" {
		t.Fatalf("owner %v", owner)
	}
	ctxFile := e.jsonFile(filepath.Join(e.root, ".kogen/local/context.json"))
	if ctxFile["active"] != nil || ctxFile["schema_version"] != float64(1) {
		t.Fatalf("context.json %v", ctxFile)
	}
	completion := e.jsonFile(filepath.Join(e.root, ".kogen/local/completion.json"))
	if len(completion["inspect"].([]any)) != 1 || len(completion["resume"].([]any)) != 0 {
		t.Fatalf("completion.json %v", completion)
	}
	if _, err := os.Stat(filepath.Join(e.root, ".kogen/local/packages/fixture.json")); err != nil {
		t.Fatal(err)
	}
}

func TestBuilderRequestCarriesTheIntentAndTools(t *testing.T) {
	// ExUnit: lib/kogen/build.ex context/1 and builder tool definitions (LOOP-2)
	e := newEnv(t)
	e.prov.then(landScript(e.prov)...)
	e.build()
	req := e.prov.requests()[0]
	input := req["input"].([]any)
	var text string
	for _, it := range input {
		m := it.(map[string]any)
		if m["role"] == "developer" {
			continue
		}
		for _, b := range m["content"].([]any) {
			text += b.(map[string]any)["text"].(string)
		}
	}
	for _, part := range []string{"# Intent: Preserve the fixture", "```gherkin\nFeature: Integration fixture", "# Project instructions (README.md)\n\n# Fixture project\n",
		"# Configured commands\n\nsetup: []\nfix (run once after each of your rounds): []\nchecks: \nacceptance: ", "# Protected paths\n\nThese files are the approved acceptance baseline.",
		"- .kogen/intents/fixture/intent.md\n- .kogen/intents/fixture/acceptance.feature\n", "- .kogen/project.yaml", "# Files\n\n", "\nREADME.md\napp.txt\n",
		"Source provenance: unavailable (legacy)"} {
		contains(t, "opening message", text, part)
	}
	var names []string
	for _, tl := range req["tools"].([]any) {
		names = append(names, tl.(map[string]any)["name"].(string))
	}
	eq(t, "tools", strings.Join(names, ","), "shell,read_file,view_image,write_file,finish,report_blocker")
}

func TestRedVerificationIsFedBackToTheSameBuilderAndRepaired(t *testing.T) {
	// ExUnit: test/integration/fail_fast_verification_test.exs: failed verification returns to the builder
	e := newEnv(t, func(c *project.Config) {
		c.Checks = []project.Check{{Name: "count", Run: "printf 'check\\n' >> " + "/dev/null"}}
	})
	e.prov.then(
		e.prov.calls("write_file", map[string]any{"path": "app.txt", "content": "red\n"}, "finish", map[string]any{"summary": "first"}),
		e.prov.calls("write_file", map[string]any{"path": "app.txt", "content": "green\n"}, "finish", map[string]any{"summary": "second"}),
	)
	a := e.build()
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	id := e.onlyRun()
	res := e.result(id)
	eq(t, "passes", res["passes"], any(float64(2)))
	eq(t, "repairs", res["repairs"], any(float64(1)))
	reqs := e.prov.requests()
	if len(reqs) != 2 {
		t.Fatalf("%d requests", len(reqs))
	}
	first, second := reqs[0]["input"].([]any), reqs[1]["input"].([]any)
	if len(second) <= len(first) {
		t.Fatalf("the second request must carry the whole conversation (%d, %d)", len(first), len(second))
	}
	feedback := ""
	for _, o := range e.prov.toolOutputs() {
		if strings.HasPrefix(o, "Verification pass 1 is not green.") {
			feedback = o
		}
	}
	if feedback == "" {
		t.Fatalf("no verification feedback in %q", e.prov.toolOutputs())
	}
	contains(t, "feedback", feedback, "acceptance ("+filepath.Join(e.aux, "accept.sh")+"): failed, exit status 1")
	contains(t, "feedback", feedback, "not run because an earlier item failed: count")
	lines := a.errs.String()
	contains(t, "progress", lines, "kogen: building (round 2)")
	contains(t, "progress", lines, "kogen: pass 1: acceptance failed; not run because an earlier item failed: count")
	contains(t, "progress", lines, "kogen: pass 2: all checks passed")
	contains(t, "stdout", a.out.String(), "  checks: acceptance 2/2, model not applicable, count passed\n")
	contains(t, "stdout", a.out.String(), "  repairs: 1 ")
}

func TestFixersRunOncePerRoundAndChecksFailBeforeAnyChange(t *testing.T) {
	// ExUnit: test/integration/builder_blocker_test.exs: configure! (fixers and checks) / AUT-5 already failing check
	marker := filepath.Join(t.TempDir(), "fixer-runs")
	e := newEnv(t, func(c *project.Config) {
		c.Fix = []string{"printf 'fix\\n' >> " + marker}
		c.Checks = []project.Check{{Name: "count", Run: "true"}}
	})
	e.prov.then(landScript(e.prov)...)
	if a := e.build(); a.exit != 0 {
		t.Fatalf("%s", a.shown())
	}
	b, _ := os.ReadFile(marker)
	eq(t, "fixer runs", string(b), "fix\n")

	failing := newEnv(t, func(c *project.Config) { c.Checks = []project.Check{{Name: "broken", Run: "echo boom; exit 7"}} })
	a := failing.build()
	if a.exit != 3 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	out := a.out.String()
	contains(t, "stdout", out, "environment/check_failing: check broken fails before the Build changes anything (status=7); fix it or remove it from commands.checks\n  boom\n")
	lacks(t, "stdout", out, "failed fixture:")
	contains(t, "stdout", out, "stopped in startup: check_failing;")
	if failing.prov.count() != 0 {
		t.Fatal("a request was sent")
	}
	// The index is as the Build found it.
	eq(t, "no commits", failing.gitOut("rev-list", "--count", "HEAD"), "1")
}

func TestStartRefusals(t *testing.T) {
	// ExUnit: lib/kogen/build.ex start checks (AUT-3..5, GIT-1)
	cases := []struct {
		name string
		prep func(e *env)
		exit int
		want string
	}{
		{"not approved", func(e *env) { os.Remove(project.ApprovalPath(e.root, testSlug)) }, 5, "intent/not_approved: fixture is not approved; review it with kogen intent approve fixture\n"},
		{"changed since approval", func(e *env) { e.write(project.FeaturePath(testSlug), testFeature+"  # changed\n") }, 1, "intent/changed_since_approval: fixture changed after approval and is now "},
		{"no intent", func(e *env) { os.RemoveAll(filepath.Join(e.root, ".kogen/intents")) }, 2, "intent/not_found: Intent does not exist\n"},
		{"dirty tree", func(e *env) { e.write("stray.txt", "x\n") }, 5, "environment/dirty_tree: 1 changed path(s) are not part of an Intent; commit, stash or discard them first\n  stray.txt\n"},
		{"operation in progress", func(e *env) { e.write(".git/MERGE_HEAD", e.head()+"\n") }, 3, "environment/git_operation_in_progress: a merge is in progress; finish or abort it first\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e := newEnv(t)
			c.prep(e)
			a := e.build()
			eq(t, "exit", a.exit, c.exit)
			if _, ok := sys.AsError(a.err); !ok {
				t.Fatalf("err %v", a.err)
			}
			text := a.shown()
			contains(t, "output", text, c.want)
			contains(t, "output", text, "  no newly created Build run; correct the named prerequisite before trying again\n")
			if len(e.runIDs()) != 0 || e.prov.count() != 0 {
				t.Fatalf("a run or request exists: %v %d", e.runIDs(), e.prov.count())
			}
		})
	}
}

func TestBuildWithoutLoginIsRefusedBeforeAnyRun(t *testing.T) {
	// ExUnit: lib/kogen/build.ex Provider.require_roles! (GPT-5)
	e := newEnv(t)
	s, out, _ := e.session()
	exit, err := Build(t.Context(), s, Input{Deps: e.deps(), Project: e.root, Slug: testSlug})
	if exit != 4 {
		t.Fatalf("exit %d\n%s", exit, out)
	}
	se, ok := sys.AsError(err)
	if !ok || se.Class != "provider" || se.Reason != "login" {
		t.Fatalf("err %v", err)
	}
	if len(e.runIDs()) != 0 {
		t.Fatal("a run was created")
	}
}

func TestACommitMsgHookThatRejectsTheMessageStopsBeforeAnyModelTime(t *testing.T) {
	// ExUnit: test/integration/build_boundaries_test.exs: AUT-5 commit-msg hook judges the message
	e := newEnv(t)
	e.hook("commit-msg", "echo 'subject too long' >&2\nexit 9\n")
	a := e.build()
	if a.exit != 3 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	contains(t, "stdout", a.out.String(), "environment/commit_rejected: the commit-msg hook rejects this Intent's commit message (status=9); change the Intent's title or the hook, then approve again\n  subject too long\n")
	eq(t, "requests", e.prov.count(), 0)
}

func TestTheBuildLockIsHeldAndRefusesASecondBuild(t *testing.T) {
	// ExUnit: test/integration/lock_test.exs: AUT-4 a live Build lock refuses
	e := newEnv(t)
	opened := make(chan struct{})
	e.prov.then(hang(opened))
	first, done := e.start()
	<-opened
	a := e.build()
	eq(t, "exit", a.exit, 3)
	contains(t, "second build", a.shown(), "environment/build_running: a Build is running in this repository (pid ")
	first.s.Interrupt("SIGINT")
	<-done
	eq(t, "interrupted exit", first.exit, 130)
	if _, err := os.Stat(filepath.Join(e.root, ".kogen/local/build.lock")); !os.IsNotExist(err) {
		t.Fatal("the lock is not released")
	}
}

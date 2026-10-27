package build

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"

	"kogen/project"
)

// stageOtherIntent stages an Intent of another Build, which must stay out of the candidate.
func (e *env) stageOtherIntent() {
	e.write(".kogen/intents/staged/draft.md", "caller staged this Intent\n")
	e.run("git", "add", ".kogen/intents/staged/draft.md")
}

func (e *env) staged() string { return e.gitOut("diff", "--cached", "--name-only") }

func waitFor(t *testing.T, path string) {
	t.Helper()
	for i := 0; i < 750; i++ {
		if _, err := os.Stat(path); err == nil {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", path)
}

func TestACommitHookThatRejectsLeavesEditsAndRestoresTheStagedIntentIndex(t *testing.T) {
	// ExUnit: test/integration/release_behavior_test.exs: GIT-5/GIT-8 a rejecting commit hook leaves edits and restores the staged Intent index
	e := newEnv(t)
	e.stageOtherIntent()
	e.hook("pre-commit", "echo 'hook says no' >&2\nexit 1\n")
	e.prov.then(landScript(e.prov)...)
	start, index := e.head(), e.state()["index"]
	a := e.build()
	eq(t, "exit", a.exit, 3)
	out := a.out.String()
	contains(t, "stdout", out, "failed fixture: commit_failed (Build "+e.onlyRun()+")\n")
	contains(t, "stdout", out, "environment/commit_failed: git commit failed (status 1); the verified changes are left uncommitted\n  hook says no\n")
	contains(t, "stdout", out, "  edited: app.txt\n")
	eq(t, "head", e.head(), start)
	eq(t, "app.txt", e.read("app.txt"), "candidate\n")
	eq(t, "index", e.state()["index"], index)
	eq(t, "staged", e.staged(), ".kogen/intents/staged/draft.md")
	if _, err := os.Stat(project.ApprovalPath(e.root, testSlug)); err != nil {
		t.Fatal("the approval of a Build that did not land must stay")
	}
	res := e.result(e.onlyRun())
	eq(t, "outcome", res["outcome"], any("commit_failed"))
	// The commit boundary cannot be resumed.
	facts := e.jsonFile(filepath.Join(e.root, ".kogen/local/facts", e.onlyRun()+".json"))
	eq(t, "resume_status", facts["resume_status"], any("unsupported"))
}

func TestAHookThatEditsTheCommitIsUndoneAndTheIndexRestored(t *testing.T) {
	// ExUnit: test/integration/release_behavior_test.exs: GIT-6/GIT-8 an editing hook is undone and the original staged Intent index is restored
	e := newEnv(t)
	e.stageOtherIntent()
	e.hook("pre-commit", "printf hooked >> app.txt\ngit add app.txt\n")
	e.prov.then(landScript(e.prov)...)
	start, index := e.head(), e.state()["index"]
	a := e.build()
	eq(t, "exit", a.exit, 1)
	contains(t, "stdout", a.out.String(), "candidate/hook_changed_commit: a commit hook changed app.txt; the commit was undone and the changes are left in place\n")
	eq(t, "head", e.head(), start)
	eq(t, "index", e.state()["index"], index)
	eq(t, "app.txt", e.read("app.txt"), "candidate\nhooked")
	eq(t, "outcome", e.result(e.onlyRun())["outcome"], any("hook_changed_commit"))
}

func TestOtherIntentsStayOutOfTheCandidateAndTheCommit(t *testing.T) {
	// ExUnit: test/integration/build_boundaries_test.exs: VER-10/GIT-4 excludes new siblings in another uncommitted Intent folder
	e := newEnv(t)
	e.stageOtherIntent()
	e.write(".kogen/intents/staged/notes.md", "an untracked sibling\n")
	f := e.prov
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": "candidate\n"},
		"write_file", map[string]any{"path": ".kogen/intents/staged/late.md", "content": "created during the Build\n"},
		"finish", map[string]any{"summary": "done"}))
	a := e.build()
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	files := e.gitOut("ls-tree", "-r", "--name-only", "HEAD")
	lacks(t, "commit", files, ".kogen/intents/staged")
	contains(t, "commit", files, ".kogen/intents/fixture/intent.md")
	for _, p := range []string{"draft.md", "notes.md", "late.md"} {
		if _, err := os.Stat(filepath.Join(e.root, ".kogen/intents/staged", p)); err != nil {
			t.Fatalf("%s: %v", p, err)
		}
	}
}

func TestSigningIsHonoured(t *testing.T) {
	// ExUnit: lib/kogen/build.ex landed/3 (GIT-6: signed when the user's configuration signs)
	e := newEnv(t)
	gpg := filepath.Join(t.TempDir(), "fake-gpg")
	os.WriteFile(gpg, []byte("#!/bin/sh\ncat >/dev/null\necho '[GNUPG:] SIG_CREATED ' >&2\nprintf -- '-----BEGIN PGP SIGNATURE-----\\n\\nZmFrZQ==\\n-----END PGP SIGNATURE-----\\n'\n"), 0o755)
	e.run("git", "config", "gpg.program", gpg)
	e.run("git", "config", "user.signingkey", "TESTKEY")
	e.run("git", "config", "commit.gpgsign", "true")
	e.prov.then(landScript(e.prov)...)
	a := e.build()
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s", a.exit, a.shown())
	}
	contains(t, "commit", e.gitOut("cat-file", "commit", "HEAD"), "gpgsig ")
}

func TestASigningFailureLeavesTheChangesUncommitted(t *testing.T) {
	// ExUnit: lib/kogen/build.ex commit/3 (the user's signing applies; a failing signer stops the commit)
	e := newEnv(t)
	gpg := filepath.Join(t.TempDir(), "failing-gpg")
	os.WriteFile(gpg, []byte("#!/bin/sh\ncat >/dev/null\necho 'no secret key' >&2\nexit 2\n"), 0o755)
	e.run("git", "config", "gpg.program", gpg)
	e.run("git", "config", "user.signingkey", "TESTKEY")
	e.run("git", "config", "commit.gpgsign", "true")
	e.prov.then(landScript(e.prov)...)
	start := e.head()
	a := e.build()
	eq(t, "exit", a.exit, 3)
	contains(t, "stdout", a.out.String(), "environment/commit_failed: git commit failed (status 128); the verified changes are left uncommitted\n")
	eq(t, "head", e.head(), start)
	eq(t, "app.txt", e.read("app.txt"), "candidate\n")
}

func TestAProviderFailureLeavesEditsAndRestoresTheIndexAndResumes(t *testing.T) {
	// ExUnit: test/integration/release_behavior_test.exs: GIT-8 a provider failure leaves edits and restores the staged Intent index
	e := newEnv(t)
	e.stageOtherIntent()
	f := e.prov
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": "candidate\n"}),
		failure(400, "invalid_request_error", "stop"))
	index := e.state()["index"]
	a := e.build()
	eq(t, "exit", a.exit, 4)
	id := e.onlyRun()
	out := a.out.String()
	contains(t, "stdout", out, "failed fixture: refused (Build "+id+")\n")
	contains(t, "stdout", out, "provider/refused: ")
	contains(t, "stdout", out, "  edited: app.txt\n")
	eq(t, "index", e.state()["index"], index)
	eq(t, "app.txt", e.read("app.txt"), "candidate\n")
	res := e.result(id)
	eq(t, "outcome", res["outcome"], any("refused"))
	pf, _ := res["provider_failure"].(map[string]any)
	if pf == nil || pf["http_status"] != float64(400) {
		t.Fatalf("provider_failure %v", res["provider_failure"])
	}
	if len(eventsNamed(e.events(id), "outcome")) != 1 || eventsNamed(e.events(id), "outcome")[0]["provider_failure"] == nil {
		t.Fatal("the outcome event lacks the provider failure")
	}
	attempts := eventsNamed(e.events(id), "provider_attempt")
	last := attempts[len(attempts)-1]["provider"].(map[string]any)
	eq(t, "failed attempt outcome", last["outcome"], any("failed"))
	// The provider failure is resumable: the same conversation continues and lands.
	f.then(f.calls("finish", map[string]any{"summary": "done"}))
	r := e.resume(id)
	if r.exit != 0 {
		t.Fatalf("exit %d\n%s", r.exit, r.shown())
	}
	contains(t, "resume", r.out.String(), "landed fixture ")
}

func TestContextLengthExhaustionStopsTheBuild(t *testing.T) {
	// ExUnit: lib/kogen/build.ex stopped/2 (context_too_long becomes candidate/context_exhausted)
	e := newEnv(t)
	e.prov.then(failure(400, "context_length_exceeded", "too long"))
	a := e.build()
	eq(t, "exit", a.exit, 1)
	contains(t, "stdout", a.out.String(), "candidate/context_exhausted: the conversation no longer fits gpt-6.1-sol's context; edits are left in place\n")
	eq(t, "outcome", e.result(e.onlyRun())["outcome"], any("context_exhausted"))
}

func TestAnInterruptedStartupRestoresTheIndexAndCannotResume(t *testing.T) {
	// ExUnit: test/integration/build_boundaries_test.exs: GIT-8/CLI-7 restores the saved index and reports an interrupted startup
	marker := filepath.Join(t.TempDir(), "setup-waiting")
	e := newEnv(t, func(c *project.Config) { c.Setup = []string{"touch " + marker + "; sleep 600"} })
	e.stageOtherIntent()
	index := e.state()["index"]
	a, done := e.start()
	waitFor(t, marker)
	a.s.Interrupt("SIGINT")
	<-done
	eq(t, "exit", a.exit, 130)
	id := e.onlyRun()
	contains(t, "stdout", a.out.String(), "stopped fixture: interrupted (Build "+id+")\n")
	eq(t, "index", e.state()["index"], index)
	r := e.resume(id)
	eq(t, "resume exit", r.exit, 1)
	contains(t, "resume", r.shown(), "uncertain startup boundary")
}

func TestStartupStagesThatFailRestoreTheIndex(t *testing.T) {
	// ExUnit: test/integration/build_boundaries_test.exs: GIT-8 restores the saved index when startup setup/checks fails
	for name, mutate := range map[string]func(c *project.Config){
		"setup": func(c *project.Config) { c.Setup = []string{"echo setup-broke; exit 4"} },
		"check": func(c *project.Config) { c.Checks = []project.Check{{Name: "broken", Run: "exit 5"}} },
	} {
		t.Run(name, func(t *testing.T) {
			e := newEnv(t, mutate)
			e.stageOtherIntent()
			index := e.state()["index"]
			a := e.build()
			eq(t, "exit", a.exit, 3)
			eq(t, "index", e.state()["index"], index)
			if name == "setup" {
				contains(t, "stdout", a.out.String(), "environment/setup_failed: Setup setup-1 failed (status=4).\n  setup-broke\n")
			}
			eq(t, "requests", e.prov.count(), 0)
		})
	}
}

func TestAHookThatChangesTheApprovedBaselineStopsTheBuild(t *testing.T) {
	// ExUnit: test/integration/build_boundaries_test.exs: AUT-2 stops a preflight hook that changes the approved baseline
	e := newEnv(t)
	e.hook("commit-msg", "printf changed >> "+stepsFile+"\n")
	a := e.build()
	eq(t, "exit", a.exit, 1)
	contains(t, "stdout", a.out.String(), "candidate/baseline_changed: the Build changed acceptance files: "+stepsFile)
	eq(t, "requests", e.prov.count(), 0)
}

func TestACommitInterruptedDuringPostcommitIsUndone(t *testing.T) {
	// ExUnit: test/integration/build_boundaries_test.exs: CLI-7 undoes a commit interrupted during postcommit validation
	e := newEnv(t)
	marker := filepath.Join(t.TempDir(), "hook-waiting")
	e.hook("post-commit", "touch "+marker+"\nsleep 600\n")
	e.prov.then(landScript(e.prov)...)
	start := e.head()
	a, done := e.start()
	waitFor(t, marker)
	a.s.Interrupt("SIGINT")
	<-done
	eq(t, "exit", a.exit, 130)
	eq(t, "head", e.head(), start)
	id := e.onlyRun()
	contains(t, "stdout", a.out.String(), "stopped fixture: interrupted (Build "+id+")\n")
	eq(t, "outcome", e.result(id)["outcome"], any("interrupted"))
	if staged := e.staged(); staged != "" {
		t.Fatalf("index not restored: %s", staged)
	}
}

func TestCleanVerificationOfTheCandidateFeedsBackWhatChanged(t *testing.T) {
	// ExUnit: test/integration/build_boundaries_test.exs: clean checks input mutations cannot certify the workspace; clean setup failure returns command output
	e := newEnv(t, func(c *project.Config) {
		c.Setup = []string{"if grep -qx candidate app.txt; then echo clean-setup-failure; exit 17; fi"}
	})
	f := e.prov
	opened := make(chan struct{})
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": "candidate\n"}, "finish", map[string]any{"summary": "done"}), hang(opened))
	a, done := e.start()
	<-opened
	a.s.Interrupt("SIGINT")
	<-done
	eq(t, "exit", a.exit, 130)
	res := e.result(e.onlyRun())
	still := res["still_failing"].([]any)
	if len(still) != 1 || still[0] != "setup-1" {
		t.Fatalf("still_failing %v", still)
	}
	found := false
	for _, o := range f.toolOutputs() {
		if strings.Contains(o, "exit status 17") && strings.Contains(o, "clean-setup-failure") {
			found = true
		}
	}
	if !found {
		t.Fatalf("outputs %q", f.toolOutputs())
	}
	contains(t, "stdout", a.out.String(), "  still failing: setup-1\n")
	eq(t, "passes", res["passes"], any(float64(1)))
}

func TestChecksThatChangeTheCandidateCannotCertifyAPass(t *testing.T) {
	// ExUnit: test/integration/build_boundaries_test.exs: clean checks input mutations / workspace drift during clean checks cannot certify a pass
	e := newEnv(t, func(c *project.Config) {
		c.Checks = []project.Check{{Name: "mutate", Run: "if grep -qx candidate app.txt; then printf 'mutated\\n' > app.txt; fi"}}
	})
	f := e.prov
	opened := make(chan struct{})
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": "candidate\n"}, "finish", map[string]any{"summary": "done"}), hang(opened))
	a, done := e.start()
	<-opened
	a.s.Interrupt("SIGINT")
	<-done
	eq(t, "exit", a.exit, 130)
	eq(t, "app.txt", e.read("app.txt"), "candidate\n")
	still := e.result(e.onlyRun())["still_failing"].([]any)
	found := false
	for _, s := range still {
		if s == "verification" {
			found = true
		}
	}
	if !found {
		t.Fatalf("still_failing %v", still)
	}
	found = false
	for _, o := range f.toolOutputs() {
		if strings.Contains(o, "files changed while checks ran: app.txt") {
			found = true
		}
	}
	if !found {
		t.Fatalf("outputs %q", f.toolOutputs())
	}
}

func TestALargeUnicodeStartupCheckIsRecordedCutAndTheBuildContinues(t *testing.T) {
	// ExUnit: test/integration/build_boundaries_test.exs: CLI-9 records a successful large Unicode startup check and continues
	e := newEnv(t, func(c *project.Config) {
		c.Checks = []project.Check{{Name: "startup", Run: "yes '€' | head -n 400000 | tr -d '\\n'"}}
	})
	e.prov.then(landScript(e.prov)...)
	a := e.build()
	eq(t, "exit", a.exit, 0)
	contains(t, "stdout", a.out.String(), "landed fixture")
	var found map[string]any
	for _, ev := range eventsNamed(e.events(e.onlyRun()), "command_result") {
		if ev["name"] == "startup" {
			found = ev
		}
	}
	if found == nil {
		t.Fatal("no command_result for the startup check")
	}
	eq(t, "status", found["status"], any(float64(0)))
	output, _ := found["output"].(string)
	if !validUTF8(output) || len(output) > 1_048_576 {
		t.Fatalf("recorded output: %d bytes, valid %v", len(output), validUTF8(output))
	}
	contains(t, "recorded output", output, "cut in the run log")
}

func TestBuildAnthropicInvalidProviderFailureReachesResultAndOutcome(t *testing.T) {
	e := newEnv(t)
	cfgPath := filepath.Join(e.root, ".kogen/project.yaml")
	cfg, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	role := regexp.MustCompile(`(?m)^  build:\n(    .*\n)+`)
	if !role.Match(cfg) {
		t.Fatalf("no build role in:\n%s", cfg)
	}
	writeFile(t, cfgPath, string(role.ReplaceAll(cfg, []byte("  build: {provider: anthropic, model: claude-sonnet-5-5, effort: high}\n"))), 0o644)
	e.run("git", "add", ".kogen/project.yaml")
	e.run("git", "commit", "-qm", "anthropic build role")
	e.approve()
	dir := filepath.Join(e.home, ".kogen", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	key, _ := json.Marshal(map[string]any{"provider": "anthropic", "api_key": "sk-ant-FIXTURE-KEY"})
	if err := os.WriteFile(filepath.Join(dir, "anthropic.json"), key, 0o600); err != nil {
		t.Fatal(err)
	}
	e.prov.then(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"PRIVATE-PAYLOAD-MARKER\"}}\n\n")
	})
	a := e.build()
	id := e.onlyRun()
	res := e.result(id)
	want := map[string]any{"anthropic_invalid": "ordering_or_shape"}
	if !reflect.DeepEqual(res["provider_failure"], any(want)) {
		t.Fatalf("exit %d, result provider_failure = %v\n%s", a.exit, res["provider_failure"], a.shown())
	}
	outcomes := eventsNamed(e.events(id), "outcome")
	if len(outcomes) != 1 || !reflect.DeepEqual(outcomes[0]["provider_failure"], any(want)) {
		t.Fatalf("outcome events = %v", outcomes)
	}
	for _, text := range []string{jsonText(res), jsonText(outcomes), a.out.String()} {
		if strings.Contains(text, "PRIVATE-PAYLOAD-MARKER") {
			t.Fatalf("the raw payload leaked:\n%s", text)
		}
	}
}

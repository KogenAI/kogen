package verify

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"kogen-loop/sys"
	"kogen/project"
)

func TestGreenPassRunsEveryItemInOrderOnTheCleanCandidate(t *testing.T) {
	tmp := isolateTmp(t)
	p := newProj(t)
	p.Config.Setup = []string{appendTo(p.trace("order"), "setup-1"), appendTo(p.trace("order"), "setup-2")}
	p.Config.Checks = []project.Check{
		{Name: "z-first", Run: appendTo(p.trace("order"), "z-first")},
		{Name: "a-later", Run: appendTo(p.trace("order"), "a-later") + "; echo checked"},
	}
	s, stderr := p.session()
	log, ev := &memLog{}, newEvidence()
	in := p.input(1)
	in.RunDir, in.Log, in.Evidence = filepath.Join(p.Aux, "run"), log, ev
	candidate, err := p.Repo.Tree(in.Start, nil)
	if err != nil {
		t.Fatal(err)
	}

	pass, err := Run(context.Background(), s, in)
	if err != nil {
		t.Fatal(err)
	}
	if !pass.Green || !pass.Clean || pass.N != 1 || pass.Tree != candidate {
		t.Fatalf("pass = %+v", pass)
	}
	eqSlice(t, "order", p.ran("order"), []string{"setup-1", "setup-2", "z-first", "a-later"})
	eq(t, "setup count", len(pass.Setup), 2)
	eq(t, "setup name", pass.Setup[1].Name, "setup-2")
	eq(t, "check name", pass.Checks[1].Name, "a-later")
	eq(t, "check output", pass.Checks[1].Output, "checked\n")
	eq(t, "acceptance passed", pass.Acceptance.Passed, 2)
	eq(t, "model", pass.Model.State, "none")
	eqSlice(t, "not run", pass.NotRun, nil)
	eqSlice(t, "failing", pass.Failing, nil)
	eqSlice(t, "moved", pass.Moved, nil)
	if !pass.Complete(p.Config, mustScenarios(t), nil) || !pass.Valid() {
		t.Fatal("a green pass is complete evidence")
	}
	eq(t, "progress", stderr.String(),
		"kogen: verifying (pass 1)\nkogen: running setup-1: "+p.Config.Setup[0]+"\nkogen: running setup-2: "+p.Config.Setup[1]+"\nkogen: pass 1: all checks passed\n")
	eq(t, "setup evidence", ev.counts["setup"], 2)
	eq(t, "acceptance evidence", ev.counts["acceptance"], 1)
	if _, err := os.Stat(filepath.Join(in.RunDir, "acceptance-1.ndjson")); err != nil {
		t.Fatalf("the acceptance report stays in the run folder: %v", err)
	}
	passEvents := log.named("pass")
	if len(passEvents) != 1 || passEvents[0]["green"] != true || passEvents[0]["pass"] != 1 {
		t.Fatalf("pass events = %v", passEvents)
	}
	requireNoLeftovers(t, tmp)
	// The user's checkout is untouched.
	eq(t, "status", p.git("status", "--porcelain"), "")
}

func mustScenarios(t *testing.T) []project.Scenario {
	t.Helper()
	sc, err := project.ParseGherkin(fixtureFeature)
	if err != nil {
		t.Fatal(err)
	}
	return sc
}

// ExUnit: fail_fast_verification_test.exs, failed setup.
func TestFailedSetupRetainsEvidenceAndNamesLaterSetupAndGatesWithoutAnAbsentModel(t *testing.T) {
	isolateTmp(t)
	p := newProj(t)
	first := appendTo(p.trace("setup-trace"), "setup-1") + "; if grep -qx red app.txt; then echo actual-setup-red; exit 23; fi"
	later := appendTo(p.trace("setup-trace"), "setup-2")
	p.Config.Setup = []string{first, later}
	p.Config.Checks = []project.Check{{Name: "z-first", Run: "true"}, {Name: "a-later", Run: "true"}}
	p.write("app.txt", "red\n")
	s, stderr := p.session()
	log := &memLog{}
	in := p.input(1)
	in.Log = log
	pass, err := Verify(context.Background(), s, in)
	if err != nil {
		t.Fatal(err)
	}
	names := []string{"setup-2", "acceptance", "z-first", "a-later"}
	eqSlice(t, "setup trace", p.ran("setup-trace"), []string{"setup-1"})
	if pass.Green || pass.Acceptance != nil || pass.Model.State != "none" || len(pass.Checks) != 0 {
		t.Fatalf("pass = %+v", pass)
	}
	if len(pass.Setup) != 1 || pass.Setup[0].Command != first || pass.Setup[0].Status != 23 || pass.Setup[0].Output != "actual-setup-red\n" {
		t.Fatalf("setup = %+v", pass.Setup)
	}
	eqSlice(t, "not run", pass.NotRun, names)
	eqSlice(t, "failing", pass.Failing, []string{"setup-1"})
	contains(t, "progress", stderr.String(), "kogen: pass 1: setup-1 failed; not run because an earlier item failed: setup-2, acceptance, z-first, a-later\n")
	events := log.named("pass")
	if len(events) != 1 || events[0]["green"] != false || !slices.Equal(events[0]["failing"].([]string), []string{"setup-1"}) ||
		!slices.Equal(events[0]["not_run"].([]string), names) {
		t.Fatalf("pass event = %v", events)
	}
	feedback := pass.Feedback(p.Config.Acceptance.Run, "")
	contains(t, "feedback", feedback, "actual-setup-red")
	contains(t, "feedback", feedback, "exit status 23")
	contains(t, "feedback", feedback, "not run because an earlier item failed: "+strings.Join(names, ", "))
	b, _ := json.Marshal(pass)
	contains(t, "record", string(b), `"acceptance":"not_run"`)
	contains(t, "record", string(b), `"model":"none"`)
	contains(t, "record", string(b), `"not_run":["setup-2","acceptance","z-first","a-later"]`)
}

func TestFirstRedItemStopsTheLaterOnesAndNamesThem(t *testing.T) {
	for _, tc := range []struct {
		name  string
		setup func(p *proj)
		fail  string
		notRn []string
	}{
		{"acceptance", func(p *proj) { p.write("app.txt", "red\n") }, "acceptance", []string{"model", "lint", "unit"}},
		{"check", func(p *proj) {
			p.Config.Checks = []project.Check{{Name: "lint", Run: "echo lint-bad; exit 3"}, {Name: "unit", Run: appendTo(p.trace("ran"), "unit")}}
		}, "lint", []string{"unit"}},
		{"later check", func(p *proj) {
			p.Config.Checks = []project.Check{{Name: "lint", Run: appendTo(p.trace("ran"), "lint")}, {Name: "unit", Run: "exit 4"}}
		}, "unit", nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			isolateTmp(t)
			p := newProj(t)
			p.Config.Checks = []project.Check{{Name: "lint", Run: appendTo(p.trace("ran"), "lint")}, {Name: "unit", Run: appendTo(p.trace("ran"), "unit")}}
			if tc.name == "acceptance" {
				p.setModel(project.ModelPath(fixtureSlug)+" invariants=X seed=1 samples=1 steps=1", map[string]string{project.ModelPath(fixtureSlug): "module m { val X = true }\n"})
			}
			tc.setup(p)
			s, _ := p.session()
			pass, err := Verify(context.Background(), s, p.input(1))
			if err != nil {
				t.Fatal(err)
			}
			if pass.Green {
				t.Fatal("red pass is not green")
			}
			eqSlice(t, "failing", pass.Failing, []string{tc.fail})
			if tc.name == "acceptance" {
				eqSlice(t, "not run", pass.NotRun, []string{"model", "lint", "unit"})
				eq(t, "model", pass.Model.State, "not_run")
				eqSlice(t, "ran", p.ran("ran"), nil)
				contains(t, "acceptance output", pass.Acceptance.Output, "actual-case-red")
			} else {
				eqSlice(t, "not run", pass.NotRun, tc.notRn)
			}
			if tc.name == "check" {
				eqSlice(t, "ran", p.ran("ran"), nil)
			}
		})
	}
}

func TestChangesWhileTheChecksRanMakeThePassNotGreen(t *testing.T) {
	isolateTmp(t)
	p := newProj(t)
	p.write("tool.sh", "#!/bin/sh\n")
	p.commit("tool")
	checkout := shellQuote(filepath.Join(p.Root, "app.txt"))
	for _, tc := range []struct {
		name  string
		check string
		moved []string
	}{
		{"scratch input rewritten", "printf 'tampered\\n' > app.txt", []string{"app.txt"}},
		{"scratch input deleted", "rm tool.sh", []string{"tool.sh"}},
		{"scratch mode changed", "chmod 755 app.txt", []string{"app.txt"}},
		{"nonignored file added", "echo x > created.txt", []string{"created.txt"}},
		{"ignored output allowed", "mkdir -p build && echo x > build/out.txt", nil},
		{"checkout edited", "printf 'edited\\n' > " + checkout, []string{"app.txt"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p.write("app.txt", "green\n")
			p.git("checkout", "--", "app.txt")
			p.Config.Checks = []project.Check{{Name: "mutating", Run: tc.check}}
			s, stderr := p.session()
			pass, err := Verify(context.Background(), s, p.input(1))
			if err != nil {
				t.Fatal(err)
			}
			eqSlice(t, "moved", pass.Moved, tc.moved)
			eqSlice(t, "failing", pass.Failing, nil)
			eq(t, "green", pass.Green, len(tc.moved) == 0)
			if len(tc.moved) > 0 {
				contains(t, "progress", stderr.String(), "kogen: pass 1: files changed while the checks ran: "+strings.Join(tc.moved, ", "))
				contains(t, "feedback", pass.Feedback("", ""), "files changed while checks ran: "+strings.Join(tc.moved, ", "))
			}
			p.git("checkout", "--", ".")
			p.git("clean", "-fdq")
		})
	}
}

func TestFixersRunOnceInTheCheckoutBeforeThePass(t *testing.T) {
	isolateTmp(t)
	p := newProj(t)
	p.Config.Fix = []string{appendTo(p.trace("fix"), "fix-1") + "; printf 'fixed\\n' > fixed.txt", appendTo(p.trace("fix"), "fix-2")}
	p.Config.Checks = []project.Check{{Name: "sees-fix", Run: "test -f fixed.txt"}}
	s, _ := p.session()
	log := &memLog{}
	in := p.input(1)
	in.Log = log
	pass, err := Run(context.Background(), s, in)
	if err != nil {
		t.Fatal(err)
	}
	if !pass.Green {
		t.Fatalf("the fixer's output is part of the candidate: %+v", pass)
	}
	eqSlice(t, "fix trace", p.ran("fix"), []string{"fix-1", "fix-2"})
	eq(t, "fixed file in the checkout", p.read("fixed.txt"), "fixed\n")
	var names []string
	for _, e := range log.named("command") {
		names = append(names, e["name"].(string))
	}
	eqSlice(t, "logged commands", names, []string{"fix-1", "fix-2", "acceptance", "sees-fix"})
	for _, e := range log.named("command_result")[:2] {
		eq(t, "fix status", e["status"], 0)
	}
	cmds := log.named("command")
	eq(t, "check cwd is the scratch folder", strings.HasPrefix(cmds[3]["cwd"].(string), os.TempDir()) || strings.Contains(cmds[3]["cwd"].(string), "kogen-verify-"), true)
}

func TestBaselineGuardRunsAfterEachFixerAndAfterThePass(t *testing.T) {
	for _, tc := range []struct {
		name     string
		failAt   int
		fix      []string
		wantCall int
	}{
		{"after the first fixer", 1, []string{"true", "true"}, 1},
		{"after the second fixer", 2, []string{"true", "true"}, 2},
		{"after the pass", 3, []string{"true", "true"}, 3},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tmp := isolateTmp(t)
			p := newProj(t)
			p.Config.Fix = tc.fix
			s, _ := p.session()
			calls := 0
			refusal := sys.Fail("candidate", "baseline_changed", "the Build changed acceptance files: x", 1)
			in := p.input(1)
			in.Intact = func() error {
				calls++
				if calls == tc.failAt {
					return refusal
				}
				return nil
			}
			_, err := Run(context.Background(), s, in)
			if err != refusal {
				t.Fatalf("err = %v, want the guard's refusal", err)
			}
			eq(t, "guard calls", calls, tc.wantCall)
			requireNoLeftovers(t, tmp)
		})
	}
}

func TestInterruptStopsThePassAndRemovesTheScratchFolder(t *testing.T) {
	tmp := isolateTmp(t)
	p := newProj(t)
	p.Config.Checks = []project.Check{{Name: "slow", Run: "touch '" + p.trace("started") + "'; sleep 30"}, {Name: "after", Run: appendTo(p.trace("after"), "after")}}
	s, _ := p.session()
	go func() {
		for i := 0; i < 400; i++ {
			if _, err := os.Stat(p.trace("started")); err == nil {
				s.Interrupt("SIGINT")
				return
			}
			time.Sleep(25 * time.Millisecond)
		}
	}()
	start := time.Now()
	_, err := Verify(context.Background(), s, p.input(1))
	var intr *sys.Interrupted
	if !errors.As(err, &intr) || intr.Signal != "SIGINT" {
		t.Fatalf("err = %v, want an interrupt", err)
	}
	if time.Since(start) > 20*time.Second {
		t.Fatal("the interrupt did not stop the command")
	}
	eqSlice(t, "later check", p.ran("after"), nil)
	requireNoLeftovers(t, tmp)
}

func TestCommandsGetTheCallersEnvironmentTheToolsAndTheAcceptancePaths(t *testing.T) {
	isolateTmp(t)
	p := newProj(t)
	p.Env = append(p.Env, "KOGEN_TEST_CALLER=caller-value")
	envFile := p.trace("env")
	dump := `{ echo "caller=$KOGEN_TEST_CALLER"; echo "node=$KOGEN_NODE"; echo "quint=$KOGEN_QUINT"; echo "cucumber=$KOGEN_CUCUMBER"; echo "cwd=$(pwd)"; } >> ` + shellQuote(envFile)
	p.Config.Setup = []string{dump}
	p.Config.Acceptance.Run = `{ echo "features=$KOGEN_ACCEPTANCE_FEATURES"; echo "report=$KOGEN_ACCEPTANCE_REPORT"; echo "cwd=$(pwd)"; } >> ` + shellQuote(envFile) + "; " + p.Config.Acceptance.Run
	p.Config.Checks = []project.Check{{Name: "env", Run: dump}}
	s, _ := p.session()
	s.Env = p.Env
	in := p.input(4)
	in.Tools = Tools{Node: "/n/node", Quint: "/q/cli.js", Cucumber: "/c/node_modules"}
	in.RunDir = filepath.Join(p.Aux, "run")
	pass, err := Verify(context.Background(), s, in)
	if err != nil {
		t.Fatal(err)
	}
	if !pass.Green {
		t.Fatalf("pass = %+v", pass)
	}
	b, _ := os.ReadFile(envFile)
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	contains(t, "env", lines[0], "caller=caller-value")
	for i, want := range []string{"node=/n/node", "quint=/q/cli.js", "cucumber=/c/node_modules"} {
		eq(t, "tool env", lines[1+i], want)
	}
	cwd := strings.TrimPrefix(lines[4], "cwd=")
	if cwd == p.Root || !strings.Contains(cwd, "kogen-verify-") {
		t.Fatalf("setup ran in %q, want a kogen-verify-* scratch folder", cwd)
	}
	eq(t, "features", lines[5], "features="+project.FeaturePath(fixtureSlug))
	eq(t, "report", lines[6], "report="+filepath.Join(in.RunDir, "acceptance-4.ndjson"))
	eq(t, "acceptance cwd", lines[7], "cwd="+cwd)
}

func TestExcludedIntentFoldersAndWorkspaceArtifactsStayOutOfTheCandidate(t *testing.T) {
	isolateTmp(t)
	p := newProj(t)
	// Another uncommitted Intent, an ignored build output and a tracked-but-ignored input.
	p.write(".kogen/intents/other/intent.md", "# other\n")
	p.write("build/undeclared.sh", "workspace only\n")
	p.write("new.txt", "new candidate\n")
	p.Config.Checks = []project.Check{{Name: "inputs", Run: `test ! -e .kogen/intents/other && test ! -e build/undeclared.sh && test -f new.txt && test "$(git status --porcelain)" = "" && git show HEAD:new.txt`}}
	s, _ := p.session()
	in := p.input(1)
	in.Excluded = []string{".kogen/intents/other"}
	pass, err := Verify(context.Background(), s, in)
	if err != nil {
		t.Fatal(err)
	}
	if !pass.Green || pass.Checks[0].Output != "new candidate\n" {
		t.Fatalf("pass = %+v", pass)
	}
}

// ExUnit: clean_snapshot_test.exs, declared Git commands in a verification pass.
func TestDeclaredGitCommandsSeeTheExactCleanInputsInAPass(t *testing.T) {
	isolateTmp(t)
	p := newProj(t)
	p.write("app.sh", "printf 'before\\n'\n")
	p.write("build/tracked.txt", "tracked ignored input\n")
	p.git("add", "-f", "build/tracked.txt")
	p.commit("baseline")
	p.write("app.sh", "printf 'candidate\\n'\n")
	if err := os.Chmod(filepath.Join(p.Root, "app.sh"), 0o755); err != nil {
		t.Fatal(err)
	}
	p.write("new.txt", "new candidate\n")
	if err := os.Symlink("new.txt", filepath.Join(p.Root, "link")); err != nil {
		t.Fatal(err)
	}
	p.write("build/undeclared.sh", "workspace only\n")
	p.Config.Checks = []project.Check{
		{Name: "show", Run: `git show HEAD:app.sh; git show HEAD:link; echo; git ls-files --error-unmatch new.txt; test -x app.sh; test -f build/tracked.txt; test ! -e build/undeclared.sh`},
		{Name: "clean", Run: `test -z "$(git status --porcelain)"`},
	}
	s, _ := p.session()
	pass, err := Verify(context.Background(), s, p.input(1))
	if err != nil {
		t.Fatal(err)
	}
	if !pass.Green {
		t.Fatalf("pass = %+v", pass)
	}
	eq(t, "show output", pass.Checks[0].Output, "printf 'candidate\\n'\nnew.txt\nnew.txt\n")
	candidate, err := p.Repo.Tree(p.head(), nil)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "tree is the candidate", pass.Tree, candidate)
}

func TestAFixerThatExitsNonzeroDoesNotStopThePass(t *testing.T) {
	isolateTmp(t)
	p := newProj(t)
	p.Config.Fix = []string{"echo fixer-noise; exit 9"}
	s, _ := p.session()
	log := &memLog{}
	in := p.input(1)
	in.Log = log
	pass, err := Run(context.Background(), s, in)
	if err != nil {
		t.Fatal(err)
	}
	if !pass.Green {
		t.Fatalf("pass = %+v", pass)
	}
	results := log.named("command_result")
	eq(t, "fixer status is logged", results[0]["status"], 9)
	eq(t, "fixer output is logged", results[0]["output"], "fixer-noise\n")
}

func TestACancelledContextStopsBeforeAnyCommandAndLeavesNothingBehind(t *testing.T) {
	tmp := isolateTmp(t)
	p := newProj(t)
	p.Config.Setup = []string{appendTo(p.trace("ran"), "setup")}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	s, _ := p.session()
	_, err := Verify(ctx, s, p.input(1))
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
	eqSlice(t, "ran", p.ran("ran"), nil)
	requireNoLeftovers(t, tmp)
}

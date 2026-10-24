package verify

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen/project"
	"kogen/sys"
)

func configWith(commands ...string) *project.Config {
	cfg := &project.Config{Acceptance: &project.Acceptance{Run: "true"}}
	for i, c := range commands {
		cfg.Checks = append(cfg.Checks, project.Check{Name: "c" + string(rune('a'+i)), Run: c})
	}
	return cfg
}

// ExUnit: contract_regressions_test.exs, SHP-2 quoted executable paths.
func TestQuotedExecutablePathsAndAssignmentValuesPassToolLookupWithoutExecution(t *testing.T) {
	root := t.TempDir()
	tool := filepath.Join(root, "check tool")
	os.WriteFile(tool, []byte("#!/bin/sh\nprintf executed > check-was-run\n"), 0o755)
	s := sys.NewWith(testEnv(), root)
	for _, command := range []string{
		`"/usr/bin/true"`,
		`"./check tool"`,
		`LABEL="two words" /usr/bin/true`,
		`./check\ tool`,
		`A=1 B='x y' "./check tool" --flag`,
		`( /usr/bin/true )`,
		`! /usr/bin/true`,
		`{ /usr/bin/true`,
	} {
		if err := RequireTools(s, Tools{}, root, configWith(command), true); err != nil {
			t.Fatalf("%q: %v", command, err)
		}
	}
	if fileExists(filepath.Join(root, "check-was-run")) {
		t.Fatal("tool lookup executed a command")
	}
}

func TestMissingProgramsAreNamedAsToolMissingWithExit3(t *testing.T) {
	root := t.TempDir()
	s := sys.NewWith(testEnv(), root)
	for _, tc := range []struct{ command, word string }{
		{"definitely-not-a-tool --x", "definitely-not-a-tool"},
		{"FOO=1 BAR=2 nope-tool", "nope-tool"},
		{"(nope-tool )", "nope-tool"},
		{"./not-there", "./not-there"},
		{"{ nope-tool; }", "nope-tool;"},
	} {
		err := RequireTools(s, Tools{}, root, configWith("true", tc.command), true)
		e := failWith(t, err, "environment", "tool_missing")
		eq(t, "detail", e.Detail, tc.word+" is not available")
		eq(t, "exit", e.Exit, 3)
	}
	// Commands are not looked at before a Build (configured false), and a blank command has
	// no program.
	if err := RequireTools(s, Tools{}, root, configWith("definitely-not-a-tool"), false); err != nil {
		t.Fatal(err)
	}
	if err := RequireTools(s, Tools{}, root, configWith("", "FOO=1"), true); err != nil {
		t.Fatal(err)
	}
}

func TestToolLookupResolvesKogenNodeFromTheCallersEnvironment(t *testing.T) {
	root := t.TempDir()
	cfg := configWith(`"$KOGEN_NODE" --version`)
	s := sys.NewWith(append(testEnv(), "KOGEN_NODE=/bin/sh"), root)
	if err := RequireTools(s, Tools{}, root, cfg, true); err != nil {
		t.Fatal(err)
	}
	// The missing-value case must not inherit an installed harness's Node binding.
	s = sys.NewWith(append(testEnv(), "KOGEN_NODE="), root)
	e := failWith(t, RequireTools(s, Tools{}, root, cfg, true), "environment", "tool_missing")
	eq(t, "detail", e.Detail, "$KOGEN_NODE is not available")
	// Commands also get the Node Kogen recorded, so it counts when the caller has none.
	if err := RequireTools(s, Tools{Node: "/bin/sh"}, root, cfg, true); err != nil {
		t.Fatal(err)
	}
}

func TestUnclosedQuoteInAConfiguredCommandIsAnInternalFailure(t *testing.T) {
	root := t.TempDir()
	s := sys.NewWith(testEnv(), root)
	err := RequireTools(s, Tools{}, root, configWith(`echo "unterminated`), true)
	if err == nil {
		t.Fatal("expected an error")
	}
	if _, ok := sys.AsError(err); ok {
		t.Fatal("a crash in Kogen is not a refusal")
	}
	eq(t, "message", err.Error(), `argv string did not terminate properly, a " was opened but never closed`)
}

func TestRunnerCheckAcceptsARunnerThatExitsZeroAndWritesAReport(t *testing.T) {
	root := t.TempDir()
	s := sys.NewWith(testEnv(), root)
	var progress strings.Builder
	s.Stderr = &progress
	reason, output, err := RunnerCheck(context.Background(), s, Tools{}, root, `cat "$KOGEN_ACCEPTANCE_FEATURES"; echo '{}' > "$KOGEN_ACCEPTANCE_REPORT"`)
	if err != nil || reason != "" {
		t.Fatalf("reason %q, err %v", reason, err)
	}
	eq(t, "the feature the runner sees has no scenarios", output, "Feature: Kogen acceptance runner check\n")
	eq(t, "progress", progress.String(), "kogen: checking the acceptance runner\n")
	reason, output, _ = RunnerCheck(context.Background(), s, Tools{}, root, "echo nope; exit 4")
	eq(t, "failed", reason, "the runner check failed with status 4")
	eq(t, "output", output, "nope\n")
	reason, _, _ = RunnerCheck(context.Background(), s, Tools{}, root, "true")
	eq(t, "no report", reason, "the runner check wrote no report")
}

func TestRequireRunnerRefusesAnUnavailableRunner(t *testing.T) {
	root := t.TempDir()
	s := sys.NewWith(testEnv(), root)
	ok := &project.Config{Acceptance: &project.Acceptance{Run: `echo '{}' > "$KOGEN_ACCEPTANCE_REPORT"`}}
	if err := RequireRunner(context.Background(), s, Tools{}, root, ok); err != nil {
		t.Fatal(err)
	}
	bad := &project.Config{Acceptance: &project.Acceptance{Run: `seq 1 100; exit 7`}}
	e := failWith(t, RequireRunner(context.Background(), s, Tools{}, root, bad), "environment", "acceptance_unavailable")
	eq(t, "detail", e.Detail, "the runner check failed with status 7; fix commands.acceptance.run in .kogen/project.yaml")
	eq(t, "exit", e.Exit, 3)
	eq(t, "excerpt of the output", len(e.Lines), 51)
	eq(t, "omitted marker", e.Lines[30], "[... 50 lines omitted ...]")
	missing := &project.Config{Acceptance: &project.Acceptance{Run: "definitely-not-a-tool"}}
	failWith(t, RequireRunner(context.Background(), s, Tools{}, root, missing), "environment", "tool_missing")
}

func TestToolsFromInstallResolveNodeAndTheBundledTools(t *testing.T) {
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "node-path"), []byte("/opt/node/bin/node\n"), 0o644)
	got := ToolsFromInstall(root)
	eq(t, "node", got.Node, "/opt/node/bin/node")
	eq(t, "quint", got.Quint, filepath.Join(root, "lib/quint/node_modules/@informalsystems/quint/dist/src/cli.js"))
	eq(t, "cucumber", got.Cucumber, filepath.Join(root, "lib/cucumber/node_modules"))
	eq(t, "unreadable node-path", ToolsFromInstall(t.TempDir()).Node[len(ToolsFromInstall(t.TempDir()).Node)-9:], "node-path")
	e := failWith(t, got.Require(), "environment", "tool_missing")
	eq(t, "detail", e.Detail, "node is not available at /opt/node/bin/node; reinstall Kogen")
	node := filepath.Join(root, "node")
	os.WriteFile(node, []byte("#!/bin/sh\n"), 0o755)
	e = failWith(t, Tools{Node: node, Quint: filepath.Join(root, "q.js")}.Require(), "environment", "tool_missing")
	eq(t, "detail", e.Detail, "quint is not available at "+filepath.Join(root, "q.js")+"; reinstall Kogen")
}

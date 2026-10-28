package doctor

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"kogen-loop/sys"
	"kogen/git"
	"kogen/project"
	"kogen/verify"
)

func TestFormatDuration(t *testing.T) {
	for d, want := range map[time.Duration]string{12 * time.Millisecond: "12ms", 0: "0ms", 1500 * time.Millisecond: "1.5s"} {
		if got := FormatDuration(d); got != want {
			t.Errorf("FormatDuration(%v) = %q, want %q", d, got, want)
		}
	}
}

func TestTextAndJSON(t *testing.T) {
	checks := []Check{{"git", "fail", "no identity", "do it"}, {"models", "ok", "fine", "stale"}}
	if got, want := Text(checks), "fail git - no identity\n  fix: do it\nok models - fine\n"; got != want {
		t.Fatalf("Text = %q, want %q", got, want)
	}
	var arr []map[string]string
	if err := json.Unmarshal([]byte(JSON(checks)), &arr); err != nil || len(arr) != 2 || arr[0]["fix"] != "do it" || arr[1]["fix"] != "" || len(arr[0]) != 4 {
		t.Fatalf("JSON = %v, %v", arr, err)
	}
	if !Failed(checks) || Failed(checks[1:]) {
		t.Fatal("Failed")
	}
}

func fakeClaude(t *testing.T, version, auth string) {
	t.Helper()
	dir := t.TempDir()
	script := "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo '" + version + " (Claude Code)'; exit 0; fi\necho '" + auth + "'\n"
	if err := os.WriteFile(filepath.Join(dir, "claude"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
}

func TestClaudeChecks(t *testing.T) {
	home := t.TempDir()
	signedIn := `{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}`
	t.Run("older claude names both versions", func(t *testing.T) {
		fakeClaude(t, "2.0.0", signedIn)
		p, f := checkClaude(Input{Home: home})
		if len(p) != 1 || !strings.Contains(p[0], "2.0.0") || !strings.Contains(p[0], "2.1.295") || len(f) != 1 {
			t.Fatalf("%v %v", p, f)
		}
	})
	t.Run("minimum with subscription sign-in", func(t *testing.T) {
		fakeClaude(t, "2.1.295", signedIn)
		if p, f := checkClaude(Input{Home: home}); len(p)+len(f) != 0 {
			t.Fatalf("%v %v", p, f)
		}
	})
	t.Run("not signed in", func(t *testing.T) {
		fakeClaude(t, "2.1.295", `{"loggedIn":false}`)
		if _, f := checkClaude(Input{Home: home}); len(f) != 1 || f[0] != "kogen provider login claude-code" {
			t.Fatalf("%v", f)
		}
	})
	t.Run("stored token replaces sign-in", func(t *testing.T) {
		fakeClaude(t, "2.1.295", `{"loggedIn":false}`)
		h := t.TempDir()
		dir := filepath.Join(h, ".kogen", "credentials")
		os.MkdirAll(dir, 0o700)
		os.WriteFile(filepath.Join(dir, "claude-code.json"), []byte(`{"provider":"claude-code","api_key":"sk-ant-oat01-synthetic"}`), 0o600)
		if p, _ := checkClaude(Input{Home: h}); len(p) != 0 {
			t.Fatalf("%v", p)
		}
	})
	t.Run("missing binary", func(t *testing.T) {
		t.Setenv("PATH", t.TempDir())
		if _, f := checkClaude(Input{Home: home}); len(f) != 1 || f[0] != installClaude {
			t.Fatalf("%v", f)
		}
	})
}

func TestInstallCheck(t *testing.T) {
	s := sys.NewWith(os.Environ(), t.TempDir())
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("no node")
	}
	c := checkInstall(s, Input{Tools: verify.Tools{Node: node, Quint: "/nonexistent/cli.js", Cucumber: "/nonexistent"}, Version: "kogen dev"})
	if c.Status != "fail" || c.Fix != reinstall || !strings.Contains(c.Detail, "cucumber") || strings.Contains(c.Detail, "node does") {
		t.Fatalf("%+v", c)
	}
	if c := checkInstall(s, Input{Tools: verify.Tools{Node: node}}); !strings.Contains(c.Detail, "VERSION") {
		t.Fatalf("%+v", c)
	}
}

func TestModelsChecks(t *testing.T) {
	home := t.TempDir()
	cfgText := "version: 1\nmodels:\n  shape: {provider: supergrok, model: grok-4.7, effort: high}\n  build: {provider: supergrok, model: grok-4.7, effort: high}\n"
	c := checkModels(readable(cfgText), Input{Home: home})
	if c.Status != "fail" || c.Fix != "kogen provider login supergrok; kogen provider login chatgpt" {
		t.Fatalf("%+v", c)
	}
}

func TestCommandsReportAndSkip(t *testing.T) {
	s := sys.NewWith(os.Environ(), t.TempDir())
	if c, err := checkCommands(context.Background(), s, Input{Quick: true}, nil, nil, true); err != nil || c.Status != "skip" {
		t.Fatalf("%+v %v", c, err)
	}
	if c, _ := checkCommands(context.Background(), s, Input{}, nil, nil, false); c.Status != "skip" || !strings.Contains(c.Detail, "not valid") {
		t.Fatalf("%+v", c)
	}
}

func readable(text string) *project.Config { return project.ReadableConfig(text) }

func gitRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for _, args := range [][]string{{"init", "-q"}, {"-c", "user.name=T", "-c", "user.email=t@example.invalid", "commit", "-q", "--allow-empty", "-m", "base"}} {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	return dir
}

func TestCommandsChecksAndAcceptanceRunner(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("no node")
	}
	dir := gitRepo(t)
	s := sys.NewWith(os.Environ(), dir)
	repo, err := git.OpenReadOnly(dir, s.Env)
	if err != nil {
		t.Fatal(err)
	}
	tools := verify.Tools{Node: node, Cucumber: "/nonexistent"}
	cfg := &project.Config{Checks: []project.Check{{Name: "broken", Run: "touch marker; exit 7"}, {Name: "fine", Run: "true"}},
		Acceptance: &project.Acceptance{Run: "anything", StepsDir: "features/steps"}}
	c, err := checkCommands(context.Background(), s, Input{Tools: tools}, repo, cfg, true)
	if err != nil {
		t.Fatal(err)
	}
	if c.Status != "fail" || !strings.Contains(c.Detail, "broken status=7 in ") || !strings.Contains(c.Detail, "fine status=0 in ") ||
		!strings.Contains(c.Detail, "check_failing (broken)") || !strings.Contains(c.Detail, "bundled Cucumber does not run") ||
		c.Fix != "fix the check broken or remove it from commands.checks; "+reinstall {
		t.Fatalf("%+v", c)
	}
	if _, err := os.Stat(filepath.Join(dir, "marker")); err == nil {
		t.Fatal("the check ran in the checkout")
	}
	cfg = &project.Config{Checks: []project.Check{{Name: "fine", Run: "true"}}}
	if c, err := checkCommands(context.Background(), s, Input{Tools: tools}, repo, cfg, true); err != nil || c.Status != "ok" || !strings.Contains(c.Detail, "acceptance runner skipped") {
		t.Fatalf("%+v %v", c, err)
	}
}

func TestOutsideRepositoryAndMissingConfigFixes(t *testing.T) {
	s := &sys.Session{Env: os.Environ()}
	_, c := checkGit(s, Input{Project: t.TempDir()})
	if c.Status != "fail" || c.Fix != "run this inside your project's repository (cd <repo>), or git init to start a new one" {
		t.Fatalf("%+v", c)
	}
	dir := gitRepo(t)
	if c, _, _ := checkConfig(nil, Input{Project: dir}); c.Status != "fail" || c.Fix != "in your project, run kogen init" {
		t.Fatalf("%+v", c)
	}
}

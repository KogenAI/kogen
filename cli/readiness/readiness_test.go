package readiness

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/KogenAI/kogen-coordinator/project"
	"github.com/KogenAI/kogen-executor/executor/claudecode"
	"github.com/KogenAI/kogen-loop/sys"
	"github.com/KogenAI/kogen-verification/verify"
)

func TestText(t *testing.T) {
	checks := []Check{{"git", "fail", "no identity", "do it; or that"}, {"models", "ok", "fine", "stale"}}
	if got, want := Text(checks), "fail git - no identity\n  fix: do it; or that\nok models - fine\n"; got != want {
		t.Fatalf("Text = %q, want %q", got, want)
	}
}

// managedClaude installs a fake Kogen Claude Code in home that answers --version and
// `auth status --json`, and puts a decoy `claude` first on PATH that must never run.
func managedClaude(t *testing.T, home, version, auth string) (decoyRan func() bool) {
	t.Helper()
	// The stand-in is not the pinned size, and readiness never installs, so this origin is never contacted.
	t.Setenv(claudecode.SeamEnv, "http://127.0.0.1:1")
	dir := filepath.Dir(claudecode.RuntimePath(home))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo '" + version + "'; exit 0; fi\necho '" + auth + "'\n"
	if err := os.WriteFile(claudecode.RuntimePath(home), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	ran := filepath.Join(bin, "ran")
	decoy := "#!/bin/sh\necho ran > '" + ran + "'\necho '2.1.312 (Claude Code)'\n"
	if err := os.WriteFile(filepath.Join(bin, "claude"), []byte(decoy), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	return func() bool { _, err := os.Stat(ran); return err == nil }
}

func storeToken(t *testing.T, home string) {
	t.Helper()
	dir := filepath.Join(home, ".kogen", "credentials")
	os.MkdirAll(dir, 0o700)
	os.WriteFile(filepath.Join(dir, "claude-code.json"), []byte(`{"provider":"claude-code","api_key":"sk-ant-oat01-synthetic"}`), 0o600)
}

func TestClaudeChecks(t *testing.T) {
	signedIn := `{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}`
	const pinned = "2.1.312 (Claude Code)"
	const signInFix = "kogen provider login claude-code"
	const noSignIn = "claude-code: no stored token and no claude.ai subscription sign-in"
	t.Run("another version names the path and the fix", func(t *testing.T) {
		home := t.TempDir()
		decoy := managedClaude(t, home, "2.1.314 (Claude Code)", signedIn)
		storeToken(t, home)
		p, f := checkClaude(Input{Home: home})
		path := claudecode.RuntimePath(home)
		if len(p) != 1 || p[0] != "claude-code: Kogen's Claude Code at "+path+" reports 2.1.314 (Claude Code), not the pinned 2.1.312" ||
			len(f) != 1 || f[0] != "rm -rf "+claudecode.RuntimeDir(home) || decoy() {
			t.Fatalf("%q %q", p, f)
		}
	})
	t.Run("pinned with subscription sign-in", func(t *testing.T) {
		home := t.TempDir()
		decoy := managedClaude(t, home, pinned, signedIn)
		if p, f := checkClaude(Input{Home: home}); len(p)+len(f) != 0 || decoy() {
			t.Fatalf("%v %v", p, f)
		}
	})
	t.Run("not signed in", func(t *testing.T) {
		home := t.TempDir()
		managedClaude(t, home, pinned, `{"loggedIn":false}`)
		if p, f := checkClaude(Input{Home: home}); len(p) != 1 || p[0] != noSignIn || len(f) != 1 || f[0] != signInFix {
			t.Fatalf("%q %q", p, f)
		}
	})
	t.Run("another sign-in route is no subscription", func(t *testing.T) {
		home := t.TempDir()
		managedClaude(t, home, pinned, `{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty"}`)
		if p, _ := checkClaude(Input{Home: home}); len(p) != 1 || p[0] != noSignIn {
			t.Fatalf("%q", p)
		}
	})
	t.Run("stored token replaces sign-in", func(t *testing.T) {
		home := t.TempDir()
		managedClaude(t, home, pinned, `{"loggedIn":false}`)
		storeToken(t, home)
		if p, f := checkClaude(Input{Home: home}); len(p)+len(f) != 0 {
			t.Fatalf("%v %v", p, f)
		}
	})
	t.Run("not installed yet is no problem with a token and never downloads", func(t *testing.T) {
		home := t.TempDir()
		t.Setenv(claudecode.SeamEnv, "http://127.0.0.1:1")
		storeToken(t, home)
		if p, f := checkClaude(Input{Home: home}); len(p)+len(f) != 0 {
			t.Fatalf("%v %v", p, f)
		}
		if _, err := os.Stat(claudecode.Root(home)); err == nil {
			t.Fatal("readiness created Kogen's Claude Code folder")
		}
	})
	t.Run("not installed and no token", func(t *testing.T) {
		home := t.TempDir()
		decoy := managedClaude(t, t.TempDir(), pinned, signedIn)
		if p, f := checkClaude(Input{Home: home}); len(p) != 1 || p[0] != noSignIn || len(f) != 1 || f[0] != signInFix || decoy() {
			t.Fatalf("%q %q", p, f)
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

func writeProjectFile(t *testing.T, root, rel, text string) {
	t.Helper()
	path := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestModelsChecks(t *testing.T) {
	home := t.TempDir()
	const projectText = "version: 1\n"
	t.Run("a project without a models file keeps the default lineup", func(t *testing.T) {
		root := t.TempDir()
		writeProjectFile(t, root, project.ConfigPath, projectText)
		c := checkModels(root, Input{Home: home})
		want := Check{"models", "fail", "shape: chatgpt has no stored login; build: chatgpt has no stored login; review: chatgpt has no stored login", "kogen provider login chatgpt"}
		if c != want {
			t.Fatalf("%+v", c)
		}
	})
	t.Run("the team models file names the roles and a role it omits stays the default", func(t *testing.T) {
		root := t.TempDir()
		writeProjectFile(t, root, project.ConfigPath, projectText)
		writeProjectFile(t, root, project.ModelsPath, "models:\n  shape: {provider: supergrok, model: grok-4.7, effort: high}\n  build: {provider: supergrok, model: grok-4.7, effort: high}\n")
		c := checkModels(root, Input{Home: home})
		if c.Status != "fail" || c.Fix != "kogen provider login supergrok; kogen provider login chatgpt" ||
			c.Detail != "shape: supergrok has no stored login; build: supergrok has no stored login; review: chatgpt has no stored login" {
			t.Fatalf("%+v", c)
		}
	})
	t.Run("the host-local models file wins per role", func(t *testing.T) {
		root := t.TempDir()
		writeProjectFile(t, root, project.ConfigPath, projectText)
		writeProjectFile(t, root, project.ModelsPath, "models:\n  shape: {provider: supergrok, model: grok-4.7, effort: high}\n  build: {provider: supergrok, model: grok-4.7, effort: high}\n  review: {provider: supergrok, model: grok-4.7, effort: high}\n")
		writeProjectFile(t, root, project.LocalModelsPath, "models:\n  build: {provider: opencode-go, model: kimi-k3, effort: high}\n")
		c := checkModels(root, Input{Home: home})
		want := Check{"models", "fail", "shape: supergrok has no stored login; build: opencode-go has no stored login; review: supergrok has no stored login", "kogen provider login supergrok; kogen provider login opencode-go"}
		if c != want {
			t.Fatalf("%+v", c)
		}
	})
	t.Run("a refused models file is a fail line naming the file", func(t *testing.T) {
		root := t.TempDir()
		writeProjectFile(t, root, project.ConfigPath, projectText)
		writeProjectFile(t, root, project.LocalModelsPath, "models:\n  build: {provider: nowhere, model: m, effort: high}\n")
		c := checkModels(root, Input{Home: home})
		if c.Status != "fail" || !strings.HasPrefix(c.Detail, project.LocalModelsPath+": line 2: ") || c.Fix != "edit "+project.LocalModelsPath {
			t.Fatalf("%+v", c)
		}
	})
	t.Run("a models key in the project file is a fail line naming the project file", func(t *testing.T) {
		root := t.TempDir()
		writeProjectFile(t, root, project.ConfigPath, "version: 1\nmodels:\n  shape: {provider: supergrok, model: grok-4.7, effort: high}\n")
		c := checkModels(root, Input{Home: home})
		want := Check{"models", "fail", project.ConfigPath + ": line 2: models is no longer read from " + project.ConfigPath + "; move the model lineup to " + project.ModelsPath, "edit " + project.ConfigPath}
		if c != want {
			t.Fatalf("%+v", c)
		}
		if got := checkConfig(root); got.Status != "fail" || got.Detail != "line 2: models is no longer read from "+project.ConfigPath+"; move the model lineup to "+project.ModelsPath {
			t.Fatalf("%+v", got)
		}
	})
}

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

func TestOutsideRepositoryAndMissingConfigFixes(t *testing.T) {
	s := &sys.Session{Env: os.Environ()}
	_, c := checkGit(s, Input{Project: t.TempDir()})
	if c.Status != "fail" || c.Fix != "run this inside your project's repository (cd <repo>), or git init to start a new one" {
		t.Fatalf("%+v", c)
	}
	dir := gitRepo(t)
	if c := checkConfig(dir); c.Status != "fail" || c.Fix != "in your project, run kogen init" {
		t.Fatalf("%+v", c)
	}
}

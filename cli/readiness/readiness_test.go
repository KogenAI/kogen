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

func TestEmptyReportPrintsNothing(t *testing.T) {
	if got := Text(nil); got != "" {
		t.Fatalf("Text(nil) = %q, want an empty string", got)
	}
}

func TestNonFailureStatusPrintsNoFixLine(t *testing.T) {
	checks := []Check{{"models", "warn", "stale login", "kogen provider login chatgpt"}}
	if got, want := Text(checks), "warn models - stale login\n"; got != want {
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
	decoy := "#!/bin/sh\necho ran > '" + ran + "'\necho '2.1.318 (Claude Code)'\n"
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
	const pinned = "2.1.318 (Claude Code)"
	const signInFix = "kogen provider login claude-code"
	const noSignIn = "claude-code: no stored token and no claude.ai subscription sign-in"
	t.Run("another version names the path and the fix", func(t *testing.T) {
		home := t.TempDir()
		decoy := managedClaude(t, home, "2.1.314 (Claude Code)", signedIn)
		storeToken(t, home)
		p, f := checkClaude(Input{Home: home})
		path := claudecode.RuntimePath(home)
		if len(p) != 1 || p[0] != "claude-code: Kogen's Claude Code at "+path+" reports 2.1.314 (Claude Code), not the pinned 2.1.318" ||
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
	for _, args := range [][]string{{"init", "-q"}, {"-c", "user.name=T", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "base"}} {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1", "GIT_TERMINAL_PROMPT=0")
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
	if c, want := checkConfig(dir), (Check{"config", "fail", ".kogen/project.yaml is missing", "in your project, run kogen init"}); c != want {
		t.Fatalf("%+v", c)
	}
}

func checkNames(checks []Check) []string {
	var names []string
	for _, c := range checks {
		names = append(names, c.Check)
	}
	return names
}

func assertReportOrder(t *testing.T, checks []Check) {
	t.Helper()
	if got, want := strings.Join(checkNames(checks), ","), "install,git,config,models"; got != want {
		t.Fatalf("Run returned the checks %q, want %q", got, want)
	}
}

// runEnv keeps the host's Git configuration out of the examined repository.
func runEnv(extra ...string) []string {
	return append(append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1", "GIT_TERMINAL_PROMPT=0"), extra...)
}

const supergrokLineup = "models:\n" +
	"  shape: {provider: supergrok, model: grok-4.7, effort: high}\n" +
	"  build: {provider: supergrok, model: grok-4.7, effort: high}\n" +
	"  review: {provider: supergrok, model: grok-4.7, effort: high}\n"

const supergrokDetail = "shape: supergrok has no stored login; build: supergrok has no stored login; review: supergrok has no stored login"

func TestRunReportsInOrderAndChecksTheRepositoryRoot(t *testing.T) {
	repo := gitRepo(t)
	for _, args := range [][]string{{"config", "user.name", "T"}, {"config", "user.email", "t@example.invalid"}} {
		cmd := exec.Command("git", args...)
		cmd.Dir = repo
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	writeProjectFile(t, repo, project.ConfigPath, "version: 1\n")
	writeProjectFile(t, repo, project.ModelsPath, supergrokLineup)
	nested := filepath.Join(repo, "services", "api")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}
	checks := Run(sys.NewWith(runEnv(), nested), Input{Project: nested, Home: t.TempDir()})
	assertReportOrder(t, checks)
	if c := checks[1]; c.Status != "ok" || !strings.HasSuffix(c.Detail, repo) {
		t.Fatalf("git check = %+v, want ok for the repository %s", c, repo)
	}
	if c, want := checks[2], ok("config", project.ConfigPath+" is valid"); c != want {
		t.Fatalf("config check = %+v, want %+v from the repository root", c, want)
	}
	if c := checks[3]; c.Status != "fail" || c.Detail != supergrokDetail {
		t.Fatalf("models check = %+v, want the lineup of the repository root", c)
	}
}

func TestRunOutsideRepositoryStillReportsAllChecks(t *testing.T) {
	base := t.TempDir()
	dir := filepath.Join(base, "project")
	writeProjectFile(t, dir, project.ConfigPath, "version: 1\n")
	writeProjectFile(t, dir, project.ModelsPath, supergrokLineup)
	// The ceiling keeps Git from finding a repository above the temporary folder.
	env := runEnv("GIT_CEILING_DIRECTORIES=" + base)
	checks := Run(sys.NewWith(env, dir), Input{Project: dir, Home: t.TempDir()})
	assertReportOrder(t, checks)
	if c := checks[1]; c.Status != "fail" || c.Detail != dir+" is not inside a Git repository" {
		t.Fatalf("git check = %+v, want the failure for %s", c, dir)
	}
	if c, want := checks[2], ok("config", project.ConfigPath+" is valid"); c != want {
		t.Fatalf("config check = %+v, want %+v from the project directory", c, want)
	}
	if c := checks[3]; c.Status != "fail" || c.Detail != supergrokDetail {
		t.Fatalf("models check = %+v, want the lineup of the project directory", c)
	}
}

func TestRunConfigReports(t *testing.T) {
	for _, state := range []string{"missing", "directory", "valid", "malformed"} {
		t.Run(state, func(t *testing.T) {
			root := t.TempDir()
			path := filepath.Join(root, project.ConfigPath)
			want := Check{"config", "fail", ".kogen/project.yaml is missing", "in your project, run kogen init"}
			wantText := "fail config - .kogen/project.yaml is missing\n  fix: in your project, run kogen init\n"
			switch state {
			case "directory":
				if err := os.MkdirAll(path, 0o755); err != nil {
					t.Fatal(err)
				}
				_, err := os.ReadFile(path)
				if err == nil {
					t.Fatal("reading a directory unexpectedly succeeded")
				}
				want.Detail = ".kogen/project.yaml cannot be read: " + err.Error()
				want.Fix = "make .kogen/project.yaml a readable regular config file"
				wantText = "fail config - .kogen/project.yaml cannot be read: " + err.Error() + "\n  fix: make .kogen/project.yaml a readable regular config file\n"
			case "valid":
				writeProjectFile(t, root, project.ConfigPath, "version: 1\n")
				want = Check{"config", "ok", ".kogen/project.yaml is valid", ""}
				wantText = "ok config - .kogen/project.yaml is valid\n"
			case "malformed":
				writeProjectFile(t, root, project.ConfigPath, "version: 1\ncommands: [\n")
				want = Check{"config", "fail", "line 2: unclosed [", "edit .kogen/project.yaml at line 2"}
				wantText = "fail config - line 2: unclosed [\n  fix: edit .kogen/project.yaml at line 2\n"
			}
			checks := Run(sys.NewWith(runEnv("GIT_CEILING_DIRECTORIES="+root), root), Input{Project: root, Home: t.TempDir()})
			var config []Check
			for _, c := range checks {
				if c.Check == "config" {
					config = append(config, c)
				}
			}
			if len(config) != 1 || config[0] != want {
				t.Fatalf("config checks = %+v, want %+v", config, want)
			}
			if got := Text(config); got != wantText {
				t.Fatalf("Text = %q, want %q", got, wantText)
			}
		})
	}
}

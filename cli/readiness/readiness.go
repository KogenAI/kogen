// Package readiness is the report that ends `kogen init`: what is ready for a first feature
// (install, Git, configuration, model logins) and the exact fix for each problem. It makes no
// model call and changes nothing in the checkout.
package readiness

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen/executor/claudecode"
	"kogen/git"
	"kogen/project"
	"kogen/verify"
)

// Check is one line of the report.
type Check struct {
	Check  string
	Status string
	Detail string
	Fix    string
}

// Input says what to examine. Version is the installed VERSION line.
type Input struct {
	Project string
	Tools   verify.Tools
	Version string
	Home    string
}

const (
	reinstall      = "reinstall Kogen"
	gitIdentityFix = `run git config user.name "<name>" and git config user.email "<email>" (global or repository)`
)

func ok(check, detail string) Check { return Check{check, "ok", detail, ""} }
func fail(check, detail string, fixes ...string) Check {
	return Check{check, "fail", detail, strings.Join(fixes, "; ")}
}

// Text is the report: one line per check, a `  fix:` line after each failure.
func Text(checks []Check) string {
	var b strings.Builder
	for _, c := range checks {
		fmt.Fprintf(&b, "%s %s - %s\n", c.Status, c.Check, c.Detail)
		if c.Status == "fail" {
			fmt.Fprintf(&b, "  fix: %s\n", c.Fix)
		}
	}
	return b.String()
}

// Run examines the project: install, git, config and models, in that order.
func Run(s *sys.Session, in Input) []Check {
	checks := []Check{checkInstall(s, in)}
	repo, gitCheck := checkGit(s, in)
	cfgCheck, cfg := checkConfig(repo, in)
	return append(checks, gitCheck, cfgCheck, checkModels(cfg, in))
}

func toolEnv(t verify.Tools) map[string]string {
	env := map[string]string{}
	for k, v := range map[string]string{"KOGEN_NODE": t.Node, "KOGEN_QUINT": t.Quint, "KOGEN_CUCUMBER": t.Cucumber} {
		if v != "" {
			env[k] = v
		}
	}
	return env
}

func exec1(s *sys.Session, t verify.Tools, command, dir string) (sys.Result, error) {
	return s.Run(command, dir, sys.Options{Env: toolEnv(t), KillGroupOnExit: true})
}

const cucumberVersion = `NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --version`

func checkInstall(s *sys.Session, in Input) Check {
	var problems []string
	if in.Version == "" {
		problems = append(problems, "the VERSION file is missing")
	}
	for _, c := range []struct{ name, command string }{
		{"node", `"$KOGEN_NODE" --version`},
		{"cucumber", cucumberVersion},
		{"quint", `"$KOGEN_NODE" "$KOGEN_QUINT" --version`},
	} {
		res, err := exec1(s, in.Tools, c.command, s.Cwd)
		if err != nil || res.Status != 0 {
			problems = append(problems, "bundled "+c.name+" does not run")
		}
	}
	if len(problems) > 0 {
		return fail("install", strings.Join(problems, "; "), reinstall)
	}
	return ok("install", in.Version+"; node, cucumber and quint run")
}

func checkGit(s *sys.Session, in Input) (*git.Repo, Check) {
	repo, err := git.OpenReadOnly(in.Project, s.Env)
	if err != nil {
		return nil, fail("git", in.Project+" is not inside a Git repository", "run this inside your project's repository (cd <repo>), or git init to start a new one")
	}
	if !repo.CanCommit() {
		return repo, fail("git", "no Git user.name and user.email", gitIdentityFix)
	}
	return repo, ok("git", "repository "+repo.Dir)
}

func checkConfig(repo *git.Repo, in Input) (Check, *project.Config) {
	root := in.Project
	if repo != nil {
		root = repo.Dir
	}
	text, err := os.ReadFile(filepath.Join(root, project.ConfigPath))
	if err != nil {
		return fail("config", project.ConfigPath+" is missing", "in your project, run kogen init"), project.ReadableConfig("")
	}
	cfg, err := project.ParseConfig(string(text), filepath.Join(root, project.ConfigPath))
	if err == nil {
		return ok("config", project.ConfigPath+" is valid"), cfg
	}
	readable := project.ReadableConfig(string(text))
	e, isKogen := sys.AsError(err)
	if !isKogen || len(e.Lines) == 0 {
		msg := err.Error()
		if isKogen {
			msg = e.Detail
		}
		return fail("config", msg, "edit "+project.ConfigPath), readable
	}
	var lines []string
	for _, l := range e.Lines {
		lines = append(lines, strings.TrimPrefix(strings.SplitN(l, ":", 2)[0], "line "))
	}
	return fail("config", strings.Join(e.Lines, "; "), "edit "+project.ConfigPath+" at line "+strings.Join(lines, ", ")), readable
}

type namedRole struct {
	name string
	role project.Role
}

func checkModels(cfg *project.Config, in Input) Check {
	var roles []namedRole
	for _, n := range project.ModelRoles {
		roles = append(roles, namedRole{n, cfg.Models[n]})
	}
	if cfg.ShapeWorkers.Enabled {
		for _, n := range []string{"read", "probe", "draft"} {
			if r, found := cfg.ShapeWorkers.Roles[n]; found {
				roles = append(roles, namedRole{"shape worker " + n, r})
			}
		}
	}
	var problems, fixes, names []string
	seen := map[string]bool{}
	needClaude := false
	for _, nr := range roles {
		names = append(names, nr.name)
		if nr.role.External() {
			needClaude = true
			continue
		}
		info, known := provider.Lookup(nr.role.Provider)
		if !known {
			problems = append(problems, nr.name+": unknown provider "+nr.role.Provider)
			fixes = append(fixes, "edit "+project.ConfigPath)
			continue
		}
		if err := provider.RequireLogin(in.Home, []provider.Role{{Provider: info.Name}}); err != nil {
			problems = append(problems, nr.name+": "+info.Name+" has no stored login")
			if !seen[info.Name] {
				fixes = append(fixes, "kogen provider login "+info.Name)
			}
			seen[info.Name] = true
		}
	}
	if needClaude {
		p, f := checkClaude(in)
		problems = append(problems, p...)
		fixes = append(fixes, f...)
	}
	if len(problems) > 0 {
		return fail("models", strings.Join(problems, "; "), dedupe(fixes)...)
	}
	return ok("models", strings.Join(names, ", ")+" ready")
}

func dedupe(list []string) []string {
	var out []string
	for _, x := range list {
		if !slices.Contains(out, x) {
			out = append(out, x)
		}
	}
	return out
}

// checkClaude examines Kogen's own Claude Code. It never downloads: a runtime that is not
// installed yet is no problem by itself.
func checkClaude(in Input) (problems, fixes []string) {
	if _, ok := claudecode.Supported(); !ok {
		return []string{"claude-code: " + claudecode.UnsupportedMessage(runtime.GOOS, runtime.GOARCH)}, []string{"run Kogen on macOS on Apple Silicon or Linux x86-64"}
	}
	path := claudecode.RuntimePath(in.Home)
	_, err := os.Lstat(path)
	present := err == nil
	if present {
		out, err := claudecode.Probe(context.Background(), in.Home, "--version")
		answer := strings.TrimSpace(string(out))
		if err != nil {
			answer = err.Error()
		}
		if err != nil || !claudecode.Pinned(answer) {
			problems = append(problems, "claude-code: "+claudecode.NotPinnedMessage(path, answer))
			fixes = append(fixes, "rm -rf "+claudecode.RuntimeDir(in.Home))
		}
	}
	if _, stored := provider.ClaudeCodeToken(in.Home); stored {
		return
	}
	var info struct {
		LoggedIn   bool   `json:"loggedIn"`
		AuthMethod string `json:"authMethod"`
	}
	signedIn := false
	if present {
		status, _ := claudecode.Probe(context.Background(), in.Home, "auth", "status", "--json")
		signedIn = json.Unmarshal(status, &info) == nil && info.LoggedIn && info.AuthMethod == "claude.ai"
	}
	if !signedIn {
		problems = append(problems, "claude-code: no stored token and no claude.ai subscription sign-in")
		fixes = append(fixes, "kogen provider login claude-code")
	}
	return
}

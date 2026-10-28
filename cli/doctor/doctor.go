// Package doctor is `kogen doctor`: a read-only report of what is ready for a first feature and
// how to fix what is not. It makes no model call, changes nothing in the checkout and sets no
// time limit; the project's commands run once on the committed tree in a scratch copy.
package doctor

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen/executor/claudecode"
	"kogen/git"
	"kogen/project"
	"kogen/verify"
)

// Check is one line of the report.
type Check struct {
	Check  string `json:"check"`
	Status string `json:"status"`
	Detail string `json:"detail"`
	Fix    string `json:"fix"`
}

// Input says what to examine. Version is the installed VERSION line.
type Input struct {
	Project string
	Quick   bool
	Tools   verify.Tools
	Version string
	Home    string
}

const (
	reinstall      = "reinstall Kogen"
	installClaude  = "npm install -g @anthropic-ai/claude-code"
	gitIdentityFix = `run git config user.name "<name>" and git config user.email "<email>" (global or repository)`
)

func ok(check, detail string) Check   { return Check{check, "ok", detail, ""} }
func skip(check, detail string) Check { return Check{check, "skip", detail, ""} }
func fail(check, detail string, fixes ...string) Check {
	return Check{check, "fail", detail, strings.Join(fixes, "; ")}
}

// Failed reports whether any check failed.
func Failed(checks []Check) bool {
	return slices.ContainsFunc(checks, func(c Check) bool { return c.Status == "fail" })
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

// JSON is the report as one JSON array.
func JSON(checks []Check) string {
	out := make([]Check, len(checks))
	for i, c := range checks {
		if c.Status != "fail" {
			c.Fix = ""
		}
		out[i] = c
	}
	b, _ := json.Marshal(out)
	return string(b) + "\n"
}

// FormatDuration is a duration as the report shows it: whole milliseconds below a second.
func FormatDuration(d time.Duration) string {
	if d < time.Second {
		return fmt.Sprintf("%dms", d.Milliseconds())
	}
	return fmt.Sprintf("%.1fs", d.Seconds())
}

// Run examines the project. The error is an interrupt or an internal failure, not a failed check.
func Run(ctx context.Context, s *sys.Session, in Input) ([]Check, error) {
	checks := []Check{checkInstall(s, in)}
	repo, gitCheck := checkGit(s, in)
	checks = append(checks, gitCheck)
	cfgCheck, cfg, valid := checkConfig(repo, in)
	checks = append(checks, cfgCheck, checkModels(cfg, in))
	cmd, err := checkCommands(ctx, s, in, repo, cfg, valid)
	if err != nil {
		return nil, err
	}
	return append(checks, cmd), nil
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

func checkConfig(repo *git.Repo, in Input) (Check, *project.Config, bool) {
	root := in.Project
	if repo != nil {
		root = repo.Dir
	}
	text, err := os.ReadFile(filepath.Join(root, project.ConfigPath))
	if err != nil {
		return fail("config", project.ConfigPath+" is missing", "in your project, run kogen init"), project.ReadableConfig(""), false
	}
	cfg, err := project.ParseConfig(string(text), filepath.Join(root, project.ConfigPath))
	if err == nil {
		return ok("config", project.ConfigPath+" is valid"), cfg, true
	}
	readable := project.ReadableConfig(string(text))
	e, isKogen := sys.AsError(err)
	if !isKogen || len(e.Lines) == 0 {
		msg := err.Error()
		if isKogen {
			msg = e.Detail
		}
		return fail("config", msg, "edit "+project.ConfigPath), readable, false
	}
	var lines []string
	for _, l := range e.Lines {
		lines = append(lines, strings.TrimPrefix(strings.SplitN(l, ":", 2)[0], "line "))
	}
	return fail("config", strings.Join(e.Lines, "; "), "edit "+project.ConfigPath+" at line "+strings.Join(lines, ", ")), readable, false
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

func checkClaude(in Input) (problems, fixes []string) {
	bin, err := exec.LookPath("claude")
	if err != nil {
		return []string{"claude-code: no claude binary on PATH"}, []string{installClaude}
	}
	out, err := exec.Command(bin, "--version").Output()
	version := strings.TrimSpace(string(out))
	switch {
	case err != nil:
		problems = append(problems, "claude-code: `claude --version` does not run")
		fixes = append(fixes, installClaude)
	case !claudecode.VersionAtLeast(version, claudecode.MinVersion):
		problems = append(problems, "claude-code: found claude "+version+", minimum "+claudecode.MinVersion)
		fixes = append(fixes, installClaude)
	}
	if _, stored := provider.ClaudeCodeToken(in.Home); stored {
		return
	}
	var info struct {
		LoggedIn   bool   `json:"loggedIn"`
		AuthMethod string `json:"authMethod"`
	}
	status, _ := exec.Command(bin, "auth", "status", "--json").Output()
	if json.Unmarshal(status, &info) != nil || !info.LoggedIn || info.AuthMethod != "claude.ai" {
		problems = append(problems, "claude-code: no stored token and no claude.ai subscription sign-in")
		fixes = append(fixes, "kogen provider login claude-code")
	}
	return
}

func checkCommands(ctx context.Context, s *sys.Session, in Input, repo *git.Repo, cfg *project.Config, valid bool) (Check, error) {
	const name = "commands"
	switch {
	case in.Quick:
		return skip(name, "skipped with --quick"), nil
	case !valid:
		return skip(name, "skipped: the configuration is not valid"), nil
	case repo == nil:
		return skip(name, "skipped: not inside a Git repository"), nil
	}
	head := repo.Head()
	if head == "" {
		return skip(name, "skipped: the repository has no commit"), nil
	}
	scratch := sys.TmpPath("kogen-doctor")
	defer os.RemoveAll(scratch)
	tree, err := repo.OK("rev-parse", head+"^{tree}")
	if err != nil {
		return Check{}, err
	}
	if _, err := repo.Materialize(strings.TrimSpace(tree), scratch); err != nil {
		return Check{}, err
	}
	if err := os.MkdirAll(filepath.Join(scratch, ".kogen/local"), 0o755); err != nil {
		return Check{}, err
	}
	var parts []string
	var failing []string
	var fixes []string
	run := func(label, command string) (bool, error) {
		start := time.Now()
		res, err := exec1(s, in.Tools, command, scratch)
		if err != nil {
			if ie := s.Err(); ie != nil {
				return false, ie
			}
			return false, err
		}
		parts = append(parts, fmt.Sprintf("%s status=%d in %s", label, res.Status, FormatDuration(time.Since(start))))
		return res.Status == 0, nil
	}
	setupFailed := false
	for i, cmd := range cfg.Setup {
		label := fmt.Sprintf("setup-%d", i+1)
		passed, err := run(label, cmd)
		if err != nil {
			return Check{}, err
		}
		if !passed {
			setupFailed = true
			failing = append(failing, "Build would stop with setup_failed ("+label+")")
			fixes = append(fixes, "fix "+label+" or remove it from commands.setup")
			break
		}
	}
	if !setupFailed {
		for _, c := range cfg.Checks {
			passed, err := run(c.Name, c.Run)
			if err != nil {
				return Check{}, err
			}
			if !passed {
				failing = append(failing, "Build would stop with check_failing ("+c.Name+")")
				fixes = append(fixes, "fix the check "+c.Name+" or remove it from commands.checks")
			}
		}
		if cfg.Acceptance != nil && cfg.Acceptance.Run != "" {
			res, err := exec1(s, in.Tools, cucumberVersion, scratch)
			if err != nil {
				return Check{}, err
			}
			if res.Status != 0 {
				parts = append(parts, "acceptance runner status="+fmt.Sprint(res.Status))
				failing = append(failing, "Kogen's bundled Cucumber does not run")
				fixes = append(fixes, reinstall)
			} else {
				parts = append(parts, "acceptance runner reachable")
			}
		} else {
			parts = append(parts, "acceptance runner skipped (run is null)")
		}
	}
	detail := strings.Join(parts, "; ")
	if len(parts) == 0 {
		detail = "no commands configured"
	}
	if len(failing) > 0 {
		return fail(name, detail+"; "+strings.Join(failing, "; "), fixes...), nil
	}
	return ok(name, detail), nil
}

package shape

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
	"kogen/agent"
	"kogen/git"
	"kogen/project"
	"kogen/verify"
)

// ---- Init: `kogen init` (SET-1..5, SET-10..13) ----

const (
	initIgnore          = ".kogen/local/"
	initStepsReadmePath = "features/steps/README.md"
	initStepsReadme     = "Cucumber step definitions for Kogen acceptance scenarios.\n"
	initNextAcceptance  = "Next: set commands.acceptance in .kogen/project.yaml"
	initNextChecks      = "Next: add the project's checks to commands.checks in .kogen/project.yaml"
	initNpmPlaceholder  = `echo "Error: no test specified" && exit 1`
)

var (
	initInstructionFiles = []string{"AGENTS.md", "CLAUDE.md", "GEMINI.md", ".cursorrules", ".cursor/rules", ".github/copilot-instructions.md"}
	initSources          = []string{"README.md", "mix.exs", "package.json", "Makefile", ".tool-versions", ".gitlab-ci.yml"}
	initManifestNames    = []string{"mix.exs", "package.json", "mix.lock", "package-lock.json", "npm-shrinkwrap.json", "go.mod", "go.sum"}
	initWorkflowRE       = regexp.MustCompile(`^\.github/workflows/[^/]+\.ya?ml$`)
	initCheckNameRE      = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*\n?$`)
	initLocalToolsRE     = regexp.MustCompile(`(?:^|[;&]\s*)mix\s+local\.(?:hex|rebar)\b`)
	initNpmScriptRE      = regexp.MustCompile(`\bnpm\s+(?:run\s+)?([a-zA-Z0-9:_-]+)\b`)
	initMixTaskRE        = regexp.MustCompile(`\bmix\s+([a-z][a-z0-9_.-]*)\b`)
)

// InitInput is what Init needs besides the session.
type InitInput struct {
	// Client sends the one setup request to the shaping model.
	Client *provider.Client
	// Tools are Kogen's own Node, Quint and Cucumber, given to every command Init runs
	// (KOGEN_NODE, KOGEN_QUINT, KOGEN_CUCUMBER).
	Tools verify.Tools
	// Home is the home directory holding ~/.kogen/credentials; "" means $HOME of the session.
	Home string
}

// Init is `kogen init` in the Git repository containing the session's working directory
// (SET-1..5, SET-10..13): detect the project's commands, ask the shaping model once, keep
// what passes on a copy of the committed tree, add the Cucumber bridge when there is no
// runner, and commit the configuration. It prints the result lines to s.Stdout and progress
// lines to s.Stderr. exit is 0, or the exit code of err (a *sys.Error's Exit, an
// *sys.Interrupted's signal code, 70 for an internal failure); the caller prints err.
func Init(ctx context.Context, s *sys.Session, in InitInput) (exit int, err error) {
	if err := initRun(ctx, s, in); err != nil {
		return initExit(err), err
	}
	return 0, nil
}

func initExit(err error) int {
	var interrupted *sys.Interrupted
	if errors.As(err, &interrupted) {
		return interrupted.ExitCode()
	}
	if e, ok := sys.AsError(err); ok {
		return e.Exit
	}
	return 70
}

func initRun(ctx context.Context, s *sys.Session, in InitInput) error {
	repo, err := git.Open(s.Cwd, s.Env)
	if err != nil {
		return err
	}
	root := repo.Dir
	if _, err := repo.RequireIdentity(); err != nil {
		return err
	}
	head := repo.Head()
	if _, err := os.Stat(filepath.Join(root, project.ConfigPath)); err == nil {
		if _, err := project.LoadConfig(root); err != nil {
			return err
		}
	}
	if head != "" {
		if _, ok := repo.Show(head, project.ConfigPath); ok {
			cfg, err := project.LoadConfig(root)
			if err != nil {
				return err
			}
			s.Puts("Kogen is already initialized in " + root)
			initNextLines(s, cfg)
			return nil
		}
	}
	paths := []string{project.ConfigPath, ".gitignore", initStepsReadmePath}
	dirty, err := repo.ChangedPaths(paths...)
	if err != nil {
		return err
	}
	var uncommitted []string
	if head == "" {
		all, err := repo.ChangedPaths()
		if err != nil {
			return err
		}
		if i := slices.Index(all, ".gitignore"); i >= 0 {
			all = slices.Delete(all, i, i+1)
		}
		uncommitted = all
	}
	configDirty := slices.Contains(dirty, project.ConfigPath)
	if configDirty {
		if st, err := os.Stat(filepath.Join(root, project.ConfigPath)); err == nil && st.Mode().IsRegular() {
			return initCommitLeftover(s, repo, root, head, dirty)
		}
	}
	if head != "" {
		for _, p := range paths {
			if slices.Contains(dirty, p) {
				return sys.Fail("environment", "dirty_tree", p+" has uncommitted changes; commit, stash or discard them first", 5)
			}
		}
	}
	switch {
	case head == "" && len(uncommitted) > 0:
		return sys.Fail("environment", "no_commits",
			fmt.Sprintf("%d file(s) are not committed yet; commit them first (git add -A && git commit -m \"Initial commit\"), then run kogen init", len(uncommitted)), 3)
	case head == "":
		if err := initWriteFiles(repo, root, "", project.Template(), nil); err != nil {
			return err
		}
		sha, err := initCommit(s, repo, []string{project.ConfigPath, ".gitignore"}, "")
		if err != nil {
			return err
		}
		s.Puts("Initialized Kogen in " + root)
		s.Puts("Commit: " + sha + " Initial commit (the first commit of this repository)")
		s.Puts(initNextAcceptance)
		s.Puts(initNextChecks)
		return nil
	}
	return initConfigure(ctx, s, in, repo, root, head)
}

// initCommitLeftover is SET-3: a configuration a failed init commit left behind is committed
// as it is.
func initCommitLeftover(s *sys.Session, repo *git.Repo, root, head string, dirty []string) error {
	if _, err := project.LoadConfig(root); err != nil {
		return err
	}
	gitignore := filepath.Join(root, ".gitignore")
	if err := os.WriteFile(gitignore, []byte(initWithLine(initRead(gitignore), initIgnore)), 0o644); err != nil {
		return err
	}
	paths := []string{project.ConfigPath, ".gitignore"}
	if slices.Contains(dirty, initStepsReadmePath) {
		paths = append(paths, initStepsReadmePath)
	}
	sha, err := initCommit(s, repo, paths, head)
	if err != nil {
		return err
	}
	s.Puts("Initialized Kogen in " + root)
	s.Puts("Commit: " + sha + " Add Kogen configuration")
	cfg, err := project.LoadConfig(root)
	if err != nil {
		return err
	}
	initNextLines(s, cfg)
	return nil
}

func initConfigure(ctx context.Context, s *sys.Session, in InitInput, repo *git.Repo, root, head string) error {
	home := in.Home
	if home == "" {
		home = s.Getenv("HOME")
	}
	if err := provider.RequireLogin(home, []provider.Role{{}}); err != nil {
		return err
	}
	s.Progress("kogen: detecting the project's commands")
	listing, err := repo.OK("ls-tree", "-r", "-z", "--name-only", "HEAD")
	if err != nil {
		return err
	}
	var tracked []string
	for _, p := range strings.Split(listing, "\x00") {
		if p != "" {
			tracked = append(tracked, p)
		}
	}
	sources, manifests := map[string]string{}, map[string]string{}
	for _, p := range tracked {
		if slices.Contains(initSources, p) || initWorkflowRE.MatchString(p) {
			if text, ok := repo.Show(head, p); ok {
				sources[p] = text
			}
		}
		if slices.Contains(initManifestNames, path.Base(p)) {
			if text, ok := repo.Show(head, p); ok {
				manifests[p] = text
			}
		}
	}
	detected := project.Detect(manifests, tracked)
	proposed, err := initAsk(ctx, s, in, detected, tracked, sources, manifests)
	if err != nil {
		return err
	}
	clone := sys.TmpPath("kogen-init")
	defer os.RemoveAll(clone)
	if err := initCommittedCopy(s, repo, root, clone, tracked); err != nil {
		return err
	}
	res, err := initVerify(ctx, s, in, repo, clone, Merge(detected, proposed), detected.Runner)
	if err != nil {
		return err
	}
	os.RemoveAll(clone)

	cfg := &project.Config{Setup: res.setup, Fix: res.fix, Checks: res.checks, Protect: res.protect, Acceptance: res.acceptance}
	var files map[string]string
	if res.bridge {
		files = map[string]string{initStepsReadmePath: initStepsReadme}
	}
	if err := initWriteFiles(repo, root, head, project.RenderConfig(cfg), files); err != nil {
		return err
	}
	s.Puts("Initialized Kogen in " + root)
	setup := "none"
	if len(res.setup) > 0 {
		setup = strings.Join(res.setup, "; ")
	}
	s.Puts("Setup: " + setup)
	var checks string
	switch {
	case len(res.checks) > 0:
		names := make([]string, len(res.checks))
		for i, c := range res.checks {
			names[i] = c.Name
		}
		checks = strings.Join(names, ", ")
	case len(res.leftOut) == 0:
		checks = "none found"
	default:
		checks = "none passed"
	}
	s.Puts("Checks: " + checks)
	if len(res.leftOut) > 0 {
		s.Puts("Left out: " + strings.Join(res.leftOut, "; "))
	}
	s.Puts("Acceptance: " + res.how)
	var found []string
	for _, f := range initInstructionFiles {
		if slices.ContainsFunc(tracked, func(p string) bool { return p == f || strings.HasPrefix(p, f+"/") }) {
			found = append(found, f)
		}
	}
	if len(found) > 0 {
		s.Puts("Note: Kogen gives its models README.md only; it does not read " + strings.Join(found, ", "))
	}
	paths := []string{project.ConfigPath, ".gitignore"}
	if res.bridge {
		paths = append(paths, initStepsReadmePath)
	}
	sha, err := initCommit(s, repo, paths, head)
	if err != nil {
		return err
	}
	s.Puts("Commit: " + sha + " Add Kogen configuration")
	written, err := project.LoadConfig(root)
	if err != nil {
		return err
	}
	initNextLines(s, written)
	return nil
}

func initNextLines(s *sys.Session, cfg *project.Config) {
	if cfg.Acceptance == nil || cfg.Acceptance.Run == "" || cfg.Acceptance.StepsDir == "" {
		s.Puts(initNextAcceptance)
	}
	if len(cfg.Checks) == 0 {
		s.Puts(initNextChecks)
	}
}

// ---- SET-11: one request to the shaping model ----

func initAsk(ctx context.Context, s *sys.Session, in InitInput, detected project.Detected, tracked []string, sources, manifests map[string]string) (InitProposal, error) {
	role := project.DefaultModels()["shape"]
	s.Progress(fmt.Sprintf("kogen: asking %s/%s about the project's commands", role.Model, role.Effort))
	t0 := time.Now()

	var ci []string
	for _, p := range tracked {
		if initWorkflowRE.MatchString(p) {
			ci = append(ci, p)
		}
	}
	var source strings.Builder
	for _, p := range append(slices.Clone(initSources), ci...) {
		if text, ok := sources[p]; ok {
			source.WriteString("\n## File " + p + "\n\n```\n" + tools.Cut(text) + "\n```\n")
		}
	}
	input := []any{map[string]any{
		"role": "user",
		"content": "# Detected\n\n" + initDetectedJSON(detected) +
			"\n\n# Tracked files\n\n" + tools.Cut(strings.Join(tracked, "\n")) + "\n" + source.String(),
	}}
	ctxInfo := InitContext{Tracked: tracked, Contents: manifests, DetectedChecks: detected.Checks}
	proposal, usage, err := initConverse(ctx, s, in, provider.Role{Provider: role.Provider, Model: role.Model, Effort: role.Effort, BaseURL: role.BaseURL}, input, ctxInfo)
	if err != nil {
		return InitProposal{}, err
	}
	s.Progress(fmt.Sprintf("kogen: init %s/%s %s wall_ms=%d", role.Model, role.Effort, usage.Line(), time.Since(t0).Milliseconds()))
	return proposal, nil
}

// initDetectedJSON is the detection result as the model reads it: the compact JSON object
// with its keys in the order the Elixir Kogen has always written them.
func initDetectedJSON(d project.Detected) string {
	list := func(ss []string) string {
		parts := make([]string, len(ss))
		for i, x := range ss {
			parts[i] = initJSONString(x)
		}
		return "[" + strings.Join(parts, ",") + "]"
	}
	checks := make([]string, len(d.Checks))
	for i, c := range d.Checks {
		checks[i] = `{"name":` + initJSONString(c.Name) + `,"run":` + initJSONString(c.Run) + `}`
	}
	return `{"setup":` + list(d.Setup) + `,"protect":` + list(d.Protect) + `,"fix":` + list(d.Fix) + `,"checks":[` + strings.Join(checks, ",") + `]}`
}

const initHex = "0123456789ABCDEF"

// initJSONString is a JSON string escaped only for quote, backslash and control characters.
func initJSONString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		switch {
		case r == utf8.RuneError && size == 1:
			b.WriteString("�")
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\t':
			b.WriteString(`\t`)
		case r == '\b':
			b.WriteString(`\b`)
		case r == '\f':
			b.WriteString(`\f`)
		case r < 0x20:
			b.WriteString(`\u00` + string(initHex[r>>4]) + string(initHex[r&15]))
		default:
			b.WriteString(s[i : i+size])
		}
		i += size
	}
	b.WriteByte('"')
	return b.String()
}

// initConverse asks, and asks once more with the correction when the answer is missing or
// invalid; a second failure ends init (provider/init_invalid).
func initConverse(ctx context.Context, s *sys.Session, in InitInput, role provider.Role, input []any, vctx InitContext) (InitProposal, provider.Usage, error) {
	var usage provider.Usage
	defs := agent.AsAny(agent.Defs(agent.SubmitConfigurationTool))
	// The setup conversation has no records of its own; its cache identity lives as long as it.
	cacheID := newCacheID()
	for attempt := 1; ; attempt++ {
		resp, err := in.Client.Respond(ctx, s, conversationRequest(provider.Request{
			Role: role, Instructions: agent.Prompt(agent.Init), Input: input, Tools: defs,
		}, cacheID), nil)
		if err != nil {
			return InitProposal{}, usage, err
		}
		usage = usage.Add(resp.Usage)
		var call *tools.Call
		for _, c := range tools.Calls(resp.Items) {
			if c.Name == agent.SubmitConfigurationTool {
				c := c
				call = &c
				break
			}
		}
		var problems []string
		if call != nil {
			var proposal InitProposal
			proposal, problems = Validate(call.Args(), vctx)
			if len(problems) == 0 {
				return proposal, usage, nil
			}
		}
		if attempt == 2 {
			return InitProposal{}, usage, sys.Fail("provider", "init_invalid", "the model did not return a valid configuration; nothing was written", 4)
		}
		input = append(slices.Clone(input), tools.Replay(resp.Items)...)
		if call == nil {
			input = append(input, map[string]any{"role": "user", "content": "Answer by calling submit_configuration."})
		} else {
			input = append(input, toolOutput(*call, "invalid: "+strings.Join(problems, "; ")))
		}
	}
}

// InitProposal is what the shaping model proposes, or the detected and proposed commands
// merged (SET-11).
type InitProposal struct {
	Setup, Fix []string
	Checks     []project.Check
	Protect    []string
}

// InitContext is what Validate checks a proposal against: the tracked paths, the committed
// text of the manifests (mix.exs, package.json, lockfiles, go.mod, go.sum; absent paths have
// no entry) and the checks Detect found.
type InitContext struct {
	Tracked        []string
	Contents       map[string]string
	DetectedChecks []project.Check
}

// Validate checks the arguments of a submit_configuration call (SET-11). It returns the
// proposal, or the problems that go back to the model.
func Validate(args map[string]any, ctx InitContext) (InitProposal, []string) {
	var problems []string
	list := func(key string) []string {
		out, problem := initStrings(args, key)
		if problem != "" {
			problems = append(problems, problem)
		}
		return out
	}
	setup, fix, protect := list("setup"), list("fix"), list("protect")
	for _, p := range protect {
		if !slices.Contains(ctx.Tracked, p) {
			problems = append(problems, "protect path "+p+" is not a tracked file")
		}
	}
	checks, checkProblems := initChecks(args)
	problems = append(problems, checkProblems...)

	proposed := map[string]bool{}
	for _, c := range checks {
		proposed[c.Name] = true
	}
	var effective []project.Check
	for _, c := range ctx.DetectedChecks {
		if !proposed[c.Name] {
			effective = append(effective, c)
		}
	}
	effective = append(effective, checks...)
	for _, p := range protect {
		if !slices.Contains(ctx.Tracked, p) {
			continue
		}
		text, ok := ctx.Contents[p]
		if reason := initProtectProblem(p, text, ok, effective); reason != "" {
			problems = append(problems, "protect path "+p+" is not eligible: "+reason)
		}
	}
	for _, command := range setup {
		if initLocalToolsRE.MatchString(command) {
			problems = append(problems, "setup command "+command+" is a one-time machine prerequisite, not recurring project setup")
		}
	}
	if len(problems) > 0 {
		return InitProposal{}, problems
	}
	return InitProposal{Setup: setup, Fix: fix, Checks: checks, Protect: protect}, nil
}

func initStrings(args map[string]any, key string) ([]string, string) {
	v, present := args[key]
	if !present {
		return nil, ""
	}
	var items []any
	switch l := v.(type) {
	case []any:
		items = l
	case []string:
		for _, x := range l {
			items = append(items, x)
		}
	default:
		return nil, key + " must be a list"
	}
	out := make([]string, 0, len(items))
	for _, it := range items {
		str, ok := it.(string)
		if !ok || strings.TrimSpace(str) == "" {
			return nil, key + " must be a list of non-empty commands"
		}
		out = append(out, str)
	}
	return out, ""
}

func initChecks(args map[string]any) ([]project.Check, []string) {
	v, present := args["checks"]
	if !present {
		return nil, nil
	}
	var items []any
	switch l := v.(type) {
	case []any:
		items = l
	case []map[string]any:
		for _, x := range l {
			items = append(items, x)
		}
	default:
		return nil, []string{"checks must be a list"}
	}
	var checks []project.Check
	var problems []string
	for _, it := range items {
		m, _ := it.(map[string]any)
		name, nameOK := m["name"].(string)
		run, runOK := m["run"].(string)
		switch {
		case !nameOK || !runOK:
			problems = append(problems, "each check needs a name and a run command")
		case name == "acceptance" || name == "model":
			problems = append(problems, "check name "+name+" is reserved")
		case !initCheckNameRE.MatchString(name):
			problems = append(problems, "check name "+name+" must be lowercase letters, digits and dashes")
		case slices.ContainsFunc(checks, func(c project.Check) bool { return c.Name == name }):
			problems = append(problems, "check name "+name+" is used twice")
		case strings.TrimSpace(run) == "":
			problems = append(problems, "check "+name+" has no command")
		default:
			checks = append(checks, project.Check{Name: name, Run: run})
		}
	}
	return checks, problems
}

// initProtectProblem is why path cannot be protected, or "" when it can.
func initProtectProblem(p, text string, hasText bool, checks []project.Check) string {
	base := path.Base(p)
	switch {
	case slices.Contains([]string{"mix.lock", "package-lock.json", "npm-shrinkwrap.json", "go.sum"}, base):
		return "dependency lockfiles are editable inputs, not verification definitions"
	case base == "go.mod":
		return "Go module requirements are editable dependency metadata, not verification definitions"
	case (base == "mix.exs" || base == "package.json") && hasText:
		explanation := "npm package and dependency metadata is editable; verification definitions or embedded settings can be protected as a whole"
		configured := initPackageVerification(text, checks)
		if base == "mix.exs" {
			explanation = "Mix project and dependency metadata is editable; verification definitions or embedded settings can be protected as a whole"
			configured = initMixVerification(text, checks)
		}
		if configured {
			return ""
		}
		return explanation
	case base == "mix.exs" || base == "package.json":
		return "dependency manifest content is unavailable for verification-definition validation"
	}
	return ""
}

func initPackageVerification(text string, checks []project.Check) bool {
	var pkg map[string]any
	if json.Unmarshal([]byte(text), &pkg) != nil || pkg == nil {
		return false
	}
	for _, key := range []string{"eslintConfig", "prettier", "stylelint", "jest"} {
		if _, ok := pkg[key]; ok {
			return true
		}
	}
	scripts, _ := pkg["scripts"].(map[string]any) // anything else is an empty map here
	for _, c := range checks {
		m := initNpmScriptRE.FindStringSubmatch(c.Run)
		if m == nil {
			continue
		}
		body, ok := scripts[m[1]].(string)
		if ok && strings.TrimSpace(body) != "" && strings.TrimSpace(body) != initNpmPlaceholder {
			return true
		}
	}
	return false
}

// Merge is the detected commands with the model's proposal merged in (SET-11): a proposed
// check replaces the detected check of the same name, other proposed checks are added after
// the detected ones; proposed setup entries and fixers follow the detected ones unless
// already present; protect is the union; checks with the same command run once.
func Merge(detected project.Detected, proposed InitProposal) InitProposal {
	byName := map[string]project.Check{}
	for _, c := range proposed.Checks {
		byName[c.Name] = c
	}
	names := map[string]bool{}
	var checks []project.Check
	for _, c := range detected.Checks {
		names[c.Name] = true
		if p, ok := byName[c.Name]; ok {
			c = p
		}
		checks = append(checks, c)
	}
	for _, c := range proposed.Checks {
		if !names[c.Name] {
			checks = append(checks, c)
		}
	}
	seen := map[string]bool{}
	unique := []project.Check{}
	for _, c := range checks {
		if !seen[c.Run] {
			seen[c.Run] = true
			unique = append(unique, c)
		}
	}
	return InitProposal{
		Setup:   initUnion(detected.Setup, proposed.Setup),
		Fix:     initUnion(detected.Fix, proposed.Fix),
		Checks:  unique,
		Protect: initUnion(detected.Protect, proposed.Protect),
	}
}

func initUnion(a, b []string) []string {
	out := []string{}
	for _, s := range append(slices.Clone(a), b...) {
		if !slices.Contains(out, s) {
			out = append(out, s)
		}
	}
	return out
}

// ---- SET-12, SET-13: run everything on a copy of the committed tree ----

// initCommittedCopy copies the working tree with its ignored folders into clone, every
// changed path reset to HEAD or removed.
func initCommittedCopy(s *sys.Session, repo *git.Repo, root, clone string, tracked []string) error {
	if err := os.MkdirAll(clone, 0o755); err != nil {
		return err
	}
	if err := verify.CopyTree(root, clone); err != nil {
		return err
	}
	changed, err := repo.ChangedPaths()
	if err != nil {
		return err
	}
	var restore []string
	for _, p := range changed {
		if err := os.RemoveAll(filepath.Join(clone, p)); err != nil {
			return err
		}
		if slices.Contains(tracked, p) {
			restore = append(restore, p)
		}
	}
	if len(restore) == 0 {
		return nil
	}
	quoted := make([]string, len(restore))
	for i, p := range restore {
		quoted[i] = initShellQuote(p)
	}
	res, err := s.Run(git.UnsetPrefix()+"git archive --format=tar HEAD -- "+strings.Join(quoted, " ")+" | tar -xf - -C "+initShellQuote(clone), root, sys.Options{KillGroupOnExit: true})
	if err != nil {
		return err
	}
	if res.Status != 0 {
		return fmt.Errorf("restoring the committed files for init failed: %s", res.Output)
	}
	return nil
}

type initResult struct {
	setup, fix, protect []string
	checks              []project.Check
	acceptance          *project.Acceptance
	how                 string
	bridge              bool
	leftOut             []string
}

func initExec(s *sys.Session, tools verify.Tools, command, dir string) (sys.Result, error) {
	env := map[string]string{}
	for k, v := range map[string]string{"KOGEN_NODE": tools.Node, "KOGEN_QUINT": tools.Quint, "KOGEN_CUCUMBER": tools.Cucumber} {
		if v != "" {
			env[k] = v
		}
	}
	return s.Run(command, dir, sys.Options{Env: env, KillGroupOnExit: true})
}

func initVerify(ctx context.Context, s *sys.Session, in InitInput, repo *git.Repo, clone string, candidates InitProposal, runner string) (initResult, error) {
	gitDir, err := repo.GitDir()
	if err != nil {
		return initResult{}, err
	}
	var res initResult
	// Setup runs before every Build, so each entry must run twice on the same tree (SET-12).
	for i, cmd := range candidates.Setup {
		n := i + 1
		s.Progress(fmt.Sprintf("kogen: running setup-%d: %s", n, cmd))
		r, err := initExec(s, in.Tools, cmd, clone)
		if err != nil {
			return res, err
		}
		if r.Status != 0 {
			res.leftOut = append(res.leftOut, fmt.Sprintf("setup-%d (%s) failed with status %d", n, cmd, r.Status))
			continue
		}
		first, err := initTreeState(repo, gitDir, clone)
		if err != nil {
			return res, err
		}
		s.Progress(fmt.Sprintf("kogen: running setup-%d again: %s", n, cmd))
		again, err := initExec(s, in.Tools, cmd, clone)
		if err != nil {
			return res, err
		}
		second, err := initTreeState(repo, gitDir, clone)
		if err != nil {
			return res, err
		}
		switch {
		case again.Status != 0:
			res.leftOut = append(res.leftOut, fmt.Sprintf("setup-%d (%s) is not repeatable: its second run failed with status %d", n, cmd, again.Status))
		case !initSameState(first, second):
			var changed []string
			for p, v := range first {
				if w, ok := second[p]; !ok || w != v {
					changed = append(changed, p)
				}
			}
			for p := range second {
				if _, ok := first[p]; !ok {
					changed = append(changed, p)
				}
			}
			sort.Strings(changed)
			res.leftOut = append(res.leftOut, fmt.Sprintf("setup-%d (%s) is not repeatable: its second run changed %s", n, cmd, strings.Join(changed, ", ")))
		default:
			res.setup = append(res.setup, cmd)
		}
	}

	if runner != "" {
		err = initExistingRunner(ctx, s, in, clone, runner, &res)
	} else {
		err = initAddBridge(ctx, s, in, clone, &res)
	}
	if err != nil {
		return res, err
	}

	for _, check := range candidates.Checks {
		s.Progress(fmt.Sprintf("kogen: checking %s: %s", check.Name, check.Run))
		r, err := initExec(s, in.Tools, check.Run, clone)
		if err != nil {
			return res, err
		}
		if r.Status == 0 {
			res.checks = append(res.checks, check)
		} else {
			res.leftOut = append(res.leftOut, fmt.Sprintf("%s (%s) failed with status %d", check.Name, check.Run, r.Status))
		}
	}
	res.fix = candidates.Fix
	if len(res.checks) > 0 {
		res.protect = candidates.Protect
	}
	return res, nil
}

func initSameState(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for p, v := range a {
		if w, ok := b[p]; !ok || w != v {
			return false
		}
	}
	return true
}

// initTreeState lists the paths of the copy that differ from HEAD (by the repository's own
// ignore rules) with their digests.
func initTreeState(repo *git.Repo, gitDir, clone string) (map[string]string, error) {
	r, err := repo.Observing().RunEnv([]string{"GIT_OPTIONAL_LOCKS=0"},
		"--git-dir="+gitDir, "--work-tree="+clone, "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all")
	if err != nil {
		return nil, err
	}
	if r.Status != 0 {
		return nil, fmt.Errorf("git status in the init copy failed (status %d): %s", r.Status, strings.TrimSpace(r.Stderr))
	}
	state := map[string]string{}
	for _, entry := range strings.Split(r.Stdout, "\x00") {
		if len(entry) < 3 || entry[2] != ' ' {
			continue
		}
		p := entry[3:]
		digest := "absent"
		file := filepath.Join(clone, p)
		if st, err := os.Lstat(file); err == nil && st.Mode().IsRegular() {
			if data, err := os.ReadFile(file); err == nil {
				sum := sha256.Sum256(data)
				digest = "sha256:" + hex.EncodeToString(sum[:])
			}
		}
		state[p] = digest
	}
	return state, nil
}

func initExistingRunner(ctx context.Context, s *sys.Session, in InitInput, clone, stepsDir string, res *initResult) error {
	run := project.AcceptanceCommand(stepsDir, project.ProjectRunner)
	reason, _, err := verify.RunnerCheck(ctx, s, in.Tools, clone, run)
	if err != nil {
		return err
	}
	if reason != "" {
		res.how = "not configured: " + reason
		return nil
	}
	res.acceptance = &project.Acceptance{Run: run, StepsDir: stepsDir}
	res.how = "existing Cucumber runner, steps in " + stepsDir
	return nil
}

func initAddBridge(ctx context.Context, s *sys.Session, in InitInput, clone string, res *initResult) error {
	if err := os.MkdirAll(filepath.Join(clone, "features/steps"), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(clone, initStepsReadmePath), []byte(initStepsReadme), 0o644); err != nil {
		return err
	}
	run := project.AcceptanceCommand("features/steps", project.KogenRunner)
	reason, _, err := verify.RunnerCheck(ctx, s, in.Tools, clone, run)
	if err != nil {
		return err
	}
	if reason != "" {
		res.how = "not configured: " + reason
		return nil
	}
	res.acceptance = &project.Acceptance{Run: run, StepsDir: "features/steps"}
	res.how = "Cucumber bridge added in features/steps"
	res.bridge = true
	return nil
}

// ---- writing and committing ----

func initWriteFiles(repo *git.Repo, root, head, config string, files map[string]string) error {
	if err := os.MkdirAll(filepath.Join(root, ".kogen"), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(root, project.ConfigPath), []byte(config), 0o644); err != nil {
		return err
	}
	var committed string
	if head != "" {
		committed, _ = repo.Show(head, ".gitignore")
	} else {
		committed = initRead(filepath.Join(root, ".gitignore"))
	}
	if err := os.WriteFile(filepath.Join(root, ".gitignore"), []byte(initWithLine(committed, initIgnore)), 0o644); err != nil {
		return err
	}
	names := make([]string, 0, len(files))
	for p := range files {
		names = append(names, p)
	}
	sort.Strings(names)
	for _, p := range names {
		file := filepath.Join(root, p)
		if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(file, []byte(files[p]), 0o644); err != nil {
			return err
		}
	}
	return nil
}

func initWithLine(text, line string) string {
	switch {
	case slices.Contains(strings.Split(text, "\n"), line):
		return text
	case text == "" || strings.HasSuffix(text, "\n"):
		return text + line + "\n"
	}
	return text + "\n" + line + "\n"
}

func initRead(file string) string {
	b, err := os.ReadFile(file)
	if err != nil {
		return ""
	}
	return string(b)
}

// initCommit is a plain git commit of exactly these paths; head is "" before the first commit.
func initCommit(s *sys.Session, repo *git.Repo, paths []string, head string) (string, error) {
	subject := "Initial commit"
	if head != "" {
		subject = "Add Kogen configuration"
	}
	return repo.CommitPaths(s, subject, paths, head != "")
}

func initShellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// ---- Mix verification settings ----
//
// The Elixir Kogen parses the committed mix.exs without evaluating it and asks whether its
// project settings or aliases define verification. The scanner below reads the same facts
// from a token stream: it finds the zero-argument `def`/`defp` functions, takes the last
// expression of each body and, when that is a literal keyword list, its keys and values.
// Comments, strings, sigils and heredocs never count.

type initKind int

const (
	initIdent initKind = iota
	initKwKey          // `key:`; text is the key
	initAtom
	initStr
	initNum
	initOp
	initPunct
	initNL
)

type initTok struct {
	kind initKind
	text string
}

func (t initTok) is(kind initKind, text string) bool { return t.kind == kind && t.text == text }

func (t initTok) opens() bool {
	return t.kind == initPunct && (t.text == "(" || t.text == "[" || t.text == "{" || t.text == "<<") ||
		t.kind == initIdent && (t.text == "do" || t.text == "fn")
}

func (t initTok) closes() bool {
	return t.kind == initPunct && (t.text == ")" || t.text == "]" || t.text == "}" || t.text == ">>") ||
		t.is(initIdent, "end")
}

func initIsIdentStart(c byte) bool {
	return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= 0x80
}

func initIsIdentChar(c byte) bool { return initIsIdentStart(c) || c >= '0' && c <= '9' || c == '@' }

const initOpChars = "+-*/<>=!&|^~@%\\"

// initSkipQuoted returns the index after the string that starts at src[i] (a quote), or -1.
func initSkipQuoted(src string, i int, interpolate bool) int {
	quote := src[i]
	if strings.HasPrefix(src[i:], strings.Repeat(string(quote), 3)) {
		return initSkipHeredoc(src, i, quote, interpolate)
	}
	return initSkipUntil(src, i+1, quote, interpolate)
}

// initSkipUntil finds the unescaped closer from j on.
func initSkipUntil(src string, j int, closer byte, interpolate bool) int {
	for j < len(src) {
		switch {
		case src[j] == '\\':
			j += 2
		case interpolate && src[j] == '#' && j+1 < len(src) && src[j+1] == '{':
			if j = initSkipInterpolation(src, j+2); j < 0 {
				return -1
			}
		case src[j] == closer:
			return j + 1
		default:
			j++
		}
	}
	return -1
}

func initSkipInterpolation(src string, j int) int {
	depth := 1
	for j < len(src) {
		switch src[j] {
		case '{':
			depth++
			j++
		case '}':
			depth--
			j++
			if depth == 0 {
				return j
			}
		case '"', '\'':
			if j = initSkipQuoted(src, j, true); j < 0 {
				return -1
			}
		default:
			j++
		}
	}
	return -1
}

// initSkipHeredoc handles `"""` and `”'`: the text ends at a line that starts, after
// white space, with the closing triple quote.
func initSkipHeredoc(src string, i int, quote byte, interpolate bool) int {
	closer := strings.Repeat(string(quote), 3)
	j := i + 3
	for j < len(src) {
		switch {
		case src[j] == '\\':
			j += 2
		case interpolate && src[j] == '#' && j+1 < len(src) && src[j+1] == '{':
			if j = initSkipInterpolation(src, j+2); j < 0 {
				return -1
			}
		case src[j] == '\n':
			k := j + 1
			for k < len(src) && (src[k] == ' ' || src[k] == '\t') {
				k++
			}
			if strings.HasPrefix(src[k:], closer) {
				return k + 3
			}
			j++
		default:
			j++
		}
	}
	return -1
}

// initSkipSigil returns the index after the sigil at src[i] == '~', or -1 when it is not one.
func initSkipSigil(src string, i int) int {
	j := i + 1
	if j >= len(src) {
		return -1
	}
	lower := src[j] >= 'a' && src[j] <= 'z'
	switch {
	case lower:
		j++
	case src[j] >= 'A' && src[j] <= 'Z':
		for j < len(src) && src[j] >= 'A' && src[j] <= 'Z' {
			j++
		}
	default:
		return -1
	}
	if j >= len(src) {
		return -1
	}
	open := src[j]
	closer := map[byte]byte{'(': ')', '[': ']', '{': '}', '<': '>'}[open]
	switch open {
	case '/', '|', '"', '\'', '(', '[', '{', '<':
	default:
		return -1
	}
	if closer == 0 {
		closer = open
	}
	var end int
	if (open == '"' || open == '\'') && strings.HasPrefix(src[j:], strings.Repeat(string(open), 3)) {
		end = initSkipHeredoc(src, j, open, lower)
	} else {
		end = initSkipSigilBody(src, j+1, closer, lower)
	}
	if end < 0 {
		return -1
	}
	for end < len(src) && (src[end] >= 'a' && src[end] <= 'z' || src[end] >= 'A' && src[end] <= 'Z') {
		end++
	}
	return end
}

func initSkipSigilBody(src string, j int, closer byte, interpolate bool) int {
	for j < len(src) {
		switch {
		case src[j] == '\\' && (interpolate || j+1 < len(src) && src[j+1] == closer):
			j += 2
		case interpolate && src[j] == '#' && j+1 < len(src) && src[j+1] == '{':
			if j = initSkipInterpolation(src, j+2); j < 0 {
				return -1
			}
		case src[j] == closer:
			return j + 1
		default:
			j++
		}
	}
	return -1
}

// initLex splits Elixir source into tokens; false when a string or sigil does not end.
func initLex(src string) ([]initTok, bool) {
	var toks []initTok
	emit := func(kind initKind, text string) { toks = append(toks, initTok{kind, text}) }
	n := len(src)
	for i := 0; i < n; {
		c := src[i]
		switch {
		case c == ' ' || c == '\t' || c == '\r':
			i++
		case c == '\n':
			emit(initNL, "")
			i++
		case c == '#':
			for i < n && src[i] != '\n' {
				i++
			}
		case c == '"' || c == '\'':
			j := initSkipQuoted(src, i, true)
			if j < 0 {
				return nil, false
			}
			if c == '"' && j < n && src[j] == ':' && (j+1 >= n || src[j+1] != ':') && !strings.HasPrefix(src[i:], `"""`) {
				emit(initKwKey, strings.Trim(src[i:j], `"`))
				j++
			} else {
				emit(initStr, src[i:j])
			}
			i = j
		case c == '~':
			if j := initSkipSigil(src, i); j >= 0 {
				emit(initStr, src[i:j])
				i = j
			} else {
				emit(initOp, "~")
				i++
			}
		case c == ':':
			switch {
			case i+1 < n && src[i+1] == ':':
				emit(initOp, "::")
				i += 2
			case i+1 < n && src[i+1] == '"':
				j := initSkipQuoted(src, i+1, true)
				if j < 0 {
					return nil, false
				}
				emit(initAtom, strings.Trim(src[i+1:j], `"`))
				i = j
			case i+1 < n && initIsIdentStart(src[i+1]):
				j := i + 1
				for j < n && initIsIdentChar(src[j]) {
					j++
				}
				if j < n && (src[j] == '?' || src[j] == '!') {
					j++
				}
				emit(initAtom, src[i+1:j])
				i = j
			case i+1 < n && strings.IndexByte(initOpChars, src[i+1]) >= 0:
				j := i + 1
				for j < n && strings.IndexByte(initOpChars, src[j]) >= 0 {
					j++
				}
				emit(initAtom, src[i+1:j])
				i = j
			default:
				emit(initOp, ":")
				i++
			}
		case c >= '0' && c <= '9':
			j := i
			if c == '0' && i+1 < n && strings.IndexByte("xXbBoO", src[i+1]) >= 0 {
				j += 2
				for j < n && (initIsIdentChar(src[j])) {
					j++
				}
			} else {
				for j < n && (src[j] >= '0' && src[j] <= '9' || src[j] == '_') {
					j++
				}
				if j+1 < n && src[j] == '.' && src[j+1] >= '0' && src[j+1] <= '9' {
					j++
					for j < n && (src[j] >= '0' && src[j] <= '9' || src[j] == '_') {
						j++
					}
				}
				if j < n && (src[j] == 'e' || src[j] == 'E') {
					k := j + 1
					if k < n && (src[k] == '+' || src[k] == '-') {
						k++
					}
					if k < n && src[k] >= '0' && src[k] <= '9' {
						for k < n && src[k] >= '0' && src[k] <= '9' {
							k++
						}
						j = k
					}
				}
			}
			emit(initNum, src[i:j])
			i = j
		case c == '?' && i+1 < n && src[i+1] != ' ' && src[i+1] != '\n' && src[i+1] != '\t':
			_, size := utf8.DecodeRuneInString(src[i+1:])
			j := i + 1 + size
			if src[i+1] == '\\' && j < n {
				_, size = utf8.DecodeRuneInString(src[j:])
				j += size
			}
			emit(initNum, src[i:j])
			i = j
		case initIsIdentStart(c):
			j := i
			for j < n && initIsIdentChar(src[j]) {
				j++
			}
			if j < n && (src[j] == '?' || src[j] == '!') && !(j+1 < n && src[j+1] == '=') {
				j++
			}
			text := src[i:j]
			if j < n && src[j] == ':' && (j+1 >= n || src[j+1] != ':') {
				emit(initKwKey, text)
				j++
			} else {
				emit(initIdent, text)
			}
			i = j
		case strings.IndexByte("()[]{},;.", c) >= 0:
			emit(initPunct, string(c))
			i++
		case c == '<' && strings.HasPrefix(src[i:], "<<") && !strings.HasPrefix(src[i:], "<<<"):
			emit(initPunct, "<<")
			i += 2
		case c == '>' && strings.HasPrefix(src[i:], ">>") && !strings.HasPrefix(src[i:], ">>>"):
			emit(initPunct, ">>")
			i += 2
		case strings.IndexByte(initOpChars, c) >= 0:
			j := i
			for j < n && strings.IndexByte(initOpChars, src[j]) >= 0 {
				j++
			}
			emit(initOp, src[i:j])
			i = j
		default:
			i++
		}
	}
	return toks, true
}

var initLeadingOps = []string{"|>", "++", "--", "<>", "&&", "||", "==", "!=", "===", "!==", "=~", "<=", ">=", "<", ">", "|", "=", "->"}

// initContinues says whether a newline between prev and next does not end the expression.
func initContinues(prev, next initTok) bool {
	switch {
	case prev.kind == initOp || prev.kind == initKwKey || prev.is(initPunct, ",") || prev.is(initPunct, "."):
		return true
	case prev.kind == initIdent && (prev.text == "and" || prev.text == "or" || prev.text == "when" || prev.text == "in" || prev.text == "not"):
		return true
	case next.kind == initOp && slices.Contains(initLeadingOps, next.text):
		return true
	case next.kind == initIdent && (next.text == "and" || next.text == "or" || next.text == "when" || next.text == "in"):
		return true
	case next.is(initPunct, "."):
		return true
	}
	return false
}

// initSplit splits tokens into expressions at the separators of depth 0 (`;` and line ends
// that do not continue the expression); newlines inside brackets and blocks are dropped. It
// stops at an unmatched closer.
func initSplit(toks []initTok) [][]initTok {
	var out [][]initTok
	var cur []initTok
	depth := 0
	flush := func() {
		if len(cur) > 0 {
			out = append(out, cur)
			cur = nil
		}
	}
	for i := 0; i < len(toks); i++ {
		t := toks[i]
		switch {
		case t.kind == initNL:
			if depth > 0 || len(cur) == 0 {
				continue
			}
			j := i + 1
			for j < len(toks) && toks[j].kind == initNL {
				j++
			}
			if j < len(toks) && !initContinues(cur[len(cur)-1], toks[j]) {
				flush()
			}
		case t.is(initPunct, ";") && depth == 0:
			flush()
		default:
			if t.closes() {
				if depth == 0 {
					flush()
					return out
				}
				depth--
			} else if t.opens() {
				depth++
			}
			cur = append(cur, t)
		}
	}
	flush()
	return out
}

// initMatching is the index of the closer matching the opener at toks[i], or -1.
func initMatching(toks []initTok, i int) int {
	depth := 0
	for j := i; j < len(toks); j++ {
		if toks[j].opens() {
			depth++
		} else if toks[j].closes() {
			depth--
			if depth == 0 {
				return j
			}
		}
	}
	return -1
}

// initDefinitions maps each zero-argument function of the source to its body's last
// expression; a later definition replaces an earlier one of the same name.
func initDefinitions(toks []initTok) map[string][]initTok {
	defs := map[string][]initTok{}
	skipNL := func(j int) int {
		for j < len(toks) && toks[j].kind == initNL {
			j++
		}
		return j
	}
	for i := 0; i < len(toks); i++ {
		if t := toks[i]; t.kind != initIdent || (t.text != "def" && t.text != "defp") || i > 0 && toks[i-1].is(initPunct, ".") {
			continue
		}
		j := i + 1
		if j >= len(toks) || toks[j].kind != initIdent {
			continue
		}
		name := toks[j].text
		j++
		if j+1 < len(toks) && toks[j].is(initPunct, "(") && toks[j+1].is(initPunct, ")") {
			j += 2
		}
		j = skipNL(j)
		switch {
		case j < len(toks) && toks[j].is(initIdent, "do"):
			end := initMatching(toks, j)
			if end < 0 {
				continue
			}
			body := toks[j+1 : end]
			if initHasClause(body) {
				continue
			}
			if exprs := initSplit(body); len(exprs) > 0 {
				defs[name] = exprs[len(exprs)-1]
			} else {
				defs[name] = nil
			}
		case j+1 < len(toks) && toks[j].is(initPunct, ",") && toks[skipNL(j+1)].is(initKwKey, "do"):
			start := skipNL(j+1) + 1
			if exprs := initSplit(toks[start:]); len(exprs) > 0 {
				defs[name] = exprs[0]
			} else {
				defs[name] = nil
			}
		}
	}
	return defs
}

// initHasClause reports a depth-0 rescue, catch, else or after in a do block body, which
// makes the function more than `[do: body]`.
func initHasClause(body []initTok) bool {
	depth := 0
	for _, t := range body {
		switch {
		case t.opens():
			depth++
		case t.closes():
			depth--
		case depth == 0 && t.kind == initIdent && (t.text == "rescue" || t.text == "catch" || t.text == "else" || t.text == "after"):
			return true
		}
	}
	return false
}

type initPair struct {
	key   string
	value []initTok
}

// initKeywordBody is the pairs of an expression that is a literal keyword list (parentheses
// around it allowed); false for anything else.
func initKeywordBody(expr []initTok) ([]initPair, bool) {
	for len(expr) >= 2 && expr[0].is(initPunct, "(") && initMatching(expr, 0) == len(expr)-1 {
		expr = expr[1 : len(expr)-1]
	}
	if len(expr) < 2 || !expr[0].is(initPunct, "[") || initMatching(expr, 0) != len(expr)-1 {
		return nil, false
	}
	var pairs []initPair
	for _, elem := range initSplitCommas(expr[1 : len(expr)-1]) {
		switch {
		case elem[0].kind == initKwKey:
			pairs = append(pairs, initPair{elem[0].text, elem[1:]})
		case len(elem) >= 4 && elem[0].is(initPunct, "{") && initMatching(elem, 0) == len(elem)-1 &&
			elem[1].kind == initAtom && elem[2].is(initPunct, ","):
			pairs = append(pairs, initPair{elem[1].text, elem[3 : len(elem)-1]})
		default:
			return nil, false
		}
	}
	return pairs, true
}

// initSplitCommas splits at the commas of depth 0 and drops empty parts.
func initSplitCommas(toks []initTok) [][]initTok {
	var out [][]initTok
	var cur []initTok
	depth := 0
	for _, t := range toks {
		switch {
		case t.kind == initNL:
		case t.is(initPunct, ",") && depth == 0:
			if len(cur) > 0 {
				out = append(out, cur)
			}
			cur = nil
		default:
			if t.opens() {
				depth++
			} else if t.closes() {
				depth--
			}
			cur = append(cur, t)
		}
	}
	if len(cur) > 0 {
		out = append(out, cur)
	}
	return out
}

func initPairValue(pairs []initPair, key string) ([]initTok, bool) {
	for _, p := range pairs {
		if p.key == key {
			return p.value, true
		}
	}
	return nil, false
}

// initMixVerification reports whether the Mix source defines verification: project settings
// for compiler options, xref, dialyzer, credo or test discovery and coverage, or an alias
// that one of the checks invokes.
func initMixVerification(text string, checks []project.Check) bool {
	toks, ok := initLex(text)
	if !ok {
		return false
	}
	defs := initDefinitions(toks)
	proj, _ := initKeywordBody(defs["project"])

	var aliases []initPair
	if value, ok := initPairValue(proj, "aliases"); ok {
		name := ""
		switch {
		case len(value) == 1 && value[0].kind == initIdent:
			name = value[0].text
		case len(value) == 3 && value[0].kind == initIdent && value[1].is(initPunct, "(") && value[2].is(initPunct, ")"):
			name = value[0].text
		}
		if _, defined := defs[name]; name != "" && defined && !slices.Contains([]string{"true", "false", "nil"}, name) {
			aliases, _ = initKeywordBody(defs[name])
		} else {
			aliases, _ = initKeywordBody(value)
		}
	}
	for _, key := range []string{"elixirc_options", "xref", "dialyzer", "credo", "test_paths", "test_pattern", "test_load_filters", "test_ignore_filters", "test_coverage"} {
		if _, ok := initPairValue(proj, key); ok {
			return true
		}
	}
	for _, c := range checks {
		if m := initMixTaskRE.FindStringSubmatch(c.Run); m != nil {
			if _, ok := initPairValue(aliases, m[1]); ok {
				return true
			}
		}
	}
	return false
}

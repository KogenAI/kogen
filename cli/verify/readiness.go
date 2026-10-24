package verify

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"kogen/git"
	"kogen/project"
	"kogen/sys"
)

// Readiness checks whether an Intent is ready to build (SHP-8): the SHP-5 rules, the model
// checks (VER-5) and a dry run of `commands.setup` and the acceptance command that must
// account for every scenario exactly once as passed or failed, all in a clean scratch
// directory of the exact candidate (clean final readiness). Complete successful evidence is
// kept in `.kogen/local/readiness/<slug>.json`, reusable while the full baseline hash, HEAD
// and candidate tree stay the same.
type Readiness struct {
	Root     string // the checkout
	Repo     *git.Repo
	Config   *project.Config
	Tools    Tools
	Log      Logger
	Evidence Evidence
	// BeforeRecord, when set, runs after the checks passed and the candidate files proved
	// unchanged, right before the evidence is recorded; its error stops the check with
	// nothing recorded (a conversation validates its private custody here).
	BeforeRecord func() error
}

func (r *Readiness) repo(s *sys.Session) *git.Repo {
	if r.Repo != nil {
		return r.Repo
	}
	return git.New(r.Root, s.Env)
}

// Ready is the complete checked result of one readiness check.
type Ready struct {
	Intent         *project.Intent
	Feasibility    []Obligation
	Model          *project.ModelSpec
	Scenarios      []ScenarioResult
	AcceptanceExit int
	Baseline       []string
	SHA256         string
	Head           string
	CandidateTree  string
}

// Failures reports whether any scenario failed in the dry run (accounted red).
func (r *Ready) Failures() bool {
	return slices.ContainsFunc(r.Scenarios, func(s ScenarioResult) bool { return s.Status == "failed" })
}

func readinessPath(root, slug string) string {
	return filepath.Join(root, ".kogen/local/readiness", slug+".json")
}

type inputs struct {
	baseline []string
	sha      string
	head     string
	tree     string
}

func (r *Readiness) inputs(s *sys.Session, slug string) (inputs, error) {
	baseline, err := project.Baseline(r.Root, slug, r.Config)
	if err != nil {
		return inputs{}, err
	}
	repo := r.repo(s)
	head := repo.Head()
	tree, err := repo.Tree(head, nil)
	if err != nil {
		return inputs{}, err
	}
	return inputs{baseline, project.Hash(r.Root, baseline), head, tree}, nil
}

func modelValue(m *project.ModelSpec) any {
	switch {
	case m == nil:
		return nil
	case m.None:
		return "none"
	}
	return map[string]any{"path": m.Path, "invariants": m.Invariants, "seed": m.Seed, "samples": m.Samples, "steps": m.Steps}
}

func modelOutcome(m *project.ModelSpec) string {
	if m != nil && m.None {
		return "not_applicable"
	}
	return "passed"
}

// Cached loads complete successful evidence for the current full baseline, HEAD and
// candidate tree, or returns nil: anything missing, malformed, legacy, mismatching or stale
// is a normal miss.
func (r *Readiness) Cached(s *sys.Session, slug string) *Ready {
	in, err := r.inputs(s, slug)
	if err != nil {
		return nil
	}
	text, err := os.ReadFile(readinessPath(r.Root, slug))
	if err != nil {
		return nil
	}
	d := json.NewDecoder(strings.NewReader(string(text)))
	d.UseNumber()
	var rec map[string]any
	if d.Decode(&rec) != nil || rec == nil {
		return nil
	}
	exit, ok := intValue(rec["acceptance_exit"])
	if v, isInt := intValue(rec["version"]); !isInt || v != 3 || rec["outcome"] != "ready" || !ok {
		return nil
	}
	if rec["sha256"] != in.sha || rec["head"] != in.head || rec["candidate_tree"] != in.tree || !jsonEqual(rec["baseline"], nonNil(in.baseline)) {
		return nil
	}
	intent, expected, err := project.CheckIntent(r.Root, slug, nil)
	if err != nil {
		return nil
	}
	if rec["title"] != intent.Title || !Valid(r.Root, intent, rec["feasibility"]) ||
		!jsonEqual(rec["model"], modelValue(intent.Model)) || rec["model_outcome"] != modelOutcome(intent.Model) {
		return nil
	}
	recorded, ok := rec["scenarios"].([]any)
	if !ok || len(recorded) != len(expected) {
		return nil
	}
	var scenarios []ScenarioResult
	anyFailed := false
	for i, e := range expected {
		sm, ok := recorded[i].(map[string]any)
		if !ok {
			return nil
		}
		status, _ := sm["status"].(string)
		detail, hasDetail := sm["detail"]
		if status != "passed" && status != "failed" || !hasDetail {
			return nil
		}
		var detailPtr *string
		if detail != nil {
			ds, isStr := detail.(string)
			if !isStr {
				return nil
			}
			detailPtr = &ds
		}
		unexercised, valid := cachedUnexercised(sm["unexercised_steps"], e)
		if !valid {
			return nil
		}
		rest := shallowCopy(sm)
		delete(rest, "status")
		delete(rest, "detail")
		delete(rest, "unexercised_steps")
		want := generic(ScenarioRecord(e)).(map[string]any)
		delete(want, "status")
		delete(want, "detail")
		delete(want, "unexercised_steps")
		if !jsonEqual(rest, want) {
			return nil
		}
		anyFailed = anyFailed || status == "failed"
		result := withResult(e, status, detailPtr)
		result.UnexercisedSteps = unexercised
		scenarios = append(scenarios, result)
	}
	if !anyFailed && exit != 0 {
		return nil
	}
	var proof []Obligation
	if rec["feasibility"] != nil {
		if json.Unmarshal([]byte(encode(rec["feasibility"])), &proof) != nil {
			return nil
		}
	}
	return &Ready{Intent: intent, Feasibility: proof, Model: intent.Model, Scenarios: scenarios, AcceptanceExit: exit,
		Baseline: in.baseline, SHA256: in.sha, Head: in.head, CandidateTree: in.tree}
}

func intValue(v any) (int, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return 0, false
	}
	i, err := n.Int64()
	return int(i), err == nil
}

// Current reports whether the complete checked baseline, HEAD and candidate tree, and the
// feasibility proof, still identify this readiness result.
func (r *Readiness) Current(s *sys.Session, slug string, ready *Ready) bool {
	if ready == nil {
		return false
	}
	in, err := r.inputs(s, slug)
	if err != nil {
		return false
	}
	return slices.Equal(in.baseline, ready.Baseline) && in.sha == ready.SHA256 && in.head == ready.Head && in.tree == ready.CandidateTree &&
		Valid(r.Root, ready.Intent, ready.Feasibility)
}

// RecordPass publishes the original successful evidence only when the complete checked
// inputs still match, before and after writing it; then it refreshes the package facts.
func (r *Readiness) RecordPass(s *sys.Session, slug string, ready *Ready) error {
	if !r.Current(s, slug, ready) {
		e := sys.Fail("intent", "not_ready", "the Intent is not ready to build", 1)
		e.Lines = []string{"readiness inputs changed during checking or publication"}
		return e
	}
	path := readinessPath(r.Root, slug)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	rec := map[string]any{
		"version":         3,
		"candidate_tree":  ready.CandidateTree,
		"outcome":         "ready",
		"sha256":          ready.SHA256,
		"head":            ready.Head,
		"baseline":        nonNil(ready.Baseline),
		"title":           ready.Intent.Title,
		"model":           modelValue(ready.Model),
		"model_outcome":   modelOutcome(ready.Model),
		"acceptance_exit": ready.AcceptanceExit,
		"scenarios":       nonNil(ready.Scenarios),
		"feasibility":     nonNil(ready.Feasibility),
	}
	b, err := project.EncodeJSON(rec)
	if err != nil {
		return err
	}
	if err := os.WriteFile(path, append(b, '\n'), 0o666); err != nil {
		return err
	}
	if !r.Current(s, slug, ready) {
		os.Remove(path)
		return sys.Fail("intent", "not_ready", "readiness inputs changed during publication", 1)
	}
	return project.WritePackageFacts(r.Root, slug, r.Config)
}

// Check checks the Intent on disk in a clean scratch directory of the candidate tree and, when it
// is ready, publishes the evidence. A failing assertion that the dry run accounts for is
// valid readiness. Problems are intent/parse, intent/lint or intent/not_ready; interrupts
// are *sys.Interrupted. The scratch directory is removed whatever happens.
func (r *Readiness) Check(ctx context.Context, s *sys.Session, slug string) (*Ready, error) {
	os.Remove(readinessPath(r.Root, slug))
	in, err := r.inputs(s, slug)
	if err != nil {
		return nil, err
	}
	scratch := sys.TmpPath("kogen-readiness")
	defer os.RemoveAll(scratch)
	mat, err := r.repo(s).Materialize(in.tree, scratch)
	if err != nil {
		return nil, err
	}
	ready, err := r.checkClean(ctx, s, scratch, slug, in)
	if err != nil {
		return nil, err
	}
	mutations, err := mat.Mutations()
	if err != nil {
		return nil, err
	}
	if len(mutations) > 0 {
		e := sys.Fail("intent", "not_ready", "readiness changed candidate files", 1)
		e.Lines = mutations
		return nil, e
	}
	if r.BeforeRecord != nil {
		if err := r.BeforeRecord(); err != nil {
			return nil, err
		}
	}
	if err := r.RecordPass(s, slug, ready); err != nil {
		return nil, err
	}
	return ready, nil
}

func (r *Readiness) checkClean(ctx context.Context, s *sys.Session, dir, slug string, in inputs) (*Ready, error) {
	intent, _, err := project.CheckIntent(dir, slug, nil)
	if err != nil {
		return nil, err
	}
	if err := r.Setup(ctx, s, dir, false); err != nil {
		return nil, err
	}
	proof, err := Execute(ctx, s, r.Tools, dir, intent, r.Root, r.Evidence)
	if err != nil {
		return nil, err
	}
	var modelProblems []string
	if m := intent.Model; m != nil && !m.None {
		if err := r.Tools.Require(); err != nil {
			return nil, err
		}
		res, err := CheckModel(ctx, s, dir, r.Tools, m, r.Evidence, nil)
		if err != nil {
			return nil, err
		}
		modelProblems = res.Problems
	}
	reportDir := sys.TmpPath("kogen-dry-run")
	defer os.RemoveAll(reportDir)
	acc, err := RunAcceptance(ctx, s, dir, r.Tools, slug, r.acceptanceRun(), filepath.Join(reportDir, "report.ndjson"), r.Evidence, nil)
	if err != nil {
		return nil, err
	}
	problems := slices.Concat(modelProblems, dryRunProblems(acc))
	if len(problems) > 0 {
		e := sys.Fail("intent", "not_ready", "the Intent is not ready to build", 1)
		for _, p := range problems {
			e.Lines = append(e.Lines, strings.Split(p, "\n")...)
		}
		return nil, e
	}
	return &Ready{Intent: intent, Feasibility: proof, Model: intent.Model, Scenarios: acc.Scenarios, AcceptanceExit: acc.Status,
		Baseline: in.baseline, SHA256: in.sha, Head: in.head, CandidateTree: in.tree}, nil
}

func (r *Readiness) acceptanceRun() string {
	if r.Config.Acceptance == nil {
		return ""
	}
	return r.Config.Acceptance.Run
}

// dryRunProblems are the reasons an acceptance run is not valid readiness: every scenario
// must be accounted exactly once as passed or failed, bindings must exist, and the report
// must be readable. A nonzero exit is fine while a scenario failed.
func dryRunProblems(acc Acceptance) []string {
	var reportProblems []string
	for _, p := range acc.Problems {
		if strings.HasPrefix(p, "report_") {
			reportProblems = append(reportProblems, p)
		}
	}
	dry := slices.Clone(acc.BindingProblems)
	undefined := false
	for _, s := range acc.Scenarios {
		undefined = undefined || s.Status == "undefined"
		if s.Status != "passed" && s.Status != "failed" && s.Status != "undefined" {
			dry = append(dry, fmt.Sprintf("%s: %s (line %d)", s.Status, s.Name, s.Line))
		}
	}
	switch {
	case len(reportProblems) > 0:
		return reportProblems
	case len(dry) > 0:
		return dry
	case undefined:
		return []string{"undefined steps in acceptance.feature"}
	}
	var out []string
	for _, p := range acc.Problems {
		switch {
		case strings.HasPrefix(p, "exit "):
			out = append(out, p+"; its output:\n"+Excerpt(acc.Output))
		case strings.HasPrefix(p, "report_"), strings.HasPrefix(p, "unexpected"):
			out = append(out, p)
		}
	}
	return out
}

// ---- start checks ----

var (
	assignmentRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*=`)
	groupingRe   = regexp.MustCompile(`^[({!]+`)
)

// RequireTools refuses (environment/tool_missing, exit 3) when git or /bin/sh is missing and,
// with configured true (a Build, after setup), when the program of a configured command is
// (LOOP-12): leading NAME=value words are skipped, a leading subshell, group or negation
// character is dropped, and the next word is looked up with `command -v` in root. The
// generated runner's "$KOGEN_NODE" resolves to the Node recorded by the installed command.
// Nothing is executed.
func RequireTools(s *sys.Session, tools Tools, root string, cfg *project.Config, configured bool) error {
	if _, err := os.Stat("/bin/sh"); err != nil {
		return sys.Fail("environment", "tool_missing", "/bin/sh is not available", 3)
	}
	var words []string
	if configured {
		for _, nc := range cfg.NamedCommands() {
			parts, err := shellWords(nc.Run)
			if err != nil {
				return err
			}
			for len(parts) > 0 && assignmentRe.MatchString(parts[0]) {
				parts = parts[1:]
			}
			var clean []string
			for _, w := range parts {
				if w = groupingRe.ReplaceAllString(w, ""); w != "" {
					clean = append(clean, w)
				}
			}
			if len(clean) > 0 {
				words = append(words, clean[0])
			}
		}
	}
	seen := map[string]bool{}
	for _, word := range slices.Concat([]string{"git"}, words) {
		if seen[word] {
			continue
		}
		seen[word] = true
		program := word
		if word == "$KOGEN_NODE" {
			// The commands run with the Node Kogen records: the caller's own variable wins.
			if program = s.Getenv("KOGEN_NODE"); program == "" {
				program = tools.Node
			}
		}
		cmd := exec.Command("/bin/sh", "-c", `command -v "$1" >/dev/null`, "sh", program)
		cmd.Dir = root
		cmd.Env = append(slices.Clone(s.Env), "PATH="+s.Getenv("PATH"))
		if err := cmd.Run(); err != nil {
			return sys.Fail("environment", "tool_missing", word+" is not available", 3)
		}
	}
	return nil
}

// Setup runs `commands.setup` in order in root; the first failure refuses with
// environment/setup_failed (AUT-5). With reuse (warm shaping preparation) it is skipped when
// it last passed for the same checkout state (SET-7); a Build always runs it.
func (r *Readiness) Setup(ctx context.Context, s *sys.Session, root string, reuse bool) error {
	key, err := r.setupKey(s, root)
	if err != nil {
		return err
	}
	stamp := filepath.Join(root, ".kogen/local/setup.json")
	if reuse {
		if b, err := os.ReadFile(stamp); err == nil && string(b) == key {
			s.Progress("kogen: setup already ran for this checkout state")
			return nil
		}
	}
	for i, cmd := range r.Config.Setup {
		name := fmt.Sprintf("setup-%d", i+1)
		s.Progress(fmt.Sprintf("kogen: running %s: %s", name, cmd))
		logEvent(r.Log, map[string]any{"event": "command", "name": name, "command": cmd})
		count(r.Evidence, "setup")
		var res sys.Result
		err := timed(r.Evidence, "setup", func() error {
			var err error
			res, err = run(ctx, s, r.Tools, cmd, root, nil)
			return err
		})
		if err != nil {
			return err
		}
		logEvent(r.Log, map[string]any{"event": "command_result", "name": name, "status": res.Status, "output": Cap(res.Output)})
		if res.Status != 0 {
			e := sys.Fail("environment", "setup_failed", fmt.Sprintf("Setup %s failed (status=%d).", name, res.Status), 3)
			e.Lines = strings.Split(Tail(res.Output, 20), "\n")
			return e
		}
	}
	if err := os.MkdirAll(filepath.Dir(stamp), 0o755); err != nil {
		return err
	}
	return os.WriteFile(stamp, []byte(key), 0o666)
}

// setupKey is the checkout state setup depends on: its commands, HEAD and every change
// outside the Intent files shaping writes (.kogen/ and the steps folder).
func (r *Readiness) setupKey(s *sys.Session, root string) (string, error) {
	exclude := []string{"--", ".", ":(exclude).kogen"}
	if a := r.Config.Acceptance; a != nil && a.StepsDir != "" {
		exclude = append(exclude, ":(exclude)"+a.StepsDir)
	}
	repo := r.repo(s).At(root)
	diff, err := repo.Run(slices.Concat([]string{"diff", "--binary", "HEAD"}, exclude)...)
	if err != nil {
		return "", err
	}
	untracked, err := repo.Run(slices.Concat([]string{"ls-files", "--others", "--exclude-standard"}, exclude)...)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256([]byte(diff.Stdout + untracked.Stdout))
	var head any
	if h := repo.Head(); h != "" {
		head = h
	}
	setup := r.Config.Setup
	if setup == nil {
		setup = []string{}
	}
	return encode(map[string]any{"setup": setup, "head": head, "changes": hex.EncodeToString(sum[:])}), nil
}

// RunnerCheck runs command, an acceptance command, in dir on a feature with no scenarios
// (SET-13, SHP-2). It returns "" when the command exits 0 and writes its report, else the
// reason and the command's output.
func RunnerCheck(ctx context.Context, s *sys.Session, tools Tools, dir, command string) (reason, output string, err error) {
	s.Progress("kogen: checking the acceptance runner")
	tmp := sys.TmpPath("kogen-runner-check")
	if err := os.MkdirAll(tmp, 0o755); err != nil {
		return "", "", err
	}
	defer os.RemoveAll(tmp)
	feature, report := filepath.Join(tmp, "check.feature"), filepath.Join(tmp, "report.ndjson")
	if err := os.WriteFile(feature, []byte("Feature: Kogen acceptance runner check\n"), 0o666); err != nil {
		return "", "", err
	}
	res, err := run(ctx, s, tools, command, dir, map[string]string{"KOGEN_ACCEPTANCE_FEATURES": feature, "KOGEN_ACCEPTANCE_REPORT": report})
	if err != nil {
		return "", "", err
	}
	switch {
	case res.Status != 0:
		return fmt.Sprintf("the runner check failed with status %d", res.Status), res.Output, nil
	case !isRegular(report):
		return "the runner check wrote no report", res.Output, nil
	}
	return "", res.Output, nil
}

// RequireRunner is the check before the first shaping request (SHP-2): the configured
// commands exist and the acceptance runner starts, else environment/acceptance_unavailable.
func RequireRunner(ctx context.Context, s *sys.Session, tools Tools, root string, cfg *project.Config) error {
	if err := RequireTools(s, tools, root, cfg, true); err != nil {
		return err
	}
	command := ""
	if cfg.Acceptance != nil {
		command = cfg.Acceptance.Run
	}
	reason, output, err := RunnerCheck(ctx, s, tools, root, command)
	if err != nil || reason == "" {
		return err
	}
	e := sys.Fail("environment", "acceptance_unavailable", reason+"; fix commands.acceptance.run in .kogen/project.yaml", 3)
	e.Lines = strings.Split(Excerpt(output), "\n")
	return e
}

// ---- observations ----

// Observations are the bounded, actual failed-baseline observations for the model and the
// approval card: empty unless a scenario failed. reference names the evidence file
// (default .kogen/local/readiness/<slug>.json).
func Observations(slug string, ready *Ready, reference string) string {
	if !ready.Failures() {
		return ""
	}
	if reference == "" {
		reference = ".kogen/local/readiness/" + slug + ".json"
	}
	var details []string
	count := 0
	for _, s := range ready.Scenarios {
		count += len(s.UnexercisedSteps)
	}
	if count > 0 {
		details = append(details, fmt.Sprintf("Unexercised acceptance steps: %d\nSkipped steps are unexercised; readiness does not prove their behavior or fixture validity.", count))
	}
	for _, s := range ready.Scenarios {
		if s.Status == "failed" {
			detail := "The runner supplied no failure detail."
			if s.Detail != nil {
				detail = *s.Detail
			}
			details = append(details, fmt.Sprintf("Scenario: %s (acceptance.feature line %d)\n%s", s.Name, s.Line, detail))
		}
	}
	// Keep executed failure locations ahead of potentially long skipped-step lists.
	for _, s := range ready.Scenarios {
		if len(s.UnexercisedSteps) == 0 {
			continue
		}
		lines := []string{fmt.Sprintf("Scenario: %s (acceptance.feature line %d)", s.Name, s.Line)}
		for _, st := range s.UnexercisedSteps {
			lines = append(lines, fmt.Sprintf("acceptance.feature line %d: %s %s", st.Line, strings.TrimSpace(st.Keyword), st.Text))
		}
		details = append(details, strings.Join(lines, "\n"))
	}

	return Cut("Readiness observations\n" +
		"Checked baseline: " + ready.SHA256 + "\nHEAD: " + ready.Head + "\n" +
		"Acceptance exit: " + itoa(ready.AcceptanceExit) + "\nEvidence: " + reference + "\n" +
		strings.Join(details, "\n\n"))
}

// AcknowledgmentGuidance is how a shaper acknowledges legitimate missing-feature red.
const AcknowledgmentGuidance = "After inspecting legitimate missing-feature red, resubmit the smallest eligible owned artifact with its exact current candidate whole body, including previously proposed corrections. The files array must be nonempty; if only one eligible large artifact exists, submit its entire body. Omitted well-formed proposals remain retained; do not retransmit large unchanged prose/helpers or restore original disk bytes for acknowledgment. Publication and acknowledgment concern the exact complete package; unchanged inputs reuse readiness, while changed candidates receive fresh checks."

// Acknowledgment is the message that returns accounted red to the shaper: what to inspect,
// how to acknowledge, and the observations.
func Acknowledgment(slug string, ready *Ready, reference string) string {
	return Cut("Inspect whether fixtures, inputs and commands reached the intended behavior, using the existing read/probe tools when needed. Repair demonstrated contract defects. " +
		AcknowledgmentGuidance + " A failure can mask later cases; this is not proof that every fixture is correct.\n\n" +
		Observations(slug, ready, reference))
}

// cachedUnexercised requires complete metadata and an ordered, unique subset of
// the scenario's expanded source steps. Absence is unknown, not zero.
func cachedUnexercised(value any, scenario project.Scenario) ([]StepRecord, bool) {
	records, ok := value.([]any)
	if !ok {
		return nil, false
	}
	out := []StepRecord{}
	next := 0
	for _, value := range records {
		m, ok := value.(map[string]any)
		if !ok || len(m) != 3 {
			return nil, false
		}
		keyword, k := m["keyword"].(string)
		text, t := m["text"].(string)
		line, l := intValue(m["line"])
		if !k || !t || !l {
			return nil, false
		}
		matched := false
		for next < len(scenario.Steps) {
			step := scenario.Steps[next]
			next++
			if step.Keyword == keyword && step.Text == text && step.Line == line {
				matched = true
				break
			}
		}
		if !matched {
			return nil, false
		}
		out = append(out, StepRecord{Keyword: keyword, Text: text, Line: line})
	}
	return out, true
}

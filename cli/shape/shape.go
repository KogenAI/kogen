// Package shape is the commands that turn requests into Intents and approvals into
// Build permission: `intent shape`, `intent refine`, `intent approve`, `intent preflight` and
// `init`'s setup conversation, with the shaping evidence they share.
package shape

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
	"kogen/agent"
	"kogen/executor"
	"kogen/git"
	"kogen/project"
	"kogen/verify"
)

// ShapeInput is one `kogen intent shape <slug> <file|->`: the request, or the answers to the
// questions a former run left pending, already read by the caller.
type ShapeInput struct {
	Project     string // a directory inside the project's repository; empty: the session's directory
	Slug        string // valid by the caller (3 to 48 lowercase letters, digits and dashes)
	Request     string // the request or the answers: never empty
	RequestPath string // the absolute path it was read from; empty for standard input
	// Tools are Kogen's own Node, Quint and Cucumber. When zero they come from InstallRoot.
	Tools       verify.Tools
	InstallRoot string
	// Client talks to the provider; nil is a new provider.Client.
	Client *provider.Client
	// External provides the executor of a shape role with `executor: claude-code`; nil: none.
	External External
}

func (in ShapeInput) tools() verify.Tools {
	if in.Tools == (verify.Tools{}) && in.InstallRoot != "" {
		return verify.ToolsFromInstall(in.InstallRoot)
	}
	return in.Tools
}

// Shape is `kogen intent shape`: the shaper model turns the request into an Intent whose
// readiness Kogen has checked, or asks numbered UI/UX questions (exit 5), or reports that the
// request needs a protected edit (exit 1). Nothing is written before a valid submission,
// shaping never approves or builds, and it holds no Build lock. Refusals are *sys.Error and
// an interrupt is *sys.Interrupted; exit is also set to the matching exit code then.
func Shape(ctx context.Context, s *sys.Session, in ShapeInput) (exit int, err error) {
	exit, err = shapeRun(ctx, s, in)
	if err != nil {
		exit = ExitCode(err)
	}
	return exit, err
}

func shapeRun(ctx context.Context, s *sys.Session, in ShapeInput) (exit int, err error) {
	dir := in.Project
	if dir == "" {
		dir = s.Cwd
	} else if !filepath.IsAbs(dir) {
		dir = filepath.Join(s.Cwd, dir)
	}
	repo, err := git.Open(dir, s.Env)
	if err != nil {
		return 0, err
	}
	root, slug := repo.Dir, in.Slug
	stateDir := filepath.Join(root, ".kogen/local/shaping", slug)
	ev, err := NewEvidence(stateDir, slug)
	if err != nil {
		return 0, err
	}
	defer ev.Finish()

	cfg, err := project.LoadConfig(root)
	if err != nil {
		return 0, err
	}
	if !cfg.AcceptanceConfigured() {
		return 0, sys.Fail("environment", "acceptance_unconfigured", "set commands.acceptance in .kogen/project.yaml", 3)
	}
	tools := in.tools()
	if err := verify.RequireTools(s, tools, root, cfg, false); err != nil {
		return 0, err
	}
	if err := requireShapeRoute(cfg); err != nil {
		return 0, err
	}
	var ext executor.Executor
	extMax := 0
	if cfg.Models["shape"].External() {
		if ext, extMax, err = selectExternal(in.External, cfg.Models["shape"]); err != nil {
			return 0, err
		}
	}
	if err := provider.RequireLogin(s.Getenv("HOME"), ShapeRoles(cfg)); err != nil {
		return 0, err
	}
	st, err := readState(stateDir)
	if err != nil {
		return 0, err
	}
	if path := untrackedRequestPath(repo, root, in.RequestPath); path != "" {
		s.Puts("note: " + path + " is untracked; commit or move it before kogen intent build")
	}
	if st == nil {
		if _, err := os.Stat(filepath.Join(root, project.IntentDir(slug))); err == nil {
			return 0, sys.Fail("intent", "exists",
				slug+" is already shaped; edit its files, or delete .kogen/intents/"+slug+"/ and shape again", 5)
		}
		origin, err := project.CaptureOrigin(root, cfg)
		if err != nil {
			return 0, err
		}
		sourcePath := in.RequestPath
		if sourcePath == "" {
			sourcePath = "-"
		}
		st = &state{Request: in.Request, SourcePath: sourcePath, Rounds: []map[string]any{}, Origin: map[string]any{
			"head": origin.Head, "tree": origin.Tree, "configuration": origin.Configuration,
		}}
	} else if err := st.answer(in.Request); err != nil {
		return 0, err
	}

	if missing := st.unanswered(); len(missing) > 0 {
		if err := saveState(stateDir, st); err != nil {
			return 0, err
		}
		return printQuestions(s, slug, missing), nil
	}
	if len(cfg.Checks) == 0 {
		s.Progress("warning: commands.checks is empty; Builds will not run your tests")
	}
	rd := &verify.Readiness{Root: root, Repo: repo, Config: cfg, Tools: tools, Evidence: ev}
	if err := ev.Timed("setup", func() error { return rd.Setup(ctx, s, root, true) }); err != nil {
		return 0, err
	}
	if err := ev.Timed("preparation", func() error { return verify.RequireRunner(ctx, s, tools, root, cfg) }); err != nil {
		return 0, err
	}
	client := in.Client
	if client == nil {
		client = provider.NewClient("")
	}
	sh := &shaping{s: s, in: in, repo: repo, root: root, slug: slug, cfg: cfg, role: cfg.Models["shape"], ev: ev, ext: ext, extMax: extMax,
		rd: rd, client: client, stateDir: stateDir, originals: map[string]original{}, proposed: map[string]string{}}
	return sh.shape(ctx, st)
}

// ---- state: the questions and answers of a conversation that spans runs (SHP-6) ----

// state is `.kogen/local/shaping/<slug>/state.json`: the request, where it came from, where
// shaping started and the rounds of questions with their answers. Rounds are kept as the
// JSON objects they were saved as, so the receipt records exactly what was asked.
type state struct {
	Request    string
	SourcePath string
	Origin     map[string]any
	Rounds     []map[string]any
}

func (st *state) toMap() map[string]any {
	rounds := make([]any, len(st.Rounds))
	for i, r := range st.Rounds {
		rounds[i] = r
	}
	return map[string]any{"request": st.Request, "source_path": st.SourcePath, "origin": st.Origin, "rounds": rounds}
}

func readState(dir string) (*state, error) {
	b, err := os.ReadFile(filepath.Join(dir, "state.json"))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var doc struct {
		Request    string           `json:"request"`
		SourcePath string           `json:"source_path"`
		Origin     map[string]any   `json:"origin"`
		Rounds     []map[string]any `json:"rounds"`
	}
	if err := json.Unmarshal(b, &doc); err != nil {
		return nil, fmt.Errorf("%s: %w", filepath.Join(dir, "state.json"), err)
	}
	return &state{Request: doc.Request, SourcePath: doc.SourcePath, Origin: doc.Origin, Rounds: doc.Rounds}, nil
}

func saveState(dir string, st *state) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return err
	}
	b, err := project.EncodeJSON(st.toMap())
	if err != nil {
		return err
	}
	path := filepath.Join(dir, "state.json")
	if err := os.WriteFile(path, b, 0o666); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}

func questionsOf(round map[string]any) []map[string]any {
	list, _ := round["questions"].([]any)
	out := make([]map[string]any, 0, len(list))
	for _, q := range list {
		m, _ := q.(map[string]any)
		out = append(out, m)
	}
	return out
}

func optionsOf(question map[string]any) []map[string]any {
	list, _ := question["options"].([]any)
	out := make([]map[string]any, 0, len(list))
	for _, o := range list {
		m, _ := o.(map[string]any)
		out = append(out, m)
	}
	return out
}

func answersOf(round map[string]any) map[string]any {
	m, _ := round["answers"].(map[string]any)
	return m
}

// textOf is a value as Elixir interpolates it: text as is, nil as nothing.
func textOf(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	}
	return fmt.Sprint(v)
}

var answerLine = regexp.MustCompile(`^\s*(\d+)\s*:\s*(.*\S)\s*$`)

var letterAnswer = regexp.MustCompile(`^[a-z]$`)

// answer merges `<n>: <answer>` lines (or `all: recommended`) into the pending round.
func (st *state) answer(input string) error {
	if len(st.Rounds) == 0 {
		return errors.New("shaping state has no pending questions")
	}
	last := len(st.Rounds) - 1
	round := st.Rounds[last]
	questions := questionsOf(round)
	count := len(questions)

	var given map[string]string
	var err error
	if strings.TrimSpace(input) == "all: recommended" {
		given, err = recommendedAnswers(questions)
	} else {
		given, err = parseAnswers(input)
	}
	if err != nil {
		return err
	}
	inRange := func(n string) (int, bool) {
		i, err := strconv.Atoi(n)
		return i, err == nil && i >= 1 && i <= count
	}
	for _, n := range sortedKeys(given) {
		i, ok := inRange(n)
		if ok && letterAnswer.MatchString(given[n]) && int(given[n][0]-'a') >= len(optionsOf(questions[i-1])) {
			return sys.Fail("intent", "answer_option_invalid", fmt.Sprintf("question %d has no option %s", i, given[n]), 2)
		}
	}
	answers := map[string]any{}
	for k, v := range answersOf(round) {
		answers[k] = v
	}
	for n, a := range given {
		if _, ok := inRange(n); ok {
			answers[n] = a
		}
	}
	updated := map[string]any{}
	for k, v := range round {
		updated[k] = v
	}
	inputs, _ := round["inputs"].([]any)
	updated["inputs"] = append(slices.Clone(inputs), input)
	updated["input"] = textOf(round["input"]) + input
	updated["answers"] = answers
	st.Rounds[last] = updated
	return nil
}

func parseAnswers(input string) (map[string]string, error) {
	given := map[string]string{}
	for _, line := range strings.Split(input, "\n") {
		if m := answerLine.FindStringSubmatch(line); m != nil {
			given[m[1]] = strings.TrimSpace(m[2])
		}
	}
	if len(given) == 0 {
		return nil, sys.Fail("intent", "answers_invalid", "expected one or more lines as <n>: <letter or your words> (or all: recommended)", 2)
	}
	return given, nil
}

func recommendedAnswers(questions []map[string]any) (map[string]string, error) {
	answers := map[string]string{}
	for i, q := range questions {
		pick := -1
		for k, o := range optionsOf(q) {
			if r, ok := o["recommended"]; ok && r != nil && r != false {
				pick = k
				break
			}
		}
		if pick < 0 {
			return nil, sys.Fail("intent", "answers_invalid", fmt.Sprintf("question %d has no recommended option", i+1), 2)
		}
		answers[strconv.Itoa(i+1)] = string(rune('a' + pick))
	}
	return answers, nil
}

type numbered struct {
	n int
	q map[string]any
}

// unanswered are the questions of the latest round without an answer.
func (st *state) unanswered() []numbered {
	if len(st.Rounds) == 0 {
		return nil
	}
	round := st.Rounds[len(st.Rounds)-1]
	answers := answersOf(round)
	var out []numbered
	for i, q := range questionsOf(round) {
		if _, ok := answers[strconv.Itoa(i+1)]; !ok {
			out = append(out, numbered{i + 1, q})
		}
	}
	return out
}

// printQuestions lists the questions and how to answer them (exit 5).
func printQuestions(s *sys.Session, slug string, list []numbered) int {
	s.Puts("Questions for " + slug + ":")
	if slices.ContainsFunc(list, func(nq numbered) bool { return nq.q["kind"] == "handoff" }) {
		s.Puts("This question is an authentication or security handoff, not a design choice.")
	}
	var sample []string
	for _, nq := range list {
		s.Puts(fmt.Sprintf("%d. %s", nq.n, textOf(nq.q["question"])))
		options := optionsOf(nq.q)
		pick := -1
		for k, o := range options {
			line := fmt.Sprintf("   %c) %s", 'a'+k, textOf(o["label"]))
			if r, ok := o["recommended"]; ok && r != nil && r != false {
				line += " (recommended)"
				if pick < 0 {
					pick = k
				}
			}
			s.Puts(line)
		}
		answer := "your words"
		if len(options) > 0 {
			answer = string(rune('a' + max(pick, 0)))
		}
		sample = append(sample, fmt.Sprintf("%d: %s", nq.n, answer))
	}
	s.Puts("Answer one per line as <n>: <letter or your words>, e.g. printf '" + strings.Join(sample, `\n`) + `\n' | kogen intent shape ` + slug + " -")
	s.Puts("Or enter all: recommended to use every question's recommended option.")
	return 5
}

// untrackedRequestPath is the request file's path relative to the repository when it is an
// untracked regular file inside it, else "".
func untrackedRequestPath(repo *git.Repo, root, path string) string {
	if path == "" {
		return ""
	}
	root, abs := filepath.Clean(root), filepath.Clean(path)
	rel, ok := strings.CutPrefix(abs, root+"/")
	if !ok {
		return ""
	}
	if st, err := os.Stat(abs); err != nil || !st.Mode().IsRegular() {
		return ""
	}
	res, err := repo.Run("status", "--porcelain=v1", "-z", "--untracked-files=all", "--", ":(literal)"+rel)
	if err != nil || res.Status != 0 || res.Stdout != "?? "+rel+"\x00" {
		return ""
	}
	return rel
}

// ---- the shaper conversation ----

// original is what a file held before shaping replaced it.
type original struct {
	content []byte
	absent  bool
}

// shaping is one run of the shaper conversation.
type shaping struct {
	s        *sys.Session
	in       ShapeInput
	repo     *git.Repo
	root     string
	slug     string
	cfg      *project.Config
	role     project.Role
	ev       *Evidence
	rd       *verify.Readiness
	client   *provider.Client
	stateDir string
	// ext is the executor of an external shape role (nil: the native shaper).
	ext    executor.Executor
	extMax int

	started       time.Time
	toolDefs      []any
	measure       ContextMeasure
	originals     map[string]original
	proposed      map[string]string // path to proposed content, accumulated over the run
	declaredSteps []string          // proposed JavaScript steps once declared in Acceptance:
	ready         *verify.Ready
	requests      int
	batchUsed     bool

	inspected bool             // a read, list or search tool answered in this conversation
	docs      []map[string]any // documentation tool results of this conversation
	window    *window
	cacheID   string // this conversation's cache identity

	auditResult *auditResult   // the request audit; nil when disabled
	auditUsage  provider.Usage // the native audit call's tokens
	auditRounds int            // the external audit session's rounds
}

func (sh *shaping) elapsed() int64 { return time.Since(sh.started).Milliseconds() / 1000 }

func (sh *shaping) progress(line string) {
	sh.s.Progress(fmt.Sprintf("%s (%d s)", line, sh.elapsed()))
}

func (sh *shaping) overlay() map[string][]byte {
	m := make(map[string][]byte, len(sh.proposed))
	for p, c := range sh.proposed {
		m[p] = []byte(c)
	}
	return m
}

func (sh *shaping) mainTools() []string {
	return []string{tools.ReadFileTool, tools.ViewImageTool, tools.ListFilesTool, tools.SearchTextTool, agent.ProbeTool, tools.DocumentationTool}
}

// outcomeKind is how a conversation ended.
type outcomeKind int

const (
	outNone outcomeKind = iota
	outInvalid
	outObservations
	outQuestions
	outBlocked
	outReady
)

type outcome struct {
	kind      outcomeKind
	problems  []string
	questions []map[string]any
	paths     []string
	reason    string
}

func (sh *shaping) shape(ctx context.Context, st *state) (int, error) {
	sh.started = time.Now()
	t0 := sh.started
	role := sh.role

	defs := agent.Defs(sh.mainTools()...)
	defs = append(defs, agent.Defs(agent.SubmitTool)...)
	if sh.cfg.ShapeWorkers.Enabled {
		defs = append(defs, agent.Defs(agent.ShapeBatchTool)...)
	}
	sh.toolDefs = agent.AsAny(defs)

	protected, err := project.Protected(sh.root, sh.cfg)
	if err != nil {
		return 0, err
	}
	selected, _, err := Navigation(sh.repo)
	if err != nil {
		return 0, err
	}
	blocks, err := contextBlocks(promptInput{root: sh.root, slug: sh.slug, cfg: sh.cfg, state: st, protected: protected, selected: selected})
	if err != nil {
		return 0, err
	}
	if sh.cfg.ShapeAudit.Enabled {
		if err := sh.audit(ctx, st.Request); err != nil {
			return 0, err
		}
		if m, ok := blocks[1].(map[string]any); ok {
			m["text"] = textOf(m["text"]) + sh.auditResult.block()
		}
	}
	input := []any{map[string]any{"role": "user", "content": blocks}}
	sh.window = newShapeWindow(sh.root, sh.slug, input)
	sh.cacheID = startConversation(sh.ev, "shape")
	sh.rd.BeforeRecord = func() error { return sh.window.validate(sh.root) }

	var res outcome
	var usageLine string
	if sh.ext != nil {
		var x *extSession
		res, x, err = sh.converseExternal(ctx, blocks)
		if x != nil {
			usageLine = fmt.Sprintf("shape %s/%s %s %d round(s) wall_ms=%d", role.Model, role.Effort, executor.ClaudeCode, x.rounds+sh.auditRounds, time.Since(t0).Milliseconds())
		}
		if err != nil {
			return 0, err
		}
	} else {
		var usage provider.Usage
		res, usage, err = sh.converse(ctx, input)
		if err != nil {
			if e, ok := sys.AsError(err); ok && e.Class == "provider" {
				return 0, sh.providerFailed(e)
			}
			return 0, err
		}
		usageLine = fmt.Sprintf("shape %s/%s %s wall_ms=%d", role.Model, role.Effort, sh.auditUsage.Add(usage).Line(), time.Since(t0).Milliseconds())
	}

	switch res.kind {
	case outInvalid:
		if len(sh.originals) > 0 {
			e := sys.Fail("intent", "not_ready", "the Intent is not ready to build", 1)
			e.Lines = res.problems
			return 0, e
		}
		e := sys.Fail("shape", "invalid_output", "the shaper's output was not a valid Intent after 3 attempts", 1)
		e.Lines = res.problems
		return 0, e
	case outQuestions:
		round := map[string]any{"questions": questionList(res.questions), "answers": map[string]any{}}
		st.Rounds = append(st.Rounds, round)
		if err := saveState(sh.stateDir, st); err != nil {
			return 0, err
		}
		list := make([]numbered, len(res.questions))
		for i, q := range res.questions {
			list[i] = numbered{i + 1, q}
		}
		return printQuestions(sh.s, sh.slug, list), nil
	case outBlocked:
		return sh.printBlocked(res), nil
	}

	// ready
	if err := sh.window.validate(sh.root); err != nil {
		return 0, err
	}
	rounds := make([]map[string]any, len(st.Rounds))
	copy(rounds, st.Rounds)
	origin := project.SourceOrigin{
		Head: textOf(st.Origin["head"]), Tree: textOf(st.Origin["tree"]), Configuration: textOf(st.Origin["configuration"]),
	}
	if err := project.CaptureSource(sh.root, sh.slug, sh.cfg, project.ShapeSource{
		Request: st.Request, SourcePath: st.SourcePath, Rounds: rounds, Origin: origin,
	}); err != nil {
		return 0, err
	}
	if err := sh.rd.RecordPass(sh.s, sh.slug, sh.ready); err != nil {
		return 0, err
	}
	os.Remove(filepath.Join(sh.stateDir, "state.json"))
	var added []string
	for p, o := range sh.originals {
		if o.absent {
			added = append(added, p)
		}
	}
	return sh.printReady(added, usageLine), nil
}

func questionList(qs []map[string]any) []any {
	out := make([]any, len(qs))
	for i, q := range qs {
		out[i] = q
	}
	return out
}

// providerFailed reports the provider error, then ends shaping with the sentence that says
// what to rerun.
func (sh *shaping) providerFailed(e *sys.Error) error {
	sh.s.Out(e.Render())
	var retry string
	if sh.in.RequestPath == "" {
		retry = "kogen intent shape " + sh.slug + " - with the original request on stdin (or the same answers if questions are pending)"
	} else {
		retry = "kogen intent shape " + sh.slug + " " + ShellQuote(sh.in.RequestPath) + " with that request file (or the same answers file if questions are pending)"
	}
	sentence := "shaping stopped on a provider error after its retries; the failed request wrote no files. Rerun " + retry + ", or write the Intent yourself."
	if e.Reason == "login" || e.Reason == "usage_limit" {
		sentence = "shaping stopped on a provider error that retrying cannot fix; the failed request wrote no files. Fix the account, then rerun " + retry + "."
	}
	return sys.Fail("shape", "provider_failed", sentence, 4)
}

// converse runs the conversation until a valid submission, or three invalid ones in a row
// (SHP-4, SHP-8).
func (sh *shaping) converse(ctx context.Context, input []any) (outcome, provider.Usage, error) {
	var usage provider.Usage
	invalid := 0
	for {
		sh.requests++
		sh.s.Progress(fmt.Sprintf("kogen: shaping (request %d, %d s)", sh.requests, sh.elapsed()))
		t0 := time.Now()

		revision, err := CurrentRevision(sh.repo)
		if err != nil {
			return outcome{}, usage, err
		}
		manifest, err := sh.writeManifest(revision)
		if err != nil {
			return outcome{}, usage, err
		}
		enc, err := project.EncodeJSON(manifest)
		if err != nil {
			return outcome{}, usage, err
		}
		input = append(input, map[string]any{"role": "user", "content": "Cumulative proposal manifest: " + string(enc)})
		event, err := selectionEvent(input, manifest, sh.measure)
		if err != nil {
			return outcome{}, usage, err
		}
		sh.ev.Record(event)

		req := conversationRequest(provider.Request{
			Role: ProviderRole(sh.role), Instructions: ShaperInstructions(), Input: input, Tools: sh.toolDefs,
			Scope: sh.ev.Dir, Context: map[string]any{"phase": "shape", "role": "shape", "slug": sh.slug},
		}, sh.cacheID)
		input, err = sh.window.prepare(windowPrep{role: req.Role,
			root: sh.root, ev: sh.ev, progress: sh.progress,
			render: func(items []any) map[string]any { r := req; r.Input = items; return sh.client.Body(r) },
			state: func(head windowRef, count int, snapshot map[string]any, observations []any) map[string]any {
				return map[string]any{
					"history": map[string]any{"head": head.value(), "count": count}, "manifest": manifest,
					"declared_steps": nonNilStrings(sh.declaredSteps), "inspected": sh.inspected,
					"documentation": snapshot, "invalid_submissions": invalid, "readiness": windowReadyRecord(sh.ready),
					"assistant_observations": observations,
				}
			},
		}, input)
		if err != nil {
			return outcome{}, usage, err
		}
		req.Input = input
		call := sh.ev.BeginCall("shape", "", revision.Map(), "main shaping", sh.role)
		resp, err := tools.Deliver(input, "shape", sh.ev.Record, func() (*provider.Response, error) {
			r, err := sh.client.Respond(ctx, sh.s, req, call)
			call.End(r, err)
			return r, err
		})
		if err != nil {
			return outcome{}, usage, err
		}
		sh.progress(fmt.Sprintf("kogen: shape response %s wall_ms=%d", resp.Usage.Line(), time.Since(t0).Milliseconds()))
		usage = usage.Add(resp.Usage)
		calls := tools.Calls(resp.Items)
		input = append(input, tools.Replay(resp.Items)...)

		var outputs []any
		var result outcome
		for _, c := range calls {
			if err := sh.window.validate(sh.root); err != nil {
				return outcome{}, usage, err
			}
			if result.kind != outNone {
				outputs = append(outputs, toolOutput(c, "ignored: only one submit counts per response"))
				continue
			}
			switch {
			case c.Name == agent.ShapeBatchTool && sh.cfg.ShapeWorkers.Enabled:
				var batch map[string]any
				if sh.batchUsed {
					batch = map[string]any{"status": "refused", "reason": "one batch per conversation", "jobs": []any{}}
				} else if batch, err = sh.runBatch(ctx, c.Args()); err != nil {
					return outcome{}, usage, err
				}
				text, err := project.EncodeJSON(batch)
				if err != nil {
					return outcome{}, usage, err
				}
				sh.batchUsed = true
				outputs = append(outputs, toolOutput(c, string(text)))
			case c.Name == agent.SubmitTool:
				text, r, err := sh.submit(ctx, c.Args())
				if err != nil {
					return outcome{}, usage, err
				}
				result = r
				outputs = append(outputs, toolOutput(c, text))
			default:
				out, err := sh.runTool(ctx, c)
				if err != nil {
					return outcome{}, usage, err
				}
				sh.noteTool(c.Name, out)
				if c.Name == tools.DocumentationTool {
					row := sh.ev.RetainDocumentation(c.Args(), out.Text)
					started, finished := DocumentationProgress(row)
					sh.progress(started)
					sh.progress(finished)
				}
				if e := tools.ReadEvent(c, out, "shape"); e != nil {
					sh.ev.Record(e)
				}
				outputs = append(outputs, toolOutput(c, out))
			}
		}
		input = append(input, outputs...)

		switch {
		case result.kind == outInvalid && invalid+1 >= 3:
			return result, usage, nil
		case result.kind == outInvalid:
			invalid++
		case result.kind == outObservations:
		case result.kind == outBlocked, result.kind == outQuestions, result.kind == outReady:
			return result, usage, nil
		case len(calls) == 0:
			if invalid+1 >= 3 {
				return outcome{kind: outInvalid, problems: []string{"the shaper ended without calling submit"}}, usage, nil
			}
			input = append(input, map[string]any{"role": "user", "content": "End by calling submit with either questions or files."})
			invalid++
		}
	}
}

// converseExternal is the external shaper's conversation: one fresh read-only session; each
// final structured result is the existing `submit` payload, routed through the same submission
// rules, and Kogen's actual feedback returns to the same session. Three invalid submissions in
// a row end it like the native shaper.
func (sh *shaping) converseExternal(ctx context.Context, blocks []any) (outcome, *extSession, error) {
	stable := ShaperInstructions() + "\n\n" + externalNote + "\n\n" + blocksText(blocks)
	x, err := startExternal(ctx, sh.ext, sh.extMax, sh.repo, sh.root, sh.s.Getenv("HOME"),
		filepath.Join(sh.ev.Dir, "executor-shape"), sh.slug, sh.role, stable, "", schemaOf(agent.SubmitTool), sh.ev.Record,
		func(e map[string]any) {
			if inspectedBy(e) {
				sh.inspected = true
			}
		})
	if err != nil {
		return outcome{}, nil, err
	}
	defer x.close()
	defer func() { sh.ev.Record(x.summary()) }()
	feedback, invalid := "", 0
	for {
		sh.s.Progress(fmt.Sprintf("kogen: shaping (external round %d, %d s)", x.rounds+1, sh.elapsed()))
		res, err := x.round(ctx, feedback)
		if err != nil {
			return outcome{}, x, err
		}
		if res.Ending != executor.EndFinish {
			return outcome{}, x, executor.Fail(executor.ReasonProtocol, "the shaper ended its round without a submission")
		}
		args, err := submissionArgs(res.Structured)
		if err != nil {
			return outcome{}, x, err
		}
		text, out, err := sh.submit(ctx, args)
		if err != nil {
			return outcome{}, x, err
		}
		switch out.kind {
		case outInvalid:
			invalid++
			if invalid >= 3 {
				return out, x, nil
			}
		case outObservations:
		case outBlocked, outQuestions, outReady:
			return out, x, nil
		}
		revision, err := CurrentRevision(sh.repo)
		if err != nil {
			return outcome{}, x, err
		}
		manifest, err := sh.writeManifest(revision)
		if err != nil {
			return outcome{}, x, err
		}
		enc, err := project.EncodeJSON(manifest)
		if err != nil {
			return outcome{}, x, err
		}
		feedback = text + "\n\nCumulative proposal manifest: " + string(enc)
	}
}

func nonNilStrings(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

// noteTool records what a tool answer means for the conversation: reading the repository
// counts as inspection, and a documentation result is kept for the lookups it may cite.
func (sh *shaping) noteTool(name string, out tools.Output) {
	switch name {
	case tools.ReadFileTool, tools.ListFilesTool, tools.SearchTextTool:
		sh.inspected = true
	case tools.DocumentationTool:
		var result map[string]any
		if err := json.Unmarshal([]byte(out.Text), &result); err == nil && result != nil {
			sh.docs = append(sh.docs, result)
			sh.window.documentation = sh.docs
		}
	}
}

// writeManifest keeps the proposals and the originals they replace under the shaping folder
// and describes them for the shaper.
func (sh *shaping) writeManifest(revision Revision) (map[string]any, error) {
	proposed := []any{}
	for _, p := range sortedKeys(sh.proposed) {
		dest := filepath.Join(sh.root, ".kogen/local/shaping", sh.slug, "proposed", p)
		if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
			return nil, err
		}
		if err := os.WriteFile(dest, []byte(sh.proposed[p]), 0o666); err != nil {
			return nil, err
		}
		proposed = append(proposed, map[string]any{
			"path": p, "sha256": ContentHash([]byte(sh.proposed[p])), "source": dest, "revision": revision.Map(),
		})
	}
	originals := []any{}
	for _, p := range sortedKeys(sh.originals) {
		o := sh.originals[p]
		if o.absent {
			originals = append(originals, map[string]any{"path": p, "source": "original absence", "sha256": nil})
			continue
		}
		dest := filepath.Join(sh.root, ".kogen/local/shaping", sh.slug, "original", p)
		if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
			return nil, err
		}
		if err := os.WriteFile(dest, o.content, 0o666); err != nil {
			return nil, err
		}
		originals = append(originals, map[string]any{"path": p, "source": dest, "sha256": ContentHash(o.content)})
	}
	return map[string]any{"proposed": proposed, "originals": originals}, nil
}

var probeSummary = regexp.MustCompile(`\Aexit status: -?\d+\ntimed_out: (?:true|false)\nwall: [\d.]+ s(?:\n|\z)`)

// runTool runs one of the shaper's read-only tools or its probe.
func (sh *shaping) runTool(ctx context.Context, c tools.Call) (tools.Output, error) {
	args := c.Args()
	tl := sh.agentTools(ctx, sh.mainTools())
	if c.Name != agent.ProbeTool {
		return tl.Run(c.Name, args)
	}
	sh.progress("kogen: probe: " + textOf(args["command"]))
	var out tools.Output
	_, err := sh.ev.ProbeText(nil, func() (string, error) {
		var err error
		out, err = tl.Run(c.Name, args)
		return out.Text, err
	})
	if err != nil {
		return out, err
	}
	summary := "tool error"
	if m := probeSummary.FindString(out.Text); m != "" {
		summary = strings.ReplaceAll(strings.TrimSpace(m), "\n", "; ")
	}
	sh.progress("kogen: probe result: " + summary)
	return out, nil
}

// agentTools are the tools a model may call in the checkout: names of them, the probe among
// them when listed.
func (sh *shaping) agentTools(ctx context.Context, names []string) *tools.Tools {
	return &tools.Tools{
		Root: sh.root, Session: sh.s, Repo: agent.Git(sh.repo), Enabled: names,
		Probe:         func(command string, files any) (string, error) { return sh.probe(ctx, command, files) },
		Documentation: tools.Documentation{UserAgent: documentationAgent(sh.client)},
	}
}

// documentationAgent is the user-agent of documentation lookups: `kogen/<version>`, the
// version being the second word of the client's version line (as the providers name Kogen).
func documentationAgent(c *provider.Client) string {
	if c != nil {
		if f := strings.Fields(c.Version); len(f) > 1 {
			return "kogen/" + f[1]
		}
	}
	return "kogen/"
}

// probe is the probe tool: the command in a scratch copy of the working tree, five minutes at
// most; its result is the text the model reads.
func (sh *shaping) probe(ctx context.Context, command string, files any) (string, error) {
	p := verify.Probe{Root: sh.root, Command: command, Tools: sh.in.tools()}
	var problems []string
	switch list := files.(type) {
	case nil:
	case []any:
		for _, f := range list {
			m, _ := f.(map[string]any)
			path, pok := m["path"].(string)
			content, cok := m["content"].(string)
			if !pok || !cok {
				problems = append(problems, "every file needs a path and a content string")
				continue
			}
			p.Files = append(p.Files, verify.ProbeFile{Path: path, Content: content})
		}
	default:
		problems = append(problems, "every file needs a path and a content string")
	}
	if len(problems) > 0 {
		return (&verify.ProbeFileError{Problems: problems}).Error(), nil
	}
	r, err := p.Run(ctx, sh.s)
	if err != nil {
		var pe *verify.ProbeFileError
		if errors.As(err, &pe) {
			return pe.Error(), nil
		}
		return "", err
	}
	return fmt.Sprintf("exit status: %d\ntimed_out: %t\nwall: %s s\n%s", r.Status, r.TimedOut, formatWall(r.Wall), r.Output), nil
}

// formatWall is a wall time as Elixir prints a float: one decimal at least.
func formatWall(w float64) string {
	s := strconv.FormatFloat(w, 'f', -1, 64)
	if !strings.Contains(s, ".") {
		s += ".0"
	}
	return s
}

// ---- submissions ----

// submit takes the shaper's submission: questions, files that pass readiness, or a
// truthful protected-conflict report. Blocked is a report only; it never authorizes an edit
// or writes submission files. The text goes back to the shaper.
func (sh *shaping) submit(ctx context.Context, args map[string]any) (string, outcome, error) {
	sub, problems, err := sh.validate(args)
	if err != nil {
		return "", outcome{}, err
	}
	if problems != nil {
		return "invalid submission:\n" + strings.Join(problems, "\n") +
				"\nNo proposals from this submission were retained; earlier proposals are unchanged.",
			outcome{kind: outInvalid, problems: problems}, nil
	}
	if lines := sh.auditGate(sub); lines != nil {
		return strings.Join(lines, "\n"), outcome{kind: outInvalid, problems: lines}, nil
	}
	switch {
	case sub.questions != nil:
		return "accepted", outcome{kind: outQuestions, questions: sub.questions}, nil
	case sub.blocked:
		return "blocked: required protected edits reported", outcome{kind: outBlocked, paths: sub.paths, reason: sub.reason}, nil
	}

	if problems := sh.publicationProblems(sub.files); len(problems) > 0 {
		return "invalid submission:\n" + strings.Join(problems, "\n") +
				"\nNo proposals from this submission were retained; earlier proposals are unchanged.",
			outcome{kind: outInvalid, problems: problems}, nil
	}
	return sh.acceptFiles(ctx, sub.files)
}

// acceptFiles merges a submission's files into the accumulated proposals and checks the
// complete candidate.
func (sh *shaping) acceptFiles(ctx context.Context, submitted []proposedFile) (string, outcome, error) {
	for _, f := range submitted {
		sh.proposed[f.path] = f.content
	}
	files := sortedKeys(sh.proposed)
	if _, ok := sh.proposed[project.IntentMDPath(sh.slug)]; ok {
		if intent, err := project.ReadIntent(sh.root, sh.slug, sh.overlay()); err == nil {
			for _, p := range intent.StepFiles() {
				if !slices.Contains(sh.declaredSteps, p) {
					sh.declaredSteps = append(sh.declaredSteps, p)
				}
			}
		}
	}
	intent, _, err := project.CheckIntent(sh.root, sh.slug, sh.overlay())
	if err != nil {
		e, ok := sys.AsError(err)
		if !ok {
			return "", outcome{}, err
		}
		return "invalid submission:\n" + strings.Join(e.Lines, "\n") +
				"\nEarlier well-formed proposals are retained; submit only corrections.",
			outcome{kind: outInvalid, problems: e.Lines}, nil
	}
	if problems := sh.retainedProblems(intent, files); len(problems) > 0 {
		return strings.Join(problems, "\n"), outcome{kind: outInvalid, problems: problems}, nil
	}
	return sh.checkSubmission(ctx, files)
}

// retainedProblems rejects a candidate that abandons a proposed artifact: a proposed
// JavaScript step once declared, or the proposed model, must stay declared.
func (sh *shaping) retainedProblems(intent *project.Intent, files []string) []string {
	steps := intent.StepFiles()
	model := ""
	if intent.Model != nil && !intent.Model.None {
		model = intent.Model.Path
	}
	var abandoned []string
	for _, p := range files {
		if (slices.Contains(sh.declaredSteps, p) && filepath.Ext(p) == ".js" && !slices.Contains(steps, p)) ||
			(p == project.ModelPath(sh.slug) && p != model) {
			abandoned = append(abandoned, p)
		}
	}
	if len(abandoned) == 0 {
		return nil
	}
	return []string{"proposed artifacts must remain declared: " + strings.Join(abandoned, ", ") + ". Omission cannot delete proposals; include them or preserve and park the partial package and its owned new step files, then remove its empty Intent directory and use normal shaping again (same slug or a new one)."}
}

// checkSubmission writes the accumulated package, formats it with the project's fixers and
// checks readiness; problems go back to the shaper, accounted red comes back as observations
// to acknowledge.
func (sh *shaping) checkSubmission(ctx context.Context, files []string) (string, outcome, error) {
	if err := sh.writeAttempt(files); err != nil {
		return "", outcome{}, err
	}
	if err := sh.fixAttempt(ctx, files); err != nil {
		return "", outcome{}, err
	}
	sh.progress("kogen: checking step code")
	feedback, err := sh.stepSelfcheck(ctx)
	if err != nil {
		return "", outcome{}, err
	}
	if feedback != "" {
		return feedback, outcome{kind: outInvalid, problems: strings.Split(feedback, "\n")[1:]}, nil
	}
	sh.progress("kogen: checking readiness")
	text, result, err := sh.certify(ctx, files)
	if err != nil {
		e, ok := sys.AsError(err)
		if ok && (e.Reason == "not_ready" || e.Reason == "parse" || e.Reason == "lint") {
			// Not-ready problems as they are; a lint or parse error with its own first line.
			problems := e.Lines
			if e.Reason != "not_ready" {
				problems = append([]string{e.Error()}, e.Lines...)
			}
			return "not ready:\n" + strings.Join(problems, "\n"), outcome{kind: outInvalid, problems: problems}, nil
		}
		return "", outcome{}, err
	}
	return text, result, nil
}

func (sh *shaping) certify(ctx context.Context, files []string) (string, outcome, error) {
	if _, err := project.SourceComparison(sh.root, sh.slug); err != nil {
		return "", outcome{}, err
	}
	// Fixers may change submitted declarations. The final formatted package must retain the
	// same executable artifacts before it can be certified.
	if intent, _, err := project.CheckIntent(sh.root, sh.slug, nil); err == nil {
		if problems := sh.retainedProblems(intent, files); len(problems) > 0 {
			e := sys.Fail("intent", "lint", "the Intent needs changes", 1)
			e.Lines = problems
			return "", outcome{}, e
		}
	}
	if sh.ready != nil && sh.rd.Current(sh.s, sh.slug, sh.ready) {
		return "accepted: unchanged checked observations acknowledged", outcome{kind: outReady}, nil
	}
	var ready *verify.Ready
	err := sh.ev.Timed("readiness", func() error {
		var err error
		ready, err = sh.rd.Check(ctx, sh.s, sh.slug)
		return err
	})
	if err != nil {
		return "", outcome{}, err
	}
	sh.ready = ready
	reference := filepath.Join(sh.root, ".kogen/local/shaping", sh.slug, fmt.Sprintf("observations-%d.txt", sh.requests))
	if err := os.WriteFile(reference, []byte(verify.Observations(sh.slug, ready, reference)), 0o666); err != nil {
		return "", outcome{}, err
	}
	if ready.Failures() {
		return verify.Acknowledgment(sh.slug, ready, reference), outcome{kind: outObservations}, nil
	}
	return "accepted: the Intent is ready", outcome{kind: outReady}, nil
}

// writeAttempt remembers what the files held and writes the accumulated proposals.
func (sh *shaping) writeAttempt(files []string) error {
	for _, p := range files {
		if _, ok := sh.originals[p]; ok {
			continue
		}
		old, err := os.ReadFile(filepath.Join(sh.root, p))
		sh.originals[p] = original{content: old, absent: err != nil}
	}
	for _, p := range files {
		path := filepath.Join(sh.root, p)
		if err := os.MkdirAll(filepath.Dir(path), 0o777); err != nil {
			return err
		}
		if err := os.WriteFile(path, []byte(sh.proposed[p]), 0o666); err != nil {
			return err
		}
	}
	return nil
}

// fixAttempt formats the attempt's files with the project's fixers, so the card, the
// approval hash and the Build's unchanged-tree checks see them formatted (SHP-4). What the
// fixers change anywhere else is undone.
func (sh *shaping) fixAttempt(ctx context.Context, paths []string) error {
	if len(sh.cfg.Fix) == 0 {
		return nil
	}
	changed, err := sh.repo.ChangedPaths()
	if err != nil {
		return err
	}
	type snapshot struct {
		text string
		ok   bool
	}
	before := map[string]snapshot{}
	for _, p := range changed {
		b, err := os.ReadFile(filepath.Join(sh.root, p))
		before[p] = snapshot{string(b), err == nil}
	}
	for i, cmd := range sh.cfg.Fix {
		sh.progress(fmt.Sprintf("kogen: running fix-%d: %s", i+1, cmd))
		if _, err := sh.s.Run(cmd, sh.root, sys.Options{KillGroupOnExit: true}); err != nil {
			return err
		}
	}
	after, err := sh.repo.ChangedPaths()
	if err != nil {
		return err
	}
	for _, p := range after {
		if slices.Contains(paths, p) {
			continue
		}
		file := filepath.Join(sh.root, p)
		switch b, known := before[p]; {
		case known && b.ok:
			if cur, err := os.ReadFile(file); err != nil || string(cur) != b.text {
				if err := os.WriteFile(file, []byte(b.text), 0o666); err != nil {
					return err
				}
			}
		case known:
			os.RemoveAll(file)
		default:
			if _, ok := sh.repo.Show("HEAD", p); ok {
				if _, err := sh.repo.OK("restore", "--source=HEAD", "--staged", "--worktree", "--", ":(literal)"+p); err != nil {
					return err
				}
			} else {
				os.RemoveAll(file)
			}
		}
	}
	return nil
}

// ---- validation of a submission (SHP-4) ----

type submission struct {
	questions []map[string]any
	files     []proposedFile
	blocked   bool
	paths     []string
	reason    string
}

type proposedFile struct{ path, content string }

func isText(v any) bool {
	s, ok := v.(string)
	return ok && strings.TrimSpace(s) != ""
}

// validate checks the submission's envelope: exactly one of questions, files or blocked. The
// problems are nil for a valid one.
func (sh *shaping) validate(args map[string]any) (submission, []string, error) {
	_, hasQ := args["questions"]
	_, hasF := args["files"]
	blocked, hasB := args["blocked"]
	qs, _ := args["questions"].([]any)
	fs, _ := args["files"].([]any)
	switch {
	case hasB && !hasQ && !hasF:
		return sh.validateBlocked(blocked)
	case len(qs) > 0 && !hasF && !hasB:
		return validateQuestions(args, qs)
	case len(fs) > 0 && !hasQ && !hasB:
		return sh.validateFiles(fs)
	}
	return submission{}, []string{"submit takes exactly one of a non-empty questions list, a non-empty files list, or a blocked report"}, nil
}

func (sh *shaping) validateBlocked(blocked any) (submission, []string, error) {
	var paths, reason any
	if m, ok := blocked.(map[string]any); ok {
		paths, reason = m["paths"], m["reason"]
	}
	list, isList := paths.([]any)
	var problems []string
	switch {
	case !isList || len(list) == 0:
		problems = append(problems, "blocked.paths must be a non-empty list")
	case !slices.ContainsFunc(list, func(p any) bool { return !isText(p) }):
	default:
		problems = append(problems, "blocked.paths must contain non-empty paths")
	}
	if !isText(reason) {
		problems = append(problems, "blocked.reason must be non-empty text")
	}
	protected, err := project.Baseline(sh.root, sh.slug, sh.cfg)
	if err != nil {
		return submission{}, nil, err
	}
	var out []string
	for _, p := range list {
		if isText(p) {
			if !slices.Contains(protected, p.(string)) {
				problems = append(problems, "blocked path "+p.(string)+" is not protected by the current contract")
			}
		}
		if s, ok := p.(string); ok {
			out = append(out, s)
		}
	}
	if len(problems) > 0 {
		return submission{}, problems, nil
	}
	return submission{blocked: true, paths: out, reason: reason.(string)}, nil, nil
}

func validateQuestions(args map[string]any, qs []any) (submission, []string, error) {
	var out []map[string]any
	for _, q := range qs {
		m, ok := q.(map[string]any)
		if !ok || !isText(m["question"]) || !validOptions(m) {
			return submission{}, []string{"every question needs question text and optional options with string labels and boolean recommended values"}, nil
		}
	}
	kinds := []any{args["kind"]}
	for _, q := range qs {
		kinds = append(kinds, q.(map[string]any)["kind"])
	}
	if slices.ContainsFunc(kinds, explicitRejectedKind) {
		return submission{}, []string{"questions: decide technical questions inside shaping; only kind product or handoff may reach the caller"}, nil
	}
	for _, q := range qs {
		m := q.(map[string]any)
		kept := map[string]any{"question": m["question"]}
		if o, ok := m["options"]; ok {
			kept["options"] = o
		}
		kind := m["kind"]
		if kind == nil || kind == false {
			kind = args["kind"]
		}
		if k, ok := kind.(string); ok {
			kept["kind"] = k
		}
		out = append(out, kept)
	}
	return submission{questions: out}, nil, nil
}

// explicitRejectedKind: a question kind other than none, product or handoff.
func explicitRejectedKind(kind any) bool {
	switch kind {
	case nil, "product", "handoff":
		return false
	}
	return true
}

func validOptions(q map[string]any) bool {
	raw, has := q["options"]
	if !has {
		return true
	}
	options, ok := raw.([]any)
	if !ok {
		return false
	}
	for _, o := range options {
		m, ok := o.(map[string]any)
		if !ok {
			return false
		}
		if _, ok := m["label"].(string); !ok {
			return false
		}
		if r, has := m["recommended"]; has {
			if _, ok := r.(bool); !ok {
				return false
			}
		}
	}
	return true
}

func (sh *shaping) validateFiles(list []any) (submission, []string, error) {
	slug := sh.slug
	own := []string{project.IntentMDPath(slug), project.FeaturePath(slug), project.ModelPath(slug)}
	steps := ""
	if sh.cfg.Acceptance != nil {
		steps = sh.cfg.Acceptance.StepsDir
	}
	var problems []string
	var files []proposedFile
	seen := map[string]bool{}
	for _, f := range list {
		m, _ := f.(map[string]any)
		p, pok := m["path"].(string)
		c, cok := m["content"].(string)
		if !pok || !cok {
			problems = append(problems, "every file needs a path and a content string")
			continue
		}
		switch {
		case !normalPath(p):
			problems = append(problems, p+": paths must be relative and normal")
		case slices.Contains(own, p):
		case steps != "" && strings.HasPrefix(p, steps+"/"):
		default:
			where := steps
			if steps == "" {
				where = "commands.acceptance.steps_dir (unset)"
			}
			problems = append(problems, p+": shaping may write only "+project.IntentDir(slug)+"/{intent.md,acceptance.feature,model.qnt} and step files under "+where+"/")
		}
		seen[p] = true
		files = append(files, proposedFile{p, c})
	}
	if len(problems) > 0 {
		return submission{}, problems, nil
	}
	if len(seen) != len(list) {
		return submission{}, []string{"file paths must be unique; no proposals from this submission were retained"}, nil
	}
	sort.Slice(files, func(i, j int) bool { return files[i].path < files[j].path })
	return submission{files: files}, nil, nil
}

// normalPath reports whether p is relative and already in its normal form: expanding it
// against a root and cutting the root again gives p back.
func normalPath(p string) bool {
	if p == "" || strings.HasPrefix(p, "/") || p == "~" || strings.HasPrefix(p, "~/") {
		return false
	}
	norm := filepath.Clean(filepath.Join("/r", p))
	rel, ok := strings.CutPrefix(norm, "/r/")
	return ok && rel == p
}

// ---- output (SHP-8) ----

func (sh *shaping) printBlocked(res outcome) int {
	sh.s.Puts("shape/protected_conflict: required edits touch protected files: " + strings.Join(res.paths, ", "))
	sh.s.Puts(res.reason)
	sh.s.Puts("Next: revise the request, or review and commit .kogen/project.yaml outside Build, then shape again; preserve checks and actual check configuration. There is no protected-edit override.")
	return 1
}

func (sh *shaping) printReady(added []string, usageLine string) int {
	var steps []string
	for _, p := range sh.ready.Intent.StepFiles() {
		state := "unchanged"
		if slices.Contains(added, p) {
			state = "new"
		} else if changed, err := sh.repo.ChangedPaths(p); err == nil && len(changed) > 0 {
			state = "edited"
		}
		steps = append(steps, p+" ("+state+")")
	}
	failing, passing := 0, 0
	for _, sc := range sh.ready.Scenarios {
		switch sc.Status {
		case "failed":
			failing++
		case "passed":
			passing++
		}
	}
	stepText := "none"
	if len(steps) > 0 {
		stepText = strings.Join(steps, ", ")
	}
	sh.s.Puts("Intent: " + filepath.Join(sh.root, project.IntentMDPath(sh.slug)))
	sh.s.Puts("Acceptance test: " + filepath.Join(sh.root, project.FeaturePath(sh.slug)))
	sh.s.Puts("Step files: " + stepText)
	sh.s.Puts("Model: " + sh.ready.Intent.ModelLine)
	sh.s.Puts(fmt.Sprintf("Scenarios: %d (%d fail now, %d pass now)", len(sh.ready.Scenarios), failing, passing))
	sh.s.Puts(usageLine)
	sh.s.Puts("Next: kogen intent approve " + sh.slug)
	return 0
}

package shape

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
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

// RefineInput is one `kogen intent refine <slug> <sha256> <file|->`: the correction request,
// already read by the caller, and the full baseline hash of the draft it corrects (SHP-11).
type RefineInput struct {
	SubmissionRetryLimit int // internal invalid-submission budget; nonpositive means 3

	// NativeRoundLimits is internal and research-only; Shape, Refine and Review
	// limits are unsupported for now and their keys are ignored.
	NativeRoundLimits map[string]int

	Project     string // a directory inside the project's repository; empty: the session's directory
	Slug        string // valid by the caller (3 to 48 lowercase letters, digits and dashes)
	Hash        string // the full 64-character lowercase SHA-256 from the draft's review card
	Request     string // the correction request: never empty
	RequestPath string // the absolute path it was read from; empty for standard input
	// Tools are Kogen's own Node, Quint and Cucumber. When zero they come from InstallRoot.
	Tools       verify.Tools
	InstallRoot string
	// Client talks to the provider; nil is a new provider.Client.
	Client *provider.Client
	// External provides the executor of a shape role with `executor: claude-code`; nil: none.
	External External
}

func (in RefineInput) tools() verify.Tools {
	if in.Tools == (verify.Tools{}) && in.InstallRoot != "" {
		return verify.ToolsFromInstall(in.InstallRoot)
	}
	return in.Tools
}

// Refine is `kogen intent refine`: the shaper model corrects an existing ready Intent in a
// scratch checkout; the complete accumulated, formatted and readiness-checked correction
// replaces the draft files only when the frozen hash, HEAD, tree, index and approval still
// match, the old approval is revoked and the receipt is updated. It holds the Build lock
// throughout, never approves and never builds. Refusals are *sys.Error and an interrupt is
// *sys.Interrupted; exit is also set to the matching exit code then.
func Refine(ctx context.Context, s *sys.Session, in RefineInput) (exit int, err error) {
	exit, err = refineStart(ctx, s, in)
	if err != nil {
		exit = ExitCode(err)
	}
	return exit, err
}

func refineStart(ctx context.Context, s *sys.Session, in RefineInput) (int, error) {
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
	lock, err := git.AcquireBuild(repo.Dir, s)
	if err != nil {
		return 0, err
	}
	defer lock.Release()
	return refineLocked(ctx, s, in, repo)
}

// refine is one run: what it froze, what it keeps privately and the conversation's state.
type refine struct {
	s      *sys.Session
	in     RefineInput
	repo   *git.Repo
	root   string
	slug   string
	cfg    *project.Config
	tools  verify.Tools
	client *provider.Client

	expected   string
	correction project.SourceRequest
	source     *project.SourceRef
	pinned     *project.SourceRef // the receipt the existing approval marker points at, resolved
	head, tree string
	approval   []byte
	approved   bool
	indexPath  string
	index      string

	evidence string
	ev       *Evidence
	scratch  string
	scratchR *git.Repo
	rd       *verify.Readiness // the checkout
	scratchD *verify.Readiness // the scratch checkout

	intent      *project.Intent // the original
	originals   map[string][]byte
	proposed    map[string]string
	observed    *verify.Ready
	allowed     []string
	observation string // the original's observations text
	measure     ContextMeasure
	attempts    int

	window  *window
	cacheID string // this conversation's cache identity

	// ext is the executor of an external shape role (nil: the native shaper).
	ext    executor.Executor
	extMax int
}

func refineLocked(ctx context.Context, s *sys.Session, in RefineInput, repo *git.Repo) (int, error) {
	root, slug := repo.Dir, in.Slug
	cfg, err := project.LoadConfig(root)
	if err != nil {
		return 0, err
	}
	if err := project.RequireIntentDir(root, slug); err != nil {
		return 0, err
	}
	approval, approved, err := refineReadApproval(root, slug)
	if err != nil {
		return 0, err
	}
	if !cfg.AcceptanceConfigured() {
		return 0, sys.Fail("environment", "acceptance_unconfigured", "set commands.acceptance in .kogen/project.yaml", 3)
	}
	original, _, err := project.CheckIntent(root, slug, nil)
	if err != nil {
		if e, ok := sys.AsError(err); ok {
			notReady := sys.Fail("intent", "not_ready", "refinement requires an existing ready Intent", 1)
			notReady.Lines = e.Lines
			return 0, notReady
		}
		return 0, err
	}
	if _, err := os.Stat(filepath.Join(root, ".kogen/local/shaping", slug, "state.json")); err == nil {
		return 0, refineConstraint("Finish or discard the pending shaping questions before refining this draft.")
	}
	if !refineHashPattern.MatchString(in.Hash) {
		return 0, sys.Fail("intent", "refinement_hash", "refinement requires the full 64-character baseline SHA-256", 2)
	}
	baseline, err := project.Baseline(root, slug, cfg)
	if err != nil {
		return 0, err
	}
	expected := in.Hash
	if current := project.Hash(root, baseline); current != expected {
		return 0, sys.Fail("intent", "refinement_stale",
			fmt.Sprintf("%s is now %s, not %s; run kogen intent approve %s to review the full current hash, then retry Refine; nothing was replaced", slug, current, expected, slug), 1)
	}
	source, err := project.BindSource(root, slug)
	if err != nil {
		return 0, err
	}
	var marker *project.Approval
	if approved {
		marker = new(project.Approval)
		if err := json.Unmarshal(approval, marker); err != nil {
			return 0, fmt.Errorf("approval %s: %w", slug, err)
		}
	}
	pinned, err := project.ResolveApproval(root, slug, marker)
	if err != nil {
		return 0, err
	}
	if approved && marker.SHA256 == expected {
		if err := preflightClean(repo, root, slug); err != nil {
			return 0, err
		}
	}
	head := repo.Head()
	if head == "" {
		return 0, sys.Fail("environment", "no_head", "commit the project before refining", 3)
	}
	tree, err := repo.Tree(head, nil)
	if err != nil {
		return 0, err
	}
	indexPath, err := repo.IndexPath()
	if err != nil {
		return 0, err
	}
	index, err := refineIndexDigest(indexPath)
	if err != nil {
		return 0, err
	}
	tools := in.tools()
	if err := requireShapeRoute(cfg); err != nil {
		return 0, err
	}
	var ext executor.Executor
	extMax := 0
	if shaper := cfg.Models["shape"]; shaper.External() {
		var err error
		if ext, extMax, err = selectExternal(in.External, shaper); err != nil {
			return 0, err
		}
	} else if err := provider.RequireLogin(s.Getenv("HOME"), []provider.Role{ProviderRole(shaper)}); err != nil {
		return 0, err
	}
	if err := verify.RequireTools(s, tools, root, cfg, false); err != nil {
		return 0, err
	}

	id := make([]byte, 8)
	if _, err := rand.Read(id); err != nil {
		return 0, err
	}
	evidence := filepath.Join(root, ".kogen/local/refinements", hex.EncodeToString(id))
	scratch := sys.TmpPath("kogen-refine")

	var files []string
	for _, p := range baseline {
		if strings.HasPrefix(p, project.IntentDir(slug)+"/") || slices.Contains(original.Acceptance, p) {
			files = append(files, p)
		}
	}
	originals := map[string][]byte{}
	for _, p := range files {
		b, err := os.ReadFile(filepath.Join(root, p))
		if err != nil {
			return 0, err
		}
		originals[p] = b
	}
	if err := os.MkdirAll(evidence, 0o755); err != nil {
		return 0, err
	}
	if err := os.Chmod(evidence, 0o700); err != nil {
		return 0, err
	}
	ev, err := NewEvidence(evidence, slug)
	if err != nil {
		return 0, err
	}
	s.Progress("kogen: refinement evidence: " + evidence)

	allowed, err := refineEditable(repo, root, slug, cfg, files)
	if err != nil {
		ev.Finish()
		return 0, err
	}
	r := &refine{
		s: s, in: in, repo: repo, root: root, slug: slug, cfg: cfg, tools: tools, client: in.Client,
		expected: expected, correction: project.NewSourceRequest(in.Request, in.RequestPath), source: source, pinned: pinned,
		head: head, tree: tree, approval: approval, approved: approved, indexPath: indexPath, index: index,
		evidence: evidence, ev: ev, scratch: scratch, scratchR: repo.At(scratch),
		intent: original, originals: originals, proposed: map[string]string{}, allowed: allowed,
		ext: ext, extMax: extMax,
	}
	if r.client == nil {
		r.client = provider.NewClient("")
	}
	r.rd = &verify.Readiness{Root: root, Repo: repo, Config: cfg, Tools: tools, Evidence: ev}
	r.scratchD = &verify.Readiness{Root: scratch, Repo: r.scratchR, Config: cfg, Tools: tools, Evidence: ev}
	return r.run(ctx)
}

var refineHashPattern = regexp.MustCompile(`\A[0-9a-f]{64}\z`)

// run is the refinement from its evidence to its publication. Whatever happens, the result
// file says how it ended, the evidence is finished and the scratch checkout is removed.
func (r *refine) run(ctx context.Context) (exit int, err error) {
	defer os.RemoveAll(r.scratch)
	defer r.ev.Finish()
	if limit := submissionRetryLimit(r.in.SubmissionRetryLimit); limit != 3 {
		r.ev.Record(map[string]any{"event": "submission_retry_limit", "limit": limit})
	}
	defer func() {
		if err == nil {
			return
		}
		extra := map[string]any{}
		var i *sys.Interrupted
		if errors.As(err, &i) {
			r.result("interrupted", map[string]any{"signal": i.Signal})
			return
		}
		extra["error"] = err.Error()
		if e, ok := sys.AsError(err); ok && e.ProviderFailure != nil {
			extra["provider_failure"] = e.ProviderFailure
		}
		r.result("failed", extra)
	}()

	if err := r.save("", map[string][]byte{"request.md": []byte(r.in.Request)}, 0o600); err != nil {
		return 0, err
	}
	if r.approved {
		if err := r.save("", map[string][]byte{"original-approval.json": r.approval}, 0o666); err != nil {
			return 0, err
		}
	}
	if err := r.save("original", r.originals, 0o666); err != nil {
		return 0, err
	}
	if err := r.prepare(); err != nil {
		return 0, err
	}
	if err := r.freeze(); err != nil {
		return 0, err
	}
	if err := r.originalReadiness(ctx); err != nil {
		return 0, err
	}

	role := r.cfg.Models["shape"]
	blocks, err := r.context()
	if err != nil {
		return 0, err
	}
	input := []any{map[string]any{"role": "user", "content": blocks}}
	defs := agent.AsAny(agent.Defs(tools.ReadFileTool, tools.ListFilesTool, tools.SearchTextTool, agent.ProbeTool, tools.DocumentationTool, agent.SubmitRefinementTool))
	r.window = newRefineWindow(r.evidence, input)
	r.cacheID = startConversation(r.ev, "refine")
	var changes map[string]string
	var ready *verify.Ready
	var usage provider.Usage
	if r.ext != nil {
		changes, ready, err = r.converseExternal(ctx, role, blocks)
	} else {
		changes, ready, usage, err = r.converse(ctx, role, defs, input)
	}
	if err != nil {
		return 0, err
	}
	if err := r.freeze(); err != nil {
		return 0, err
	}
	// Publication is serialized with approval and Build. Each destination existed at the
	// frozen baseline; scratch checks and failed submissions never write the draft.
	if err := r.publish(ctx, changes, ready); err != nil {
		return 0, err
	}
	paths := sortedKeys(changes)
	r.result("ready", map[string]any{"usage": map[string]any{
		"input": usage.Input, "cached": usage.Cached, "output": usage.Output, "reasoning": usage.Reasoning,
	}, "changed": paths})

	baseline, err := project.Baseline(r.root, r.slug, r.cfg)
	if err != nil {
		return 0, err
	}
	r.s.Puts("refined " + r.slug + " " + project.Hash(r.root, baseline)[:8])
	r.s.Puts("Changed: " + strings.Join(paths, ", "))
	r.s.Puts("Evidence: " + r.evidence)
	r.s.Puts("Next: kogen intent approve " + r.slug)
	return 0, nil
}

// ---- errors ----

func refineStale() *sys.Error {
	return sys.Fail("intent", "refinement_stale",
		"the draft or checkout changed; nothing was replaced. Review its current full hash and retry.", 1)
}

func refineConstraint(reason string) *sys.Error {
	return sys.Fail("shape", "refinement_constraint", reason+" The original draft is preserved.", 1)
}

// ---- files and results ----

func (r *refine) result(outcome string, extra map[string]any) {
	doc := map[string]any{"outcome": outcome, "slug": r.slug, "baseline": r.expected, "head": r.head}
	for k, v := range extra {
		doc[k] = v
	}
	b, err := project.EncodeJSON(doc)
	if err != nil {
		return
	}
	os.WriteFile(filepath.Join(r.evidence, "result.json"), append(b, '\n'), 0o666)
}

// save writes files under folder of the evidence (the evidence itself for "").
func (r *refine) save(folder string, files map[string][]byte, mode os.FileMode) error {
	for p, content := range files {
		dest := filepath.Join(r.evidence, folder, p)
		if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(dest, content, mode); err != nil {
			return err
		}
		if mode != 0o666 {
			if err := os.Chmod(dest, mode); err != nil {
				return err
			}
		}
	}
	return nil
}

func (r *refine) saveText(folder string, files map[string]string) error {
	b := make(map[string][]byte, len(files))
	for p, c := range files {
		b[p] = []byte(c)
	}
	return r.save(folder, b, 0o666)
}

func refineReadApproval(root, slug string) ([]byte, bool, error) {
	b, err := os.ReadFile(project.ApprovalPath(root, slug))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	return b, true, nil
}

// refineIndexDigest is the SHA-256 of the index file; "" when there is none.
func refineIndexDigest(path string) (string, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:]), nil
}

// refineRegularPath: an existing path is an ordinary file with no symlink ancestor, so that
// publishing a correction cannot follow a link into another artifact or out of the checkout.
func refineRegularPath(root, path string) bool {
	full := root
	for _, part := range strings.Split(path, "/") {
		full = filepath.Join(full, part)
		fi, err := os.Lstat(full)
		if err != nil || (!fi.Mode().IsRegular() && !fi.IsDir()) {
			return false
		}
	}
	return true
}

// refineEditable are the files of the package a correction may replace: the Intent's own
// `intent.md`, `acceptance.feature` and `model.qnt`, and its step files under `steps_dir`
// that HEAD does not have and no other Intent lists. Protected and non-regular paths are
// never editable.
func refineEditable(repo *git.Repo, root, slug string, cfg *project.Config, files []string) ([]string, error) {
	var shared []string
	others, _ := filepath.Glob(filepath.Join(root, ".kogen/intents/*/intent.md"))
	slices.Sort(others)
	for _, p := range others {
		if p == filepath.Join(root, project.IntentMDPath(slug)) {
			continue
		}
		if other, err := project.LoadIntent(root, filepath.Base(filepath.Dir(p))); err == nil {
			shared = append(shared, other.Acceptance...)
		}
	}
	protected, err := project.Protected(root, cfg)
	if err != nil {
		return nil, err
	}
	owned := []string{project.IntentMDPath(slug), project.FeaturePath(slug), project.ModelPath(slug)}
	stepsDir := ""
	if cfg.Acceptance != nil {
		stepsDir = cfg.Acceptance.StepsDir
	}
	allowed := []string{}
	for _, p := range files {
		step := false
		if stepsDir != "" && strings.HasPrefix(p, stepsDir+"/") && !slices.Contains(shared, p) {
			_, inHead := repo.Show("HEAD", p)
			step = !inHead
		}
		if (slices.Contains(owned, p) || step) && !slices.Contains(protected, p) && refineRegularPath(root, p) {
			allowed = append(allowed, p)
		}
	}
	return allowed, nil
}

// ---- the frozen checkout ----

// freeze fails with intent/refinement_stale when anything the run froze has changed: the
// bound source, the raw approval, the index, HEAD, the acceptance baseline or the tree.
func (r *refine) freeze() error {
	if r.window != nil {
		if err := r.window.validate(r.root); err != nil {
			return err
		}
	}
	if err := project.ValidateSource(r.source); err != nil {
		return err
	}
	if err := project.ValidateSource(r.pinned); err != nil {
		return err
	}
	if bound, err := project.BindSource(r.root, r.slug); err != nil {
		return err
	} else if !bound.Equal(r.source) {
		return refineStale()
	}
	approval, approved, err := refineReadApproval(r.root, r.slug)
	if err != nil {
		return err
	}
	if approved != r.approved || !bytes.Equal(approval, r.approval) {
		return refineStale()
	}
	index, err := refineIndexDigest(r.indexPath)
	if err != nil {
		return err
	}
	if index != r.index || r.repo.Head() != r.head {
		return refineStale()
	}
	baseline, err := project.Baseline(r.root, r.slug, r.cfg)
	if err != nil {
		return err
	}
	if project.Hash(r.root, baseline) != r.expected {
		return refineStale()
	}
	tree, err := r.repo.Tree(r.head, nil)
	if err != nil {
		return err
	}
	if tree != r.tree {
		return refineStale()
	}
	return nil
}

// prepare makes the warm scratch checkout: a shared clone with the working tree's files
// (ignored warmth included) and the source's ignore rules, whose index holds the frozen
// tree. Final proof never uses it: readiness materializes the tree afresh.
func (r *refine) prepare() error {
	if _, err := r.repo.OK("clone", "--quiet", "--shared", "--no-checkout", "--", r.root, r.scratch); err != nil {
		return err
	}
	if err := verify.CopyTree(r.root, r.scratch); err != nil {
		return err
	}
	// The warm clone has its own Git metadata. Keep the source's ignore rules so that local
	// workspace warmth cannot become candidate inputs merely because clone did not copy
	// info/exclude or local config.
	out, err := r.repo.OK("rev-parse", "--path-format=absolute", "--git-path", "info/exclude")
	if err != nil {
		return err
	}
	if exclude := strings.TrimSpace(out); refineIsRegular(exclude) {
		b, err := os.ReadFile(exclude)
		if err != nil {
			return err
		}
		dest := filepath.Join(r.scratch, ".git/info/exclude")
		if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(dest, b, 0o666); err != nil {
			return err
		}
	}
	res, err := r.repo.Run("config", "--path", "--get", "core.excludesFile")
	if err != nil {
		return err
	}
	switch res.Status {
	case 0:
		path := strings.TrimSpace(res.Stdout)
		if !filepath.IsAbs(path) {
			path = filepath.Join(r.root, path)
		}
		if _, err := r.scratchR.OK("config", "core.excludesFile", filepath.Clean(path)); err != nil {
			return err
		}
	case 1:
	default:
		return fmt.Errorf("git config core.excludesFile failed (status %d): %s", res.Status, strings.TrimSpace(res.Stderr))
	}
	_, err = r.scratchR.OK("read-tree", r.tree)
	return err
}

func refineIsRegular(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Mode().IsRegular()
}

// originalReadiness establishes that the original is ready: the retained version-3 record
// for the exact baseline, declarations, HEAD and tree, or a check of the original in the
// scratch checkout. `original-readiness.json` records which and what ran.
func (r *refine) originalReadiness(ctx context.Context) (err error) {
	cached := r.rd.Cached(r.s, r.slug)
	if cached != nil {
		b, err := os.ReadFile(filepath.Join(r.root, ".kogen/local/readiness", r.slug+".json"))
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(r.evidence, "retained-original-readiness.json"), b, 0o666); err != nil {
			return err
		}
	}
	before := map[string]int{}
	kinds := []string{"setup", "acceptance", "quint"}
	for _, k := range kinds {
		before[k] = r.ev.Counted(k)
	}
	var ready *verify.Ready
	defer func() {
		counts := map[string]int{}
		for _, k := range kinds {
			counts[k] = r.ev.Counted(k) - before[k]
		}
		status, reason, source, reference := "miss", "no valid complete version3 evidence; normal scratch path", "scratch", "original-observations.txt"
		if cached != nil {
			status, reason, source, reference = "hit", "valid complete version3 protected-baseline/HEAD evidence", "retained", "retained-original-readiness.json"
		}
		b, encErr := project.EncodeJSON(map[string]any{
			"event": "original_readiness", "status": status, "reason": reason, "source": source,
			"baseline": r.expected, "head": r.head, "reference": reference,
			"setup_executions": counts["setup"], "acceptance_executions": counts["acceptance"],
			"model_executions": counts["quint"],
			"avoided":          map[string]any{"setup": nil, "acceptance": nil, "model": nil, "source_wall_ms": nil},
		})
		if encErr == nil {
			if werr := os.WriteFile(filepath.Join(r.evidence, "original-readiness.json"), b, 0o666); werr != nil && err == nil {
				err = werr
			}
		}
	}()
	if cached != nil {
		ready = cached
	} else if err := r.ev.Timed("readiness", func() error {
		var err error
		ready, err = r.scratchD.Check(ctx, r.s, r.slug)
		return err
	}); err != nil {
		return err
	}

	tree, err := r.scratchR.Tree(r.head, nil)
	if err != nil {
		return err
	}
	if tree != r.tree {
		return refineConstraint("Readiness changed project files; preserve the draft and resolve that before refining.")
	}
	b, err := project.EncodeJSON(refineReadyRecord(ready))
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(r.evidence, "original-readiness-observations.json"), b, 0o666); err != nil {
		return err
	}
	reference := filepath.Join(r.evidence, "original-observations.txt")
	r.observation = verify.Observations(r.slug, ready, reference)
	if r.observation != "" {
		if err := os.WriteFile(reference, []byte(r.observation), 0o666); err != nil {
			return err
		}
	}
	if ready.Failures() {
		r.observed = ready
	}
	return nil
}

// refineReadyRecord is a readiness result as JSON, without its Intent.
func refineReadyRecord(ready *verify.Ready) map[string]any {
	scenarios := ready.Scenarios
	if scenarios == nil {
		scenarios = []verify.ScenarioResult{}
	}
	feasibility := ready.Feasibility
	if feasibility == nil {
		feasibility = []verify.Obligation{}
	}
	baseline := ready.Baseline
	if baseline == nil {
		baseline = []string{}
	}
	var model any
	if m := ready.Model; m != nil {
		if m.None {
			model = "none"
		} else {
			model = map[string]any{"path": m.Path, "invariants": m.Invariants, "seed": m.Seed, "samples": m.Samples, "steps": m.Steps}
		}
	}
	return map[string]any{
		"acceptance_exit": ready.AcceptanceExit, "baseline": baseline, "candidate_tree": ready.CandidateTree,
		"feasibility": feasibility, "head": ready.Head, "model": model, "scenarios": scenarios, "sha256": ready.SHA256,
	}
}

// ---- the first message ----

// refineInspectLimit is the number of elements Elixir's inspect/1 prints before `...`.
const refineInspectLimit = 50

func refineInspect(items []string, wrap func(string) string) string {
	var parts []string
	for i, it := range items {
		if i == refineInspectLimit {
			parts = append(parts, "...")
			break
		}
		parts = append(parts, wrap(it))
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

func (r *refine) context() ([]any, error) {
	// Owned authority is already included in full below; unrelated repository
	// declarations are retrieved on demand rather than pinned into every window.
	selected, _, err := Navigation(r.repo)
	if err != nil {
		return nil, err
	}
	r.measure = ContextMeasure{}
	for _, p := range sortedKeys(r.originals) {
		content := r.originals[p]
		r.measure.Included += len(content)
		r.measure.Selection = append(r.measure.Selection, ContextSelection{
			Path: p, SHA256: ContentHash(content), IncludedBodyBytes: len(content), Reason: "owned-original",
		})
	}
	protected, err := project.Protected(r.root, r.cfg)
	if err != nil {
		return nil, err
	}
	var checks []string
	for _, c := range r.cfg.Checks {
		checks = append(checks, "{"+inspectString(c.Name)+", "+inspectString(c.Run)+"}")
	}
	var originals []string
	for _, p := range sortedKeys(r.originals) {
		originals = append(originals, "--- "+p+"\n"+string(r.originals[p]))
	}
	acceptance := ""
	if r.cfg.Acceptance != nil {
		acceptance = r.cfg.Acceptance.Run
	}
	quoted := func(s string) string { return inspectString(s) }
	same := func(s string) string { return s }

	var b strings.Builder
	b.WriteString("Full contract inclusions: original Intent prose, Gherkin and declared model preserve exact authority, irrespective of excerpt budget.\n\n")
	b.WriteString(project.SourceMessage(r.source) + "\n\n")
	b.WriteString("# Correction requested\n" + r.in.Request + "\n")
	b.WriteString("# Original authoritative contracts and owned originals (full contents)\n")
	b.WriteString("Within this run, omitted paths retain earlier well-formed proposals; paths never proposed retain these original bytes. Submit original content explicitly to revert a proposal. Nothing is published until the complete accumulated candidate is ready.\n")
	b.WriteString(strings.Join(originals, "\n") + "\n")
	b.WriteString("# Exclusively owned editable files\n" + strings.Join(r.allowed, "\n") + "\n")
	b.WriteString("# Protection and commands\n")
	b.WriteString("Configured protected files: " + refineInspect(protected, quoted) + "\n")
	b.WriteString("No config, protected, shared or other Intent files may change. Existing Acceptance paths and model presence/path must remain unchanged.\n")
	b.WriteString("Setup: " + refineInspect(r.cfg.Setup, quoted) + "\n")
	b.WriteString("Checks: " + refineInspect(checks, same) + "\n")
	b.WriteString("Fixers: " + refineInspect(r.cfg.Fix, quoted) + "\n")
	b.WriteString("Acceptance: " + acceptance + "\n")
	b.WriteString("# Project README\n" + ReadmeText(r.root) + "\n")
	b.WriteString("# Testing rules\n" + agent.Prompt(agent.TestingRules) + "\n")

	dynamic := "# Original baseline observations\n" +
		"Exact retained readiness result: " + filepath.Join(r.evidence, "original-readiness-observations.json") + "\n" +
		r.observation + "\n" + selected + "\n"
	return provider.ContractBlocks(b.String(), dynamic), nil
}

// ---- the conversation ----

// refineInstructions is the correction conversation's policy: the discovery rules, the
// feasibility guidance, the refinement rules and the context guidance.
func refineInstructions() string { return agent.Prompt(agent.Refine) + contextGuidance() }

type refineKind int

const (
	refineNone refineKind = iota
	refineInvalid
	refineObservations
	refineConstrained
	refineReady
)

// refineOutcome is how a submission ended.
type refineOutcome struct {
	kind       refineKind
	reason     string // the constraint
	diagnostic string // why the submission was invalid
	files      map[string]string
	ready      *verify.Ready
}

// converseExternal is the external refiner: one fresh read-only session whose final structured
// results are `submit_refinement` payloads through the same cumulative rules; Kogen's actual
// feedback returns to the same session. Nothing is published here.
func (r *refine) converseExternal(ctx context.Context, role project.Role, blocks []any) (map[string]string, *verify.Ready, error) {
	stable := refineInstructions() + "\n\n" + externalNote + "\n\n" + blocksText(blocks)
	x, err := startExternal(ctx, r.ext, r.extMax, r.repo, r.root, r.s.Getenv("HOME"),
		filepath.Join(r.evidence, "executor-refine"), r.slug, role, stable, "", schemaOf(agent.SubmitRefinementTool), r.ev.Record, nil)
	if err != nil {
		return nil, nil, err
	}
	defer x.close()
	defer func() { r.ev.Record(x.summary()) }()
	feedback, invalid := "", 0
	for {
		if err := interrupted(ctx, r.s); err != nil {
			return nil, nil, err
		}
		if err := r.freeze(); err != nil {
			return nil, nil, err
		}
		r.s.Progress("kogen: refining " + r.slug + " " + role.Model + "/" + role.Effort + " (external round " + fmt.Sprint(x.rounds+1) + ")")
		res, err := x.round(ctx, feedback)
		if err != nil {
			return nil, nil, err
		}
		if res.Ending != executor.EndFinish {
			return nil, nil, executor.Fail(executor.ReasonProtocol, "the refiner ended its round without a submission")
		}
		args, err := submissionArgs(res.Structured)
		if err != nil {
			return nil, nil, err
		}
		text, out, err := r.submit(ctx, args)
		if err != nil {
			return nil, nil, err
		}
		switch out.kind {
		case refineReady:
			return out.files, out.ready, nil
		case refineConstrained:
			return nil, nil, refineConstraint(out.reason)
		case refineInvalid:
			invalid++
			if invalid >= submissionRetryLimit(r.in.SubmissionRetryLimit) {
				e := sys.Fail("shape", "refinement_invalid", fmt.Sprintf("no valid ready correction after %d submissions; the original draft is preserved", submissionRetryLimit(r.in.SubmissionRetryLimit)), 1)
				e.Lines = strings.Split(out.diagnostic, "\n")
				return nil, nil, e
			}
		}
		feedback = text
	}
}

// converse runs the conversation until a ready complete candidate, an unsupported
// correction, or three invalid or not-ready submissions (SHP-11).
func (r *refine) converse(ctx context.Context, role project.Role, defs []any, input []any) (map[string]string, *verify.Ready, provider.Usage, error) {
	var usage provider.Usage
	invalid := 0
	for {
		if err := interrupted(ctx, r.s); err != nil {
			return nil, nil, usage, err
		}
		if err := r.freeze(); err != nil {
			return nil, nil, usage, err
		}
		r.s.Progress("kogen: refining " + r.slug + " " + role.Model + "/" + role.Effort)
		started := time.Now()

		var manifest []any
		for _, p := range sortedKeys(r.originals) {
			entry := map[string]any{
				"path":     p,
				"revision": map[string]any{"head": r.head, "tree": r.tree},
				"sha256":   ContentHash(r.originals[p]),
				"source":   filepath.Join(r.evidence, "original", p),
				"proposed": nil,
			}
			if submitted, ok := r.proposed[p]; ok {
				b, err := os.ReadFile(filepath.Join(r.scratch, p))
				if err != nil {
					return nil, nil, usage, err
				}
				entry["proposed"] = map[string]any{
					"sha256": ContentHash(b), "source": filepath.Join(r.scratch, p), "submitted_sha256": ContentHash([]byte(submitted)),
				}
			}
			manifest = append(manifest, entry)
		}
		enc, err := project.EncodeJSON(manifest)
		if err != nil {
			return nil, nil, usage, err
		}
		input = append(input, map[string]any{"role": "user", "content": "Cumulative proposal/original manifest: " + string(enc)})
		event, err := selectionEvent(input, manifest, r.measure)
		if err != nil {
			return nil, nil, usage, err
		}
		r.ev.Record(event)

		req := conversationRequest(provider.Request{
			Role: ProviderRole(role), Instructions: refineInstructions(), Input: input, Tools: defs,
			Scope: r.ev.Dir, Context: map[string]any{"phase": "shape", "role": "shape", "slug": r.slug},
		}, r.cacheID)
		input, err = r.window.prepare(windowPrep{role: req.Role,
			root: r.root, ev: r.ev, progress: r.s.Progress,
			render: func(items []any) map[string]any { q := req; q.Input = items; return r.client.Body(q) },
			state: func(head windowRef, count int, snapshot map[string]any, observations []any) map[string]any {
				frozen := []any{}
				for _, p := range sortedKeys(r.originals) {
					frozen = append(frozen, map[string]any{"path": p, "sha256": ContentHash(r.originals[p])})
				}
				return map[string]any{
					"history": map[string]any{"head": head.value(), "count": count}, "manifest": manifest,
					"frozen_originals": frozen, "ownership": nonNilStrings(r.allowed),
					"documentation": snapshot, "invalid_submissions": invalid, "readiness": windowReadyRecord(r.observed),
					"assistant_observations": observations,
				}
			},
		}, input)
		if err != nil {
			return nil, nil, usage, err
		}
		req.Input = input
		call := r.ev.BeginCall("shape", "", map[string]any{"head": r.head, "tree": r.tree}, "targeted refinement", role).Sized(r.client, req)
		resp, err := r.client.Respond(ctx, r.s, req, call)
		call.End(resp, err)
		if err != nil {
			return nil, nil, usage, err
		}
		r.s.Progress(fmt.Sprintf("kogen: refinement response %s wall_ms=%d", resp.Usage.Line(), time.Since(started).Milliseconds()))
		usage = usage.Add(resp.Usage)
		replay := tools.Replay(resp.Items)
		calls := tools.Calls(resp.Items)

		var outputs []any
		var result refineOutcome
		for _, c := range calls {
			if err := interrupted(ctx, r.s); err != nil {
				return nil, nil, usage, err
			}
			if err := r.window.validate(r.root); err != nil {
				return nil, nil, usage, err
			}
			switch {
			case result.kind != refineNone:
				outputs = append(outputs, toolOutput(c, "ignored: only one submission counts"))
			case c.Name == agent.SubmitRefinementTool:
				text, out, err := r.submit(ctx, c.Args())
				if err != nil {
					return nil, nil, usage, err
				}
				result = out
				outputs = append(outputs, toolOutput(c, text))
			default:
				out, err := r.runTool(ctx, c)
				if err != nil {
					return nil, nil, usage, err
				}
				if c.Name == tools.DocumentationTool {
					row := r.ev.RetainDocumentation(c.Args(), out.Text)
					started, finished := DocumentationProgress(row)
					r.s.Progress(started)
					r.s.Progress(finished)
					r.window.documentation = append(r.window.documentation, row)
				}
				outputs = append(outputs, toolOutput(c, out))
			}
		}
		input = append(input, replay...)
		input = append(input, outputs...)

		switch result.kind {
		case refineReady:
			return result.files, result.ready, usage, nil
		case refineObservations:
			r.ev.NextAttempt()
			continue
		case refineConstrained:
			return nil, nil, usage, refineConstraint(result.reason)
		}
		if result.kind == refineInvalid || len(calls) == 0 {
			invalid++
			r.ev.NextAttempt()
		}
		if invalid >= submissionRetryLimit(r.in.SubmissionRetryLimit) {
			e := sys.Fail("shape", "refinement_invalid",
				fmt.Sprintf("no valid ready correction after %d submissions; the original draft is preserved", submissionRetryLimit(r.in.SubmissionRetryLimit)), 1)
			if result.kind == refineInvalid {
				e.Lines = strings.Split(result.diagnostic, "\n")
			}
			return nil, nil, usage, e
		}
		if len(calls) == 0 {
			input = append(input, map[string]any{"role": "user", "content": "Call submit_refinement with a nonempty files array of complete existing owned artifact contents (edits or readiness acknowledgment), or constraint."})
		}
	}
}

// runTool runs one of the read-only tools or the probe in the scratch checkout.
func (r *refine) runTool(ctx context.Context, c tools.Call) (tools.Output, error) {
	tl := &tools.Tools{
		Root: r.scratch, Session: r.s, Repo: agent.Git(r.scratchR),
		Enabled:       []string{tools.ReadFileTool, tools.ListFilesTool, tools.SearchTextTool, agent.ProbeTool, tools.DocumentationTool},
		Probe:         func(command string, files any) (string, error) { return r.probe(ctx, command, files) },
		Documentation: tools.Documentation{UserAgent: documentationAgent(r.client)},
	}
	if c.Name != agent.ProbeTool {
		return tl.Run(c.Name, c.Args())
	}
	var out tools.Output
	_, err := r.ev.ProbeText(nil, func() (string, error) {
		var err error
		out, err = tl.Run(c.Name, c.Args())
		return out.Text, err
	})
	return out, err
}

// probe is the probe tool: the command in a copy of the scratch checkout, five minutes at
// most; its result is the text the model reads.
func (r *refine) probe(ctx context.Context, command string, files any) (string, error) {
	p := verify.Probe{Root: r.scratch, Command: command, Tools: r.tools}
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
	res, err := p.Run(ctx, r.s)
	if err != nil {
		var pe *verify.ProbeFileError
		if errors.As(err, &pe) {
			return pe.Error(), nil
		}
		return "", err
	}
	return fmt.Sprintf("exit status: %d\ntimed_out: %t\nwall: %s s\n%s", res.Status, res.TimedOut, formatWall(res.Wall), res.Output), nil
}

// ---- submissions ----

const refineInvalidShape = "invalid: submit exactly a nonempty files array of complete existing owned artifact contents (edits or readiness acknowledgment), or constraint (why this correction needs unsupported work). No proposals from this submission were retained; earlier proposals are unchanged."

const refineInvalidFiles = "invalid: a path is not an exclusively owned editable draft file, or a change has invalid content/duplicate paths; no new/shared/protected paths. No proposals from this submission were retained; earlier proposals are unchanged."

// submit takes one submit_refinement call: a constraint, or files merged into the
// accumulated proposals and checked as a complete candidate. The text goes back to the model.
func (r *refine) submit(ctx context.Context, args map[string]any) (string, refineOutcome, error) {
	if reason, ok := args["constraint"].(string); ok && len(args) == 1 {
		if strings.TrimSpace(reason) == "" {
			const d = "constraint must explain the unsupported work"
			return "invalid: " + d, refineOutcome{kind: refineInvalid, diagnostic: d}, nil
		}
		return "constraint recorded", refineOutcome{kind: refineConstrained, reason: reason}, nil
	}
	list, ok := args["files"].([]any)
	if !ok || len(list) == 0 || len(args) != 1 {
		return refineInvalidShape, refineOutcome{kind: refineInvalid, diagnostic: refineInvalidShape}, nil
	}

	r.attempts++
	attempt := r.attempts
	enc, err := project.EncodeJSON(args)
	if err != nil {
		return "", refineOutcome{}, err
	}
	if err := r.save("", map[string][]byte{fmt.Sprintf("submission-%d.json", attempt): enc}, 0o666); err != nil {
		return "", refineOutcome{}, err
	}

	proposals := map[string]string{}
	valid, seen := true, map[string]bool{}
	for _, f := range list {
		m, isMap := f.(map[string]any)
		if !isMap {
			valid = false
			continue
		}
		path, hasPath := m["path"]
		if hasPath {
			if p, ok := path.(string); ok {
				if seen[p] {
					valid = false
				}
				seen[p] = true
			}
		}
		p, pok := path.(string)
		content, cok := m["content"].(string)
		if !hasPath || len(m) != 2 || !pok || !cok || !slices.Contains(r.allowed, p) {
			valid = false
			continue
		}
		proposals[p] = content
	}
	if !valid {
		if err := r.save("", map[string][]byte{fmt.Sprintf("diagnostic-%d.txt", attempt): []byte(refineInvalidFiles)}, 0o666); err != nil {
			return "", refineOutcome{}, err
		}
		return refineInvalidFiles, refineOutcome{kind: refineInvalid, diagnostic: refineInvalidFiles}, nil
	}
	for p, c := range proposals {
		r.proposed[p] = c
	}
	paths := sortedKeys(r.proposed)
	if _, err := r.scratchR.OK("read-tree", "--reset", "-u", r.tree); err != nil {
		return "", refineOutcome{}, err
	}
	for _, p := range paths {
		if err := os.WriteFile(filepath.Join(r.scratch, p), []byte(r.proposed[p]), 0o666); err != nil {
			return "", refineOutcome{}, err
		}
	}
	if err := r.saveText(fmt.Sprintf("candidate-%d", attempt), r.proposed); err != nil {
		return "", refineOutcome{}, err
	}

	text, out, err := r.check(ctx, attempt, paths)
	if err == nil {
		return text, out, nil
	}
	e, ok := sys.AsError(err)
	if !ok {
		return "", refineOutcome{}, err
	}
	diagnostic := e.Render()
	if werr := r.save("", map[string][]byte{fmt.Sprintf("diagnostic-%d.txt", attempt): []byte(diagnostic)}, 0o666); werr != nil {
		return "", refineOutcome{}, werr
	}
	if e.Reason == "refinement_constraint" {
		return diagnostic, refineOutcome{kind: refineConstrained, reason: e.Detail}, nil
	}
	return "not ready:\n" + diagnostic +
			"\nWell-formed proposals are retained in this run; submit only corrections. Omitted paths retain their previous proposal, or the original if never proposed.",
		refineOutcome{kind: refineInvalid, diagnostic: diagnostic}, nil
}

// check formats and checks the accumulated candidate in the scratch checkout. A *sys.Error is
// a diagnostic for the model (refinement_constraint: unsupported work); anything else ends
// the run.
func (r *refine) check(ctx context.Context, attempt int, paths []string) (string, refineOutcome, error) {
	for _, command := range r.cfg.Fix {
		res, err := r.s.Run(command, r.scratch, sys.Options{KillGroupOnExit: true})
		if err != nil {
			return "", refineOutcome{}, err
		}
		if res.Status != 0 {
			return "", refineOutcome{}, refineConstraint("A configured fixer failed: " + command)
		}
	}
	if _, err := project.SourceComparison(r.scratch, r.slug); err != nil {
		return "", refineOutcome{}, err
	}
	candidate, err := project.LoadIntent(r.scratch, r.slug)
	if err != nil {
		return "", refineOutcome{}, err
	}
	if !slices.Equal(candidate.Acceptance, r.intent.Acceptance) {
		return "", refineOutcome{}, refineConstraint(refineTopology)
	}
	if key, known := refineModelKey(candidate.Model); known && key != refineOriginalModel(r.intent.Model) {
		return "", refineOutcome{}, refineConstraint(refineTopology)
	}
	// Unparseable Model metadata is a correctable lint failure, not proof of model removal.
	// Readiness rejects it before any candidate can publish.

	tree, err := r.scratchR.Tree(r.head, nil)
	if err != nil {
		return "", refineOutcome{}, err
	}
	changed, err := r.scratchR.Changed(r.tree, tree)
	if err != nil {
		return "", refineOutcome{}, err
	}
	for _, p := range changed {
		if !slices.Contains(paths, p) {
			return "", refineOutcome{}, refineConstraint("A fixer changed files outside the submitted correction.")
		}
	}

	acknowledged := r.observed != nil && r.scratchD.Current(r.s, r.slug, r.observed)
	ready := r.observed
	if !acknowledged {
		if err := r.ev.Timed("readiness", func() error {
			var err error
			ready, err = r.scratchD.Check(ctx, r.s, r.slug)
			return err
		}); err != nil {
			return "", refineOutcome{}, err
		}
	}
	after, err := r.scratchR.Tree(r.head, nil)
	if err != nil {
		return "", refineOutcome{}, err
	}
	if after != tree {
		return "", refineOutcome{}, refineConstraint("Readiness changed candidate files; a stable ready correction is required.")
	}

	changes := map[string]string{}
	for _, p := range paths {
		b, err := os.ReadFile(filepath.Join(r.scratch, p))
		if err != nil {
			return "", refineOutcome{}, err
		}
		changes[p] = string(b)
	}
	if err := r.saveText(fmt.Sprintf("candidate-%d", attempt), changes); err != nil {
		return "", refineOutcome{}, err
	}

	if !acknowledged && ready.Failures() {
		reference := filepath.Join(r.evidence, fmt.Sprintf("observations-%d.txt", attempt))
		if err := os.WriteFile(reference, []byte(verify.Observations(r.slug, ready, reference)), 0o666); err != nil {
			return "", refineOutcome{}, err
		}
		r.observed = ready
		return verify.Acknowledgment(r.slug, ready, reference), refineOutcome{kind: refineObservations}, nil
	}
	return "accepted: complete accumulated draft is ready", refineOutcome{kind: refineReady, files: changes, ready: ready}, nil
}

const refineTopology = "Refinement cannot add/remove Acceptance paths or change whether a model exists; it changes existing files only."

// refineModelKey identifies the model a candidate declares: false when it declares none the
// parser can read.
func refineModelKey(m *project.ModelSpec) (string, bool) {
	switch {
	case m == nil:
		return "", false
	case m.None:
		return "\x00none", true
	}
	return m.Path, true
}

func refineOriginalModel(m *project.ModelSpec) string {
	key, _ := refineModelKey(m)
	return key
}

// ---- publication ----

// publish replaces the draft files with the checked candidate and revokes the approval. On
// an error or interrupt it puts back this run's own replacements and the approval; a file
// changed by anyone else is never overwritten.
func (r *refine) publish(ctx context.Context, changes map[string]string, ready *verify.Ready) error {
	if err := r.saveText("publish", changes); err != nil {
		return err
	}
	rollback := map[string]string{}
	for p := range changes {
		rollback[p] = string(r.originals[p])
	}
	if err := r.saveText("rollback", rollback); err != nil {
		return err
	}
	for p := range changes {
		fi, err := os.Stat(filepath.Join(r.root, p))
		if err != nil {
			return err
		}
		for _, folder := range []string{"publish", "rollback"} {
			if err := os.Chmod(filepath.Join(r.evidence, folder, p), fi.Mode().Perm()); err != nil {
				return err
			}
		}
	}
	if err := interrupted(ctx, r.s); err != nil {
		return err
	}
	if err := r.freeze(); err != nil {
		return err
	}

	err := r.replace(ctx, changes, ready)
	if err == nil {
		return nil
	}
	if rerr := errors.Join(r.restorePublished(changes), r.restoreApproval()); rerr != nil {
		return errors.Join(err, rerr)
	}
	return err
}

func (r *refine) replace(ctx context.Context, changes map[string]string, ready *verify.Ready) error {
	paths := sortedKeys(changes)
	for _, p := range paths {
		dest := filepath.Join(r.root, p)
		current, err := os.ReadFile(dest)
		if !refineRegularPath(r.root, p) || err != nil || !bytes.Equal(current, r.originals[p]) {
			return refineStale()
		}
		if err := os.Rename(filepath.Join(r.evidence, "publish", p), dest); err != nil {
			return err
		}
		if err := interrupted(ctx, r.s); err != nil {
			return err
		}
	}
	if r.approved {
		approval, approved, err := refineReadApproval(r.root, r.slug)
		if err != nil {
			return err
		}
		index, err := refineIndexDigest(r.indexPath)
		if err != nil {
			return err
		}
		if !approved || !bytes.Equal(approval, r.approval) || index != r.index || r.repo.Head() != r.head {
			return refineStale()
		}
		if err := os.Rename(project.ApprovalPath(r.root, r.slug), filepath.Join(r.evidence, "revoked-approval.json")); err != nil {
			return err
		}
		if err := interrupted(ctx, r.s); err != nil {
			return err
		}
	}
	if err := r.rd.RecordPass(r.s, r.slug, ready); err != nil {
		return err
	}
	if err := project.ValidateSource(r.pinned); err != nil {
		return err
	}
	if err := project.ValidateSource(r.source); err != nil {
		return err
	}
	var previous []byte
	if r.source != nil {
		var err error
		if previous, err = os.ReadFile(r.source.Path); err != nil {
			return err
		}
	}
	published, err := project.RefineSource(r.root, r.slug, r.correction, r.expected, r.source)
	if err != nil {
		return err
	}
	if err := r.confirmPublished(ctx, ready, published); err != nil {
		// Roll back only the receipt this operation published, never a concurrent edit.
		return errors.Join(err, project.RestoreSource(published, previous))
	}
	return nil
}

// confirmPublished checks, after the receipt moved, that the readiness inputs, the approval
// (revoked), the index, HEAD and the receipt chain still hold.
func (r *refine) confirmPublished(ctx context.Context, ready *verify.Ready, published *project.SourceRef) error {
	if !r.rd.Current(r.s, r.slug, ready) {
		return sys.Fail("intent", "not_ready", "readiness inputs changed during refinement publication", 1)
	}
	_, approved, err := refineReadApproval(r.root, r.slug)
	if err != nil {
		return err
	}
	index, err := refineIndexDigest(r.indexPath)
	if err != nil {
		return err
	}
	if approved || index != r.index || r.repo.Head() != r.head {
		return refineStale()
	}
	if err := project.ValidateSource(published); err != nil {
		return err
	}
	pinned := r.pinned
	if r.pinned != nil && r.pinned.Equal(r.source) && !published.Equal(r.source) {
		pinned = r.pinned.Archived()
	}
	if err := project.ValidateSource(pinned); err != nil {
		return err
	}
	bound, err := project.BindSource(r.root, r.slug)
	if err != nil {
		return err
	}
	if !bound.Equal(published) {
		return refineStale()
	}
	return interrupted(ctx, r.s)
}

// restoreApproval puts the archived approval back when it is still the exact original and
// nothing else took its place.
func (r *refine) restoreApproval() error {
	if !r.approved {
		return nil
	}
	archived := filepath.Join(r.evidence, "revoked-approval.json")
	if _, exists, err := refineReadApproval(r.root, r.slug); err != nil || exists {
		return err
	}
	if b, err := os.ReadFile(archived); err != nil || !bytes.Equal(b, r.approval) {
		return nil
	}
	return os.Rename(archived, project.ApprovalPath(r.root, r.slug))
}

// restorePublished undoes only this run's completed replacements.
func (r *refine) restorePublished(changes map[string]string) error {
	var errs []error
	for _, p := range sortedKeys(changes) {
		current, err := os.ReadFile(filepath.Join(r.root, p))
		if !refineRegularPath(r.root, p) || err != nil || string(current) != changes[p] {
			continue
		}
		if err := os.Rename(filepath.Join(r.evidence, "rollback", p), filepath.Join(r.root, p)); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

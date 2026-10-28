package build

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
	"kogen/executor"
	"kogen/git"
	"kogen/project"
	"kogen/verify"
)

// Input is one `kogen intent build <slug>`.
type Input struct {
	Deps
	// Project is a directory inside the project's repository.
	Project string
	Slug    string
	// Context is the optional diagnostic data of `--context <file>`, already read.
	Context *Diagnostic
}

// ResumeInput is one `kogen intent resume <build-id>`.
type ResumeInput struct {
	Deps
	Project string
	ID      string
}

// Attempt is a Build in progress: its checkpointed state and the environment it runs in. The
// exported methods are what an independent review needs (see Reviewer).
type Attempt struct {
	State

	s           *sys.Session
	blockerNote string // invalid external blocker claim to prefix the next feedback
	deps        Deps
	repo        *git.Repo
	cache       *provider.Cache
	facts       *localFacts
	intent      *project.Intent
	model       *project.ModelSpec
	diag        *Diagnostic
	// ext is the external build executor of a fresh Build (nil: the native builder).
	ext *externalBuild
	// watch is the no-progress evidence of the native builder's rounds (noprogress.go).
	watch progressWatch
}

// noRunNotice follows a refusal that happened before any run was created (stdout, indented
// like the refusal's detail lines).
const noRunNotice = "no newly created Build run; correct the named prerequisite before trying again"

// Build is `kogen intent build <slug>` (chapters 03-07): the start checks, then the builder
// conversation with the fixers and a verification pass after each round; a green pass goes
// to independent review and a verified, still identical candidate is committed. A Build has
// no time or token limit: it ends with a commit, an integrity stop, a provider failure,
// context exhaustion, an invalid or unresolved review, or an interrupt.
//
// The returned exit code is the command's. A refusal before any run exists is the
// *sys.Error to show (its lines end with the notice that no run was created); an interrupt
// is *sys.Interrupted. Once a run exists every other end, landed or not, is reported by
// Build itself on stdout and returns err nil (an unexpected internal failure is the only
// other error; the exit code is then 70).
func Build(ctx context.Context, s *sys.Session, in Input) (exit int, err error) {
	var b *Attempt
	return conclude(s, &b, buildRun(ctx, s, in, &b))
}

// Resume is `kogen intent resume <build-id>`: it continues a stopped Build of this checkout
// from its checkpoint as a new run, after every custody check, or reports that the Build
// already landed. Returns and errors are those of Build.
func Resume(ctx context.Context, s *sys.Session, in ResumeInput) (exit int, err error) {
	var b *Attempt
	return conclude(s, &b, resumeRun(ctx, s, in, &b))
}

// conclude turns the end of a command into its exit code, reporting a stopped or
// interrupted Build.
func conclude(s *sys.Session, pb **Attempt, err error) (int, error) {
	b := *pb
	var interrupted *sys.Interrupted
	var refusal *sys.Error
	switch {
	case err == nil:
		return 0, nil
	case errors.As(err, &interrupted):
		if b != nil {
			if herr := b.interrupted(interrupted.Signal); herr != nil {
				return 70, herr
			}
		}
		return interrupted.ExitCode(), interrupted
	case errors.As(err, &refusal):
		if b == nil {
			refusal.Lines = append(refusal.Lines, noRunNotice)
			return refusal.Exit, refusal
		}
		exit, herr := b.stopped(refusal)
		if herr != nil {
			return 70, herr
		}
		return exit, nil
	}
	return 70, err
}

func buildRun(ctx context.Context, s *sys.Session, in Input, out **Attempt) error {
	if in.Context != nil {
		if err := in.Context.Validate(); err != nil {
			return err
		}
	}
	repo, err := git.Open(in.Project, s.Env)
	if err != nil {
		return err
	}
	root := repo.Dir
	cfg, err := project.LoadConfig(root)
	if err != nil {
		return err
	}
	start := repo.Head()
	if start == "" {
		return sys.Fail("environment", "no_head", root+" has no commits; run kogen init", 3)
	}
	op, err := repo.OperationInProgress()
	if err != nil {
		return err
	}
	if op != "" {
		return sys.Fail("environment", "git_operation_in_progress", "a "+op+" is in progress; finish or abort it first", 3)
	}
	lock, err := git.AcquireBuild(root, s)
	if err != nil {
		return err
	}
	defer lock.Release()
	return checked(ctx, s, in, repo, cfg, start, out)
}

// cleanPaths is the Git rule of a Build (GIT-1): only this Intent's folder and acceptance
// files, and other Intents' own folders, may be uncommitted; other Intents stay out of the
// candidate and the commit (VER-10). It returns the folders to exclude.
func cleanPaths(repo *git.Repo, intent *project.Intent) ([]string, error) {
	changed, err := repo.ChangedPaths()
	if err != nil {
		return nil, err
	}
	own := project.IntentDir(intent.Slug) + "/"
	var other, dirty []string
	for _, p := range changed {
		if strings.HasPrefix(p, ".kogen/intents/") && !strings.HasPrefix(p, own) {
			other = append(other, p)
		}
	}
	for _, p := range changed {
		if !slices.Contains(other, p) && !slices.Contains(intent.Acceptance, p) && !strings.HasPrefix(p, own) {
			dirty = append(dirty, p)
		}
	}
	if len(dirty) > 0 {
		e := sys.Fail("environment", "dirty_tree",
			fmt.Sprintf("%d changed path(s) are not part of an Intent; commit, stash or discard them first", len(dirty)), 5)
		e.Lines = dirty[:min(20, len(dirty))]
		return nil, e
	}
	var excluded []string
	for _, p := range other {
		parts := strings.Split(p, "/")
		dir := strings.Join(parts[:min(3, len(parts))], "/")
		if !slices.Contains(excluded, dir) {
			excluded = append(excluded, dir)
		}
	}
	return excluded, nil
}

// buildRoles are the provider roles a Build signs in with: the review's, and the builder's
// unless an external executor serves it (it uses its own sign-in, never a Kogen provider's).
func buildRoles(cfg *project.Config) []provider.Role {
	var roles []provider.Role
	if role := cfg.Models["build"]; !role.External() {
		roles = append(roles, providerRole(role))
	}
	if role := cfg.Models["review"]; !role.External() {
		roles = append(roles, providerRole(role))
	}
	return roles
}

func checked(ctx context.Context, s *sys.Session, in Input, repo *git.Repo, cfg *project.Config, start string, out **Attempt) error {
	root, slug := repo.Dir, in.Slug
	if err := project.RequireIntentDir(root, slug); err != nil {
		return err
	}
	approval, err := project.ReadApproval(root, slug)
	if err != nil {
		return err
	}
	if approval == nil {
		return sys.Fail("intent", "not_approved", slug+" is not approved; review it with kogen intent approve "+slug, 5)
	}
	baseline, err := project.Baseline(root, slug, cfg)
	if err != nil {
		return err
	}
	if sha := project.Hash(root, baseline); sha != approval.SHA256 {
		return sys.Fail("intent", "changed_since_approval",
			fmt.Sprintf("%s changed after approval and is now %s; review it again with kogen intent approve %s", slug, short(sha), slug), 1)
	}
	source := project.SourceRefFromMap(approval.SourceProvenance)
	if err := project.ValidateSource(source); err != nil {
		return err
	}
	intent, err := project.LoadIntent(root, slug)
	if err != nil {
		return err
	}
	excluded, err := cleanPaths(repo, intent)
	if err != nil {
		return err
	}
	if !repo.CanCommit() {
		return sys.Fail("environment", "git_identity_missing", "no Git identity for the commit; run git config user.name \"<name>\" and git config user.email \"<email>\" (global or repository) before building", 3)
	}
	if intent.Model == nil {
		return sys.Fail("intent", "parse", "the Intent's Model: line cannot be read", 1)
	}
	stages, err := project.ParseStages(intent.Text)
	if err != nil {
		return sys.Fail("intent", "lint", err.Error(), 1)
	}
	plan := stageDefs(stages)
	ext, err := selectExecutor(in.Deps, cfg.Models["build"])
	if err != nil {
		return err
	}
	reviewer, err := selectReviewer(in.Deps, cfg.Models["review"])
	if err != nil {
		return err
	}
	if reviewer != nil {
		in.Deps.Reviewer = reviewer
	}
	if err := provider.RequireLogin(s.Getenv("HOME"), buildRoles(cfg)); err != nil {
		return err
	}
	if err := verify.RequireTools(s, in.Tools, root, cfg, false); err != nil {
		return err
	}
	if !intent.Model.None {
		if err := in.Tools.Require(); err != nil {
			return err
		}
	}
	run, err := StartRun(root)
	if err != nil {
		return err
	}
	facts, err := startFacts(root, slug, run, cfg, "", "")
	if err != nil {
		return err
	}
	if in.Context != nil {
		if err := in.Context.capture(run); err != nil {
			return err
		}
	}
	// GIT-8: a Build that does not commit leaves the index as it found it.
	gitIndex, err := repo.IndexPath()
	if err != nil {
		return err
	}
	if err := repo.SaveIndex(filepath.Join(run.Dir, "index-at-start")); err != nil {
		return err
	}
	digests := map[string]string{}
	for _, p := range baseline {
		digests[p] = fileDigest(root, p)
	}
	startTree, err := repo.Tree(start, excluded)
	if err != nil {
		return err
	}
	approvalFile, err := os.ReadFile(project.ApprovalPath(root, slug))
	if err != nil {
		return err
	}
	b := &Attempt{
		State: State{
			Root: root, Slug: slug, Config: cfg, IntentText: intent.Text, Start: start, Baseline: baseline,
			BaselineDigests: digests, Excluded: nonNil(excluded), Run: run, GitIndex: gitIndex, StartTree: startTree,
			Phase: "startup", T0: time.Now().UnixMilli(), Continuation: Continuation{Stage: StageStartup},
			ApprovalBytes: encodeBase64(approvalFile), WorkingContext: map[string]*OwnerContext{},
			SourceProvenance: source, PromptCache: map[string]provider.CacheState{},
			Usage: zeroTokens(), AttemptUsage: zeroTokens(), CacheIDs: map[string]string{},
			StagePlan: plan, StageProgress: initialProgress(plan),
		},
		s: s, deps: in.Deps, repo: repo, cache: provider.NewCache(nil), facts: facts, intent: intent, model: intent.Model, diag: in.Context, ext: ext,
	}
	*out = b
	run.Event(map[string]any{"event": "start", "slug": slug, "start_head": start, "approved": approval.SHA256})
	if err := b.Save(b.Continuation); err != nil {
		return err
	}
	return b.begin(ctx)
}

// begin is a fresh Build's start checks (AUT-3..5) and then the builder.
func (b *Attempt) begin(ctx context.Context) error {
	if err := b.repo.CheckCommitMsg(b.s, b.intent.Title, b.Slug); err != nil {
		return err
	}
	if err := b.BaselineIntact(); err != nil {
		return err
	}
	ready := b.readiness()
	if err := ready.Setup(ctx, b.s, b.Root, false); err != nil {
		return err
	}
	if err := verify.RequireTools(b.s, b.deps.Tools, b.Root, b.Config, true); err != nil {
		return err
	}
	if err := b.BaselineIntact(); err != nil {
		return err
	}
	if err := b.alreadyFailing(ctx); err != nil {
		return err
	}
	b.s.Puts("building " + b.Slug)
	if err := b.facts.update(b, "building", ""); err != nil {
		return err
	}
	b.Phase = "building"
	if err := b.Track(); err != nil {
		return err
	}
	brief, err := b.brief()
	if err != nil {
		return err
	}
	sess, err := b.startBuilder(ctx, brief)
	if err != nil {
		return err
	}
	defer sess.Close()
	return b.drive(ctx, sess, executor.Input{}, true)
}

func (b *Attempt) readiness() *verify.Readiness {
	return &verify.Readiness{Root: b.Root, Repo: b.repo, Config: b.Config, Tools: b.deps.Tools, Log: b.Run}
}

// alreadyFailing refuses when a check fails before any change, which could never turn
// green (AUT-5).
func (b *Attempt) alreadyFailing(ctx context.Context) error {
	for _, c := range b.Config.Checks {
		b.s.Progress("kogen: checking " + c.Name + " before the Build changes anything")
		b.Run.Event(map[string]any{"event": "command", "name": c.Name, "command": c.Run, "before_change": true})
		r, err := b.s.Run(c.Run, b.Root, sys.Options{KillGroupOnExit: true})
		if err != nil {
			return err
		}
		b.Run.Event(map[string]any{"event": "command_result", "name": c.Name, "status": r.Status, "output": Cap(r.Output)})
		if r.Status != 0 {
			e := sys.Fail("environment", "check_failing", fmt.Sprintf(
				"check %s fails before the Build changes anything (status=%d); fix it or remove it from commands.checks", c.Name, r.Status), 3)
			e.Lines = strings.Split(verify.Tail(r.Output, 20), "\n")
			return e
		}
	}
	return nil
}

// ---- state, facts and checkpoints ----

// Track publishes the local facts of the Build's current state.
func (b *Attempt) Track() error { return b.facts.update(b, "", "") }

// Save makes c the continuation and publishes a complete checkpoint: the state together
// with the identity of the checkout, the candidate tree, the user's index and the
// approval, by atomic rename (0600).
func (b *Attempt) Save(c Continuation) error {
	b.Continuation = c
	b.PromptCache = b.cache.States()
	if err := b.Track(); err != nil {
		return err
	}
	candidate, err := b.repo.Tree(b.Start, nil)
	if err != nil {
		return err
	}
	index, err := os.ReadFile(b.GitIndex)
	if err != nil {
		return err
	}
	identity, err := fileIdentity(b.Root)
	if err != nil {
		return err
	}
	state, err := encodeJSON(b.State)
	if err != nil {
		return err
	}
	if err := b.Run.takeLogErr(); err != nil {
		return err
	}
	doc := Checkpoint{
		Version: 4, Identity: identity, Candidate: candidate, Index: encodeBase64(index),
		Approval: b.ApprovalBytes, State: state, StageProgress: b.StageProgress,
	}
	if b.Blocker != nil {
		if doc.RecoveryRaw, err = rawIdentity(b.repo, b.Root, b.StartTree); err != nil {
			return err
		}
	}
	return b.Run.PublishCheckpoint(doc)
}

// BaselineIntact is the baseline guard (VER-8): after every shell call, fixer and pass the
// baseline must be as approved, the same files (a new file in the Intent's folder or
// matching `protect` joins it) with the same bytes.
func (b *Attempt) BaselineIntact() error {
	if err := b.validateStages(); err != nil {
		return err
	}
	if err := b.validateWorkingContext(); err != nil {
		return err
	}
	if err := project.ValidateSource(b.SourceProvenance); err != nil {
		return err
	}
	now, err := project.Baseline(b.Root, b.Slug, b.Config)
	if err != nil {
		return err
	}
	var changed []string
	for _, p := range b.Baseline {
		if fileDigest(b.Root, p) != b.BaselineDigests[p] {
			changed = append(changed, p)
		}
	}
	for _, p := range now {
		if !slices.Contains(b.Baseline, p) {
			changed = append(changed, p)
		}
	}
	if len(changed) > 0 {
		return sys.Fail("candidate", "baseline_changed", "the Build changed acceptance files: "+strings.Join(changed, ", ")+
			"; nothing was committed; review the files, then approve again or discard the edits", 1)
	}
	return nil
}

func (b *Attempt) headIntact() error {
	head := b.repo.Head()
	if head == b.Start {
		return nil
	}
	current := "(missing)"
	if head != "" {
		current = short(head)
	}
	return sys.Fail("candidate", "head_moved",
		fmt.Sprintf("HEAD moved from %s to %s during the Build; nothing was committed", short(b.Start), current), 1)
}

// attempts is the provider's observer: each transport attempt goes to the run log.
type attempts struct{ run *Run }

func (a attempts) Attempt(record map[string]any) {
	a.run.Event(map[string]any{"event": "provider_attempt", "provider": record})
}

// RequestSpec is one model request of a Build.
type RequestSpec struct {
	// Owner is the conversation: "build" or "review".
	Owner        string
	Role         project.Role
	Instructions string
	Input        []any
	Tools        []any
	// Retain records the input actually sent (after working-context resets) in the
	// continuation the request is checkpointed with. Nil: the builder's Continuation.Input.
	Retain func(c *Continuation, input []any)
	// Prefill, when set, may append native data to the input after the working window is
	// prepared and before the request is checkpointed, so the checkpoint, the archive and the
	// request all hold exactly what is sent.
	Prefill func(input []any) ([]any, error)
}

// Request sends one request of a conversation and returns the response and the input that
// was sent (reduced to a local working window when the request outgrew its budget). It
// validates custody first, checkpoints before and after, and keeps the Build's usage,
// model time and unknown-request count, the provider attempt records and the image
// delivery events (LOOP-10, GPT-9).
func (b *Attempt) Request(ctx context.Context, sp RequestSpec) (*provider.Response, []any, error) {
	if err := b.s.Err(); err != nil {
		return nil, nil, err
	}
	if err := b.validateStages(); err != nil {
		return nil, nil, err
	}
	if err := b.validateWorkingContext(); err != nil {
		return nil, nil, err
	}
	if err := project.ValidateSource(b.SourceProvenance); err != nil {
		return nil, nil, err
	}
	input, err := b.prepareContext(sp.Owner, sp.Role, sp.Instructions, sp.Input, sp.Tools)
	if err != nil {
		return nil, nil, err
	}
	if sp.Prefill != nil {
		if input, err = sp.Prefill(input); err != nil {
			return nil, nil, err
		}
	}
	cont := b.Continuation
	switch {
	case sp.Retain != nil:
		sp.Retain(&cont, input)
	case sp.Owner == "build":
		cont.Input = input
	}
	if err := b.Save(cont); err != nil {
		return nil, nil, err
	}
	t0 := time.Now()
	b.s.Progress(fmt.Sprintf("kogen: %s request %s/%s", sp.Owner, sp.Role.Model, sp.Role.Effort))
	b.UnknownRequests++
	if err := b.Save(b.Continuation); err != nil {
		return nil, nil, err
	}
	var parent any
	if b.RootRun != nil {
		parent = *b.RootRun
	}
	req := provider.Request{
		Role: providerRole(sp.Role), Instructions: sp.Instructions, Input: input, Tools: sp.Tools, CacheID: b.cacheID(sp.Owner), Cache: b.cache,
		Context: map[string]any{
			"phase": sp.Owner, "role": sp.Owner, "run_id": b.Run.ID, "slug": b.Slug, "lineage": parent,
			"pass": b.Pass, "repair": b.Repairs,
		},
	}
	resp, err := tools.Deliver(input, sp.Owner, b.Run.Event, func() (*provider.Response, error) {
		return b.deps.Client.Respond(ctx, b.s, req, attempts{b.Run})
	})
	if err != nil {
		return nil, nil, err
	}
	wall := time.Since(t0).Milliseconds()
	b.UnknownRequests--
	b.ModelActiveMS += wall
	got := responseTokens(sp.Role, resp)
	b.AttemptUsage = b.AttemptUsage.plus(got)
	b.Usage = b.Usage.plus(got)
	if err := b.Save(Continuation{Stage: StageTool, Owner: sp.Owner, Response: resp.Items, Request: true}); err != nil {
		return nil, nil, err
	}
	b.s.Progress(fmt.Sprintf("kogen: %s response %s wall_ms=%d", sp.Owner, got.Line(), wall))
	b.Run.Event(map[string]any{
		"event": "request", "operation_id": resp.OperationID, "role": sp.Owner, "model": sp.Role.Model,
		"effort": sp.Role.Effort, "usage": got, "wall_ms": wall,
	})
	return resp, input, nil
}

// Verify runs one verification pass over the current candidate (VER-1..10): numbered from 1
// in this Build, recorded in the run log and as b.LastPass. The fixers belong to the end of a
// builder round, not to a pass.
func (b *Attempt) Verify(ctx context.Context) (verify.Pass, error) {
	b.Pass++
	if err := b.Track(); err != nil {
		return verify.Pass{}, err
	}
	if err := b.facts.update(b, "verifying", ""); err != nil {
		return verify.Pass{}, err
	}
	pass, err := verify.Verify(ctx, b.s, b.verifyInput(b.Pass))
	if err != nil {
		return verify.Pass{}, err
	}
	b.LastPass = &pass
	return pass, b.Track()
}

func (b *Attempt) verifyInput(n int) verify.Input {
	return verify.Input{
		Root: b.Root, Repo: b.repo, Config: b.Config, Intent: b.intent, Start: b.Start, Excluded: b.Excluded,
		N: n, RunDir: b.Run.Dir, Tools: b.deps.Tools, Log: b.Run, Intact: b.BaselineIntact,
	}
}

// PassFeedback is what goes back to the repair owner after a red pass; completion names the
// tool the owner calls when done ("finish", "submit_review").
func (b *Attempt) PassFeedback(pass verify.Pass, completion string) string {
	acceptance := ""
	if b.Config.Acceptance != nil {
		acceptance = b.Config.Acceptance.Run
	}
	return pass.Feedback(acceptance, completion)
}

func (b *Attempt) elapsed() time.Duration { return time.Since(time.UnixMilli(b.T0)) }

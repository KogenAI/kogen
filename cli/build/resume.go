package build

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen/executor"
	"kogen/git"
	"kogen/internal/research"
	"kogen/project"
)

var buildID = regexp.MustCompile(`^[a-f0-9]{8}$`)

func refuse(id, reason, kind string) *sys.Error {
	if kind == "" {
		kind = "resume_refused"
	}
	return sys.Fail("candidate", kind, "Build "+id+": "+reason+
		"; inspect the checkpoint and checkout, correct drift or obtain fresh approval for a new Build", 1)
}

func resumeRun(ctx context.Context, s *sys.Session, in ResumeInput, out **Attempt) error {
	if err := research.Validate(ctx, s); err != nil {
		return err
	}
	research.ApplyBuildReview(in.Deps.Client)
	repo, err := git.Open(in.Project, s.Env)
	if err != nil {
		return err
	}
	lock, err := git.AcquireBuild(repo.Dir, s)
	if err != nil {
		return err
	}
	defer lock.Release()
	return resumeLocked(ctx, s, in, repo, out)
}

// decodeCheckpoint reads a checkpoint file: a version 4 state, or through legacy a version 3
// one. why is the reason a resume is refused.
func decodeCheckpoint(raw []byte, legacy LegacyDecoder) (loaded *Loaded, why string) {
	const malformed = "malformed required checkpoint fields"
	v, err := decodeJSONNumbers(raw)
	m, ok := v.(map[string]any)
	if err != nil || !ok {
		return nil, malformed
	}
	version, ok := m["version"]
	if !ok {
		return nil, malformed
	}
	n, _ := version.(json.Number)
	switch n {
	case "4":
		var doc Checkpoint
		dec := json.NewDecoder(bytes.NewReader(raw))
		if err := dec.Decode(&doc); err != nil || len(doc.State) == 0 {
			return nil, malformed
		}
		st, ok := decodeState(doc.State)
		if !ok {
			return nil, malformed
		}
		loaded = &Loaded{Doc: doc, State: st}
	case "3":
		if legacy == nil {
			return nil, "incompatible checkpoint version 3"
		}
		l, err := legacy(raw)
		if err != nil {
			return nil, err.Error()
		}
		if l == nil || l.State == nil {
			return nil, malformed
		}
		loaded = l
	default:
		return nil, "incompatible checkpoint version " + inspectScalar(version)
	}
	if !loaded.State.valid(&loaded.Doc) {
		return nil, malformed
	}
	for _, field := range []string{loaded.Doc.Index, loaded.Doc.Approval} {
		if _, err := decodeBase64(field); err != nil {
			return nil, malformed
		}
	}
	return loaded, ""
}

func inspectScalar(v any) string {
	switch x := v.(type) {
	case nil:
		return "nil"
	case string:
		return inspectString(x)
	case json.Number:
		return x.String()
	case bool:
		return fmt.Sprint(x)
	}
	b, _ := json.Marshal(v)
	return string(b)
}

func resumeLocked(ctx context.Context, s *sys.Session, in ResumeInput, repo *git.Repo, out **Attempt) error {
	root, id := repo.Dir, in.ID
	if !buildID.MatchString(id) {
		return refuse(id, "unknown checkpoint", "resume_unsupported")
	}
	path := filepath.Join(root, ".kogen/local/runs", id, "checkpoint.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		return refuse(id, "absent or legacy checkpoint", "resume_unsupported")
	}
	loaded, why := decodeCheckpoint(raw, in.Deps.legacy())
	if why != "" {
		return refuse(id, why, "")
	}
	doc := loaded.Doc
	b := &Attempt{State: *loaded.State, s: s, deps: in.Deps, repo: repo, cache: provider.NewCache(loaded.State.PromptCache)}
	if err := b.validateWorkingContext(); err != nil {
		return err
	}
	if err := project.ValidateSource(b.SourceProvenance); err != nil {
		return err
	}
	identity, err := fileIdentity(root)
	if err != nil {
		return err
	}
	if b.Root != root || doc.Identity != identity {
		return refuse(id, "another checkout identity", "")
	}
	gitIndex, err := repo.IndexPath()
	if err != nil {
		return err
	}
	runDir := filepath.Dir(path)
	if b.Run.ID != id || b.Run.Dir != runDir || b.Run.LogPath != filepath.Join(runDir, "log.jsonl") || b.GitIndex != gitIndex {
		return refuse(id, "checkpoint run/index paths changed", "")
	}
	head := repo.Head()
	if c := b.Continuation; c.Stage == StageLanded && head == c.Commit {
		parent, err1 := repo.Resolve(c.Commit + "^")
		tree, err2 := repo.Resolve(c.Commit + "^{tree}")
		if err1 != nil || err2 != nil || parent != b.Start || tree != b.LastPass.Tree ||
			b.LastReview.Tree != b.LastPass.Tree || !b.LastPass.Green {
			return refuse(id, "already-landed commit provenance changed", "")
		}
		s.Puts("Build " + id + " already landed " + c.Commit)
		return nil
	}
	if head != b.Start {
		e := refuse(id, "HEAD moved or uncertain commit; inspect git log", "")
		// A Build stopped inside its commit step may have created HEAD before kogen ended
		// (CLI-8): name that commit instead of leaving the user to find it.
		if parent, err := repo.Resolve(head + "^"); err == nil && parent == b.Start && b.Continuation.Stage == StageCommit && len(head) >= 8 {
			e.Lines = append(e.Lines, "HEAD is "+head+", created after this Build's last checkpoint; inspect it with git show "+head[:8])
		}
		return e
	}
	if slices.Contains([]string{StageTool, StageCommit, StageStartup}, b.Continuation.Stage) {
		return refuse(id, "uncertain "+b.Continuation.Stage+" boundary; inspect effects before starting a freshly approved Build", "")
	}
	if b.Blocker != nil {
		return refuse(id, "protected-contract blocker requires correction and fresh approval", "")
	}
	// An external independent review has no exact resume either, and its reviewer conversation
	// is never revived (nor is a builder's used as one): refuse before any inference or change.
	if rv := b.Config.Models["review"]; rv.External() && slices.Contains([]string{StageReview, StageReviewVerify, StageReviewRetry}, b.Continuation.Stage) {
		return refuse(id, "an independent review by executor "+rv.Executor+" cannot be resumed (resume capability: none); "+
			"inspect the preserved candidate and evidence read-only and preserve them manually, then start a fresh Build from a Build-clean checkout "+
			"under the still-current exact approval (ordinary Refine and new approval if the authority must change)", "")
	}
	// An external executor's Build has resume capability none: refuse before any new run,
	// facts or checkpoint exists, like every other refusal here.
	if x := b.Executor; x != nil && x.Name != executor.Native {
		return refuse(id, "Builds by executor "+x.Name+" cannot be resumed in this version (resume capability: none); "+
			"inspect the preserved candidate or start a fresh Build", "")
	}
	approval, err := os.ReadFile(project.ApprovalPath(root, b.Slug))
	saved, derr := decodeBase64(doc.Approval)
	if err != nil || derr != nil || !bytes.Equal(approval, saved) {
		return refuse(id, "approval changed", "")
	}
	for _, p := range b.Baseline {
		if fileDigest(root, p) != b.BaselineDigests[p] {
			return refuse(id, "baseline changed: "+p, "")
		}
	}
	cfg, err := project.LoadConfig(root)
	if err != nil {
		return err
	}
	baseline, err := project.Baseline(root, b.Slug, b.Config)
	if err != nil {
		return err
	}
	if !sameConfig(cfg, b.Config) || !slices.Equal(baseline, b.Baseline) {
		return refuse(id, "baseline/configuration changed", "")
	}
	// An external review role is served by its own executor on resume too, never natively.
	if reviewer, err := selectReviewer(in.Deps, b.Config.Models["review"]); err != nil {
		return err
	} else if reviewer != nil {
		b.deps.Reviewer = reviewer
	}
	if intent, err := project.ReadIntent(root, b.Slug, nil); err != nil || intent.Text != b.IntentText {
		return refuse(id, "saved Intent differs from exact approved contract", "")
	}
	// The user's index must record exactly what it recorded at the checkpoint. A plain `git
	// status` may since have refreshed its stat cache: that alone is not a change.
	savedIndex, _ := decodeBase64(doc.Index)
	currentIndex, err := os.ReadFile(b.GitIndex)
	if err != nil {
		return refuse(id, "index/staged custody changed", "")
	}
	refreshed := !bytes.Equal(currentIndex, savedIndex)
	if refreshed {
		format, err := repo.ObjectFormat()
		if err != nil || !git.StagedEquivalent(currentIndex, savedIndex, format) {
			return refuse(id, "index/staged custody changed", "")
		}
	}
	original := filepath.Join(b.Run.Dir, "index-at-start")
	if backup, err := os.ReadFile(original); err != nil || !bytes.Equal(backup, savedIndex) {
		return refuse(id, "original index backup missing or damaged: "+original, "")
	}
	candidate, err := repo.Tree(b.Start, nil)
	if err != nil {
		return err
	}
	if candidate != doc.Candidate {
		paths, err := repo.Changed(doc.Candidate, candidate)
		if err != nil {
			return err
		}
		return refuse(id, "candidate contents/modes or unrelated paths changed: "+strings.Join(paths, ", "), "")
	}

	// A review-only checkpoint starts a fresh review of exactly the verified green tree: the
	// saved pass must be the one the checkpointed candidate was verified as, and the candidate
	// (as a review sees it, without other Intents' folders) must still be that tree.
	if c := b.Continuation; c.Stage == StageReviewOnly {
		tree, err := repo.Tree(b.Start, b.Excluded)
		if err != nil {
			return err
		}
		if tree != c.Pass.Tree || b.LastPass == nil || b.LastPass.Tree != c.Pass.Tree {
			return refuse(id, "the candidate is not the verified green tree of the review-only checkpoint", "")
		}
	}

	b.intent, err = b.State.intent()
	if err != nil {
		return err
	}
	b.model = b.intent.Model
	root0 := id
	if b.RootRun != nil {
		root0 = *b.RootRun
	}
	run, err := StartRun(root)
	if err != nil {
		return err
	}
	facts, err := startFacts(root, b.Slug, run, b.Config, id, root0)
	if err != nil {
		return err
	}
	// The custody copy is the user's index as it is now, equivalent to the saved one.
	if err := os.WriteFile(filepath.Join(run.Dir, "index-at-start"), currentIndex, 0o666); err != nil {
		return err
	}
	b.facts = facts
	facts.inherit(b, b.Run)
	b.Run, b.Parent, b.RootRun = run, &id, &root0
	b.T0 = time.Now().UnixMilli()
	b.AttemptUsage = zeroTokens()
	*out = b
	s.Puts(fmt.Sprintf("resuming Build %s as %s (root %s)", id, run.ID, root0))
	event := map[string]any{"event": "resume", "parent": id, "root": root0}
	if refreshed {
		s.Progress("kogen: the index stat cache was refreshed since Build " + id + "; staged entries are unchanged")
		event["index"] = "stat_refreshed"
		event["checkpoint_index_sha256"], event["index_sha256"] = hashHex(savedIndex), hashHex(currentIndex)
	}
	run.Event(event)
	run.Event(research.BudgetEvent(in.Deps.Client))
	if err := b.Save(b.Continuation); err != nil {
		return err
	}
	return b.resumeStage(ctx)
}

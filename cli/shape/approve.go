package shape

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"kogen-loop/sys"
	"kogen/git"
	"kogen/project"
	"kogen/verify"
)

// ApproveInput is one `kogen intent approve <slug> [<hash>]` (AUT-1, AUT-2).
type ApproveInput struct {
	Project string // a directory inside the project's repository
	Slug    string
	Hash    string // 6 to 64 lowercase hex characters; empty: show the review card
	By      string // the approver; empty: the Git identity
	Tools   verify.Tools

	// Log and Evidence receive the events of a readiness check; both may be nil.
	Log      verify.Logger
	Evidence verify.Evidence

	// approveAfterWrite runs right after the approval file is written and before the
	// publication is checked: tests change inputs or interrupt there.
	approveAfterWrite func()
}

// Approve is `kogen intent approve`: without a hash it obtains current readiness and prints
// the review card (exit 5); with a hash that matches the acceptance baseline it publishes
// `.kogen/local/approvals/<slug>.json` and prints the approval (exit 0). It holds the
// repository's Build lock throughout and never starts a Build. Refusals are *sys.Error and
// an interrupt is *sys.Interrupted; exit is also set to the matching exit code then.
func Approve(ctx context.Context, s *sys.Session, in ApproveInput) (exit int, err error) {
	exit, err = approveRun(ctx, s, in)
	if err != nil {
		exit = approveExitCode(err)
	}
	return exit, err
}

func approveExitCode(err error) int {
	var e *sys.Error
	var i *sys.Interrupted
	switch {
	case errors.As(err, &e):
		return e.Exit
	case errors.As(err, &i):
		return i.ExitCode()
	}
	return 1
}

func approveRun(ctx context.Context, s *sys.Session, in ApproveInput) (int, error) {
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
	return approveLocked(ctx, s, in, repo)
}

func approveLocked(ctx context.Context, s *sys.Session, in ApproveInput, repo *git.Repo) (int, error) {
	root, slug, prefix := repo.Dir, in.Slug, in.Hash
	cfg, err := project.LoadConfig(root)
	if err != nil {
		return 0, err
	}
	if err := approveQuestionsPending(root, slug); err != nil {
		return 0, err
	}
	if err := project.RequireIntentDir(root, slug); err != nil {
		return 0, err
	}
	// An existing marker's receipt is resolved by its pinned digest, also when the marker is
	// stale and a later refresh moved the receipt into native history.
	previous, readErr := os.ReadFile(project.ApprovalPath(root, slug))
	if readErr != nil && !errors.Is(readErr, fs.ErrNotExist) {
		return 0, readErr
	}
	approval, err := project.ReadApproval(root, slug)
	if err != nil {
		return 0, err
	}
	pinned, err := project.ResolveApproval(root, slug, approval)
	if err != nil {
		return 0, err
	}
	approver := in.By
	if approver == "" {
		if approver = repo.Identity(); approver == "" {
			return 0, sys.Fail("intent", "approval_identity_unavailable", "configure git user.name and user.email, or pass --by <name>", 2)
		}
	}

	baseline, err := project.Baseline(root, slug, cfg)
	if err != nil {
		return 0, err
	}
	before := project.Hash(root, baseline)
	if prefix != "" && !strings.HasPrefix(before, prefix) {
		return 0, approveMismatch(slug, before, prefix)
	}
	source, err := project.BindSource(root, slug)
	if err != nil {
		return 0, err
	}
	rd := &verify.Readiness{Root: root, Repo: repo, Config: cfg, Tools: in.Tools, Log: in.Log, Evidence: in.Evidence}
	ready := rd.Cached(s, slug)
	if ready == nil {
		if ready, err = rd.Check(ctx, s, slug); err != nil {
			return 0, err
		}
	}
	if baseline, err = project.Baseline(root, slug, cfg); err != nil {
		return 0, err
	}
	sha := project.Hash(root, baseline)
	if prefix != "" && sha != before {
		return 0, approveMismatch(slug, sha, prefix)
	}
	if !rd.Current(s, slug, ready) {
		return 0, sys.Fail("intent", "not_ready", "readiness inputs changed; review again", 1)
	}
	if err := project.ValidateSource(source); err != nil {
		return 0, err
	}
	now, err := project.BindSource(root, slug)
	if err != nil {
		return 0, err
	}
	if !now.Equal(source) {
		return 0, sys.Fail("candidate", "source_provenance_changed",
			"source provenance changed during readiness: "+project.SourcePath(root, slug)+"; restore exact custody from preserved native receipt history, then run the card", 1)
	}
	if err := project.ValidateSource(pinned); err != nil {
		return 0, err
	}
	if current, err := os.ReadFile(project.ApprovalPath(root, slug)); !sameFile(current, err, previous, readErr) {
		return 0, sys.Fail("intent", "not_ready", "approval changed during readiness; run the card again", 1)
	}

	if prefix == "" {
		if approval != nil && approval.SHA256 != sha {
			s.Puts("Stale approval: " + approval.SHA256 + "; it does not authorize the current package " + sha + ".")
		}
		if source != nil && source.ContractSHA256 != sha {
			s.Puts("Historical source receipt contract: " + source.ContractSHA256 + "; current contract: " + sha + ". Shape has not run again.")
		}
		card, err := project.SourceCard(source)
		if err != nil {
			return 0, err
		}
		s.Puts(card)
		approveCard(s, slug, sha, approver, ready, baseline)
		return 5, nil
	}

	if err := approvePublish(ctx, s, in, rd, ready, publication{
		source: source, pinned: pinned, approval: approval, previous: previous, readErr: readErr,
	}, approver, sha); err != nil {
		return 0, err
	}
	if err := project.WritePackageFacts(root, slug, cfg); err != nil {
		return 0, err
	}
	s.Puts("approved " + slug + " " + sha[:8])
	s.Puts("Next: kogen intent build " + slug)
	return 0, nil
}

// publication is what approvePublish needs from the readiness phase: the receipt bound, the
// receipt the existing marker pins, the existing marker and its bytes as read.
type publication struct {
	source, pinned *project.SourceRef
	approval       *project.Approval
	previous       []byte
	readErr        error
}

func sameFile(a []byte, aErr error, b []byte, bErr error) bool {
	if aErr != nil || bErr != nil {
		return errors.Is(aErr, fs.ErrNotExist) && errors.Is(bErr, fs.ErrNotExist)
	}
	return bytes.Equal(a, b)
}

// pinnedBeforeRefresh is the receipt the existing marker pins once a refresh moved the
// current receipt: validated through its immutable hash-named history.
func pinnedBeforeRefresh(pinned, source, published *project.SourceRef) *project.SourceRef {
	if pinned != nil && pinned.Equal(source) && !source.Equal(published) {
		return pinned.Archived()
	}
	return pinned
}

// approvePublish writes the approval and checks that the readiness inputs, the receipt chain
// and the marker still hold; on an error or an interrupt this operation's own marker and
// receipt are rolled back (a file someone else changed is never overwritten). A stale marker
// of another contract is first kept in the approval history, and a receipt bound to an earlier
// contract is refreshed to this one with its predecessor kept.
func approvePublish(ctx context.Context, s *sys.Session, in ApproveInput, rd *verify.Readiness, ready *verify.Ready, p publication, approver, sha string) error {
	root, slug := rd.Root, in.Slug
	path := project.ApprovalPath(root, slug)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	if p.approval != nil && p.approval.SHA256 != sha {
		if err := archiveApproval(s, root, slug, p.previous); err != nil {
			return err
		}
	}
	var previousSource []byte
	if p.source != nil {
		var err error
		if previousSource, err = os.ReadFile(p.source.Path); err != nil {
			return err
		}
	}
	published, err := project.RefreshSource(root, slug, sha, p.source)
	if err != nil {
		return err
	}
	bytesToWrite, err := project.EncodeApproval(project.Approval{
		Slug:             slug,
		SHA256:           sha,
		Approver:         approver,
		ApprovedAt:       time.Now().UTC().Truncate(time.Second).Format("2006-01-02T15:04:05Z"),
		SourceProvenance: published.Map(),
	})
	if err != nil {
		return err
	}
	rollback := func(cause error) error {
		var errs []error
		if err := project.RestoreSource(published, previousSource); err != nil {
			errs = append(errs, err)
		}
		if current, err := os.ReadFile(path); err == nil && bytes.Equal(current, bytesToWrite) {
			var rerr error
			if p.readErr == nil {
				rerr = os.WriteFile(path, p.previous, 0o644)
			} else if rmErr := os.Remove(path); rmErr != nil && !errors.Is(rmErr, fs.ErrNotExist) {
				rerr = rmErr
			}
			if rerr != nil {
				errs = append(errs, rerr)
			}
		}
		if len(errs) > 0 {
			return errors.Join(append([]error{cause}, errs...)...)
		}
		return cause
	}
	notReady := func(detail string) error { return rollback(sys.Fail("intent", "not_ready", detail, 1)) }

	pin := pinnedBeforeRefresh(p.pinned, p.source, published)
	if err := project.ValidateSource(pin); err != nil {
		return rollback(err)
	}
	if current, err := os.ReadFile(path); !sameFile(current, err, p.previous, p.readErr) {
		return notReady("approval changed during publication; run the card again")
	}
	if err := os.WriteFile(path, bytesToWrite, 0o644); err != nil {
		return rollback(err)
	}
	if in.approveAfterWrite != nil {
		in.approveAfterWrite()
	}
	if err := s.Err(); err != nil {
		return rollback(err)
	}
	if err := ctx.Err(); err != nil {
		return rollback(err)
	}
	if err := project.ValidateSource(published); err != nil {
		return rollback(err)
	}
	if !rd.Current(s, slug, ready) {
		return notReady("readiness inputs changed during approval publication")
	}
	if err := project.ValidateSource(published); err != nil {
		return rollback(err)
	}
	if err := project.ValidateSource(pin); err != nil {
		return rollback(err)
	}
	bound, err := project.BindSource(root, slug)
	if err != nil {
		return rollback(err)
	}
	if current, err := os.ReadFile(path); !bound.Equal(published) || err != nil || !bytes.Equal(current, bytesToWrite) {
		return notReady("source or approval changed during publication; inspect the changed custody before running the card")
	}
	if err := s.Err(); err != nil {
		return rollback(err)
	}
	return ctx.Err()
}

// archiveApproval keeps a stale marker, byte for byte, in the private approval history of the
// Intent (`.kogen/local/approvals/history/<slug>/<sha256>.json`, 0600, folders 0700 below
// approvals) before a new approval replaces it.
func archiveApproval(s *sys.Session, root, slug string, marker []byte) error {
	unsafe := func(path string) error {
		return sys.Fail("candidate", "source_provenance_changed", "unsafe approval history: "+path+"; restore exact private history, then run the card", 1)
	}
	for _, rel := range []string{".kogen", ".kogen/local", ".kogen/local/approvals", ".kogen/local/approvals/history", ".kogen/local/approvals/history/" + slug} {
		dir := filepath.Join(root, rel)
		fi, err := os.Lstat(dir)
		switch {
		case errors.Is(err, fs.ErrNotExist):
			if err := os.Mkdir(dir, 0o777); err != nil {
				return err
			}
		case err == nil && fi.IsDir():
		default:
			return unsafe(dir)
		}
		if strings.Contains(rel, "/history") {
			if err := os.Chmod(dir, 0o700); err != nil {
				return err
			}
		}
	}
	archive := filepath.Join(root, ".kogen/local/approvals/history/"+slug, ContentHash(marker)+".json")
	switch fi, err := os.Lstat(archive); {
	case errors.Is(err, fs.ErrNotExist):
		f, err := os.OpenFile(archive, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o666)
		if err != nil {
			return err
		}
		_, werr := f.Write(marker)
		if cerr := f.Close(); werr == nil {
			werr = cerr
		}
		if werr != nil {
			return werr
		}
	case err == nil && fi.Mode().IsRegular():
		if b, err := os.ReadFile(archive); err != nil || !bytes.Equal(b, marker) {
			return sys.Fail("candidate", "source_provenance_changed", "restore exact approval history: "+archive, 1)
		}
	default:
		return unsafe(archive)
	}
	if err := os.Chmod(archive, 0o600); err != nil {
		return err
	}
	s.Puts("Retained stale approval: " + archive)
	return nil
}

func approveMismatch(slug, sha, prefix string) error {
	return sys.Fail("intent", "hash_mismatch",
		fmt.Sprintf("%s is now %s, not %s; review it again with kogen intent approve %s", slug, sha, prefix, slug), 1)
}

// approveQuestionsPending refuses while the last shaping round has unanswered questions.
func approveQuestionsPending(root, slug string) error {
	b, err := os.ReadFile(filepath.Join(root, ".kogen/local/shaping", slug, "state.json"))
	if err != nil {
		return nil
	}
	var state struct {
		Rounds []struct {
			Questions []json.RawMessage `json:"questions"`
			Answers   map[string]any    `json:"answers"`
		} `json:"rounds"`
	}
	if err := json.Unmarshal(b, &state); err != nil || len(state.Rounds) == 0 {
		return fmt.Errorf("shaping state of %s is unreadable", slug)
	}
	round := state.Rounds[len(state.Rounds)-1]
	if n := len(round.Questions) - len(round.Answers); n > 0 {
		return sys.Fail("intent", "questions_pending",
			fmt.Sprintf("%s has %d unanswered question(s); answer them with kogen intent shape %s <file|->", slug, n, slug), 5)
	}
	return nil
}

// approveCard prints the review card (AUT-1): each Scenario Outline once with its number of
// examples and `fails now` if any row fails, each ordinary Scenario once.
func approveCard(s *sys.Session, slug, sha, approver string, ready *verify.Ready, baseline []string) {
	s.Puts("Intent: " + slug + " — " + ready.Intent.Title)
	s.Puts("SHA-256: " + sha)
	s.Puts("Approver: " + approver)
	s.Puts("")
	s.Puts("Acceptance")
	for i := 0; i < len(ready.Scenarios); {
		first := ready.Scenarios[i]
		j := i + 1
		for j < len(ready.Scenarios) && approveSameGroup(first, ready.Scenarios[j]) {
			j++
		}
		failed := false
		for _, r := range ready.Scenarios[i:j] {
			failed = failed || r.Status == "failed"
		}
		status, name, count := "passes now", first.Name, ""
		if failed {
			status = "fails now"
		}
		if first.OutlineName != nil {
			name = *first.OutlineName
		}
		if first.OutlineExamples != nil {
			count = fmt.Sprintf(" (%d examples)", *first.OutlineExamples)
		}
		s.Puts("  - " + name + count + " (" + status + ")")
		i = j
	}
	if obs := verify.Observations(slug, ready, ""); obs != "" {
		s.Puts("\n" + obs + "\n")
	}
	if stages, err := project.ParseStages(ready.Intent.Text); err == nil && stages != nil {
		s.Puts("Staged plan")
		for i, stage := range stages {
			s.Puts(fmt.Sprintf("  %d. %s (%s): %s", i+1, stage.Title, stage.ID, stage.Goal))
			for _, cmd := range stage.Checks {
				s.Puts("    - " + cmd)
			}
		}
	}
	s.Puts("Files")
	for _, p := range baseline {
		s.Puts("  - " + p)
	}
	s.Puts("Approve with:")
	s.Puts("  kogen intent approve " + slug + " " + sha)
}

// approveSameGroup reports whether b continues the card line of a: both are rows of the
// same Scenario Outline.
func approveSameGroup(a, b verify.ScenarioResult) bool {
	if a.OutlineLine == nil || b.OutlineLine == nil {
		return false
	}
	return *a.OutlineLine == *b.OutlineLine
}

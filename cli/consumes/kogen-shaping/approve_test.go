package consumes

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/KogenAI/kogen-loop/sys"
	"github.com/KogenAI/kogen-shaping/shape"
)

var shaRe = regexp.MustCompile(`SHA-256: ([0-9a-f]{64})\n`)

// approve calls shape.Approve as kogen's runEngine does for `kogen intent approve`.
func (f *fx) approve(hash, by string) (int, string, error) {
	f.t.Helper()
	s, out := f.session()
	exit, err := shape.Approve(s.Context(), s, shape.ApproveInput{Project: f.root, Slug: slug, Hash: hash, By: by, Tools: f.tools})
	return exit, out.String(), err
}

// card shows the review card and returns the full hash it prints.
func (f *fx) card() string {
	f.t.Helper()
	exit, out, err := f.approve("", "")
	if err != nil || exit != 5 {
		f.t.Fatalf("exit %d, err %v\n%s", exit, err, out)
	}
	m := shaRe.FindStringSubmatch(out)
	if m == nil {
		f.t.Fatalf("no SHA-256 line:\n%s", out)
	}
	return m[1]
}

// TestApproveWithoutAHashShowsTheCardWithExit5: kogen passes no Hash for the card. Approve
// prints the card (the Intent, its full SHA-256, the Git identity as approver, and the command
// to approve with) and returns exit 5 and a nil error; nothing is approved.
func TestApproveWithoutAHashShowsTheCardWithExit5(t *testing.T) {
	f := newFx(t, false)
	f.addIntent()
	exit, out, err := f.approve("", "")
	if err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, out)
	}
	sha := f.card()
	for _, want := range []string{
		"Intent: fixture — Fixture intent\n",
		"Approver: Kogen Test Owner <fixture@example.invalid>\n",
		"  - First (fails now)\n",
		"Approve with:\n  kogen intent approve fixture " + sha + "\n",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("card lacks %q:\n%s", want, out)
		}
	}
	if f.exists(".kogen/local/approvals/fixture.json") {
		t.Fatal("the card approved the Intent")
	}
}

// TestApproveRunsTheAcceptanceCommandWithTheTools: the Tools of the input are the ones the
// readiness check's commands run with (KOGEN_NODE and KOGEN_CUCUMBER).
func TestApproveRunsTheAcceptanceCommandWithTheTools(t *testing.T) {
	f := newFx(t, false)
	f.addIntent()
	f.card()
	if got, want := f.readAux("tools"), f.tools.Node+"\n"+f.tools.Cucumber+"\n"; got != want {
		t.Fatalf("acceptance command saw %q, want %q", got, want)
	}
}

// TestApproveWithTheHashPublishesTheApproval: a Hash of 6 to 64 hex characters that matches the
// baseline publishes .kogen/local/approvals/<slug>.json and returns exit 0; By names the
// approver, and an empty By is the Git identity.
func TestApproveWithTheHashPublishesTheApproval(t *testing.T) {
	for _, tc := range []struct {
		name, by, approver string
		prefix             int
	}{
		{"full hash, Git identity", "", "Kogen Test Owner <fixture@example.invalid>", 64},
		{"six characters, named approver", "Reviewer <reviewer@example.invalid>", "Reviewer <reviewer@example.invalid>", 6},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFx(t, false)
			f.addIntent()
			sha := f.card()
			exit, out, err := f.approve(sha[:tc.prefix], tc.by)
			if err != nil || exit != 0 {
				t.Fatalf("exit %d, err %v\n%s", exit, err, out)
			}
			var approval map[string]any
			if err := json.Unmarshal([]byte(f.read(".kogen/local/approvals/fixture.json")), &approval); err != nil {
				t.Fatal(err)
			}
			if approval["sha256"] != sha || approval["base"] != f.head() {
				t.Fatalf("approval = %v, want sha256 %s and base %s", approval, sha, f.head())
			}
			if !strings.HasPrefix(out, "approved fixture "+sha[:8]+"\n") || approval["approver"] != tc.approver {
				t.Fatalf("stdout %q, approver %v; want approved fixture %s and approver %q", out, approval["approver"], sha[:8], tc.approver)
			}
		})
	}
}

// TestApproveRefusalsAreSysErrorsWithTheirExit: a refusal is a *sys.Error and Approve's exit is
// its Exit, which kogen's exitFor prints with Render and returns.
func TestApproveRefusalsAreSysErrorsWithTheirExit(t *testing.T) {
	t.Run("hash does not match", func(t *testing.T) {
		f := newFx(t, false)
		f.addIntent()
		sha := f.card()
		exit, _, err := f.approve("000000", "")
		e := wantError(t, exit, err, "intent", "hash_mismatch", 1)
		if !strings.Contains(e.Detail, sha) || !strings.Contains(e.Detail, "kogen intent approve fixture") {
			t.Fatalf("detail = %q, want the current hash and the card command", e.Detail)
		}
		if f.exists(".kogen/local/approvals/fixture.json") {
			t.Fatal("a mismatching hash approved the Intent")
		}
	})
	t.Run("no such Intent", func(t *testing.T) {
		f := newFx(t, false)
		exit, _, err := f.approve("", "")
		wantError(t, exit, err, "intent", "not_found", 2)
	})
	t.Run("not a Git repository", func(t *testing.T) {
		f := newFx(t, false)
		plain := filepath.Join(f.base, "plain")
		if err := os.MkdirAll(plain, 0o755); err != nil {
			t.Fatal(err)
		}
		s, _ := f.session()
		exit, err := shape.Approve(s.Context(), s, shape.ApproveInput{Project: plain, Slug: slug, Tools: f.tools})
		wantError(t, exit, err, "environment", "not_a_git_repo", 3)
	})
	t.Run("no Git identity names no approver", func(t *testing.T) {
		f := newFx(t, false)
		f.addIntent()
		f.git("config", "--unset", "user.name")
		f.git("config", "--unset", "user.email")
		exit, _, err := f.approve("", "")
		wantError(t, exit, err, "intent", "approval_identity_unavailable", 2)
	})
}

// TestApproveInterruptExitsWithTheSignalsCode: an interrupted session gives *sys.Interrupted
// whose exit is the signal's code, and Approve returns that code.
func TestApproveInterruptExitsWithTheSignalsCode(t *testing.T) {
	f := newFx(t, false)
	f.addIntent()
	s, _ := f.session()
	s.Interrupt("SIGTERM")
	exit, err := shape.Approve(context.Background(), s, shape.ApproveInput{Project: f.root, Slug: slug, Tools: f.tools})
	wantInterrupted(t, exit, err, 143)
	if f.exists(".kogen/local/approvals/fixture.json") {
		t.Fatal("an interrupted Approve approved the Intent")
	}
}

func wantInterrupted(t *testing.T, exit int, err error, code int) {
	t.Helper()
	in, ok := err.(*sys.Interrupted)
	if !ok || in.ExitCode() != code || exit != code {
		t.Fatalf("exit %d, error %v (%T); want *sys.Interrupted, exit %d", exit, err, err, code)
	}
}

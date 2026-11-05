package consumes

import (
	"errors"
	"strings"
	"testing"

	"github.com/KogenAI/kogen-coordinator/project"
	"github.com/KogenAI/kogen-executor/executor"
	"github.com/KogenAI/kogen-loop/sys"
	"github.com/KogenAI/kogen-shaping/shape"
)

const externalShaperConfig = acceptanceConfig + "models:\n  shape: {executor: claude-code, model: claude-sonnet-5-5, effort: high}\n"

// refine calls shape.Refine as kogen's runEngine does for `kogen intent refine`.
func (f *fx) refine(hash string, external shape.External) (int, string, error) {
	f.t.Helper()
	s, out := f.session()
	exit, err := shape.Refine(s.Context(), s, shape.RefineInput{Project: f.root, Slug: slug, Hash: hash,
		Request: "Correct the fixture.", RequestPath: f.base + "/correction.md", Tools: f.tools, InstallRoot: f.base + "/install", Client: f.client(), External: external})
	return exit, out.String(), err
}

// TestRefineRefusalsAreSysErrorsWithTheirExit: a refusal is a *sys.Error and Refine's exit is its
// Exit, which kogen's exitFor prints with Render and returns. The frozen hash must be the full
// 64 characters of the card and the current one; nothing is replaced.
func TestRefineRefusalsAreSysErrorsWithTheirExit(t *testing.T) {
	t.Run("no such Intent", func(t *testing.T) {
		f := newFx(t, true)
		exit, _, err := f.refine(strings.Repeat("0", 64), nil)
		wantError(t, exit, err, "intent", "not_found", 2)
	})
	t.Run("hash is not the full hash", func(t *testing.T) {
		f := newFx(t, true)
		f.addIntent()
		exit, _, err := f.refine(f.card()[:8], nil)
		wantError(t, exit, err, "intent", "refinement_hash", 2)
	})
	t.Run("hash is stale", func(t *testing.T) {
		f := newFx(t, true)
		f.addIntent()
		sha := f.card()
		exit, _, err := f.refine(strings.Repeat("0", 64), nil)
		e := wantError(t, exit, err, "intent", "refinement_stale", 1)
		if !strings.Contains(e.Detail, sha) || !strings.Contains(e.Detail, "kogen intent approve fixture") {
			t.Fatalf("detail = %q, want the current hash and the card command", e.Detail)
		}
	})
	t.Run("not signed in", func(t *testing.T) {
		f := newFx(t, false)
		f.addIntent()
		exit, _, err := f.refine(f.card(), nil)
		wantError(t, exit, err, "provider", "login", 4)
		if f.requests() != 0 {
			t.Fatalf("%d model requests", f.requests())
		}
	})
}

// TestRefineAsksKogensExecutorForAnExternalShapeRole: for a shape role with `executor:
// claude-code`, Refine calls the External field with that role before it asks for a login. The
// error External returns is Refine's refusal; no executor is `executor/unavailable`.
func TestRefineAsksKogensExecutorForAnExternalShapeRole(t *testing.T) {
	refuse := sys.Fail("executor", "unavailable", "claude-code is refused by the fixture", 1)
	for _, tc := range []struct {
		name   string
		answer func() (executor.Executor, error)
		reason string
		detail string
	}{
		{"an error", func() (executor.Executor, error) { return nil, refuse }, "unavailable", "claude-code is refused by the fixture"},
		{"no executor", func() (executor.Executor, error) { return nil, nil }, "unavailable", "executor claude-code is not available for the shape role"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFx(t, false)
			f.configure(externalShaperConfig)
			f.commitAll("external shaper")
			f.addIntent()
			sha := f.card()
			var roles []project.Role
			exit, _, err := f.refine(sha, func(role project.Role) (executor.Executor, error) {
				roles = append(roles, role)
				return tc.answer()
			})
			e := wantError(t, exit, err, "executor", tc.reason, 1)
			if !strings.Contains(e.Detail, tc.detail) {
				t.Fatalf("detail = %q, want %q", e.Detail, tc.detail)
			}
			if len(roles) != 1 || roles[0].Executor != project.ExecutorClaudeCode || roles[0].Model != "claude-sonnet-5-5" {
				t.Fatalf("External called with %+v", roles)
			}
		})
	}
	t.Run("not provided", func(t *testing.T) {
		f := newFx(t, false)
		f.configure(externalShaperConfig)
		f.commitAll("external shaper")
		f.addIntent()
		exit, _, err := f.refine(f.card(), nil)
		wantError(t, exit, err, "executor", "unavailable", 1)
	})
}

// TestRefineInterruptExitsWithTheSignalsCode: an interrupted session gives *sys.Interrupted
// whose exit is the signal's code.
func TestRefineInterruptExitsWithTheSignalsCode(t *testing.T) {
	f := newFx(t, true)
	f.addIntent()
	sha := f.card()
	s, _ := f.session()
	s.Interrupt("SIGINT")
	exit, err := shape.Refine(s.Context(), s, shape.RefineInput{Project: f.root, Slug: slug, Hash: sha, Request: "Correct the fixture.", Tools: f.tools, Client: f.client()})
	var in *sys.Interrupted
	if !errors.As(err, &in) || in.ExitCode() != 130 || exit != 130 {
		t.Fatalf("exit %d, error %v (%T); want *sys.Interrupted, exit 130", exit, err, err)
	}
}

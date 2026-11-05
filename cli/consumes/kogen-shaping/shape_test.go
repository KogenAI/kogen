package consumes

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/KogenAI/kogen-coordinator/project"
	"github.com/KogenAI/kogen-executor/executor"
	"github.com/KogenAI/kogen-loop/sys"
	"github.com/KogenAI/kogen-shaping/shape"
)

// shapeWith calls shape.Shape as kogen's runEngine does for `kogen intent shape`; requestPath is
// empty for a request from standard input.
func (f *fx) shapeWith(request, requestPath string, external shape.External) (int, string, error) {
	f.t.Helper()
	s, out := f.session()
	exit, err := shape.Shape(s.Context(), s, shape.ShapeInput{Project: f.root, Slug: slug, Request: request, RequestPath: requestPath,
		Tools: f.tools, InstallRoot: f.base + "/install", Client: f.client(), External: external})
	return exit, out.String(), err
}

// asks is a model that asks one UI/UX question and lets it reach the user.
func asks() []reply {
	return []reply{
		call("submit", map[string]any{"questions": []any{map[string]any{"question": "Which layout?", "options": []any{
			map[string]any{"label": "grid", "recommended": true}, map[string]any{"label": "list"}}}}}),
		call("submit_question_check", map[string]any{"items": []any{map[string]any{"number": 1, "class": "ui_ux", "why": "a ui_ux question"}}}),
	}
}

// TestShapeRefusalsAreSysErrorsWithTheirExit: a refusal is a *sys.Error and Shape's exit is its
// Exit, which kogen's exitFor prints with Render and returns.
func TestShapeRefusalsAreSysErrorsWithTheirExit(t *testing.T) {
	t.Run("not a Git repository", func(t *testing.T) {
		f := newFx(t, true)
		plain := filepath.Join(f.base, "plain")
		if err := os.MkdirAll(plain, 0o755); err != nil {
			t.Fatal(err)
		}
		s, _ := f.session()
		exit, err := shape.Shape(s.Context(), s, shape.ShapeInput{Project: plain, Slug: slug, Request: "Add it.", Tools: f.tools})
		wantError(t, exit, err, "environment", "not_a_git_repo", 3)
	})
	t.Run("acceptance not configured", func(t *testing.T) {
		f := newFx(t, true)
		f.configure("version: 1\n")
		f.commitAll("no acceptance")
		exit, _, err := f.shapeWith("Add it.", "", nil)
		wantError(t, exit, err, "environment", "acceptance_unconfigured", 3)
	})
	t.Run("not signed in", func(t *testing.T) {
		f := newFx(t, false)
		exit, _, err := f.shapeWith("Add it.", "", nil)
		wantError(t, exit, err, "provider", "login", 4)
		if f.requests() != 0 {
			t.Fatalf("%d model requests", f.requests())
		}
	})
	t.Run("already shaped", func(t *testing.T) {
		f := newFx(t, true)
		f.addIntent()
		exit, _, err := f.shapeWith("Add it.", "", nil)
		e := wantError(t, exit, err, "intent", "exists", 5)
		if !strings.Contains(e.Detail, "fixture is already shaped") {
			t.Fatalf("detail = %q", e.Detail)
		}
	})
	t.Run("the model fails", func(t *testing.T) {
		f := newFx(t, true)
		exit, _, err := f.shapeWith("Add it.", "", nil)
		wantError(t, exit, err, "shape", "provider_failed", 4)
		if f.requests() == 0 {
			t.Fatal("the loopback provider received no request")
		}
		if f.exists(".kogen/intents/fixture") {
			t.Fatal("the failed request wrote an Intent")
		}
	})
}

// TestShapeAsksTheModelThroughTheClientAndPrintsItsQuestions: the Client of the input reaches the
// provider named by the session's environment and the login under the session's HOME; the
// question the model asks and the check lets through are printed, and Shape returns exit 5 and a
// nil error. Nothing is written but the pending state.
func TestShapeAsksTheModelThroughTheClientAndPrintsItsQuestions(t *testing.T) {
	f := newFx(t, true, asks()...)
	exit, out, err := f.shapeWith("Add a list view.", "", nil)
	if err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, out)
	}
	if f.requests() != 2 || !strings.Contains(out, "Questions for fixture:") || !strings.Contains(out, "Which layout?") {
		t.Fatalf("%d requests, stdout:\n%s", f.requests(), out)
	}
	if f.exists(".kogen/intents/fixture/intent.md") {
		t.Fatal("pending questions wrote the Intent")
	}
	if !strings.Contains(f.read(".kogen/local/shaping/fixture/state.json"), "Add a list view.") {
		t.Fatal("the request is not kept with the pending questions")
	}
}

// TestShapeTakesTheRequestAsTheAnswersWhileQuestionsArePending: kogen passes the answers file as
// the Request of the next Shape; answers that are not `<n>: <letter or words>` lines are refused
// as intent/answers_invalid with exit 2, before the model is asked again.
func TestShapeTakesTheRequestAsTheAnswersWhileQuestionsArePending(t *testing.T) {
	f := newFx(t, true, asks()...)
	if exit, out, err := f.shapeWith("Add a list view.", "", nil); err != nil || exit != 5 {
		t.Fatalf("exit %d, err %v\n%s", exit, err, out)
	}
	asked := f.requests()
	exit, _, err := f.shapeWith("grid, please", "", nil)
	wantError(t, exit, err, "intent", "answers_invalid", 2)
	if f.requests() != asked {
		t.Fatalf("%d requests after the refused answers, %d before", f.requests(), asked)
	}
}

// TestShapeNamesTheRequestPath: the RequestPath is where the request came from. An untracked
// request file inside the repository is noted by its repository path, and a failed Shape tells the user to rerun with
// that file; without a path it says the request goes on stdin.
func TestShapeNamesTheRequestPath(t *testing.T) {
	f := newFx(t, true)
	path := filepath.Join(f.root, "request.md")
	if err := os.WriteFile(path, []byte("Add it.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s, out := f.session()
	exit, err := shape.Shape(s.Context(), s, shape.ShapeInput{Project: f.root, Slug: slug, Request: "Add it.", RequestPath: path, Tools: f.tools, Client: f.client()})
	e := wantError(t, exit, err, "shape", "provider_failed", 4)
	if !strings.Contains(out.String(), "note: request.md is untracked; commit or move it before kogen intent build\n") || !strings.Contains(e.Detail, path) {
		t.Fatalf("stdout %q, detail %q", out.String(), e.Detail)
	}
	_, _, err = f.shapeWith("Add it.", "", nil)
	if e, _ := sys.AsError(err); e == nil || !strings.Contains(e.Detail, "on stdin") {
		t.Fatalf("error %v, want a rerun hint with the request on stdin", err)
	}
}

// TestShapeAsksKogensExecutorForAnExternalShapeRole: for a shape role with `executor:
// claude-code`, Shape calls the External field with that role before it asks for a login. The
// error External returns is Shape's refusal; no executor is `executor/unavailable`.
func TestShapeAsksKogensExecutorForAnExternalShapeRole(t *testing.T) {
	refuse := sys.Fail("executor", "unavailable", "claude-code is refused by the fixture", 1)
	for _, tc := range []struct {
		name   string
		answer func() (executor.Executor, error)
		detail string
	}{
		{"an error", func() (executor.Executor, error) { return nil, refuse }, "claude-code is refused by the fixture"},
		{"no executor", func() (executor.Executor, error) { return nil, nil }, "executor claude-code is not available for the shape role"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newFx(t, false)
			f.configure(externalShaperConfig)
			f.commitAll("external shaper")
			var roles []project.Role
			exit, _, err := f.shapeWith("Add it.", "", func(role project.Role) (executor.Executor, error) {
				roles = append(roles, role)
				return tc.answer()
			})
			e := wantError(t, exit, err, "executor", "unavailable", 1)
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
		exit, _, err := f.shapeWith("Add it.", "", nil)
		wantError(t, exit, err, "executor", "unavailable", 1)
	})
}

// TestShapeInterruptExitsWithTheSignalsCode: an interrupted session gives *sys.Interrupted whose
// exit is the signal's code, and Shape returns that code.
func TestShapeInterruptExitsWithTheSignalsCode(t *testing.T) {
	f := newFx(t, true, asks()...)
	s, _ := f.session()
	s.Interrupt("SIGTERM")
	exit, err := shape.Shape(s.Context(), s, shape.ShapeInput{Project: f.root, Slug: slug, Request: "Add it.", Tools: f.tools, Client: f.client()})
	var in *sys.Interrupted
	if !errors.As(err, &in) || in.ExitCode() != 143 || exit != 143 {
		t.Fatalf("exit %d, error %v (%T); want *sys.Interrupted, exit 143", exit, err, err)
	}
	if f.exists(".kogen/intents/fixture") {
		t.Fatal("an interrupted Shape wrote an Intent")
	}
}

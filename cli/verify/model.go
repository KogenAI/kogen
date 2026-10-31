package verify

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"kogen-loop/sys"
	"kogen/project"
)

// ModelResult is the Quint model check of one pass: not applicable ("none"), not run
// ("not_run"), passed ("ok") or failed with the problems found. Its JSON is `"none"`,
// `"not_run"`, `{"ok":[]}` or `{"failed":[problem, ...]}`, the values Kogen's records hold.
type ModelResult struct {
	State    string // "none", "not_run", "ok", "failed"
	Problems []string
}

var (
	ModelNone   = ModelResult{State: "none"}
	ModelNotRun = ModelResult{State: "not_run"}
)

// Failed reports whether the model check found problems.
func (m ModelResult) Failed() bool { return m.State == "failed" }

var hasModelTests = regexp.MustCompile(`\brun\s+\w*Test\b`)

// CheckModel runs the Intent's Quint model in dir with Kogen's own Node and Quint and the
// TypeScript backend (VER-5): typecheck, test when the model has tests, and one run per
// declared invariant with the recorded seed and bounds. Every step runs; any failure fails
// the model, with Quint's output kept at both ends.
func CheckModel(ctx context.Context, s *sys.Session, dir string, tools Tools, m *project.ModelSpec, ev Evidence, log Logger) (ModelResult, error) {
	text, err := os.ReadFile(filepath.Join(dir, m.Path))
	if err != nil {
		return ModelResult{}, err
	}
	type step struct {
		args      []string
		what      string // typecheck, test or run
		invariant string
	}
	steps := []step{{args: []string{"typecheck", m.Path}, what: "typecheck"}}
	if hasModelTests.Match(text) {
		steps = append(steps, step{args: []string{"test", m.Path, "--backend", "typescript", "--match", "Test"}, what: "test"})
	}
	for _, inv := range m.Invariants {
		steps = append(steps, step{
			args:      []string{"run", m.Path, "--backend", "typescript", "--invariant", inv, "--seed", m.Seed, "--max-samples", m.Samples, "--max-steps", m.Steps},
			what:      "run",
			invariant: inv,
		})
	}
	var problems []string
	for _, st := range steps {
		logEvent(log, map[string]any{"event": "command", "name": "model", "command": strings.Join(append([]string{"quint"}, st.args...), " "), "node": tools.Node})
		count(ev, "quint")
		words := []string{shellQuote(tools.Node), shellQuote(tools.Quint)}
		for _, a := range st.args {
			words = append(words, shellQuote(a))
		}
		name := "model-" + st.what
		if st.invariant != "" {
			name += "-" + st.invariant
		}
		r, err := runStep(withStep(ctx, name, "model"), s, tools, name, log, strings.Join(words, " "), dir, nil)
		if err != nil {
			return ModelResult{}, err
		}
		logEvent(log, map[string]any{"event": "command_result", "name": "model", "status": r.Status, "output": Cap(r.Output)})
		switch {
		case r.Status == 0:
		case st.invariant != "" && strings.Contains(r.Output, "[violation]"):
			problems = append(problems, "model.qnt: invariant "+st.invariant+" violated (seed "+m.Seed+")\n"+Diagnostic(r.Output))
		default:
			problems = append(problems, "model.qnt: quint "+st.what+" failed (status "+itoa(r.Status)+")\n"+Diagnostic(r.Output))
		}
	}
	if len(problems) == 0 {
		return ModelResult{State: "ok", Problems: []string{}}, nil
	}
	return ModelResult{State: "failed", Problems: problems}, nil
}

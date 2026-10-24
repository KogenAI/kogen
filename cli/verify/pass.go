package verify

import (
	"bytes"
	"encoding/json"
	"fmt"
	"slices"
	"strings"

	"kogen/project"
)

// CommandResult is one setup command or project check that ran.
type CommandResult struct {
	Name    string `json:"name"`
	Command string `json:"command"`
	Status  int    `json:"status"`
	Output  string `json:"output"`
}

// Pass is one verification pass over the exact clean candidate Tree (VER-6 .. VER-9). Its
// JSON is what Kogen records for a pass: `acceptance` is `"not_run"` or the acceptance
// object, `model` is `"none"`, `"not_run"`, `{"ok":[]}` or `{"failed":[...]}`, and `not_run`
// names the required items an earlier failure kept from running.
type Pass struct {
	N          int
	Clean      bool
	Green      bool
	Tree       string
	Setup      []CommandResult
	Acceptance *Acceptance // nil: not run
	Model      ModelResult
	Checks     []CommandResult
	NotRun     []string
	Moved      []string
	Failing    []string

	// Legacy marks a recorded pass from before `setup` and `not_run` existed: complete clean
	// evidence of that kind stays reusable (VER-7).
	Legacy bool
}

type passJSON struct {
	N          int             `json:"n"`
	Clean      bool            `json:"clean"`
	Green      bool            `json:"green"`
	Tree       string          `json:"tree"`
	Setup      any             `json:"setup,omitempty"` // absent in a legacy record
	Acceptance any             `json:"acceptance"`
	Model      any             `json:"model"`
	Checks     []CommandResult `json:"checks"`
	NotRun     any             `json:"not_run,omitempty"` // absent in a legacy record
	Moved      []string        `json:"moved"`
	Failing    []string        `json:"failing"`
}

func nonNil[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

// MarshalJSON writes the record Kogen keeps for a pass.
func (p Pass) MarshalJSON() ([]byte, error) {
	j := passJSON{N: p.N, Clean: p.Clean, Green: p.Green, Tree: p.Tree, Checks: nonNil(p.Checks),
		Moved: nonNil(p.Moved), Failing: nonNil(p.Failing)}
	if !p.Legacy {
		j.Setup, j.NotRun = nonNil(p.Setup), nonNil(p.NotRun)
	}
	if p.Acceptance == nil {
		j.Acceptance = "not_run"
	} else {
		a := *p.Acceptance
		a.Scenarios, a.Problems, a.BindingProblems = nonNil(a.Scenarios), nonNil(a.Problems), nonNil(a.BindingProblems)
		j.Acceptance = a
	}
	switch p.Model.State {
	case "ok":
		j.Model = jmap{"ok": nonNil(p.Model.Problems)}
	case "failed":
		j.Model = jmap{"failed": nonNil(p.Model.Problems)}
	case "":
		j.Model = "not_run"
	default:
		j.Model = p.Model.State
	}
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(j); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(b.Bytes(), []byte("\n")), nil
}

// UnmarshalJSON reads a recorded pass.
func (p *Pass) UnmarshalJSON(data []byte) error {
	var present map[string]json.RawMessage
	if err := json.Unmarshal(data, &present); err != nil {
		return err
	}
	var j struct {
		N          int             `json:"n"`
		Clean      bool            `json:"clean"`
		Green      bool            `json:"green"`
		Tree       string          `json:"tree"`
		Setup      []CommandResult `json:"setup"`
		Acceptance json.RawMessage `json:"acceptance"`
		Model      json.RawMessage `json:"model"`
		Checks     []CommandResult `json:"checks"`
		NotRun     []string        `json:"not_run"`
		Moved      []string        `json:"moved"`
		Failing    []string        `json:"failing"`
	}
	if err := json.Unmarshal(data, &j); err != nil {
		return err
	}
	*p = Pass{N: j.N, Clean: j.Clean, Green: j.Green, Tree: j.Tree, Setup: j.Setup, Checks: j.Checks,
		NotRun: j.NotRun, Moved: j.Moved, Failing: j.Failing}
	_, hasSetup := present["setup"]
	_, hasNotRun := present["not_run"]
	p.Legacy = !hasSetup && !hasNotRun
	if len(j.Acceptance) > 0 && string(j.Acceptance) != `"not_run"` && string(j.Acceptance) != "null" {
		var a Acceptance
		if err := json.Unmarshal(j.Acceptance, &a); err != nil {
			return fmt.Errorf("pass acceptance: %w", err)
		}
		p.Acceptance = &a
	}
	var name string
	if err := json.Unmarshal(j.Model, &name); err == nil {
		p.Model = ModelResult{State: name}
		return nil
	}
	var tagged map[string][]string
	if err := json.Unmarshal(j.Model, &tagged); err != nil || len(tagged) != 1 {
		return fmt.Errorf("pass model: unreadable %s", j.Model)
	}
	for state, problems := range tagged {
		p.Model = ModelResult{State: state, Problems: problems}
	}
	if p.Model.State != "ok" && p.Model.State != "failed" {
		return fmt.Errorf("pass model: unknown %s", j.Model)
	}
	return nil
}

// Valid is the shape a recorded pass must have to be resumed from: clean, numbered, with a
// tree, a model value and well-formed acceptance, checks and not_run.
func (p Pass) Valid() bool {
	if !p.Clean || p.Tree == "" || p.Model.State == "" {
		return false
	}
	if p.Acceptance != nil && p.Acceptance.Scenarios == nil {
		return false
	}
	return true
}

// Complete is whether a recorded pass proves every required gate green for the current
// configuration, Intent and its expected scenarios, rather than trusting its Green flag
// (VER-7): clean, nothing moved or failing, nothing left unrun, acceptance exit 0 with every
// expected scenario passed exactly once, the model passed or not applicable, every check
// and (when the record has them) every setup command passed in declared order. Old clean
// passes without `setup` and `not_run` stay reusable.
func (p Pass) Complete(cfg *project.Config, expected []project.Scenario, model *project.ModelSpec) bool {
	if !p.Clean || !p.Green || len(p.Moved) != 0 || len(p.Failing) != 0 || p.Acceptance == nil || len(p.NotRun) != 0 {
		return false
	}
	a := p.Acceptance
	if a.Status != 0 || len(a.Problems) != 0 || len(a.Scenarios) != len(expected) {
		return false
	}
	for i, e := range expected {
		s := a.Scenarios[i]
		if s.Line != e.Line || s.Name != e.Name || s.Status != "passed" {
			return false
		}
	}
	if a.Passed != len(expected) {
		return false
	}
	want := "ok"
	if model == nil || model.None {
		want = "none"
	}
	if p.Model.State != want || (want == "ok" && len(p.Model.Problems) != 0) {
		return false
	}
	if len(p.Checks) != len(cfg.Checks) {
		return false
	}
	for i, c := range cfg.Checks {
		if got := p.Checks[i]; got.Name != c.Name || got.Command != c.Run || got.Status != 0 {
			return false
		}
	}
	if p.Legacy {
		return true
	}
	if len(p.Setup) != len(cfg.Setup) {
		return false
	}
	for i, cmd := range cfg.Setup {
		if got := p.Setup[i]; got.Name != fmt.Sprintf("setup-%d", i+1) || got.Command != cmd || got.Status != 0 {
			return false
		}
	}
	return true
}

// NotRunSummary is `; not run because an earlier item failed: a, b` (empty for none), the
// tail of progress and stopped lines.
func NotRunSummary(names []string) string {
	if len(names) == 0 {
		return ""
	}
	return "; not run because an earlier item failed: " + strings.Join(names, ", ")
}

// NotRunNotice is NotRunSummary without its leading separator, for lines of its own.
func NotRunNotice(names []string) string {
	return strings.TrimPrefix(NotRunSummary(names), "; ")
}

// Summary is the progress line of a finished pass.
func (p Pass) Summary() string {
	var what string
	switch {
	case p.Green:
		what = "all checks passed"
	case len(p.Failing) > 0:
		what = strings.Join(p.Failing, ", ") + " failed"
	default:
		what = "files changed while the checks ran: " + strings.Join(p.Moved, ", ")
	}
	return fmt.Sprintf("kogen: pass %d: %s%s", p.N, what, NotRunSummary(p.NotRun))
}

// ChecksLine is the commit report's account of a green pass.
func (p Pass) ChecksLine() string {
	model := "model passed"
	if p.Model.State == "none" {
		model = "model not applicable"
	}
	passed, total := 0, 0
	if p.Acceptance != nil {
		passed, total = p.Acceptance.Passed, len(p.Acceptance.Scenarios)
	}
	parts := []string{fmt.Sprintf("acceptance %d/%d", passed, total), model}
	for _, c := range p.Checks {
		parts = append(parts, c.Name+" passed")
	}
	return strings.Join(parts, ", ")
}

func indent(text string) string {
	lines := strings.Split(text, "\n")
	for i, l := range lines {
		lines[i] = "  " + l
	}
	return strings.Join(lines, "\n")
}

// Feedback is what goes back to the repair owner after a red pass: the failed items with
// their evidence and the items that did not run. acceptanceRun is the configured acceptance
// command; completion names the tool the owner calls when done (`finish`).
func (p Pass) Feedback(acceptanceRun, completion string) string {
	if completion == "" {
		completion = "finish"
	}
	parts := []string{fmt.Sprintf("Verification pass %d is not green. Fix the implementation (the approved acceptance files cannot change), then call %s again.", p.N, completion)}
	if a := p.Acceptance; a != nil && len(a.Problems) > 0 {
		parts = append(parts, fmt.Sprintf("acceptance (%s): failed, exit status %d", acceptanceRun, a.Status))
		for _, problem := range a.Problems {
			parts = append(parts, indent(problem))
		}
	}
	if p.Model.Failed() {
		parts = append(parts, "model: failed")
		for _, problem := range p.Model.Problems {
			parts = append(parts, indent(problem))
		}
	}
	for _, c := range slices.Concat(p.Setup, p.Checks) {
		if c.Status != 0 {
			parts = append(parts, fmt.Sprintf("check %s (%s): failed, exit status %d\n%s", c.Name, c.Command, c.Status, indent(Tail(c.Output, 60))))
		}
	}
	if len(p.Moved) > 0 {
		parts = append(parts, "files changed while checks ran: "+strings.Join(p.Moved, ", "))
	}
	if len(p.NotRun) > 0 {
		parts = append(parts, NotRunNotice(p.NotRun))
	}
	return strings.Join(parts, "\n")
}

// Results is the green pass as the reviewer's material states it: scenarios passed, the
// model, and each check, one line each.
func (p Pass) Results() string {
	model := "model: passed"
	if p.Model.State == "none" {
		model = "model: not applicable"
	}
	scenarios := 0
	if p.Acceptance != nil {
		scenarios = len(p.Acceptance.Scenarios)
	}
	lines := []string{fmt.Sprintf("acceptance: passed (%d scenarios)", scenarios), model}
	for _, c := range p.Checks {
		lines = append(lines, "check "+c.Name+": passed")
	}
	return strings.Join(lines, "\n")
}

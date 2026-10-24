package verify

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"

	"kogen/project"
)

// StepRecord is one Gherkin step as recorded with its scenario.
type StepRecord struct {
	Keyword string `json:"keyword"`
	Text    string `json:"text"`
	Line    int    `json:"line"`
}

// ScenarioResult is an expected scenario (one per Scenario, one per Examples row) with the
// status and failure detail the report gave it. Status is passed, failed, undefined,
// pending, skipped, ambiguous, unknown, missing, duplicate, report_missing or report_invalid.
type ScenarioResult struct {
	Name            string       `json:"name"`
	Line            int          `json:"line"`
	Tags            []string     `json:"tags"`
	Steps           []StepRecord `json:"steps"`
	OutlineName     *string      `json:"outline_name,omitempty"`
	OutlineLine     *int         `json:"outline_line,omitempty"`
	OutlineExamples *int         `json:"outline_examples,omitempty"`
	Status          string       `json:"status"`
	Detail          *string      `json:"detail"`
}

// ScenarioRecord is the scenario as the readiness record holds it, without a result: the
// shape Kogen's Gherkin reader gives it.
func ScenarioRecord(s project.Scenario) ScenarioResult {
	r := ScenarioResult{Name: s.Name, Line: s.Line, Tags: s.Tags, Steps: []StepRecord{}}
	if r.Tags == nil {
		r.Tags = []string{}
	}
	for _, st := range s.Steps {
		r.Steps = append(r.Steps, StepRecord{Keyword: st.Keyword, Text: st.Text, Line: st.Line})
	}
	if o := s.Outline; o != nil {
		r.OutlineName, r.OutlineLine, r.OutlineExamples = &o.Name, &o.Line, &o.Examples
	}
	return r
}

func withResult(s project.Scenario, status string, detail *string) ScenarioResult {
	r := ScenarioRecord(s)
	r.Status, r.Detail = status, detail
	return r
}

// Acceptance is the result of one acceptance run (VER-4): the command's exit status and
// output, the expected scenarios with their statuses and every problem found. Problems is
// empty only when the command exited 0 and every expected scenario passed exactly once in a
// finished test case with nothing else present. BindingProblems keeps undefined and
// ambiguous steps whatever the scenario's own status.
type Acceptance struct {
	Status          int              `json:"status"`
	Output          string           `json:"output"`
	Scenarios       []ScenarioResult `json:"scenarios"`
	Problems        []string         `json:"problems"`
	BindingProblems []string         `json:"binding_problems"`
	Passed          int              `json:"passed"`
	Failed          int              `json:"failed"`
}

// Account is the VER-4 accounting of one acceptance run: the expected scenarios of feature
// (relative to root) against the Cucumber Messages report at report and the command's exit
// status and output.
func Account(root, feature string, expected []project.Scenario, report string, status int, output string) Acceptance {
	base := Acceptance{Status: status, Output: output, Scenarios: []ScenarioResult{}, Problems: []string{}, BindingProblems: []string{}}
	cases, problem := readReport(root, report)
	if problem != "" {
		base.Problems = []string{problem + ": the acceptance command exited " + itoa(status) + "; its output:\n" + Excerpt(output)}
		for _, e := range expected {
			base.Scenarios = append(base.Scenarios, withResult(e, problem, nil))
		}
		return base
	}
	var mine []reportCase
	for _, c := range cases {
		if c.uri == feature {
			mine = append(mine, c)
		}
	}
	var scenProblems, unexpected []string
	for _, e := range expected {
		var hits []reportCase
		for _, c := range mine {
			if c.hasLine && c.line == e.Line {
				hits = append(hits, c)
			}
		}
		var r ScenarioResult
		switch len(hits) {
		case 0:
			r = withResult(e, "missing", nil)
		case 1:
			r = withResult(e, hits[0].status, hits[0].detail)
		default:
			r = withResult(e, "duplicate", nil)
		}
		base.Scenarios = append(base.Scenarios, r)
		if r.Status != "passed" {
			scenProblems = append(scenProblems, fmt.Sprintf("%s: %s (line %d)", r.Status, r.Name, r.Line)+detailSuffix(r.Detail))
		}
		switch r.Status {
		case "passed":
			base.Passed++
		case "failed":
			base.Failed++
		}
	}
	for _, c := range cases {
		known := c.uri == feature && c.hasLine && slices.ContainsFunc(expected, func(e project.Scenario) bool { return e.Line == c.line })
		if !known {
			line := ""
			if c.hasLine {
				line = itoa(c.line)
			}
			unexpected = append(unexpected, fmt.Sprintf("unexpected: %s line %s (%s)", c.uri, line, c.name))
		}
	}
	switch {
	case len(scenProblems)+len(unexpected) > 0:
		base.Problems = append(scenProblems, unexpected...)
	case status != 0:
		base.Problems = []string{fmt.Sprintf("exit %d with all scenarios passed", status)}
	}
	for _, c := range cases {
		for _, p := range c.binding {
			if !slices.Contains(base.BindingProblems, p) {
				base.BindingProblems = append(base.BindingProblems, p)
			}
		}
	}
	return base
}

func detailSuffix(d *string) string {
	if d == nil {
		return ""
	}
	return "\n" + *d
}

// reportCase is one test case of the report: its feature path, scenario line (the Examples
// row for outlines), name and final status.
type reportCase struct {
	uri     string
	line    int
	hasLine bool
	name    string
	status  string
	detail  *string
	binding []string
}

type jmap = map[string]any

// invalid is the panic value of a report that cannot be read; Elixir's accounting rescues
// every failure of this kind into report_invalid.
type invalid struct{}

func fail() { panic(invalid{}) }

// get is Elixir's Access on JSON values: a missing key or a non-object gives nil.
func get(v any, keys ...string) any {
	for _, k := range keys {
		m, ok := v.(jmap)
		if !ok {
			return nil
		}
		v = m[k]
	}
	return v
}

func truthy(v any) bool {
	switch x := v.(type) {
	case nil:
		return false
	case bool:
		return x
	}
	return true
}

func str(v any) string {
	s, ok := v.(string)
	if !ok {
		fail()
	}
	return s
}

func list(v any) []any {
	if v == nil {
		return nil
	}
	l, ok := v.([]any)
	if !ok {
		fail()
	}
	return l
}

func lineOf(v any) int {
	f, ok := v.(float64)
	if !ok {
		fail()
	}
	return int(f)
}

type astNode struct {
	line    int
	keyword string
	step    bool
}

func readReport(root, report string) (cases []reportCase, problem string) {
	text, err := os.ReadFile(report)
	if err != nil {
		return nil, "report_missing"
	}
	var msgs []jmap
	for _, line := range strings.Split(string(text), "\n") {
		if line == "" {
			continue
		}
		var m any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			return nil, "report_invalid"
		}
		obj, ok := m.(jmap)
		if !ok {
			return nil, "report_invalid"
		}
		msgs = append(msgs, obj)
	}
	if len(msgs) == 0 {
		return nil, "report_invalid"
	}
	defer func() {
		if r := recover(); r != nil {
			if _, ok := r.(invalid); !ok {
				panic(r)
			}
			cases, problem = nil, "report_invalid"
		}
	}()
	return accountCases(root, msgs), ""
}

type stepResult struct {
	started, step string
	result        any
}

func accountCases(root string, msgs []jmap) []reportCase {
	lines := map[string]astNode{}
	pickles, tcases, hooks := map[string]any{}, map[string]any{}, map[string]any{}
	started := map[string]string{}
	retried, finished := map[string]bool{}, map[string]bool{}
	for _, m := range msgs {
		if d := m["gherkinDocument"]; d != nil {
			for k, v := range astLines(get(d, "feature", "children")) {
				lines[k] = v
			}
		}
	}
	for _, m := range msgs {
		if p, ok := m["pickle"].(jmap); ok {
			pickles[str(p["id"])] = p
		}
		if c, ok := m["testCase"].(jmap); ok {
			tcases[str(c["id"])] = c
		}
		if h, ok := m["hook"].(jmap); ok {
			hooks[str(h["id"])] = h
		}
		if s, ok := m["testCaseStarted"].(jmap); ok {
			started[str(s["id"])] = str(s["testCaseId"])
		}
		if f, ok := m["testCaseFinished"].(jmap); ok {
			if truthy(f["willBeRetried"]) {
				retried[str(f["testCaseStartedId"])] = true
			} else {
				finished[str(f["testCaseStartedId"])] = true
			}
		}
	}
	var steps []stepResult
	for _, m := range msgs {
		if f, ok := m["testStepFinished"].(jmap); ok && !retried[str(f["testCaseStartedId"])] {
			steps = append(steps, stepResult{str(f["testCaseStartedId"]), str(f["testStepId"]), f["testStepResult"]})
		}
	}
	ids := make([]string, 0, len(started))
	for sid := range started {
		ids = append(ids, sid)
	}
	sort.Strings(ids)

	var out []reportCase
	for _, sid := range ids {
		if retried[sid] {
			continue
		}
		tc, _ := tcases[started[sid]].(jmap)
		pickle, _ := pickles[str(get(tc, "pickleId"))].(jmap)
		var mine []stepResult
		for _, s := range steps {
			if s.started == sid {
				mine = append(mine, s)
			}
		}
		complete := finished[sid]
		if complete {
			tsteps := list(get(tc, "testSteps"))
			if tsteps == nil {
				fail()
			}
			for _, ts := range tsteps {
				id := str(get(ts, "id"))
				if !slices.ContainsFunc(mine, func(s stepResult) bool { return s.step == id }) {
					complete = false
				}
			}
		}
		var status string
		var detail *string
		if complete {
			status, detail = caseStatus(tc, pickle, mine, lines, hooks)
		} else {
			d := "the report does not finish this scenario"
			status, detail = "report_invalid", &d
		}
		c := reportCase{name: str(get(pickle, "name")), status: status, detail: detail}
		c.uri = relativeTo(expandPath(str(get(pickle, "uri")), root), root)
		nodeIDs := list(get(pickle, "astNodeIds"))
		if len(nodeIDs) == 0 {
			fail()
		}
		if n, ok := lines[str(nodeIDs[len(nodeIDs)-1])]; ok {
			c.line, c.hasLine = n.line, true
		}
		c.binding = bindingProblems(tc, pickle, mine, lines)
		out = append(out, c)
	}
	return out
}

func expandPath(p, root string) string {
	if !filepath.IsAbs(p) {
		p = filepath.Join(root, p)
	}
	return filepath.Clean(p)
}

func relativeTo(p, root string) string {
	root = filepath.Clean(root)
	if rel, ok := strings.CutPrefix(p, root+"/"); ok {
		return rel
	}
	if p == root {
		return "."
	}
	return p
}

// astLines maps AST node ids to the line (and, for steps, keyword) of scenarios, Examples
// rows and steps.
func astLines(children any) map[string]astNode {
	out := map[string]astNode{}
	var walk func(children any)
	walk = func(children any) {
		for _, ch := range list(children) {
			if rule := get(ch, "rule"); truthy(rule) {
				walk(get(rule, "children"))
				continue
			}
			node := get(ch, "scenario")
			if !truthy(node) {
				node = get(ch, "background")
			}
			if !truthy(node) {
				continue
			}
			out[str(get(node, "id"))] = astNode{line: lineOf(get(node, "location", "line"))}
			for _, ex := range list(get(node, "examples")) {
				for _, row := range list(get(ex, "tableBody")) {
					out[str(get(row, "id"))] = astNode{line: lineOf(get(row, "location", "line"))}
				}
			}
			for _, st := range list(get(node, "steps")) {
				out[str(get(st, "id"))] = astNode{line: lineOf(get(st, "location", "line")), keyword: str(get(st, "keyword")), step: true}
			}
		}
	}
	walk(children)
	return out
}

var statusOrder = []string{"UNKNOWN", "PASSED", "SKIPPED", "PENDING", "UNDEFINED", "AMBIGUOUS", "FAILED"}

func rank(status string) int {
	if i := slices.Index(statusOrder, status); i >= 0 {
		return i
	}
	return len(statusOrder)
}

func caseStatus(tc, pickle jmap, results []stepResult, lines map[string]astNode, hooks map[string]any) (string, *string) {
	worst := "UNKNOWN"
	var bad *stepResult
	for i, r := range results {
		st := str(get(r.result, "status"))
		if i == 0 || rank(st) > rank(worst) {
			worst = st
		}
	}
	for i := range results {
		if str(get(results[i].result, "status")) == worst {
			bad = &results[i]
			break
		}
	}
	var detail *string
	if worst != "PASSED" && bad != nil {
		d := stepDetail(tc, pickle, bad.step, bad.result, lines, hooks)
		detail = &d
	}
	return strings.ToLower(worst), detail
}

func stepDetail(tc, pickle jmap, stepID string, result any, lines map[string]astNode, hooks map[string]any) string {
	var step any
	for _, ts := range list(get(tc, "testSteps")) {
		if get(ts, "id") == stepID {
			step = ts
			break
		}
	}
	pickleStepID := get(step, "pickleStepId")
	var pstep any
	for _, ps := range list(get(pickle, "steps")) {
		if get(ps, "id") == pickleStepID {
			pstep = ps
			break
		}
	}
	var where string
	var node astNode
	var found bool
	if pstep != nil {
		ids := list(get(pstep, "astNodeIds"))
		if len(ids) == 0 {
			fail()
		}
		node, found = lines[str(ids[0])]
	}
	if found && node.step {
		where = fmt.Sprintf("acceptance.feature line %d: %s %s", node.line, strings.TrimSpace(node.keyword), str(get(pstep, "text")))
	} else if ref, ok := get(hooks[str0(get(step, "hookId"))], "sourceReference").(jmap); ok && get(ref, "uri") != nil && get(ref, "location", "line") != nil {
		where = fmt.Sprintf("a hook at %s line %d", str(ref["uri"]), lineOf(get(ref, "location", "line")))
	} else {
		where = "a hook (location not reported)"
	}
	msg := ""
	if m := get(result, "message"); truthy(m) {
		msg = str(m)
	} else if m := get(result, "exception", "message"); truthy(m) {
		msg = str(m)
	}
	msgLines := strings.Split(msg, "\n")
	msg = strings.Join(msgLines[:min(20, len(msgLines))], "\n")
	if len(msgLines) > 20 {
		msg += fmt.Sprintf("\n[... %d lines omitted ...]", len(msgLines)-20)
	}
	return Cut(trimTrailing(where + "\n" + msg))
}

func str0(v any) string {
	s, _ := v.(string)
	return s
}

var whereRe = regexp.MustCompile(`^(acceptance\.feature line \d+): `)

// bindingProblems: binding evidence must survive a failed assertion in the same scenario.
// Ordinary skipped steps after that assertion are allowed at readiness; missing or ambiguous
// bindings are not.
func bindingProblems(tc, pickle jmap, results []stepResult, lines map[string]astNode) []string {
	var out []string
	for _, r := range results {
		st := str(get(r.result, "status"))
		if st != "UNDEFINED" && st != "AMBIGUOUS" {
			continue
		}
		where, _, _ := strings.Cut(stepDetail(tc, pickle, r.step, r.result, lines, nil), "\n")
		where = whereRe.ReplaceAllString(where, "${1}: "+strings.ToLower(st)+" step: ")
		if !slices.Contains(out, where) {
			out = append(out, where)
		}
	}
	return out
}

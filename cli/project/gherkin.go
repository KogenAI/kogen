package project

import (
	"fmt"
	"regexp"
	"slices"
	"strings"
)

// Step is one Given/When/Then/And/But/* step; Keyword keeps its trailing space ("Then ").
type Step struct {
	Keyword, Text string
	Line          int
}

// Outline records where an Examples-row scenario came from.
type Outline struct {
	Name     string // the outline's own name, with its <placeholders>
	Line     int    // the Scenario Outline line
	Examples int    // Examples rows in the whole outline
}

// Scenario is one scenario of a feature (one per Scenario, one per Examples row of an
// Outline) with the line Cucumber reports for it: for an example, its row.
type Scenario struct {
	Name    string
	Line    int
	Tags    []string // Feature, Rule and own tags (and the Examples block's)
	Steps   []Step   // Background steps first
	Outline *Outline // nil unless the scenario is an Examples row
}

// GherkinError is a feature that cannot be read: the line and the problem.
type GherkinError struct {
	Line    int
	Message string
}

func (e *GherkinError) Error() string { return fmt.Sprintf("line %d: %s", e.Line, e.Message) }

var (
	stepKeywords     = []string{"Given ", "When ", "Then ", "And ", "But ", "* "}
	scenarioKeywords = []string{"Scenario Outline:", "Scenario Template:", "Scenario:", "Example:"}
	examplesKeywords = []string{"Examples:", "Scenarios:"}
	tagCommentRe     = regexp.MustCompile(`\s+#`)
)

type gMode int

const (
	gStart gMode = iota
	gFeature
	gRule
	gBackground
	gBackgroundDesc
	gScenario
	gScenarioDesc
	gExamples
	gExamplesDesc
)

type gRow struct {
	line  int
	cells []string
}

type gExamplesBlock struct {
	line      int
	tags      []string
	header    []string
	hasHeader bool
	rows      []gRow
}

// gCur is the open Background or Scenario.
type gCur struct {
	background bool
	steps      []Step
	name       string
	line       int
	outline    bool
	tags       []string
	examples   []*gExamplesBlock
	bg         []Step // set when the scenario closes
}

type gState struct {
	mode              gMode
	tags, featureTags []string
	ruleTags          []string
	bg, ruleBG        []Step
	cur               *gCur
	out               []*gCur
	docFence          string
	docLine           int
	inRule            bool
}

func gFail(n int, format string, a ...any) {
	panic(&GherkinError{n, fmt.Sprintf(format, a...)})
}

// ParseGherkin reads a `.feature` file (English keywords) far enough to know its scenarios:
// Kogen counts the expected scenarios itself (VER-4) and checks the Intent's acceptance rules
// (SHP-5). An unreadable file is a *GherkinError.
func ParseGherkin(text string) (scenarios []Scenario, err error) {
	defer func() {
		if r := recover(); r != nil {
			ge, ok := r.(*GherkinError)
			if !ok {
				panic(r)
			}
			scenarios, err = nil, ge
		}
	}()
	st := &gState{}
	for i, raw := range strings.Split(text, "\n") {
		st.line(raw, i+1)
	}
	if st.docFence != "" {
		gFail(st.docLine, "the doc string is not closed")
	}
	if st.mode == gStart {
		gFail(1, "the file has no Feature:")
	}
	st.close()
	for _, c := range st.out {
		scenarios = append(scenarios, pickles(c)...)
	}
	return scenarios, nil
}

func hasAnyPrefix(t string, prefixes []string) bool {
	return slices.ContainsFunc(prefixes, func(p string) bool { return strings.HasPrefix(t, p) })
}

func (st *gState) line(raw string, n int) {
	// Inside a doc string everything up to the closing fence is content.
	if st.docFence != "" {
		if strings.TrimSpace(raw) == st.docFence {
			st.docFence = ""
		}
		return
	}
	t := strings.TrimSpace(raw)
	switch {
	case t == "" || strings.HasPrefix(t, "#"):
	case strings.HasPrefix(t, "@"):
		st.tags = append(st.tags, gTags(t, n)...)
	case st.mode == gStart:
		if !strings.HasPrefix(t, "Feature:") {
			gFail(n, "expected Feature:, got: %s", t)
		}
		st.mode, st.featureTags, st.tags = gFeature, st.tags, nil
	case strings.HasPrefix(t, "Background:"):
		st.close()
		st.mode, st.tags = gBackgroundDesc, nil
		st.cur = &gCur{background: true}
	case strings.HasPrefix(t, "Rule:"):
		st.close()
		st.mode, st.ruleTags, st.tags, st.inRule, st.ruleBG = gRule, st.tags, nil, true, nil
	case hasAnyPrefix(t, scenarioKeywords):
		st.close()
		st.scenario(t, n)
	case hasAnyPrefix(t, examplesKeywords):
		st.examples(n)
	case hasAnyPrefix(t, stepKeywords):
		st.step(t, n)
	case strings.HasPrefix(t, "|"):
		st.row(t, n)
	case strings.HasPrefix(t, `"""`) || strings.HasPrefix(t, "```"):
		st.doc(t, n)
	case st.mode == gFeature || st.mode == gRule || st.mode == gBackgroundDesc || st.mode == gScenarioDesc || st.mode == gExamplesDesc:
		// description text
	default:
		gFail(n, "unexpected text: %s", t)
	}
}

func gTags(t string, n int) []string {
	if loc := tagCommentRe.FindStringIndex(t); loc != nil {
		t = t[:loc[0]]
	}
	var tags []string
	for _, f := range strings.Fields(t) {
		if !strings.HasPrefix(f, "@") {
			gFail(n, "a tag must start with @: %s", f)
		}
		tags = append(tags, f)
	}
	return tags
}

func (st *gState) scenario(t string, n int) {
	kw, name, _ := strings.Cut(t, ":")
	var ruleTags []string
	if st.inRule {
		ruleTags = st.ruleTags
	}
	var tags []string
	tags = append(tags, st.featureTags...)
	tags = append(tags, ruleTags...)
	tags = append(tags, st.tags...)
	st.mode, st.tags = gScenarioDesc, nil
	st.cur = &gCur{
		name:    strings.TrimSpace(name),
		line:    n,
		outline: kw == "Scenario Outline" || kw == "Scenario Template",
		tags:    tags,
	}
}

func (st *gState) examples(n int) {
	if st.cur == nil || st.cur.background || !st.cur.outline {
		gFail(n, "Examples: belongs to a Scenario Outline")
	}
	st.cur.examples = append(st.cur.examples, &gExamplesBlock{line: n, tags: st.tags})
	st.mode, st.tags = gExamplesDesc, nil
}

func (st *gState) step(t string, n int) {
	switch {
	case st.cur != nil && st.cur.background:
		st.mode = gBackground
		st.cur.steps = append(st.cur.steps, parseStep(t, n))
	case st.cur != nil && len(st.cur.examples) == 0:
		st.mode = gScenario
		st.cur.steps = append(st.cur.steps, parseStep(t, n))
	default:
		gFail(n, "a step must belong to a Scenario or Background: %s", t)
	}
}

func parseStep(t string, n int) Step {
	for _, kw := range stepKeywords {
		if strings.HasPrefix(t, kw) {
			return Step{Keyword: kw, Text: strings.TrimSpace(strings.TrimPrefix(t, kw)), Line: n}
		}
	}
	panic("unreachable: step without keyword")
}

// row reads a table row: an argument of the last step, or an Examples row.
func (st *gState) row(t string, n int) {
	if st.cur != nil && !st.cur.background && len(st.cur.examples) > 0 {
		cells := gCells(t, n)
		ex := st.cur.examples[len(st.cur.examples)-1]
		if ex.hasHeader {
			ex.rows = append(ex.rows, gRow{n, cells})
		} else {
			ex.header, ex.hasHeader = cells, true
		}
		if len(cells) != len(ex.header) {
			gFail(n, "this row has %d cells, the header %d", len(cells), len(ex.header))
		}
		st.mode = gExamples
		return
	}
	if st.mode == gScenario || st.mode == gBackground {
		gCells(t, n)
		return
	}
	gFail(n, "a table must follow a step or Examples:")
}

func gCells(t string, n int) []string {
	if !strings.HasSuffix(t, "|") {
		gFail(n, "a table row must end with |")
	}
	inner := ""
	if len(t) >= 2 {
		inner = t[1 : len(t)-1]
	}
	var cells []string
	start := 0
	for i := 0; i < len(inner); i++ {
		if inner[i] == '|' && (i == 0 || inner[i-1] != '\\') {
			cells = append(cells, strings.TrimSpace(inner[start:i]))
			start = i + 1
		}
	}
	return append(cells, strings.TrimSpace(inner[start:]))
}

func (st *gState) doc(t string, n int) {
	if st.mode != gScenario && st.mode != gBackground {
		gFail(n, "a doc string must follow a step")
	}
	st.docFence, st.docLine = `"""`, n
	if strings.HasPrefix(t, "```") {
		st.docFence = "```"
	}
}

// close ends the open Background or Scenario.
func (st *gState) close() {
	c := st.cur
	if c == nil {
		return
	}
	st.cur = nil
	if c.background {
		// A Rule's Background adds to the Feature's, for that Rule only.
		if st.inRule {
			st.ruleBG = c.steps
		} else {
			st.bg = c.steps
		}
		return
	}
	if c.outline && !slices.ContainsFunc(c.examples, func(e *gExamplesBlock) bool { return len(e.rows) > 0 }) {
		gFail(c.line, "Scenario Outline %s has no Examples rows", c.name)
	}
	c.bg = slices.Concat(st.bg, st.ruleBG)
	st.out = append(st.out, c)
}

func pickles(s *gCur) []Scenario {
	if !s.outline {
		return []Scenario{{Name: s.name, Line: s.line, Tags: s.tags, Steps: slices.Concat(s.bg, s.steps)}}
	}
	total := 0
	for _, ex := range s.examples {
		total += len(ex.rows)
	}
	var out []Scenario
	for _, ex := range s.examples {
		if !ex.hasHeader {
			continue
		}
		for _, row := range ex.rows {
			subst := func(text string) string {
				for i, k := range ex.header {
					text = strings.ReplaceAll(text, "<"+k+">", row.cells[i])
				}
				return text
			}
			steps := make([]Step, len(s.steps))
			for i, st := range s.steps {
				st.Text = subst(st.Text)
				steps[i] = st
			}
			out = append(out, Scenario{
				Name:    subst(s.name),
				Line:    row.line,
				Tags:    slices.Concat(s.tags, ex.tags),
				Steps:   slices.Concat(s.bg, steps),
				Outline: &Outline{Name: s.name, Line: s.line, Examples: total},
			})
		}
	}
	return out
}

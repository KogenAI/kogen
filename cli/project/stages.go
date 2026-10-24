package project

import (
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"strings"
	"unicode"
)

// Stage is one milestone of an Intent's optional `## Stages` plan: a scoped goal and the
// ordered shell commands that gate it. Stage proof is historical for its tree, never
// delivery.
type Stage struct {
	ID     string
	Title  string
	Goal   string
	Checks []string
}

// Map is the stage as the JSON object the plan declares (keys checks, goal, id, title).
func (s Stage) Map() map[string]any {
	checks := make([]any, len(s.Checks))
	for i, c := range s.Checks {
		checks[i] = c
	}
	return map[string]any{"id": s.ID, "title": s.Title, "goal": s.Goal, "checks": checks}
}

var (
	stagesHeading = regexp.MustCompile(`^## Stages[ \t\r]*$`)
	fenceOpen     = regexp.MustCompile("^ {0,3}(`{3,}|~{3,})")
	stageID       = regexp.MustCompile(`^[a-z0-9]+(?:-[a-z0-9]+)*\n?\z`)
	jsonFence     = regexp.MustCompile("\\A\\s*```json\\s*\\n((?s:.*?))\\n```\\s*\\z")
)

const stagesInvalid = "stages: expected one JSON fence with version 1 and at least two unique stages (id, title, goal, nonempty checks); no extra fields"

// ParseStages reads the Intent's `## Stages` section: nil without an error when there is
// none (the single whole-Intent route), the ordered stages when there is one valid plan, and
// an error whose text starts `stages:` otherwise. Headings inside code fences do not start or
// end a section, a second section is a duplicate and extra fields are refused.
func ParseStages(text string) ([]Stage, error) {
	var sections [][]string
	active, fence := false, ""
	for _, line := range strings.Split(text, "\n") {
		switch {
		case fence == "" && stagesHeading.MatchString(line):
			sections = append(sections, nil)
			active = true
			continue
		case fence == "" && strings.HasPrefix(line, "## "):
			active = false
			continue
		}
		if active {
			sections[len(sections)-1] = append(sections[len(sections)-1], line)
		}
		if fence != "" {
			closing := regexp.MustCompile("^ {0,3}" + regexp.QuoteMeta(fence) + regexp.QuoteMeta(fence[:1]) + "*[ \\t\\r]*$")
			if closing.MatchString(line) {
				fence = ""
			}
		} else if m := fenceOpen.FindStringSubmatch(line); m != nil {
			fence = m[1]
		}
	}
	switch len(sections) {
	case 0:
		return nil, nil
	case 1:
		return decodeStages(strings.Join(sections[0], "\n"))
	}
	return nil, errors.New("stages: duplicate ## Stages sections")
}

func decodeStages(body string) ([]Stage, error) {
	bad := errors.New(stagesInvalid)
	m := jsonFence.FindStringSubmatch(body)
	if m == nil {
		return nil, bad
	}
	d := json.NewDecoder(strings.NewReader(m[1]))
	d.UseNumber()
	var doc any
	if err := d.Decode(&doc); err != nil {
		return nil, bad
	}
	if _, err := d.Token(); !errors.Is(err, io.EOF) {
		return nil, bad
	}
	plan, ok := doc.(map[string]any)
	if !ok || len(plan) != 2 {
		return nil, bad
	}
	version, ok := plan["version"].(json.Number)
	list, listOK := plan["stages"].([]any)
	if !ok || version.String() != "1" || !listOK || len(list) < 2 {
		return nil, bad
	}
	var out []Stage
	seen := map[string]bool{}
	for _, entry := range list {
		s, ok := stageOf(entry)
		if !ok || seen[s.ID] {
			return nil, bad
		}
		seen[s.ID] = true
		out = append(out, s)
	}
	return out, nil
}

func stageOf(v any) (Stage, bool) {
	m, ok := v.(map[string]any)
	if !ok || len(m) != 4 {
		return Stage{}, false
	}
	id, idOK := m["id"].(string)
	title, titleOK := m["title"].(string)
	goal, goalOK := m["goal"].(string)
	checks, checksOK := m["checks"].([]any)
	if !idOK || !titleOK || !goalOK || !checksOK || !stageID.MatchString(id) ||
		!nonblank(title) || !nonblank(goal) || len(checks) == 0 {
		return Stage{}, false
	}
	s := Stage{ID: id, Title: title, Goal: goal}
	for _, c := range checks {
		text, ok := c.(string)
		if !ok || !nonblank(text) {
			return Stage{}, false
		}
		s.Checks = append(s.Checks, text)
	}
	return s, true
}

func nonblank(s string) bool { return strings.TrimFunc(s, unicode.IsSpace) != "" }

// stagesProblem is the lint problem of a malformed plan, or "" for no plan or a valid one.
func stagesProblem(text string) string {
	if _, err := ParseStages(text); err != nil {
		return err.Error()
	}
	return ""
}

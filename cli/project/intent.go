package project

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"unicode"

	"kogen-loop/sys"
)

// Intent is `.kogen/intents/<slug>/intent.md` as read: `intent.md`, `acceptance.feature` and an
// optional `model.qnt`, plus the step files its `Acceptance:` list names (chapter 02). Fields
// whose line or section is missing are empty.
type Intent struct {
	Root, Slug, Text string
	SlugLine         string // the Slug: line's text, as written
	Title            string
	ModelLine        string     // the Model: line's text
	Model            *ModelSpec // nil when the Model: line is missing or unreadable
	Acceptance       []string   // the Acceptance: list
	Decisions        []string   // ## Decisions bullet lines
	Feasibility      []string   // ## Feasibility bullet lines
	Tests            []string   // ## Tests bullet lines
	Overlay          map[string][]byte
}

// ModelSpec is the parsed Model: line: either `not applicable — <reason>` (None) or a Quint model
// with the invariants to check and the sampling numbers (digits, as written).
type ModelSpec struct {
	None                 bool
	Path                 string
	Invariants           []string
	Seed, Samples, Steps string
}

// Forbidden scenario tags (SHP-5).
var forbiddenTags = []string{"@skip", "@wip", "@pending", "@manual", "@ignore"}

// IntentDir is the Intent's folder, relative to the repository root.
func IntentDir(slug string) string { return ".kogen/intents/" + slug }

// FeaturePath is the Intent's `acceptance.feature`, relative to the repository root.
func FeaturePath(slug string) string { return IntentDir(slug) + "/acceptance.feature" }

// IntentMDPath is the Intent's `intent.md`, relative to the repository root.
func IntentMDPath(slug string) string { return IntentDir(slug) + "/intent.md" }

// ModelPath is the Intent's `model.qnt`, relative to the repository root.
func ModelPath(slug string) string { return IntentDir(slug) + "/model.qnt" }

// IntentExists reports whether the Intent has an `intent.md`.
func IntentExists(root, slug string) bool {
	_, err := os.Stat(filepath.Join(root, IntentMDPath(slug)))
	return err == nil
}

// RequireIntentDir fails with intent/not_found when the Intent's folder does not exist.
func RequireIntentDir(root, slug string) error {
	if fi, err := os.Stat(filepath.Join(root, IntentDir(slug))); err != nil || !fi.IsDir() {
		return sys.Fail("intent", "not_found", "Intent does not exist", 2)
	}
	return nil
}

// fetch is a file's content from the overlay of files not yet written, or from the disk.
func fetch(root string, overlay map[string][]byte, rel string) ([]byte, error) {
	if b, ok := overlay[rel]; ok {
		return b, nil
	}
	return os.ReadFile(filepath.Join(root, rel))
}

// Fetch is a project file's content from overlay (files not yet written) or the disk.
func Fetch(root string, overlay map[string][]byte, rel string) ([]byte, error) {
	return fetch(root, overlay, rel)
}

func parseError(problems ...string) *sys.Error {
	e := sys.Fail("intent", "parse", "the Intent cannot be read", 1)
	e.Lines = problems
	return e
}

// LoadIntent reads the Intent from disk.
func LoadIntent(root, slug string) (*Intent, error) { return ReadIntent(root, slug, nil) }

// ReadIntent reads intent.md from overlay or disk. A missing intent.md is an intent/parse error.
func ReadIntent(root, slug string, overlay map[string][]byte) (*Intent, error) {
	b, err := fetch(root, overlay, IntentMDPath(slug))
	if err != nil {
		return nil, parseError("intent.md does not exist")
	}
	return parseIntent(root, slug, string(b), overlay), nil
}

func parseIntent(root, slug, text string, overlay map[string][]byte) *Intent {
	lines := strings.Split(text, "\n")
	i := &Intent{Root: root, Slug: slug, Text: text, Overlay: overlay}
	if v, ok := firstWithPrefix(lines, "# "); ok {
		i.Title = strings.TrimSpace(v)
	}
	if v, ok := firstWithPrefix(lines, "Model:"); ok {
		i.ModelLine = strings.TrimSpace(v)
		i.Model = ParseModelSpec(i.ModelLine)
	}
	i.SlugLine, _ = firstWithPrefix(lines, "Slug:")
	i.Acceptance = listAfter(lines, "Acceptance:")
	i.Decisions = sectionBullets(lines, "## Decisions")
	i.Feasibility = sectionBullets(lines, "## Feasibility")
	i.Tests = sectionBullets(lines, "## Tests")
	return i
}

func firstWithPrefix(lines []string, prefix string) (string, bool) {
	for _, l := range lines {
		if rest, ok := strings.CutPrefix(l, prefix); ok {
			return rest, true
		}
	}
	return "", false
}

func afterHeader(lines []string, header string) ([]string, bool) {
	for i, l := range lines {
		if strings.TrimSpace(l) == header {
			return lines[i+1:], true
		}
	}
	return nil, false
}

// listAfter is the `- ` bullets right after a header line, skipping blank lines before the first.
func listAfter(lines []string, header string) []string {
	rest, ok := afterHeader(lines, header)
	if !ok {
		return nil
	}
	for len(rest) > 0 && strings.TrimSpace(rest[0]) == "" {
		rest = rest[1:]
	}
	var out []string
	for _, l := range rest {
		item, ok := strings.CutPrefix(l, "- ")
		if !ok {
			break
		}
		out = append(out, strings.TrimSpace(item))
	}
	return out
}

// sectionBullets is the `- ` lines of a section, up to the next line starting with #.
func sectionBullets(lines []string, header string) []string {
	rest, ok := afterHeader(lines, header)
	if !ok {
		return nil
	}
	var out []string
	for _, l := range rest {
		if strings.HasPrefix(l, "#") {
			break
		}
		if strings.HasPrefix(l, "- ") {
			out = append(out, l)
		}
	}
	return out
}

var modelLineRe = regexp.MustCompile(`^(\S+\.qnt) invariants=([A-Za-z_][A-Za-z0-9_]*(?:,[A-Za-z_][A-Za-z0-9_]*)*) seed=(\d+) samples=(\d+) steps=(\d+)$`)

// ParseModelSpec parses a Model: line; nil when it cannot be read.
func ParseModelSpec(line string) *ModelSpec {
	if notApplicable(line) {
		return &ModelSpec{None: true}
	}
	m := modelLineRe.FindStringSubmatch(line)
	if m == nil {
		return nil
	}
	return &ModelSpec{Path: m[1], Invariants: strings.Split(m[2], ","), Seed: m[3], Samples: m[4], Steps: m[5]}
}

// notApplicable matches `not applicable — <reason>` (an em dash or a hyphen, then a reason).
func notApplicable(line string) bool {
	rest, ok := strings.CutPrefix(line, "not applicable")
	if !ok {
		return false
	}
	rest = trimLeftSpace(rest)
	if r, ok := strings.CutPrefix(rest, "—"); ok {
		rest = r
	} else if r, ok := strings.CutPrefix(rest, "-"); ok {
		rest = r
	} else {
		return false
	}
	rest = trimLeftSpace(rest)
	return rest != ""
}

// StepFiles are the step files and other acceptance files after the feature.
func (i *Intent) StepFiles() []string {
	feature := FeaturePath(i.Slug)
	return slices.DeleteFunc(slices.Clone(i.Acceptance), func(p string) bool { return p == feature })
}

// CheckIntent checks the SHP-5 rules on the Intent with overlay (files not yet written) laid over
// the disk. It returns the Intent and its scenarios, or an *sys.Error `intent/parse: the Intent
// cannot be read` / `intent/lint: the Intent needs changes` (exit 1) with one line per problem.
func CheckIntent(root, slug string, overlay map[string][]byte) (*Intent, []Scenario, error) {
	if _, err := fetch(root, overlay, IntentMDPath(slug)); err != nil {
		return nil, nil, parseError("intent.md does not exist")
	}
	intent, err := ReadIntent(root, slug, overlay)
	if err != nil {
		return nil, nil, err
	}
	b, err := fetch(root, overlay, FeaturePath(slug))
	if err != nil {
		return nil, nil, parseError("acceptance.feature does not exist")
	}
	scenarios, err := ParseGherkin(string(b))
	if err != nil {
		ge := err.(*GherkinError)
		return nil, nil, parseError(fmt.Sprintf("acceptance.feature line %d: %s", ge.Line, ge.Message))
	}
	if problems := lintIntent(intent, scenarios); len(problems) > 0 {
		e := sys.Fail("intent", "lint", "the Intent needs changes", 1)
		e.Lines = problems
		return nil, nil, e
	}
	return intent, scenarios, nil
}

var (
	sourceRe   = regexp.MustCompile(`\(source: (request|answer \d+)\)\s*$`)
	testLineRe = regexp.MustCompile(`^- (none: \S.*|.+: .+ \((unit|integration|scenario|regression|existing)\))$`)
)

func lintIntent(i *Intent, scenarios []Scenario) []string {
	var problems []string
	add := func(p ...string) { problems = append(problems, p...) }

	switch {
	case i.Title == "":
		add("title: intent.md must start with a # title")
	case graphemeLen(i.Title) > 50:
		add("title: the title must be at most 50 characters")
	case strings.HasSuffix(i.Title, "."):
		add("title: the title must not end with a period")
	}

	if strings.TrimSpace(i.SlugLine) != i.Slug {
		add("slug: the Slug: line must be " + i.Slug)
	}

	switch {
	case i.Model == nil:
		add("model: the Model: line must be `not applicable — <reason>` or `" + ModelPath(i.Slug) + " invariants=<Name> seed=<n> samples=<n> steps=<n>`")
	case !i.Model.None:
		add(modelProblems(i, i.Model)...)
	}

	switch {
	case len(i.Tests) == 0:
		add("tests: the ## Tests section is missing or empty")
	default:
		for _, l := range i.Tests {
			if !testLineRe.MatchString(l) {
				add("tests: " + l + " must be `- <rule>: <test to add or update> (<layer>)` or `- none: <reason>`")
			}
		}
	}

	feature := FeaturePath(i.Slug)
	if len(i.Acceptance) > 0 && i.Acceptance[0] == feature {
		ignored := gitIgnored(i.Root, i.Acceptance)
		for _, p := range i.Acceptance {
			_, inOverlay := i.Overlay[p]
			switch {
			case !inOverlay && !isRegular(filepath.Join(i.Root, p)):
				add("acceptance: " + p + " does not exist")
			case ignored[p]:
				add("acceptance: " + p + " is ignored by Git")
			}
		}
	} else {
		add("acceptance: the Acceptance: list must start with " + feature)
	}

	for _, d := range i.Decisions {
		if !sourceRe.MatchString(d) {
			add("decisions: a decision has no source")
			break
		}
	}

	if len(i.Feasibility) == 0 {
		add("feasibility: intent.md needs a ## Feasibility section listing each probe, or - none")
	}

	if len(scenarios) == 0 {
		add("acceptance: acceptance.feature has no scenario")
	} else {
		var scen []string
		for _, s := range scenarios {
			for _, t := range s.Tags {
				if slices.Contains(forbiddenTags, t) {
					scen = append(scen, "acceptance: scenario "+s.Name+" is tagged "+t)
				}
			}
			if !slices.ContainsFunc(s.Steps, func(st Step) bool { return st.Keyword == "Then " }) {
				scen = append(scen, "acceptance: scenario "+s.Name+" has no Then step")
			}
		}
		add(uniqStrings(scen)...)
	}

	if p := stagesProblem(i.Text); p != "" {
		add(p)
	}
	return problems
}

func modelProblems(i *Intent, m *ModelSpec) []string {
	expected := ModelPath(i.Slug)
	if m.Path != expected {
		return []string{"model: the model must be " + expected}
	}
	b, err := fetch(i.Root, i.Overlay, m.Path)
	if err != nil {
		return []string{"model: " + m.Path + " does not exist"}
	}
	var out []string
	for _, inv := range m.Invariants {
		if !regexp.MustCompile(`\b(val|def)\s+` + inv + `\b`).Match(b) {
			out = append(out, "model: invariant "+inv+" does not exist in model.qnt")
		}
	}
	return out
}

func isRegular(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Mode().IsRegular()
}

func uniqStrings(ss []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range ss {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

// gitIgnored asks Git which of paths are ignored, whether or not they are tracked
// (`git check-ignore --no-index`). Any Git failure means none.
func gitIgnored(root string, paths []string) map[string]bool {
	cmd := exec.Command("git", append([]string{"check-ignore", "--no-index", "--"}, paths...)...)
	cmd.Dir = root
	out, err := cmd.Output()
	if err != nil {
		return nil
	}
	ignored := map[string]bool{}
	for _, l := range strings.Split(string(out), "\n") {
		if l != "" {
			ignored[l] = true
		}
	}
	return ignored
}

// graphemeLen counts user-perceived characters: a base character with its combining marks, a
// zero-width-joiner emoji sequence or a pair of regional indicators is one.
func graphemeLen(s string) int {
	n, ri := 0, 0 // ri: regional indicators so far in the current run
	var prev rune
	for _, r := range s {
		attach := false
		switch {
		case n == 0:
		case prev == '\r' && r == '\n':
			attach = true
		case unicode.In(r, unicode.Mn, unicode.Me, unicode.Mc),
			r == 0x200C, r == 0x200D, r >= 0x1F3FB && r <= 0x1F3FF, r >= 0xE0020 && r <= 0xE007F:
			attach = true
		case prev == 0x200D && isPictographic(r):
			attach = true
		case isRegionalIndicator(r) && ri%2 == 1:
			attach = true
		}
		if isRegionalIndicator(r) {
			ri++
		} else {
			ri = 0
		}
		if !attach {
			n++
		}
		prev = r
	}
	return n
}

func isRegionalIndicator(r rune) bool { return r >= 0x1F1E6 && r <= 0x1F1FF }

func isPictographic(r rune) bool {
	return r >= 0x1F300 && r <= 0x1FAFF || r >= 0x2600 && r <= 0x27BF || r == 0x2764 || r == 0x2B50
}

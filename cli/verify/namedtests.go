package verify

import (
	"encoding/json"
	"fmt"
	"regexp"
	"slices"
	"strings"
)

// A step that requires named tests to have run (acceptance helpers that run `go test -json`
// for a test id given as a step argument) reports a bare assertion when they did not, such as
// "must run exactly once: 0 !== 1". Feedback for such a failed step also names the required
// ids, the command or package the acceptance ran them in and the step definition, derived
// from the step's arguments and the run's own output rather than the assertion's wording.

// stepDefinition is where a step definition is declared, as the report gives it.
type stepDefinition struct {
	uri  string
	line int
}

var (
	testIDRe      = regexp.MustCompile(`^(Test|Fuzz|Example)([^a-z]\w*)?$`)
	packageArgRe  = regexp.MustCompile(`^(\.{1,2}(/\S*)?|[\w.-]+(/[\w.-]+)+)$`)
	runSelectorRe = regexp.MustCompile(`-run[= ]\s*(?:'([^']*)'|"([^"]*)"|(\S+))`)
	goTestCommand = regexp.MustCompile(`go test\b[^;\n"]*`)
	selectorPunct = strings.NewReplacer("^", "", "$", "", "(", "", ")", "")
)

const maxNamedReason = 16

func num(v any) float64 {
	f, _ := v.(float64)
	return f
}

// goRows is what a `go test` run's output, as embedded in a failure message, shows.
type goRows struct {
	runs, skips map[string]int
	packages    []string
	noTests     bool
	seen        bool // any `go test -json` row
}

func parseGoRows(msg string) goRows {
	g := goRows{runs: map[string]int{}, skips: map[string]int{}}
	for _, line := range strings.Split(msg, "\n") {
		line = strings.TrimSpace(line)
		var row struct {
			Action, Package, Test, Output string
		}
		if !strings.HasPrefix(line, "{") || json.Unmarshal([]byte(line), &row) != nil || row.Action == "" {
			g.noTests = g.noTests || strings.Contains(line, "no tests to run")
			continue
		}
		g.seen = true
		if row.Package != "" && !slices.Contains(g.packages, row.Package) {
			g.packages = append(g.packages, row.Package)
		}
		g.noTests = g.noTests || strings.Contains(row.Output, "no tests to run")
		switch {
		case row.Test == "":
		case row.Action == "run":
			g.runs[row.Test]++
		case row.Action == "skip":
			g.skips[row.Test]++
		}
	}
	return g
}

// missingNamedTests is the feedback block for a failed step whose required tests did not run,
// or "" when the step names no tests or they all ran. The ids come from the step's arguments
// and from `-run` selectors in the failure message.
func missingNamedTests(tc jmap, results []stepResult, defs map[string]stepDefinition) string {
	_, bad := worstStep(results)
	if bad == nil {
		return ""
	}
	msg := str0(get(bad.result, "message"))
	if msg == "" {
		msg = str0(get(bad.result, "exception", "message"))
	}
	var step jmap
	for _, ts := range list(get(tc, "testSteps")) {
		if m, ok := ts.(jmap); ok && m["id"] == bad.step {
			step = m
			break
		}
	}
	var ids, packages []string
	for _, l := range list(get(step, "stepMatchArgumentsLists")) {
		for _, a := range list(get(l, "stepMatchArguments")) {
			v, ok := get(a, "group", "value").(string)
			if !ok {
				continue
			}
			v = strings.Trim(v, `"'`)
			switch {
			case testIDRe.MatchString(v):
				if !slices.Contains(ids, v) {
					ids = append(ids, v)
				}
			case packageArgRe.MatchString(v):
				if !slices.Contains(packages, v) {
					packages = append(packages, v)
				}
			}
		}
	}
	for _, m := range runSelectorRe.FindAllStringSubmatch(msg, -1) {
		for _, sel := range strings.Split(selectorPunct.Replace(m[1]+m[2]+m[3]), "|") {
			id, _, _ := strings.Cut(sel, "/")
			if testIDRe.MatchString(id) && !slices.Contains(ids, id) {
				ids = append(ids, id)
			}
		}
	}
	rows := parseGoRows(msg)
	// A test-like argument alone ("Example", "TestUser") is not a required test: the step must
	// also name a package or its failure must show a go test run.
	ran := len(packages) > 0 || rows.seen || rows.noTests || goTestCommand.MatchString(msg) || runSelectorRe.MatchString(msg)
	if len(ids) == 0 || !ran {
		return ""
	}
	var lines []string
	for _, id := range ids {
		switch {
		case rows.skips[id] > 0:
			lines = append(lines, id+": skipped")
		case rows.runs[id] > 0:
		case rows.noTests:
			lines = append(lines, id+": did not run (no tests to run)")
		case rows.seen:
			lines = append(lines, id+": did not run (no run of it in the go test output)")
		default:
			lines = append(lines, id+": did not run (the failure shows no run of it)")
		}
	}
	if len(lines) == 0 {
		return ""
	}
	if len(lines) > maxNamedReason {
		lines = append(lines[:maxNamedReason], fmt.Sprintf("[... %d more required tests omitted ...]", len(lines)-maxNamedReason))
	}
	ranIn := slices.Clone(packages)
	if c := strings.TrimSpace(goTestCommand.FindString(msg)); c != "" {
		ranIn = append([]string{c}, ranIn...)
	}
	for _, p := range rows.packages {
		ranIn = append(ranIn, "package "+p)
	}
	where := "not reported"
	if len(ranIn) > 0 {
		where = strings.Join(ranIn, "; ")
	}
	def := "not reported"
	if refs := list(get(step, "stepDefinitionIds")); len(refs) == 1 {
		if d, ok := defs[str0(refs[0])]; ok && d.uri != "" {
			def = fmt.Sprintf("%s line %d", d.uri, d.line)
		}
	}
	return "\nrequired tests that did not run (from the step's arguments and the acceptance output):\n  " +
		strings.Join(lines, "\n  ") + "\nacceptance ran them in: " + where + "\nstep definition: " + def
}

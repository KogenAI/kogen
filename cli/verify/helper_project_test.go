package verify

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen/project"
	"kogen/sys"
)

const fixtureSlug = "fixture"

const fixtureFeature = "Feature: Fixture\n  Scenario: First\n    Then the candidate succeeds\n  Scenario: Later\n    Then the candidate succeeds\n"

// proj is a repository with one committed Intent `fixture` whose acceptance command is a
// small shell script reading a prepared Cucumber Messages report: green unless app.txt
// holds `red`. Tests that need a real runner use realProject instead.
type proj struct {
	*fixture
	Config *project.Config
	Intent *project.Intent
	Aux    string // a folder outside the repository (reports, traces)
	Green  string
	Red    string
}

func intentMD(model string, feasibility string) string {
	if feasibility == "" {
		feasibility = "- none"
	}
	return "# Fixture intent\n\nSlug: " + fixtureSlug + "\nModel: " + model + "\nAcceptance:\n- " + project.FeaturePath(fixtureSlug) +
		"\n- features/steps/fixture_steps.js\n\nThe fixture.\n\n## Decisions\n- Fixture decision. (source: request)\n\n## Tests\n- none: fixture\n\n## Feasibility\n" + feasibility + "\n"
}

func writeIntent(f *fixture, model, feasibility string) {
	f.write(project.IntentMDPath(fixtureSlug), intentMD(model, feasibility))
	f.write(project.FeaturePath(fixtureSlug), fixtureFeature)
	if _, err := os.Stat(filepath.Join(f.Root, "features/steps/fixture_steps.js")); err != nil {
		f.write("features/steps/fixture_steps.js", "// steps\n")
	}
}

func newProj(t *testing.T) *proj { return newProjIn(t, "") }

func newProjIn(t *testing.T, name string) *proj {
	t.Helper()
	f := newFixtureIn(t, name)
	p := &proj{fixture: f, Aux: t.TempDir()}
	f.write(".gitignore", ".kogen/local/\nbuild/\n")
	f.write("app.txt", "green\n")
	f.write(".kogen/project.yaml", "commands:\n  acceptance:\n    run: ./accept.sh\n")
	writeIntent(f, "not applicable — nothing to model", "")
	expected, err := project.ParseGherkin(fixtureFeature)
	if err != nil {
		t.Fatal(err)
	}
	p.Green = writeReport(t, p.Aux, "green.ndjson", simpleMessages(project.FeaturePath(fixtureSlug), expected, reportOpts{}))
	p.Red = writeReport(t, p.Aux, "red.ndjson", simpleMessages(project.FeaturePath(fixtureSlug), expected, reportOpts{results: statuses("FAILED")}))
	run := fmt.Sprintf(`if grep -qx red app.txt; then cp '%s' "$KOGEN_ACCEPTANCE_REPORT"; echo actual-case-red; exit 1; fi; cp '%s' "$KOGEN_ACCEPTANCE_REPORT"`, p.Red, p.Green)
	p.Config = &project.Config{Acceptance: &project.Acceptance{Run: run}}
	f.commit("fixture project")
	intent, _, err := project.CheckIntent(f.Root, fixtureSlug, nil)
	if err != nil {
		t.Fatal(err)
	}
	p.Intent = intent
	return p
}

// input is a pass input for the project at its current HEAD.
func (p *proj) input(n int) Input {
	return Input{Root: p.Root, Repo: p.Repo, Config: p.Config, Intent: p.Intent, Start: p.head(), N: n}
}

// setModel rewrites the Intent's Model: line and reloads it.
func (p *proj) setModel(line string, files map[string]string) {
	p.t.Helper()
	writeIntent(p.fixture, line, "")
	for path, text := range files {
		p.write(path, text)
	}
	intent, _, err := project.CheckIntent(p.Root, fixtureSlug, nil)
	if err != nil {
		p.t.Fatal(err)
	}
	p.Intent = intent
}

func (p *proj) trace(name string) string { return filepath.Join(p.Aux, name) }

// ran is the lines a command wrote to a trace file.
func (p *proj) ran(name string) []string {
	b, err := os.ReadFile(p.trace(name))
	if err != nil {
		return nil
	}
	return strings.Fields(string(b))
}

func appendTo(path, line string) string {
	return fmt.Sprintf("printf '%%s\\n' %s >> %s", shellQuote(line), shellQuote(path))
}

func requireNoLeftovers(t *testing.T, tmp string) {
	t.Helper()
	for _, prefix := range []string{"kogen-verify", "kogen-readiness", "kogen-dry-run", "kogen-runner-check", "kogen-probe", "kogen-index"} {
		if l := leftovers(t, tmp, prefix); len(l) != 0 {
			t.Fatalf("left behind in the temporary folder: %v", l)
		}
	}
}

var _ = sys.Fail

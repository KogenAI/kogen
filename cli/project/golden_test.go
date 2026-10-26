package project

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"kogen-loop/sys"
)

// golden.json holds the results of the Elixir Kogen for the inputs below, generated once by
// testdata/golden-gen.exs. Every Go result must equal its Elixir result.

type goldenError struct {
	Class, Reason, Detail string
	Exit                  int
	Lines                 []string
}

type golden struct {
	Config []struct {
		Text   string
		Result struct {
			Config map[string]any
			Error  *goldenError
		}
	}
	Render []struct {
		Input struct {
			Setup, Fix, Protect []string
			Checks              [][2]string
			Acceptance          *[2]string
		}
		Text   string
		Parsed map[string]any
	}
	Yaml []struct {
		Text   string
		Result struct {
			Ok    any
			Error *[2]any
		}
	}
	Gherkin []struct {
		Text   string
		Result struct {
			Scenarios []map[string]any
			Error     *[2]any
		}
	}
	Intent []struct {
		Label   string
		Overlay map[string]string
		Result  struct {
			Ok       map[string]any
			Problems []string
		}
	}
	IntentRead []struct {
		Text   string
		Result map[string]any
	} `json:"intent_read"`
	Detect []struct {
		Files   map[string]string
		Tracked []string
		Result  map[string]any
	}
	Acceptance map[string]string
}

func loadGolden(t *testing.T) *golden {
	t.Helper()
	b, err := os.ReadFile("testdata/golden.json")
	if err != nil {
		t.Fatal(err)
	}
	var g golden
	if err := json.Unmarshal(b, &g); err != nil {
		t.Fatal(err)
	}
	return &g
}

// canon re-encodes a value as JSON so structurally equal values compare equal as strings;
// nil slices and empty slices are the same, and so are null and "" for strings.
func canon(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var back any
	json.Unmarshal(b, &back)
	b, _ = json.Marshal(back)
	return string(b)
}

func list(ss []string) []any {
	out := []any{}
	for _, s := range ss {
		out = append(out, s)
	}
	return out
}

func orNull(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func roleJSON(r Role) map[string]any {
	return map[string]any{"model": r.Model, "effort": r.Effort, "provider": orNull(r.Provider)}
}

// configJSON is a Config in the shape golden-gen.exs normalizes the Elixir struct to.
func configJSON(c *Config) map[string]any {
	checks := []any{}
	for _, ch := range c.Checks {
		checks = append(checks, []any{ch.Name, ch.Run})
	}
	models := map[string]any{}
	for k, r := range c.Models {
		models[k] = roleJSON(r)
	}
	workers := map[string]any{"enabled": c.ShapeWorkers.Enabled}
	for k, r := range c.ShapeWorkers.Roles {
		workers[k] = roleJSON(r)
	}
	var run, steps any = "", ""
	if c.Acceptance != nil {
		run, steps = c.Acceptance.Run, c.Acceptance.StepsDir
	}
	return map[string]any{
		"setup": list(c.Setup), "fix": list(c.Fix), "checks": checks,
		"acceptance_run": run, "steps_dir": steps,
		"protect": list(c.Protect), "models": models, "shape_workers": workers,
	}
}

// elixirConfig turns the Elixir result's nulls for acceptance into "" (a Go Acceptance holds strings).
func elixirConfig(m map[string]any) map[string]any {
	for _, k := range []string{"acceptance_run", "steps_dir"} {
		if m[k] == nil {
			m[k] = ""
		}
	}
	return m
}

var (
	allowlistLine = regexp.MustCompile(`^line \d+: (models|shape_workers)\.(\w+): (supergrok|opencode-go|anthropic) supports `)
	requiresLine  = regexp.MustCompile(`^line \d+: shape_workers\.(\w+) requires explicit model and effort$`)
)

// openModelSelection is main's expected configuration error under the one approved change to
// configuration (KOGEN-057, intent go-core-migration "Open model selection"): the model and
// effort allowlist refusals are gone, a shape worker they refused now counts as configured,
// and the provider list names openai-compatible. accepted reports that nothing is left to
// refuse. The golden file itself stays exactly what main's Elixir produced.
func openModelSelection(want *goldenError) (*goldenError, bool) {
	refused := map[string]bool{}
	var kept []string
	dropped := false
	for _, l := range want.Lines {
		if m := allowlistLine.FindStringSubmatch(l); m != nil {
			dropped = true
			if m[1] == "shape_workers" {
				refused[m[2]] = true
			}
			continue
		}
		kept = append(kept, l)
	}
	var lines []string
	for _, l := range kept {
		if m := requiresLine.FindStringSubmatch(l); m != nil && refused[m[1]] {
			continue
		}
		lines = append(lines, strings.Replace(l, "must be chatgpt, supergrok, opencode-go or anthropic",
			"must be chatgpt, supergrok, opencode-go, anthropic or openai-compatible", 1))
	}
	if dropped && len(lines) == 0 {
		return nil, true
	}
	c := *want
	c.Lines = lines
	return &c, false
}

func TestConfigMatchesElixir(t *testing.T) {
	g := loadGolden(t)
	if len(g.Config) < 100 {
		t.Fatalf("golden has %d config cases", len(g.Config))
	}
	for i, c := range g.Config {
		cfg, err := ParseConfig(c.Text, "/p/.kogen/project.yaml")
		accepted := false
		if c.Result.Error != nil {
			c.Result.Error, accepted = openModelSelection(c.Result.Error)
		}
		switch {
		case accepted:
			// Main refused this only for its model allowlist, which KOGEN-057 removed.
			if err != nil {
				t.Errorf("case %d %q: KOGEN-057 accepts any model and effort, got %v", i, c.Text, err)
			}
		case c.Result.Error != nil:
			se, ok := sys.AsError(err)
			if !ok {
				t.Errorf("case %d %q: got %v, want error %+v", i, c.Text, err, c.Result.Error)
				continue
			}
			want := c.Result.Error
			if se.Class != want.Class || se.Reason != want.Reason || se.Detail != want.Detail || se.Exit != want.Exit ||
				canon(t, list(se.Lines)) != canon(t, list(want.Lines)) {
				t.Errorf("case %d %q:\n got %s/%s %q exit %d %q\nwant %+v", i, c.Text, se.Class, se.Reason, se.Detail, se.Exit, se.Lines, *want)
			}
		case err != nil:
			t.Errorf("case %d %q: unexpected error %v", i, c.Text, err)
		default:
			if got, want := canon(t, configJSON(cfg)), canon(t, elixirConfig(c.Result.Config)); got != want {
				t.Errorf("case %d %q:\n got %s\nwant %s", i, c.Text, got, want)
			}
		}
	}
}

func TestRenderMatchesElixir(t *testing.T) {
	g := loadGolden(t)
	for i, c := range g.Render {
		cfg := &Config{Setup: c.Input.Setup, Fix: c.Input.Fix, Protect: c.Input.Protect}
		for _, ch := range c.Input.Checks {
			cfg.Checks = append(cfg.Checks, Check{ch[0], ch[1]})
		}
		if a := c.Input.Acceptance; a != nil {
			cfg.Acceptance = &Acceptance{a[0], a[1]}
		}
		got := RenderConfig(cfg)
		if got != c.Text {
			t.Errorf("case %d:\n got %q\nwant %q", i, got, c.Text)
		}
		parsed, err := ParseConfig(got, "r")
		if err != nil {
			t.Errorf("case %d: rendered text does not parse: %v", i, err)
			continue
		}
		if g, w := canon(t, configJSON(parsed)), canon(t, elixirConfig(c.Parsed)); g != w {
			t.Errorf("case %d parsed:\n got %s\nwant %s", i, g, w)
		}
	}
}

func yamlJSON(n *yamlNode) any {
	switch n.kind {
	case kindMap:
		pairs := []any{}
		for _, p := range n.pairs {
			pairs = append(pairs, []any{p.key, p.line, yamlJSON(p.node)})
		}
		return []any{"map", n.line, pairs}
	case kindSeq:
		items := []any{}
		for _, it := range n.items {
			items = append(items, yamlJSON(it))
		}
		return []any{"seq", n.line, items}
	}
	kind := "plain"
	if n.quoted {
		kind = "quoted"
	}
	var text any = n.text
	if n.null {
		text = nil
	}
	return []any{"scalar", n.line, text, kind}
}

func TestYAMLMatchesElixir(t *testing.T) {
	g := loadGolden(t)
	for i, c := range g.Yaml {
		node, problems := parseYAML(c.Text)
		if c.Result.Error != nil {
			if node != nil || len(problems) != 1 || canon(t, []any{problems[0].line, problems[0].msg}) != canon(t, *c.Result.Error) {
				t.Errorf("case %d %q: got %v %v, want error %v", i, c.Text, node, problems, *c.Result.Error)
			}
			continue
		}
		if node == nil {
			t.Errorf("case %d %q: got problems %v", i, c.Text, problems)
			continue
		}
		if got, want := canon(t, yamlJSON(node)), canon(t, c.Result.Ok); got != want {
			t.Errorf("case %d %q:\n got %s\nwant %s", i, c.Text, got, want)
		}
	}
}

func scenarioJSON(s Scenario) map[string]any {
	steps := []any{}
	for _, st := range s.Steps {
		steps = append(steps, []any{st.Keyword, st.Text, st.Line})
	}
	var outline any
	if s.Outline != nil {
		outline = []any{s.Outline.Name, s.Outline.Line, s.Outline.Examples}
	}
	return map[string]any{"name": s.Name, "line": s.Line, "tags": list(s.Tags), "steps": steps, "outline": outline}
}

func TestGherkinMatchesElixir(t *testing.T) {
	g := loadGolden(t)
	for i, c := range g.Gherkin {
		scenarios, err := ParseGherkin(c.Text)
		if c.Result.Error != nil {
			ge, ok := err.(*GherkinError)
			if !ok || canon(t, []any{ge.Line, ge.Message}) != canon(t, *c.Result.Error) {
				t.Errorf("case %d %q: got %v, want error %v", i, c.Text, err, *c.Result.Error)
			}
			continue
		}
		if err != nil {
			t.Errorf("case %d %q: unexpected error %v", i, c.Text, err)
			continue
		}
		got := []any{}
		for _, s := range scenarios {
			got = append(got, scenarioJSON(s))
		}
		if gs, ws := canon(t, got), canon(t, c.Result.Scenarios); gs != ws {
			t.Errorf("case %d %q:\n got %s\nwant %s", i, c.Text, gs, ws)
		}
	}
}

// gitSandbox makes Git ignore the machine's configuration, for tests that run it.
func gitSandbox(t *testing.T) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("GIT_CONFIG_GLOBAL", filepath.Join(home, ".gitconfig"))
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
}

func gitRepo(t *testing.T) string {
	t.Helper()
	gitSandbox(t)
	root := t.TempDir()
	for _, args := range [][]string{{"init", "--quiet"}, {"config", "user.name", "Kogen Test"}, {"config", "user.email", "kogen-test@example.test"}, {"config", "commit.gpgsign", "false"}} {
		cmd := exec.Command("git", args...)
		cmd.Dir = root
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	return root
}

func writeFile(t *testing.T, root, rel, content string) {
	t.Helper()
	full := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// emptyLists turns the nulls of the list fields (a missing section in Elixir) into empty lists.
func emptyLists(m map[string]any) map[string]any {
	for _, k := range []string{"acceptance", "decisions", "feasibility", "tests"} {
		if v, ok := m[k]; ok && v == nil {
			m[k] = []any{}
		}
	}
	return m
}

func modelJSON(m *ModelSpec) any {
	switch {
	case m == nil:
		return nil
	case m.None:
		return "none"
	}
	return map[string]any{"path": m.Path, "invariants": list(m.Invariants), "seed": m.Seed, "samples": m.Samples, "steps": m.Steps}
}

func TestIntentCheckMatchesElixir(t *testing.T) {
	g := loadGolden(t)
	root := gitRepo(t)
	writeFile(t, root, ".gitignore", "ignored.js\nbuild/\n")
	for _, c := range g.Intent {
		overlay := map[string][]byte{}
		for k, v := range c.Overlay {
			overlay[k] = []byte(v)
		}
		intent, scenarios, err := CheckIntent(root, "demo-intent", overlay)
		if c.Result.Problems != nil {
			se, ok := sys.AsError(err)
			if !ok || se.Class != "intent" || se.Exit != 1 {
				t.Errorf("%s: got %v, want problems %q", c.Label, err, c.Result.Problems)
				continue
			}
			wantReason := c.Result.Problems[0]
			wantDetail := map[string]string{"parse": "the Intent cannot be read", "lint": "the Intent needs changes"}[wantReason]
			if se.Reason != wantReason || se.Detail != wantDetail || canon(t, list(se.Lines)) != canon(t, list(c.Result.Problems[1:])) {
				t.Errorf("%s:\n got %s %q\nwant %q", c.Label, se.Reason, se.Lines, c.Result.Problems)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: unexpected error %v", c.Label, err)
			continue
		}
		got := map[string]any{
			"title": intent.Title, "acceptance": list(intent.Acceptance), "model": modelJSON(intent.Model),
			"decisions": list(intent.Decisions), "tests": list(intent.Tests), "feasibility": list(intent.Feasibility),
			"scenarios": len(scenarios),
		}
		if gs, ws := canon(t, got), canon(t, emptyLists(c.Result.Ok)); gs != ws {
			t.Errorf("%s:\n got %s\nwant %s", c.Label, gs, ws)
		}
	}
}

func TestIntentReadMatchesElixir(t *testing.T) {
	g := loadGolden(t)
	for i, c := range g.IntentRead {
		overlay := map[string][]byte{IntentMDPath("demo-intent"): []byte(c.Text)}
		in, err := ReadIntent("/nonexistent", "demo-intent", overlay)
		if err != nil {
			t.Fatal(err)
		}
		got := map[string]any{
			"title": in.Title, "slug_line": in.SlugLine, "model": in.ModelLine, "model_spec": modelJSON(in.Model),
			"acceptance": list(in.Acceptance), "decisions": list(in.Decisions),
			"feasibility": list(in.Feasibility), "tests": list(in.Tests),
		}
		want := map[string]any{}
		for k, v := range c.Result {
			want[k] = v
		}
		for _, k := range []string{"title", "slug_line", "model"} {
			if want[k] == nil {
				want[k] = ""
			}
		}
		emptyLists(want)
		if gs, ws := canon(t, got), canon(t, want); gs != ws {
			t.Errorf("case %d %q:\n got %s\nwant %s", i, c.Text, gs, ws)
		}
	}
}

func TestDetectMatchesElixir(t *testing.T) {
	g := loadGolden(t)
	for i, c := range g.Detect {
		d := Detect(c.Files, c.Tracked)
		checks := []any{}
		for _, ch := range d.Checks {
			checks = append(checks, []any{ch.Name, ch.Run})
		}
		got := map[string]any{"setup": list(d.Setup), "fix": list(d.Fix), "checks": checks, "protect": list(d.Protect), "runner": orNull(d.Runner)}
		if gs, ws := canon(t, got), canon(t, c.Result); gs != ws {
			t.Errorf("case %d %v %v:\n got %s\nwant %s", i, c.Files, c.Tracked, gs, ws)
		}
	}
	if got := AcceptanceCommand("features/steps", ProjectRunner); got != g.Acceptance["project"] {
		t.Errorf("project command %q, want %q", got, g.Acceptance["project"])
	}
	if got := AcceptanceCommand("features/step_definitions", KogenRunner); got != g.Acceptance["kogen"] {
		t.Errorf("kogen command %q, want %q", got, g.Acceptance["kogen"])
	}
}

func TestGoldenIsCurrent(t *testing.T) {
	// A guard against an empty or truncated golden file.
	g := loadGolden(t)
	counts := map[string]int{"config": len(g.Config), "render": len(g.Render), "yaml": len(g.Yaml), "gherkin": len(g.Gherkin),
		"intent": len(g.Intent), "intent_read": len(g.IntentRead), "detect": len(g.Detect)}
	for name, n := range counts {
		if n < 5 {
			t.Errorf("golden %s has only %d cases", name, n)
		}
	}
	if !strings.Contains(g.Render[0].Text, "models:\n  shape:") {
		t.Error("golden render does not look like a template")
	}
}

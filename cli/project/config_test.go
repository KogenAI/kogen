package project

import (
	"encoding/json"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	"kogen-loop/sys"
)

func mustParse(t *testing.T, text string) *Config {
	t.Helper()
	c, err := ParseConfig(text, "/project/.kogen/project.yaml")
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func configError(t *testing.T, text, file string) *sys.Error {
	t.Helper()
	_, err := ParseConfig(text, file)
	se, ok := sys.AsError(err)
	if !ok {
		t.Fatalf("got %v, want a *sys.Error", err)
	}
	return se
}

func TestRenderConfigBlockCollectionsAndLongValues(t *testing.T) {
	// ExUnit: SET-8: generated settings use block collections and preserve long command values
	input := &Config{
		Setup: []string{"mix deps.get", "npm ci --no-audit --no-fund"},
		Fix:   []string{"mix format"},
		Checks: []Check{
			{"format", "mix format --check-formatted && npx prettier --check '**/*.{js,css,json,yaml}'"},
			{"test", `mix test && printf '%s\n' 'checks passed'`},
		},
		Protect: []string{".formatter.exs", "config/checks/very-long-path-to-project-formatting-configuration.yaml"},
		Acceptance: &Acceptance{
			Run:      `node "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --format message:"$KOGEN_ACCEPTANCE_REPORT"`,
			StepsDir: "features/steps",
		},
	}
	text := RenderConfig(input)
	for _, want := range []string{
		"  checks:\n    - name: format\n      run:",
		"protect:\n  - '.formatter.exs'\n",
		"models:\n  shape:\n    model: gpt-6.1-sol\n    effort: high\n",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("rendered text lacks %q:\n%s", want, text)
		}
	}
	long := "gpt-6.1-sol-with-a-long-explicit-model-identifier-for-formatting-regression"
	cfg := mustParse(t, strings.ReplaceAll(text, "gpt-6.1-sol", long))
	if !slices.Equal(cfg.Setup, input.Setup) || !slices.Equal(cfg.Fix, input.Fix) || !slices.Equal(cfg.Checks, input.Checks) || !slices.Equal(cfg.Protect, input.Protect) {
		t.Errorf("round trip lost commands: %+v", cfg)
	}
	if *cfg.Acceptance != *input.Acceptance {
		t.Errorf("acceptance %+v", cfg.Acceptance)
	}
	for _, role := range []string{"shape", "review"} {
		if cfg.Models[role] != (Role{Model: long, Effort: "high"}) {
			t.Errorf("%s = %+v", role, cfg.Models[role])
		}
	}
	if cfg.Models["build"] != (Role{Model: long, Effort: "medium"}) {
		t.Errorf("build = %+v", cfg.Models["build"])
	}
}

func TestRenderEmptyConfigEqualsTemplate(t *testing.T) {
	// ExUnit: SET-8: empty generated settings retain the template's nulls and empty lists
	text := RenderConfig(&Config{})
	if text != Template() {
		t.Errorf("rendered empty settings differ from the template:\n%s\n---\n%s", text, Template())
	}
	if !reflect.DeepEqual(mustParse(t, text), mustParse(t, Template())) {
		t.Error("parsed generated text differs from parsed template")
	}
}

func TestTemplateText(t *testing.T) {
	want := `version: 1
commands:
  setup: []          # run before readiness dry runs and before each Build
  fix: []            # deterministic fixers, run once after each builder round
  checks: []         # project checks, e.g. {name: test, run: "mix test"}
  acceptance:
    run: null        # the acceptance command (VER-3)
    steps_dir: null  # where shaping writes step-definition files
protect: []          # check configuration the Build must not change, e.g. .credo.exs
models:
  shape:
    model: gpt-6.1-sol
    effort: high
  build:
    model: gpt-6.1-sol
    effort: medium
  review:
    model: gpt-6.1-sol
    effort: high
`
	if Template() != want {
		t.Errorf("template:\n%s", Template())
	}
	d := DefaultModels()
	d["shape"] = Role{Model: "changed"}
	if DefaultModels()["shape"].Model != "gpt-6.1-sol" {
		t.Error("DefaultModels shares state between calls")
	}
}

func TestRenderConfigQuoting(t *testing.T) {
	text := RenderConfig(&Config{
		Setup:      []string{"it's"},
		Checks:     []Check{{"a", "echo 'q'"}},
		Protect:    []string{"a'b"},
		Acceptance: &Acceptance{Run: "x", StepsDir: "s"},
	})
	for _, want := range []string{"    - 'it''s'\n", "      run: 'echo ''q'''\n", "  - 'a''b'\n", "    run: 'x'\n    steps_dir: 's'\n"} {
		if !strings.Contains(text, want) {
			t.Errorf("lacks %q:\n%s", want, text)
		}
	}
	cfg := mustParse(t, text)
	if cfg.Setup[0] != "it's" || cfg.Checks[0].Run != "echo 'q'" || cfg.Protect[0] != "a'b" {
		t.Errorf("round trip %+v", cfg)
	}
}

func TestParseConfigInterpretsCommands(t *testing.T) {
	// ExUnit: SET-8: commands, checks, acceptance, protect, and model defaults are interpreted
	cfg := mustParse(t, `version: 1
commands:
  setup: [mix deps.get, npm ci]
  fix: [mix format]
  checks: [{name: test, run: mix test}, {name: lint, run: mix credo}]
  acceptance: {run: "npx cucumber --format message:$KOGEN_ACCEPTANCE_REPORT", steps_dir: features/steps/}
protect: [".credo.exs", "config/**/*.yaml"]
models:
  build: {model: gpt-6-luna, effort: high}
`)
	if !slices.Equal(cfg.Setup, []string{"mix deps.get", "npm ci"}) || !slices.Equal(cfg.Fix, []string{"mix format"}) {
		t.Errorf("setup/fix %v %v", cfg.Setup, cfg.Fix)
	}
	if !slices.Equal(cfg.Checks, []Check{{"test", "mix test"}, {"lint", "mix credo"}}) {
		t.Errorf("checks %v", cfg.Checks)
	}
	if *cfg.Acceptance != (Acceptance{Run: "npx cucumber --format message:$KOGEN_ACCEPTANCE_REPORT", StepsDir: "features/steps"}) {
		t.Errorf("acceptance %+v", cfg.Acceptance)
	}
	if !slices.Equal(cfg.Protect, []string{".credo.exs", "config/**/*.yaml"}) {
		t.Errorf("protect %v", cfg.Protect)
	}
	wantModels := map[string]Role{
		"shape":  {Model: "gpt-6.1-sol", Effort: "high"},
		"build":  {Model: "gpt-6-luna", Effort: "high"},
		"review": {Model: "gpt-6.1-sol", Effort: "high"},
	}
	if !maps.Equal(cfg.Models, wantModels) {
		t.Errorf("models %v", cfg.Models)
	}
	wantNamed := []NamedCommand{
		{"setup-1", "mix deps.get"}, {"setup-2", "npm ci"}, {"fix-1", "mix format"},
		{"test", "mix test"}, {"lint", "mix credo"},
		{"acceptance", "npx cucumber --format message:$KOGEN_ACCEPTANCE_REPORT"},
	}
	if got := cfg.NamedCommands(); !slices.Equal(got, wantNamed) {
		t.Errorf("named commands %v", got)
	}
	if !cfg.AcceptanceConfigured() {
		t.Error("acceptance is configured")
	}
}

func TestParseConfigIgnoresPlanRole(t *testing.T) {
	// ExUnit: SET-8: obsolete planner settings do not add a planner role
	cfg := mustParse(t, Template()+"  plan: {model: old-planner, effort: high}\n")
	if _, ok := cfg.Models["plan"]; ok {
		t.Error("a plan role was added")
	}
	if cfg.Models["build"] != (Role{Model: "gpt-6.1-sol", Effort: "medium"}) {
		t.Errorf("build %+v", cfg.Models["build"])
	}
	// The ignored role is not even validated.
	mustParse(t, "version: 1\nmodels:\n  plan: garbage\n")
}

func TestParseConfigPlainScalarKeepsComma(t *testing.T) {
	// ExUnit: SET-8: a plain command scalar keeps its comma and shell arguments
	cfg := mustParse(t, "version: 1\ncommands:\n  checks:\n    - name: test\n      run: python3 -c \"print(1, 2)\"\n")
	if !slices.Equal(cfg.Checks, []Check{{"test", `python3 -c "print(1, 2)"`}}) {
		t.Errorf("checks %v", cfg.Checks)
	}
}

func TestParseConfigAcceptanceNull(t *testing.T) {
	// ExUnit: SET-8: acceptance run and steps_dir may remain null until configured
	cfg := mustParse(t, "version: 1\ncommands:\n  acceptance:\n    run: null\n    steps_dir: null\n")
	if cfg.Acceptance != nil || cfg.AcceptanceConfigured() {
		t.Errorf("acceptance %+v", cfg.Acceptance)
	}
	for _, nc := range cfg.NamedCommands() {
		if nc.Name == "acceptance" {
			t.Error("a null acceptance command is listed")
		}
	}
	half := mustParse(t, "version: 1\ncommands:\n  acceptance:\n    run: x\n")
	if half.Acceptance == nil || half.Acceptance.Run != "x" || half.AcceptanceConfigured() {
		t.Errorf("half-configured acceptance %+v", half.Acceptance)
	}
}

func TestParseConfigInvalidNamesFileAndLine(t *testing.T) {
	// ExUnit: SET-4 / SET-8: invalid configuration errors name the file and each source line
	cases := []struct {
		label, text string
		line        int
		message     string
	}{
		{"root unknown key", "version: 1\nlimits: 3\n", 2, "unknown key limits"},
		{"nested unknown key", "version: 1\ncommands:\n  checks:\n    - name: test\n      runn: mix test\n", 5, "unknown key runn"},
		{"duplicate key", "version: 1\ncommands:\n  acceptance:\n    run: first\n    run: second\n", 5, "duplicate key run"},
		{"acceptance run boolean", "version: 1\ncommands:\n  acceptance:\n    run: true\n", 4, "commands.acceptance.run must be a string or null"},
		{"check run boolean", "version: 1\ncommands:\n  checks:\n    - name: test\n      run: true\n", 4, "a check needs a name and a run string"},
		{"checks null", "version: 1\ncommands:\n  checks: null\n", 3, "commands.checks must be a list"},
		{"setup null", "version: 1\ncommands:\n  setup: null\n", 3, "commands.setup must be a list"},
		{"protect null", "version: 1\nprotect: null\n", 2, "protect must be a list"},
		{"duplicate check name", "version: 1\ncommands:\n  checks:\n    - name: test\n      run: one\n    - name: test\n      run: two\n", 6, "check name test is used twice"},
		{"uppercase check name", "version: 1\ncommands:\n  checks:\n    - name: Unit\n      run: mix test\n", 4, "check name Unit must be lowercase"},
		{"acceptance reserved name", "version: 1\ncommands:\n  checks:\n    - name: acceptance\n      run: mix test\n", 4, "check name acceptance is reserved"},
		{"model reserved name", "version: 1\ncommands:\n  checks:\n    - name: model\n      run: mix test\n", 4, "check name model is reserved"},
		{"steps_dir number", "version: 1\ncommands:\n  acceptance:\n    steps_dir: 3\n", 4, "commands.acceptance.steps_dir must be a string or null"},
	}
	for _, c := range cases {
		t.Run(c.label, func(t *testing.T) {
			file := "/tmp/" + c.label + "/.kogen/project.yaml"
			se := configError(t, c.text, file)
			if se.Class != "environment" || se.Reason != "project_config_invalid" || se.Detail != file || se.Exit != 3 {
				t.Errorf("error %+v", se)
			}
			if want := []string{fmt.Sprintf("line %d: %s", c.line, c.message)}; !slices.Equal(se.Lines, want) {
				t.Errorf("lines %q, want %q", se.Lines, want)
			}
		})
	}
}

func TestParseConfigMoreRules(t *testing.T) {
	cases := []struct {
		label, text string
		lines       []string
	}{
		{"version wrong", "version: 2\n", []string{"line 1: version must be 1"}},
		{"version quoted", "version: \"1\"\n", []string{"line 1: version must be 1"}},
		{"top level list", "- a\n- b\n", []string{"line 1: the file must be a mapping"}},
		{"empty file", "", []string{"line 1: the file is empty"}},
		{"yaml error", "version: 1\ncommands:\n  setup: [a\n", []string{"line 3: unclosed ["}},
		{"commands scalar", "version: 1\ncommands: 3\n", []string{"line 2: commands must be a mapping"}},
		{"commands unknown key", "version: 1\ncommands:\n  lint: []\n", []string{"line 3: unknown key lint"}},
		{"setup entries", "version: 1\ncommands:\n  setup:\n    - true\n    - 3\n    - ok\n    -\n", []string{"line 4: commands.setup entries must be strings", "line 5: commands.setup entries must be strings", "line 7: commands.setup entries must be strings"}},
		{"acceptance list", "version: 1\ncommands:\n  acceptance: [a]\n", []string{"line 3: commands.acceptance must be a mapping"}},
		{"acceptance unknown key", "version: 1\ncommands:\n  acceptance: {run: x, extra: 1}\n", []string{"line 3: unknown key extra"}},
		{"check not a map", "version: 1\ncommands:\n  checks:\n    - just text\n", []string{"line 4: a check must be {name, run}"}},
		{"check unknown keys only", "version: 1\ncommands:\n  checks:\n    - name: a\n      extra: 1\n      other: 2\n", []string{"line 5: unknown key extra", "line 6: unknown key other"}},
		{"models scalar", "version: 1\nmodels: x\n", []string{"line 2: models must be a mapping"}},
		{"models unknown role", "version: 1\nmodels:\n  other: {model: m, effort: e}\n", []string{"line 3: unknown key other"}},
		{"models missing effort", "version: 1\nmodels:\n  build: {model: m}\n", []string{"line 3: models.build must be {model, effort}"}},
		{"models extra key", "version: 1\nmodels:\n  build: {model: m, effort: e, extra: 1}\n", []string{"line 3: models.build must be {model, effort}"}},
		{"models number model", "version: 1\nmodels:\n  build: {model: 1, effort: high}\n", []string{"line 3: models.build must be {model, effort}"}},
		{"workers scalar", "version: 1\nshape_workers: x\n", []string{"line 2: shape_workers must be a mapping"}},
		{"workers unknown key", "version: 1\nshape_workers:\n  extra: 1\n", []string{"line 3: unknown key extra"}},
		{"workers enabled not boolean", "version: 1\nshape_workers:\n  enabled: 'true'\n", []string{"line 3: shape_workers.enabled must be a Boolean"}},
		{"workers enabled yes", "version: 1\nshape_workers:\n  enabled: yes\n", []string{"line 3: shape_workers.enabled must be a Boolean"}},
		{"workers blank model", "version: 1\nshape_workers:\n  read: {model: ' ', effort: b}\n", []string{"line 3: shape_workers.read must be {model, effort} strings"}},
		{"workers not a map", "version: 1\nshape_workers:\n  draft: [x]\n", []string{"line 3: shape_workers.draft must be {model, effort} strings"}},
		{"workers enabled lacks roles", "version: 1\nshape_workers:\n  enabled: true\n  read: {model: a, effort: b}\n", []string{"line 3: shape_workers.draft requires explicit model and effort", "line 3: shape_workers.probe requires explicit model and effort"}},
		{"problems sorted by line then text", "version: 1\nprotect: x\ncommands:\n  setup: y\nzzz: 1\naaa: 2\n", []string{"line 2: protect must be a list", "line 4: commands.setup must be a list", "line 5: unknown key zzz", "line 6: unknown key aaa"}},
	}
	for _, c := range cases {
		t.Run(c.label, func(t *testing.T) {
			se := configError(t, c.text, "f")
			if !slices.Equal(se.Lines, c.lines) {
				t.Errorf("lines %q, want %q", se.Lines, c.lines)
			}
		})
	}
}

func TestParseConfigWorkers(t *testing.T) {
	cfg := mustParse(t, `version: 1
shape_workers:
  enabled: true
  read: {model: a, effort: b}
  probe: {model: a, effort: b, provider: chatgpt}
  draft: {model: grok-4.7, effort: low, provider: supergrok}
`)
	want := Workers{Enabled: true, Roles: map[string]Role{
		"read":  {Model: "a", Effort: "b"},
		"probe": {Provider: "chatgpt", Model: "a", Effort: "b"},
		"draft": {Provider: "supergrok", Model: "grok-4.7", Effort: "low"},
	}}
	if !reflect.DeepEqual(cfg.ShapeWorkers, want) {
		t.Errorf("workers %+v", cfg.ShapeWorkers)
	}
	off := mustParse(t, "version: 1\nshape_workers:\n  enabled: false\n  read: {model: a, effort: b}\n")
	if off.ShapeWorkers.Enabled || len(off.ShapeWorkers.Roles) != 1 {
		t.Errorf("disabled workers %+v", off.ShapeWorkers)
	}
	if def := mustParse(t, "version: 1\n"); def.ShapeWorkers.Enabled || len(def.ShapeWorkers.Roles) != 0 || len(def.Models) != 3 {
		t.Errorf("defaults %+v", def)
	}
}

func TestLoadConfigReportsActualPathAndSourceLine(t *testing.T) {
	// ExUnit: SET-4: loading an invalid project file reports its actual path and source line
	root := t.TempDir()
	path := filepath.Join(root, ConfigPath)
	writeFile(t, root, ConfigPath, "version: 1\ncommands:\n  acceptance:\n    run: true\n")
	_, err := LoadConfig(root)
	se, ok := sys.AsError(err)
	if !ok || se.Detail != path || !slices.Equal(se.Lines, []string{"line 4: commands.acceptance.run must be a string or null"}) {
		t.Fatalf("got %v", err)
	}
	if want := "environment/project_config_invalid: " + path + "\n  line 4: commands.acceptance.run must be a string or null\n"; se.Render() != want {
		t.Errorf("render %q", se.Render())
	}
}

func TestLoadConfigNotInitialized(t *testing.T) {
	root := t.TempDir()
	_, err := LoadConfig(root)
	se, ok := sys.AsError(err)
	if !ok || se.Class != "environment" || se.Reason != "not_initialized" || se.Exit != 3 ||
		se.Detail != root+" has no .kogen/project.yaml; run kogen init" {
		t.Fatalf("got %+v", err)
	}
}

func TestLoadConfigReadsTheTemplate(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, ConfigPath, Template())
	cfg, err := LoadConfig(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Setup) != 0 || cfg.Acceptance != nil || !maps.Equal(cfg.Models, DefaultModels()) {
		t.Errorf("template config %+v", cfg)
	}
}

func TestParseConfigOldConfig(t *testing.T) {
	for _, text := range []string{"commands:\n  setup: []\n", "limits: 3\n", "commands: {}\n"} {
		se := configError(t, text, "f")
		if se.Class != "environment" || se.Reason != "old_kogen_config" || se.Exit != 3 || len(se.Lines) != 0 ||
			se.Detail != ".kogen/ is from an earlier Kogen; move it aside (git mv .kogen .kogen-old), commit, and run kogen init" {
			t.Errorf("%q: %+v", text, se)
		}
	}
}

func TestProviderSelections(t *testing.T) {
	// ExUnit: provider selections preserve omission and validate every role and effort
	for _, section := range []string{"models", "shape_workers"} {
		roles := []string{"shape", "build", "review"}
		if section == "shape_workers" {
			roles = []string{"read", "probe", "draft"}
		}
		for _, role := range roles {
			parse := func(fields string) (Role, *sys.Error) {
				text := "version: 1\n" + section + ":\n  " + role + ": {" + fields + "}\n"
				cfg, err := ParseConfig(text, "/project/.kogen/project.yaml")
				if err != nil {
					se, _ := sys.AsError(err)
					return Role{}, se
				}
				if section == "models" {
					return cfg.Models[role], nil
				}
				return cfg.ShapeWorkers.Roles[role], nil
			}
			if r, _ := parse("model: fixture, effort: arbitrary"); r != (Role{Model: "fixture", Effort: "arbitrary"}) {
				t.Errorf("%s.%s without provider: %+v", section, role, r)
			}
			if r, _ := parse("model: fixture, effort: arbitrary, provider: chatgpt"); r != (Role{Provider: "chatgpt", Model: "fixture", Effort: "arbitrary"}) {
				t.Errorf("%s.%s chatgpt: %+v", section, role, r)
			}
			for _, effort := range []string{"low", "medium", "high", "xhigh"} {
				if r, _ := parse("model: grok-4.7, effort: " + effort + ", provider: supergrok"); r != (Role{Provider: "supergrok", Model: "grok-4.7", Effort: effort}) {
					t.Errorf("%s.%s supergrok %s: %+v", section, role, effort, r)
				}
			}
			for _, model := range []string{"claude-opus-5-5", "claude-sonnet-5-5"} {
				for _, effort := range []string{"low", "medium", "high", "max"} {
					if r, _ := parse("model: " + model + ", effort: " + effort + ", provider: anthropic"); r != (Role{Provider: "anthropic", Model: model, Effort: effort}) {
						t.Errorf("%s.%s anthropic %s %s: %+v", section, role, model, effort, r)
					}
				}
			}
			// KOGEN-057: no allowlists. Any model and effort reach the provider unchanged,
			// including the ones the old lists refused.
			for _, c := range []struct{ provider, model, effort string }{
				{"anthropic", "claude-invented", "high"}, {"anthropic", "claude-opus-5-5", "xhigh"}, {"anthropic", "claude-haiku-5-5", "default"},
				{"opencode-go", "kimi-k3.1-pro", "xhigh"}, {"opencode-go", "glm-5", "low"}, {"opencode-go", "kimi-k3", "default"},
				{"supergrok", "grok-4.20-0309-reasoning", "max"}, {"supergrok", "grok-5", "default"},
				{"chatgpt", "gpt-7-preview", "minimal"},
			} {
				fields := "model: " + c.model + ", effort: " + c.effort + ", provider: " + c.provider
				if r, se := parse(fields); se != nil || r != (Role{Provider: c.provider, Model: c.model, Effort: c.effort}) {
					t.Errorf("%s.%s %s: %+v %+v", section, role, fields, r, se)
				}
			}
			// A named provider other than ChatGPT still needs a non-blank model and effort.
			for _, fields := range []string{"model: '', effort: high, provider: supergrok", "model: kimi-k3, effort: ' ', provider: opencode-go"} {
				_, se := parse(fields)
				want := "line 3: " + section + "." + role + " must be {model, effort}"
				if section == "shape_workers" {
					want += " strings"
				}
				if se == nil || se.Exit != 3 || !slices.Equal(se.Lines, []string{want}) {
					t.Errorf("%s.%s %s: %+v", section, role, fields, se)
				}
			}
			for _, provider := range []string{"grok", "xai", "true", "null", "claude", "opencode", "openai", "ollama"} {
				_, se := parse("model: grok-4.7, effort: low, provider: " + provider)
				if se == nil || se.Exit != 3 || !slices.Equal(se.Lines, []string{"line 3: " + section + "." + role + ".provider must be chatgpt, supergrok, opencode-go, anthropic or openai-compatible"}) {
					t.Errorf("%s.%s provider %s: %+v", section, role, provider, se)
				}
			}
			// openai-compatible: base_url is required, must be http(s), is trimmed of a trailing
			// slash, and is refused on every other provider.
			for _, base := range []string{"'http://localhost:11434/v1'", "\"https://llm.example.com/v1/\""} {
				r, se := parse("provider: openai-compatible, model: qwen3-coder:30b, effort: default, base_url: " + base)
				want := strings.TrimRight(strings.Trim(base, "'\""), "/")
				if se != nil || r != (Role{Provider: "openai-compatible", Model: "qwen3-coder:30b", Effort: "default", BaseURL: want}) {
					t.Errorf("%s.%s base %s: %+v %+v", section, role, base, r, se)
				}
			}
			for _, c := range []struct{ fields, want string }{
				{"provider: openai-compatible, model: m, effort: default", ": openai-compatible needs base_url, for example http://localhost:11434/v1"},
				{"provider: openai-compatible, model: m, effort: default, base_url: 'ftp://host/v1'", ".base_url must be an http:// or https:// URL"},
				{"provider: openai-compatible, model: m, effort: default, base_url: 'localhost:11434'", ".base_url must be an http:// or https:// URL"},
				{"provider: openai-compatible, model: m, effort: default, base_url: 'http://h/v1?x=1'", ".base_url must be an http:// or https:// URL"},
				{"provider: openai-compatible, model: m, effort: default, base_url: 3", ".base_url must be an http:// or https:// URL"},
				{"provider: opencode-go, model: kimi-k3, effort: high, base_url: 'http://localhost:1/v1'", ".base_url is only for provider openai-compatible"},
				{"model: gpt-6.1-sol, effort: high, base_url: 'http://localhost:1/v1'", ".base_url is only for provider openai-compatible"},
			} {
				_, se := parse(c.fields)
				if se == nil || se.Exit != 3 || !slices.Equal(se.Lines, []string{"line 3: " + section + "." + role + c.want}) {
					t.Errorf("%s.%s %s: %+v", section, role, c.fields, se)
				}
			}
		}
	}
}

func TestConfigErrorRendering(t *testing.T) {
	se := configError(t, "version: 1\nlimits: 3\n", "/p/.kogen/project.yaml")
	want := "environment/project_config_invalid: /p/.kogen/project.yaml\n  line 2: unknown key limits\n"
	if se.Render() != want {
		t.Errorf("got %q", se.Render())
	}
}

func TestLoadConfigOfTheRepository(t *testing.T) {
	// The configuration this repository itself uses must stay readable.
	root := filepath.Join("..", "..")
	if _, err := os.Stat(filepath.Join(root, ConfigPath)); err != nil {
		t.Skip("not inside the Kogen repository")
	}
	if _, err := LoadConfig(root); err != nil {
		t.Fatal(err)
	}
}

// ---- the executor of the build role (docs/executor-contract.md section 5) ----

func TestBuildExecutorSelection(t *testing.T) {
	for _, tt := range []struct {
		name, build string
		want        Role
	}{
		{"claude-code with model and effort", "{executor: claude-code, model: claude-sonnet-5-5, effort: high}",
			Role{Model: "claude-sonnet-5-5", Effort: "high", Executor: "claude-code"}},
		{"claude-code with max_rounds", "{executor: claude-code, model: claude-sonnet-5-5, effort: high, max_rounds: 6}",
			Role{Model: "claude-sonnet-5-5", Effort: "high", Executor: "claude-code", MaxRounds: 6}},
		{"key order does not matter", "{max_rounds: 12, effort: low, model: m, executor: claude-code}",
			Role{Model: "m", Effort: "low", Executor: "claude-code", MaxRounds: 12}},
		{"quoted executor name", `{executor: "claude-code", model: m, effort: e}`, Role{Model: "m", Effort: "e", Executor: "claude-code"}},
		// Written out, the native executor is the native builder: no value differs from a file
		// that says nothing, so checkpoints keep their bytes.
		{"native written out", "{executor: native, model: gpt-6.1-sol, effort: medium}", Role{Model: "gpt-6.1-sol", Effort: "medium"}},
		{"native keeps its provider", "{executor: native, provider: supergrok, model: grok-4.7, effort: low}",
			Role{Provider: "supergrok", Model: "grok-4.7", Effort: "low"}},
		{"no executor", "{model: gpt-6.1-sol, effort: medium}", Role{Model: "gpt-6.1-sol", Effort: "medium"}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			cfg := mustParse(t, "version: 1\nmodels:\n  build: "+tt.build+"\n")
			if got := cfg.Models["build"]; got != tt.want {
				t.Fatalf("build = %+v, want %+v", got, tt.want)
			}
			if want := tt.want.Executor == "claude-code"; cfg.Models["build"].External() != want {
				t.Fatalf("External() = %v", !want)
			}
		})
	}
	// Block form.
	cfg := mustParse(t, "version: 1\nmodels:\n  build:\n    executor: claude-code\n    model: m\n    effort: e\n    max_rounds: 2\n")
	if got := cfg.Models["build"]; got != (Role{Model: "m", Effort: "e", Executor: "claude-code", MaxRounds: 2}) {
		t.Fatalf("block form %+v", got)
	}
	// The other roles keep their defaults.
	if cfg.Models["shape"] != DefaultModels()["shape"] || cfg.Models["review"] != DefaultModels()["review"] {
		t.Fatalf("other roles changed: %+v", cfg.Models)
	}
}

func TestBuildExecutorConfigurationErrors(t *testing.T) {
	const head = "version: 1\nmodels:\n  "
	for _, tt := range []struct{ name, text, want string }{
		{"unknown executor", "build: {executor: codex, model: m, effort: e}", "line 3: models.build.executor must be native or claude-code"},
		{"executor is not a string", "build: {executor: true, model: m, effort: e}", "line 3: models.build.executor must be native or claude-code"},
		{"executor is empty", "build: {executor: , model: m, effort: e}", "line 3: models.build.executor must be native or claude-code"},
		{"claude-code forbids provider", "build: {executor: claude-code, provider: anthropic, model: m, effort: e}",
			"line 3: models.build.provider is not allowed with executor claude-code"},
		{"claude-code forbids base_url", "build: {executor: claude-code, base_url: 'http://localhost:1/v1', model: m, effort: e}",
			"line 3: models.build.base_url is not allowed with executor claude-code"},
		{"claude-code needs a model", "build: {executor: claude-code, effort: e}", "line 3: models.build with executor claude-code must be {model, effort} non-blank strings"},
		{"claude-code needs an effort", "build: {executor: claude-code, model: m}", "line 3: models.build with executor claude-code must be {model, effort} non-blank strings"},
		{"claude-code needs non-blank model", "build: {executor: claude-code, model: ' ', effort: e}", "line 3: models.build with executor claude-code must be {model, effort} non-blank strings"},
		{"claude-code takes no other key", "build: {executor: claude-code, model: m, effort: e, sandbox: true}", "line 3: models.build with executor claude-code must be {model, effort} non-blank strings"},
		{"max_rounds needs claude-code", "build: {model: m, effort: e, max_rounds: 3}", "line 3: models.build.max_rounds is only for executor claude-code"},
		{"max_rounds with native", "build: {executor: native, model: m, effort: e, max_rounds: 3}", "line 3: models.build.max_rounds is only for executor claude-code"},
		{"max_rounds zero", "build: {executor: claude-code, model: m, effort: e, max_rounds: 0}", "line 3: models.build.max_rounds must be a positive integer"},
		{"max_rounds negative", "build: {executor: claude-code, model: m, effort: e, max_rounds: -1}", "line 3: models.build.max_rounds must be a positive integer"},
		{"max_rounds fraction", "build: {executor: claude-code, model: m, effort: e, max_rounds: 2.5}", "line 3: models.build.max_rounds must be a positive integer"},
		{"max_rounds text", "build: {executor: claude-code, model: m, effort: e, max_rounds: six}", "line 3: models.build.max_rounds must be a positive integer"},
		{"max_rounds quoted", `build: {executor: claude-code, model: m, effort: e, max_rounds: "6"}`, "line 3: models.build.max_rounds must be a positive integer"},
		{"max_rounds leading zero", "build: {executor: claude-code, model: m, effort: e, max_rounds: 06}", "line 3: models.build.max_rounds must be a positive integer"},
		{"executor on shape", "shape: {executor: claude-code, model: m, effort: e}", "line 3: models.shape.executor: executor is supported for the build role only"},
		{"native executor on review", "review: {executor: native, model: m, effort: e}", "line 3: models.review.executor: executor is supported for the build role only"},
		{"max_rounds on review", "review: {model: m, effort: e, max_rounds: 3}", "line 3: models.review.max_rounds: executor is supported for the build role only"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			se := configError(t, head+tt.text+"\n", "f")
			if se.Class != "environment" || se.Reason != "project_config_invalid" || se.Exit != 3 || !slices.Equal(se.Lines, []string{tt.want}) {
				t.Fatalf("%+v", se)
			}
		})
	}
}

func TestExecutorKeysAreNotAcceptedAnywhereElse(t *testing.T) {
	// The workers are not build roles: the keys are unknown to them, as before.
	se := configError(t, "version: 1\nshape_workers:\n  enabled: false\n  read: {executor: claude-code, model: m, effort: e}\n", "f")
	if !slices.Equal(se.Lines, []string{"line 4: shape_workers.read must be {model, effort} strings"}) {
		t.Fatalf("%+v", se)
	}
}

func TestNativeRoleJSONKeepsItsBytes(t *testing.T) {
	// The new fields are omitted when empty, so checkpoints of native Builds do not change.
	b, err := json.Marshal(Role{Provider: "chatgpt", Model: "m", Effort: "e"})
	if err != nil || string(b) != `{"Provider":"chatgpt","Model":"m","Effort":"e"}` {
		t.Fatalf("%s %v", b, err)
	}
	b, _ = json.Marshal(Role{Model: "m", Effort: "e", Executor: "claude-code", MaxRounds: 4})
	if string(b) != `{"Provider":"","Model":"m","Effort":"e","Executor":"claude-code","MaxRounds":4}` {
		t.Fatalf("%s", b)
	}
}

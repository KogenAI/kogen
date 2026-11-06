package consumes

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/KogenAI/kogen-coordinator/project"
	"github.com/KogenAI/kogen-loop/sys"
)

// kogen cli/readiness/readiness.go validates the project's configuration text with ParseConfig
// and reads the model lineup (the defaults, .kogen/models.yaml, .kogen/local/models.yaml) with
// LoadConfig.
var (
	_ func(string, string) (*project.Config, error) = project.ParseConfig
	_ func(string) (*project.Config, error)         = project.LoadConfig
	_ func(string) *project.Config                  = project.ReadableConfig
	_ func(project.Role) bool                       = project.Role.External
)

// The configuration fields and role fields kogen reads.
var (
	_           = func(c *project.Config) (map[string]project.Role, project.Workers) { return c.Models, c.ShapeWorkers }
	_           = func(w project.Workers) (bool, map[string]project.Role) { return w.Enabled, w.Roles }
	_           = func(r project.Role) (string, string) { return r.Provider, r.Executor }
	_ [3]string = project.ModelRoles
)

func parse(t *testing.T, text string) *project.Config {
	t.Helper()
	cfg, err := project.ParseConfig(text, "project.yaml")
	if err != nil {
		t.Fatalf("ParseConfig: %v\n%s", err, text)
	}
	return cfg
}

// TestConfigPathAndModelRoles: the configuration lives at .kogen/project.yaml, and the model
// roles, in the template's order, are shape, build and review.
func TestConfigPathAndModelRoles(t *testing.T) {
	if project.ConfigPath != ".kogen/project.yaml" {
		t.Fatalf("ConfigPath = %q", project.ConfigPath)
	}
	if got := project.ModelRoles[:]; !slices.Equal(got, []string{"shape", "build", "review"}) {
		t.Fatalf("ModelRoles = %q", got)
	}
}

// TestParsedConfigHasARoleForEveryModelRole: the models map has an entry for each model role,
// also when the file selects none, as readiness indexes it with every ModelRoles name. A role
// the file does not name is native (no executor, so not External) and names no provider.
func TestParsedConfigHasARoleForEveryModelRole(t *testing.T) {
	cfg := parse(t, "version: 1\n")
	for _, name := range project.ModelRoles {
		role, ok := cfg.Models[name]
		if !ok {
			t.Fatalf("Models has no %s", name)
		}
		if role.Provider != "" || role.Executor != "" || role.External() {
			t.Fatalf("default %s role = %+v, want native with no provider", name, role)
		}
	}
	if cfg.ShapeWorkers.Enabled || len(cfg.ShapeWorkers.Roles) != 0 {
		t.Fatalf("ShapeWorkers = %+v, want disabled and empty", cfg.ShapeWorkers)
	}
}

// loadRoles writes a project file and the given models files (by relative path) in a temporary
// project and returns the configuration project.LoadConfig reads from them.
// The model lineup files project.LoadConfig reads: the team file and the host-local override.
const (
	modelsFile      = ".kogen/models.yaml"
	localModelsFile = ".kogen/local/models.yaml"
)

func loadRoles(t *testing.T, files map[string]string) *project.Config {
	t.Helper()
	root := t.TempDir()
	files[project.ConfigPath] = "version: 1\n"
	for rel, text := range files {
		path := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cfg, err := project.LoadConfig(root)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	return cfg
}

// TestRoleProviderAndExecutor: a role's Provider is the models file's provider; a role with
// `executor: claude-code` has Executor project.ExecutorClaudeCode and is External, one with the
// native executor is not. The roles come from .kogen/models.yaml through project.LoadConfig, a
// role of .kogen/local/models.yaml replaces the whole role of the team file, and a role no file
// names stays the default.
func TestRoleProviderAndExecutor(t *testing.T) {
	cfg := loadRoles(t, map[string]string{modelsFile: `models:
  shape: {provider: anthropic, model: m, effort: high}
  build: {executor: claude-code, model: m, effort: high}
  review: {executor: native, model: m, effort: high}
`})
	shape, build, review := cfg.Models["shape"], cfg.Models["build"], cfg.Models["review"]
	if shape.Provider != "anthropic" || shape.External() || shape.Executor != "" {
		t.Fatalf("shape = %+v (external %v)", shape, shape.External())
	}
	if project.ExecutorClaudeCode != "claude-code" {
		t.Fatalf("ExecutorClaudeCode = %q", project.ExecutorClaudeCode)
	}
	if build.Executor != project.ExecutorClaudeCode || !build.External() {
		t.Fatalf("build = %+v (external %v), want the claude-code executor", build, build.External())
	}
	if review.External() || review.Executor == project.ExecutorClaudeCode {
		t.Fatalf("review = %+v (external %v), want native", review, review.External())
	}
	if only := (project.Role{Executor: project.ExecutorClaudeCode}); !only.External() {
		t.Fatalf("a role with only the claude-code executor is not External: %+v", only)
	}

	local := loadRoles(t, map[string]string{
		modelsFile:      "models:\n  shape: {provider: anthropic, model: m, effort: high}\n  build: {provider: supergrok, model: g, effort: high}\n",
		localModelsFile: "models:\n  build: {executor: claude-code, model: l, effort: low}\n",
	})
	if got := local.Models["shape"]; got.Provider != "anthropic" || got.Model != "m" {
		t.Fatalf("shape = %+v, want the team role", got)
	}
	if got := local.Models["build"]; got.Provider != "" || got.Executor != project.ExecutorClaudeCode || got.Model != "l" {
		t.Fatalf("build = %+v, want the host-local role replacing the whole team role", got)
	}
	if got, want := local.Models["review"], project.DefaultModels()["review"]; got != want {
		t.Fatalf("review = %+v, want the default %+v", got, want)
	}
}

// TestModelsKeyOfTheProjectFileIsRefused: a root models key of .kogen/project.yaml is refused by
// ParseConfig and LoadConfig with environment/project_config_invalid (exit 3), the file and the
// line `line N: models is no longer read from .kogen/project.yaml; move the model lineup to
// .kogen/models.yaml`.
func TestModelsKeyOfTheProjectFileIsRefused(t *testing.T) {
	const text = "version: 1\nmodels:\n  shape: {provider: anthropic, model: m, effort: high}\n"
	const line = "line 2: models is no longer read from .kogen/project.yaml; move the model lineup to .kogen/models.yaml"
	check := func(what string, err error, file string) {
		t.Helper()
		var e *sys.Error
		if !errors.As(err, &e) {
			t.Fatalf("%s: error %v (%T), want *sys.Error", what, err, err)
		}
		if e.Class != "environment" || e.Reason != "project_config_invalid" || e.Detail != file || e.Exit != 3 || !slices.Equal(e.Lines, []string{line}) {
			t.Fatalf("%s: %+v", what, e)
		}
	}
	_, err := project.ParseConfig(text, "project.yaml")
	check("ParseConfig", err, "project.yaml")
	root := t.TempDir()
	file := filepath.Join(root, project.ConfigPath)
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err = project.LoadConfig(root)
	check("LoadConfig", err, file)
}

// requireFixedWorkers: ShapeWorkers is the fixed value project.Workers{Enabled: false, Roles:
// an empty, non-nil map}, whatever the file said.
func requireFixedWorkers(t *testing.T, what string, cfg *project.Config) {
	t.Helper()
	var workers project.Workers = cfg.ShapeWorkers
	if workers.Enabled || workers.Roles == nil || len(workers.Roles) != 0 {
		t.Fatalf("%s: ShapeWorkers = %#v, want disabled with an empty, non-nil Roles map", what, workers)
	}
}

// TestShapeWorkers: the shape_workers key was removed and is ignored whatever its value, so
// ShapeWorkers is always disabled with an empty, non-nil Roles map: with workers enabled and the
// read, probe and draft roles given, without the section, with enabled: false, and with the
// former refusal text (enabled, one role only).
func TestShapeWorkers(t *testing.T) {
	for _, c := range []struct{ name, text string }{
		{"enabled with roles", `version: 1
shape_workers:
  enabled: true
  read: {model: r, effort: low, provider: anthropic}
  probe: {model: p, effort: low}
  draft: {model: d, effort: low, provider: supergrok}
`},
		{"without the section", "version: 1\n"},
		{"enabled: false", "version: 1\nshape_workers:\n  enabled: false\n  read: {model: r, effort: low}\n"},
		{"enabled without roles", "version: 1\nshape_workers:\n  enabled: true\n  read: {model: r, effort: low}\n"},
	} {
		t.Run(c.name, func(t *testing.T) {
			requireFixedWorkers(t, c.name, parse(t, c.text))
		})
	}
}

// TestParseConfigRefusalsAreSysErrorsWithLines: an invalid file is a *sys.Error whose Detail is
// the file name passed in and whose Lines, one per problem, start `line <n>:`, which readiness
// shows and turns into the lines to edit. Nothing is returned for the configuration.
func TestParseConfigRefusalsAreSysErrorsWithLines(t *testing.T) {
	cases := []struct {
		name, text string
		lines      []string
	}{
		{"unknown keys", "version: 1\nbogus: 1\nother: 2\n", []string{"line 2: unknown key bogus", "line 3: unknown key other"}},
		{"unsupported version", "version: 2\n", []string{"line 1: version must be 1"}},
		{"empty file", "", []string{"line 1: the file is empty"}},
		{"unclosed flow", "version: 1\n\tbad: [\n", []string{"line 2: unclosed ["}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cfg, err := project.ParseConfig(c.text, "project.yaml")
			if err == nil || cfg != nil {
				t.Fatalf("ParseConfig = %+v, %v; want an error", cfg, err)
			}
			e, ok := sys.AsError(err)
			if !ok {
				t.Fatalf("error %v (%T), want *sys.Error", err, err)
			}
			if e.Detail != "project.yaml" || e.Exit != 3 || !slices.Equal(e.Lines, c.lines) {
				t.Fatalf("Detail %q, Exit %d, Lines %q; want project.yaml, 3, %q", e.Detail, e.Exit, e.Lines, c.lines)
			}
			if want := "environment/project_config_invalid: project.yaml\n  " + strings.Join(c.lines, "\n  ") + "\n"; e.Render() != want {
				t.Fatalf("Render = %q, want %q", e.Render(), want)
			}
		})
	}
}

// TestParseConfigOldKogenFolderHasNoLines: a configuration of an earlier Kogen is a *sys.Error
// with a Detail that says what to do and no Lines; readiness shows the Detail.
func TestParseConfigOldKogenFolderHasNoLines(t *testing.T) {
	_, err := project.ParseConfig("commands:\n  setup: []\n", "old.yaml")
	var e *sys.Error
	if !errors.As(err, &e) {
		t.Fatalf("error %v (%T), want *sys.Error", err, err)
	}
	if len(e.Lines) != 0 || !strings.Contains(e.Detail, "earlier Kogen") || e.Exit != 3 {
		t.Fatalf("Lines %q, Detail %q, Exit %d", e.Lines, e.Detail, e.Exit)
	}
}

// TestReadableConfigKeepsWhatItCanRead: of an invalid file it keeps what validation accepted, and
// the model roles are project.DefaultModels() for every role (a models key is refused, not
// applied; no provider, not External), as they are for text it cannot read, or no text. Whatever
// the text, the shaping workers are the fixed disabled value with an empty, non-nil Roles map.
func TestReadableConfigKeepsWhatItCanRead(t *testing.T) {
	partial := project.ReadableConfig("version: 1\nbogus: 1\nmodels:\n  shape: {provider: anthropic, model: m, effort: high}\n  build: {executor: claude-code, model: m, effort: high}\nshape_workers:\n  enabled: true\n  read: {model: r, effort: low, provider: supergrok}\n")
	for _, name := range project.ModelRoles {
		if partial.Models[name] != project.DefaultModels()[name] || partial.Models[name].Provider != "" || partial.Models[name].External() {
			t.Fatalf("Models[%s] = %+v, want the default", name, partial.Models[name])
		}
	}
	requireFixedWorkers(t, "partial", partial)

	for _, text := range []string{"", "version: 1\n\tbad: [\n"} {
		cfg := project.ReadableConfig(text)
		if cfg == nil {
			t.Fatalf("ReadableConfig(%q) = nil", text)
		}
		for _, name := range project.ModelRoles {
			role, ok := cfg.Models[name]
			if !ok || role != project.DefaultModels()[name] || role.Provider != "" || role.External() {
				t.Fatalf("ReadableConfig(%q).Models[%s] = %+v (present %v)", text, name, role, ok)
			}
		}
		requireFixedWorkers(t, fmt.Sprintf("ReadableConfig(%q)", text), cfg)
	}
}

package consumes

import (
	"errors"
	"slices"
	"strings"
	"testing"

	"github.com/KogenAI/kogen-coordinator/project"
	"kogen-loop/sys"
)

// kogen cli/readiness/readiness.go parses the project's configuration text and, when that fails,
// reads what it can of it.
var (
	_ func(string, string) (*project.Config, error) = project.ParseConfig
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

// TestRoleProviderAndExecutor: a role's Provider is the file's provider; a role with `executor:
// claude-code` has Executor project.ExecutorClaudeCode and is External, one with the native
// executor is not.
func TestRoleProviderAndExecutor(t *testing.T) {
	cfg := parse(t, `version: 1
models:
  shape: {provider: anthropic, model: m, effort: high}
  build: {executor: claude-code, model: m, effort: high}
  review: {executor: native, model: m, effort: high}
`)
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
}

// TestShapeWorkers: with workers enabled and the read, probe and draft roles given, ShapeWorkers
// is enabled and holds each role by that name; without the section it is disabled. A role the
// file does not give is absent from Roles, which readiness tests with a lookup.
func TestShapeWorkers(t *testing.T) {
	cfg := parse(t, `version: 1
shape_workers:
  enabled: true
  read: {model: r, effort: low, provider: anthropic}
  probe: {model: p, effort: low}
  draft: {model: d, effort: low, provider: supergrok}
`)
	var workers project.Workers = cfg.ShapeWorkers
	if !workers.Enabled {
		t.Fatal("ShapeWorkers.Enabled is false")
	}
	for _, name := range []string{"read", "probe", "draft"} {
		if _, ok := workers.Roles[name]; !ok {
			t.Fatalf("ShapeWorkers.Roles has no %s: %+v", name, workers.Roles)
		}
	}
	if workers.Roles["read"].Provider != "anthropic" || workers.Roles["read"].External() {
		t.Fatalf("read = %+v", workers.Roles["read"])
	}
	if workers.Roles["draft"].Provider != "supergrok" || workers.Roles["draft"].External() {
		t.Fatalf("draft = %+v", workers.Roles["draft"])
	}
	if workers.Roles["probe"].Provider != "" {
		t.Fatalf("probe = %+v, want no provider", workers.Roles["probe"])
	}

	off := parse(t, "version: 1\n")
	if off.ShapeWorkers.Enabled {
		t.Fatal("ShapeWorkers.Enabled without the section")
	}
	disabled := parse(t, "version: 1\nshape_workers:\n  enabled: false\n  read: {model: r, effort: low}\n")
	if disabled.ShapeWorkers.Enabled {
		t.Fatal("ShapeWorkers.Enabled with enabled: false")
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
		{"workers without roles", "version: 1\nshape_workers:\n  enabled: true\n  read: {model: r, effort: low}\n", []string{
			"line 3: shape_workers.draft requires explicit model and effort",
			"line 3: shape_workers.probe requires explicit model and effort"}},
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

// TestReadableConfigKeepsWhatItCanRead: of an invalid file it keeps the model roles and workers
// it accepted (the invalid problem aside), with a role for every model role; of text it cannot
// read, or no text, it gives a native role with no provider for each model role and no workers.
func TestReadableConfigKeepsWhatItCanRead(t *testing.T) {
	partial := project.ReadableConfig("version: 1\nbogus: 1\nmodels:\n  shape: {provider: anthropic, model: m, effort: high}\n  build: {executor: claude-code, model: m, effort: high}\nshape_workers:\n  enabled: true\n  read: {model: r, effort: low, provider: supergrok}\n")
	for _, name := range project.ModelRoles {
		if _, ok := partial.Models[name]; !ok {
			t.Fatalf("Models has no %s", name)
		}
	}
	if partial.Models["shape"].Provider != "anthropic" || !partial.Models["build"].External() || partial.Models["review"].External() {
		t.Fatalf("Models = %+v", partial.Models)
	}
	if !partial.ShapeWorkers.Enabled || partial.ShapeWorkers.Roles["read"].Provider != "supergrok" {
		t.Fatalf("ShapeWorkers = %+v", partial.ShapeWorkers)
	}
	if _, found := partial.ShapeWorkers.Roles["probe"]; found {
		t.Fatalf("ShapeWorkers.Roles has an unsent probe: %+v", partial.ShapeWorkers.Roles)
	}

	for _, text := range []string{"", "version: 1\n\tbad: [\n"} {
		cfg := project.ReadableConfig(text)
		if cfg == nil {
			t.Fatalf("ReadableConfig(%q) = nil", text)
		}
		for _, name := range project.ModelRoles {
			role, ok := cfg.Models[name]
			if !ok || role.Provider != "" || role.External() {
				t.Fatalf("ReadableConfig(%q).Models[%s] = %+v (present %v)", text, name, role, ok)
			}
		}
		if cfg.ShapeWorkers.Enabled || len(cfg.ShapeWorkers.Roles) != 0 {
			t.Fatalf("ReadableConfig(%q).ShapeWorkers = %+v", text, cfg.ShapeWorkers)
		}
	}
}

package shape

import (
	"strings"
	"testing"

	"kogen-loop/sys"
	"kogen/executor"
	"kogen/project"
)

func lineupShapeConfig(t *testing.T, text string) *project.Config {
	t.Helper()
	cfg, err := project.ParseConfig("version: 1\n"+text, "f")
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}

// TestClaudeLineupNativeCompatibility: an omitted and an explicit native shape role are the same
// provider role and route natively; an external shaper is refused before inference (never shaped
// natively instead), enabled workers with it are refused explicitly, and a native shaper keeps
// its workers.
func TestClaudeLineupNativeCompatibility(t *testing.T) {
	omitted := lineupShapeConfig(t, "models:\n  shape: {model: s, effort: high}\n")
	explicit := lineupShapeConfig(t, "models:\n  shape: {executor: native, model: s, effort: high}\n")
	if ProviderRole(omitted.Models["shape"]) != ProviderRole(explicit.Models["shape"]) || omitted.Models["shape"] != explicit.Models["shape"] {
		t.Fatalf("explicit native differs: %+v %+v", omitted.Models["shape"], explicit.Models["shape"])
	}
	for _, cfg := range []*project.Config{omitted, explicit} {
		if err := requireShapeRoute(cfg); err != nil {
			t.Fatal(err)
		}
		if roles := ShapeRoles(cfg); len(roles) != 1 || roles[0].Model != "s" {
			t.Fatalf("native roles %+v", roles)
		}
	}
	workers := lineupShapeConfig(t, "models:\n  shape: {model: s, effort: high}\nshape_workers:\n  enabled: true\n  read: {model: r, effort: low}\n  probe: {model: p, effort: low}\n  draft: {model: d, effort: low}\n")
	if err := requireShapeRoute(workers); err != nil || len(ShapeRoles(workers)) != 4 {
		t.Fatalf("native workers: %v %+v", err, ShapeRoles(workers))
	}

	// An external shaper needs no native login and is selected only through the program's
	// executor; none available stops executor/unavailable (never shaped natively instead).
	ext := lineupShapeConfig(t, "models:\n  shape: {executor: claude-code, model: s, effort: high}\n")
	if err := requireShapeRoute(ext); err != nil || len(ShapeRoles(ext)) != 0 {
		t.Fatalf("external shaper: %v %+v", err, ShapeRoles(ext))
	}
	_, _, err := selectExternal(nil, ext.Models["shape"])
	if se, ok := sys.AsError(err); !ok || se.Class != "executor" || se.Reason != executor.ReasonUnavailable {
		t.Fatalf("no executor: %v", err)
	}
	ext.ShapeWorkers.Enabled = true
	se, ok := sys.AsError(requireShapeRoute(ext))
	if !ok || se.Reason != executor.ReasonUnavailable || !strings.Contains(se.Detail, "shape workers are not supported") {
		t.Fatalf("workers with a Claude Code shaper: %v", se)
	}
}

package build

import (
	"encoding/json"
	"strings"
	"testing"

	"kogen-loop/sys"
	"kogen/executor"
	"kogen/project"
)

func lineupConfig(t *testing.T, models string) *project.Config {
	t.Helper()
	cfg, err := project.ParseConfig("version: 1\nmodels:\n"+models, "f")
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}

// TestClaudeLineupNativeCompatibility: an omitted executor and an explicit `executor: native`
// are the same native role on every route, carry no executor identity in their serialized
// state, and a native role is never described as a claim of the v2 external adapter; an
// external review role without a route is refused, never reviewed natively.
func TestClaudeLineupNativeCompatibility(t *testing.T) {
	omitted := lineupConfig(t, "  shape: {model: s, effort: high}\n  build: {model: b, effort: medium}\n  review: {model: r, effort: high}\n")
	explicit := lineupConfig(t, "  shape: {executor: native, model: s, effort: high}\n  build: {executor: native, model: b, effort: medium}\n  review: {executor: native, model: r, effort: high}\n")
	a, _ := json.Marshal(omitted.Models)
	b, _ := json.Marshal(explicit.Models)
	if string(a) != string(b) {
		t.Fatalf("explicit native serializes differently:\n%s\n%s", a, b)
	}
	for _, key := range []string{"Executor", "MaxRounds", "executor", "max_rounds"} {
		if strings.Contains(string(b), key) {
			t.Fatalf("native role state names %s: %s", key, b)
		}
	}
	d := Deps{
		External: func(project.Role) (executor.Executor, error) {
			t.Error("a native role asked for an external executor")
			return nil, nil
		},
	}
	for _, role := range []string{"shape", "build", "review"} {
		if ext, err := selectExecutor(d, explicit.Models[role]); ext != nil || err != nil {
			t.Fatalf("%s: %v %v", role, ext, err)
		}
	}
	if got := buildRoles(explicit); len(got) != 2 || got[0].Model != "b" || got[1].Model != "r" {
		t.Fatalf("native login roles %+v", got)
	}

	desc := nativeExecutor{}.Describe()
	if desc.Contract != "kogen.executor/v2" || len(desc.RoleCapabilities) != 0 || len(desc.Capabilities.Roles) != 1 {
		t.Fatalf("native descriptor %+v", desc)
	}
	if err := desc.ValidateRole(executor.RoleBuild); err != nil {
		t.Fatal(err)
	}
	for _, role := range []string{executor.RoleShape, executor.RoleReview} {
		if err := desc.ValidateRole(role); err == nil {
			t.Fatalf("the native Build adapter claims the %s role", role)
		}
	}

	// External review: refused before any run when the program cannot provide the executor,
	// never reviewed natively, and without needing a native-provider login for the role.
	ext := lineupConfig(t, "  review: {executor: claude-code, model: r, effort: high}\n")
	for name, deps := range map[string]Deps{"no provider": {}, "nil executor": {External: func(project.Role) (executor.Executor, error) { return nil, nil }}} {
		rev, err := selectReviewer(deps, ext.Models["review"])
		se, ok := sys.AsError(err)
		if rev != nil || !ok || se.Class != "executor" || se.Reason != executor.ReasonUnavailable {
			t.Fatalf("%s: %v %v", name, rev, err)
		}
	}
	// A Build-only descriptor does not serve Review.
	buildOnly := Deps{External: func(project.Role) (executor.Executor, error) { return nativeExecutor{}, nil }}
	if _, err := selectReviewer(buildOnly, ext.Models["review"]); err == nil {
		t.Fatal("a Build-only executor was accepted for Review")
	}
	if rev, err := selectReviewer(Deps{Reviewer: reviewIndependent{}}, ext.Models["review"]); err != nil || rev == nil {
		t.Fatalf("a supplied reviewer seam was refused: %v", err)
	}
	if rev, err := selectReviewer(d, explicit.Models["review"]); rev != nil || err != nil {
		t.Fatalf("native review selection: %v %v", rev, err)
	}
	for _, r := range buildRoles(ext) {
		if r.Model == "r" {
			t.Fatalf("an external review role needs a native login: %+v", buildRoles(ext))
		}
	}
}

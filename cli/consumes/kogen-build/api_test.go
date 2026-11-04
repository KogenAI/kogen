package consumes

import (
	"context"
	"reflect"
	"regexp"
	"testing"

	"github.com/KogenAI/kogen-build/build"
	"github.com/KogenAI/kogen-coordinator/project"
	"github.com/KogenAI/kogen-executor/executor"
	"github.com/KogenAI/kogen-verification/verify"
	"kogen-loop/provider"
	"kogen-loop/sys"
)

// kogen cli/engine.go calls Build, Resume and Recover with the session's context and the
// session, and uses the exit code only when the error is nil.
var (
	_ func(context.Context, *sys.Session, build.Input) (int, error)        = build.Build
	_ func(context.Context, *sys.Session, build.ResumeInput) (int, error)  = build.Resume
	_ func(context.Context, *sys.Session, build.RecoverInput) (int, error) = build.Recover
)

// fields checks that the struct has each named field with the type, ignoring other fields.
func fields(t *testing.T, v any, want map[string]reflect.Type) {
	t.Helper()
	typ := reflect.TypeOf(v)
	for name, wt := range want {
		f, ok := typ.FieldByName(name)
		if !ok || f.Type != wt {
			t.Fatalf("%s.%s = %v (present %v), want %s", typ, name, f.Type, ok, wt)
		}
	}
}

// TestInputFields pins the fields kogen sets: the embedded Deps, with the client, the tools and
// the external executor function, and per command the project, the Intent slug or Build id, the
// optional diagnostic data and, for recovery, the output directory.
func TestInputFields(t *testing.T) {
	str := reflect.TypeOf("")
	deps := reflect.TypeOf(build.Deps{})
	fields(t, build.Deps{}, map[string]reflect.Type{
		"Client":   reflect.TypeOf((*provider.Client)(nil)),
		"Tools":    reflect.TypeOf(verify.Tools{}),
		"External": reflect.TypeOf((func(project.Role) (executor.Executor, error))(nil)),
	})
	fields(t, build.Input{}, map[string]reflect.Type{
		"Deps": deps, "Project": str, "Slug": str, "Context": reflect.TypeOf((*build.Diagnostic)(nil)),
	})
	fields(t, build.ResumeInput{}, map[string]reflect.Type{"Deps": deps, "Project": str, "ID": str})
	fields(t, build.RecoverInput{}, map[string]reflect.Type{"Project": str, "ID": str, "Output": str})
	fields(t, build.Diagnostic{}, map[string]reflect.Type{"Text": str, "SourcePath": str, "SHA256": str})
	// Input embeds Deps: kogen builds it with Input{Deps: Deps{...}}.
	if f, _ := reflect.TypeOf(build.Input{}).FieldByName("Deps"); !f.Anonymous {
		t.Fatal("Input.Deps is not an embedded field")
	}
	if f, _ := reflect.TypeOf(build.ResumeInput{}).FieldByName("Deps"); !f.Anonymous {
		t.Fatal("ResumeInput.Deps is not an embedded field")
	}
}

// TestExternalIsTheExecutorFactoryOfBuildRoles: a build role that selects an external executor
// calls Deps.External with that role, and an error it returns stops the Build before any run
// exists, as a refusal whose exit kogen returns. Here the function refuses the way kogen's
// externalExecutor does for an executor it does not provide.
func TestExternalIsTheExecutorFactoryOfBuildRoles(t *testing.T) {
	e := newEnv(t)
	roleEntry := regexp.MustCompile(`(?m)^  build:\n(?:    .*\n)+`)
	yaml := e.read(".kogen/project.yaml")
	if !roleEntry.MatchString(yaml) {
		t.Fatalf("no build role in:\n%s", yaml)
	}
	e.write(".kogen/project.yaml", roleEntry.ReplaceAllLiteralString(yaml, "  build:\n    executor: claude-code\n    model: claude-sonnet-5-5\n    effort: high\n"))
	e.run("git", "add", ".kogen/project.yaml")
	e.run("git", "commit", "-qm", "build with an external executor")
	e.approve()

	var asked []project.Role
	a := e.build(func(in *build.Input) {
		in.External = func(role project.Role) (executor.Executor, error) {
			asked = append(asked, role)
			return nil, executor.Fail(executor.ReasonUnavailable, "executor "+role.Executor+" is not available in this program")
		}
	})
	if len(asked) == 0 || asked[0].Executor != project.ExecutorClaudeCode {
		t.Fatalf("External was asked for %+v, want the claude-code build role", asked)
	}
	refusal := asRefusal(t, a.err)
	if a.exit != refusal.Exit || a.exit == 0 {
		t.Fatalf("exit %d, error exit %d\n%s", a.exit, refusal.Exit, a.shown())
	}
	contains(t, "rendering", refusal.Render(), "executor claude-code is not available in this program")
	if len(e.runIDs()) != 0 || len(e.prov.requests()) != 0 {
		t.Fatalf("runs %v, requests %d", e.runIDs(), len(e.prov.requests()))
	}
}

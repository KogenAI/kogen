package consumes

import (
	"context"
	"reflect"
	"testing"

	"github.com/KogenAI/kogen-coordinator/project"
	"github.com/KogenAI/kogen-executor/executor"
	"github.com/KogenAI/kogen-shaping/shape"
	"github.com/KogenAI/kogen-verification/verify"
	"kogen-loop/provider"
	"kogen-loop/sys"
)

// kogen cli/engine.go and cli/facts.go call these four functions with the session's context and
// the session, and use the exit code only when err is nil.
var (
	_ func(context.Context, *sys.Session, shape.ShapeInput) (int, error)     = shape.Shape
	_ func(context.Context, *sys.Session, shape.RefineInput) (int, error)    = shape.Refine
	_ func(context.Context, *sys.Session, shape.ApproveInput) (int, error)   = shape.Approve
	_ func(context.Context, *sys.Session, shape.PreflightInput) (int, error) = shape.Preflight
)

// externalExecutor is the shape of kogen's own externalExecutor (cli/engine.go), which kogen
// passes as the External field of ShapeInput and RefineInput.
func externalExecutor(project.Role) (executor.Executor, error) { return nil, nil }

// fields checks that the struct has each named field with exactly the type.
func fields(t *testing.T, typ reflect.Type, want map[string]reflect.Type) {
	t.Helper()
	for name, wantType := range want {
		f, ok := typ.FieldByName(name)
		if !ok || f.Type != wantType {
			t.Errorf("%s.%s = %v (present %v), want %s", typ.Name(), name, f.Type, ok, wantType)
		}
	}
}

// TestInputFields pins the fields kogen sets on each input, with their types, and that
// External accepts kogen's externalExecutor.
func TestInputFields(t *testing.T) {
	str, tools, client := reflect.TypeOf(""), reflect.TypeOf(verify.Tools{}), reflect.TypeOf((*provider.Client)(nil))
	_ = shape.ShapeInput{Project: "", Slug: "", Request: "", RequestPath: "", Tools: verify.Tools{}, InstallRoot: "", Client: (*provider.Client)(nil), External: externalExecutor}
	_ = shape.RefineInput{Project: "", Slug: "", Hash: "", Request: "", RequestPath: "", Tools: verify.Tools{}, InstallRoot: "", Client: (*provider.Client)(nil), External: externalExecutor}
	_ = shape.ApproveInput{Project: "", Slug: "", Hash: "", By: "", Tools: verify.Tools{}}
	_ = shape.PreflightInput{Project: "", Slug: "", JSON: false, Checkout: map[string]any{}}

	external := reflect.TypeOf(externalExecutor)
	for _, in := range []any{shape.ShapeInput{}, shape.RefineInput{}} {
		typ := reflect.TypeOf(in)
		fields(t, typ, map[string]reflect.Type{"Project": str, "Slug": str, "Request": str, "RequestPath": str, "Tools": tools, "InstallRoot": str, "Client": client})
		f, ok := typ.FieldByName("External")
		if !ok || !external.AssignableTo(f.Type) || f.Type.Kind() != reflect.Func {
			t.Errorf("%s.External = %v (present %v), want a func kogen's externalExecutor is assignable to", typ.Name(), f.Type, ok)
		}
	}
	fields(t, reflect.TypeOf(shape.RefineInput{}), map[string]reflect.Type{"Hash": str})
	fields(t, reflect.TypeOf(shape.ApproveInput{}), map[string]reflect.Type{"Project": str, "Slug": str, "Hash": str, "By": str, "Tools": tools})
	fields(t, reflect.TypeOf(shape.PreflightInput{}), map[string]reflect.Type{"Project": str, "Slug": str, "JSON": reflect.TypeOf(true), "Checkout": reflect.TypeOf((*any)(nil)).Elem()})
}

package consumes

import (
	"context"
	"reflect"
	"slices"
	"strings"
	"testing"

	"github.com/KogenAI/kogen-loop/provider"
	"github.com/KogenAI/kogen-loop/sys"
	"github.com/KogenAI/kogen-setup/setup"
	"github.com/KogenAI/kogen-verification/verify"
)

// kogen cli/engine.go calls
// `setup.Init(s.Context(), s, setup.InitInput{Client: client, Tools: tools})` and uses the exit
// code only when err is nil.
var _ func(context.Context, *sys.Session, setup.InitInput) (int, error) = setup.Init

// TestInitInputFields pins the two fields kogen sets: Client, a *provider.Client, and Tools, a
// verify.Tools.
func TestInitInputFields(t *testing.T) {
	_ = setup.InitInput{Client: (*provider.Client)(nil), Tools: verify.Tools{}}
	typ := reflect.TypeOf(setup.InitInput{})
	for name, want := range map[string]reflect.Type{
		"Client": reflect.TypeOf((*provider.Client)(nil)),
		"Tools":  reflect.TypeOf(verify.Tools{}),
	} {
		f, ok := typ.FieldByName(name)
		if !ok || f.Type != want {
			t.Fatalf("InitInput.%s = %v (present %v), want %s", name, f.Type, ok, want)
		}
	}
}

// TestInitUsesTheClientAndTheToolsOfTheInput: the client is the one that asks the shaping model
// (reading the login under the session's HOME, as kogen leaves no home in the input), and the
// tools are the ones the project's setup is checked with: the fake node and Cucumber of the
// fixture run, which makes the acceptance bridge write its steps folder README.
func TestInitUsesTheClientAndTheToolsOfTheInput(t *testing.T) {
	f := newInitFx(t, true, nothing())
	f.write("README.md", "x\n")
	f.commitAll("first")
	f.mustRun()
	if got := f.requests(); got != 1 {
		t.Fatalf("model requests = %d, want 1", got)
	}
	if !f.exists("features/steps/README.md") {
		t.Fatalf("the acceptance bridge wrote no features/steps/README.md\n%s", f.git("show", "--stat", "HEAD"))
	}
	want := []string{".gitignore", ".kogen/models.yaml", ".kogen/project.yaml", "features/steps/README.md"}
	if got := strings.Fields(f.git("show", "--name-only", "--format=", "HEAD")); !slices.Equal(got, want) {
		t.Fatalf("commit holds %q, want the configuration, the models file, .gitignore and the bridge %q", got, want)
	}
}

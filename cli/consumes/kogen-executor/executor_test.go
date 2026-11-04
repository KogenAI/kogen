package consumes

import (
	"reflect"
	"testing"

	"github.com/KogenAI/kogen-executor/executor"
	"github.com/KogenAI/kogen-executor/executor/claudecode"
	"kogen-loop/sys"
)

// TestFailIsAnExecutorSysError: kogen's externalExecutor refuses an executor that is not
// available with `executor.Fail(executor.ReasonUnavailable, detail)`, which kogen's exitFor
// prints with Render and exits with its Exit.
func TestFailIsAnExecutorSysError(t *testing.T) {
	t.Parallel()
	var err error = executor.Fail(executor.ReasonUnavailable, "executor other is not available in this program")
	e, ok := sys.AsError(err)
	if !ok {
		t.Fatalf("error %v (%T) is not a *sys.Error", err, err)
	}
	if e.Class != "executor" || e.Reason != executor.ReasonUnavailable {
		t.Fatalf("error %s/%s, want executor/unavailable", e.Class, e.Reason)
	}
	if e.Detail != "executor other is not available in this program" || e.Exit != 1 {
		t.Fatalf("detail %q, exit %d", e.Detail, e.Exit)
	}
	if got, want := e.Render(), "executor/unavailable: executor other is not available in this program\n"; got != want {
		t.Fatalf("Render = %q, want %q", got, want)
	}
}

// TestNewReturnsAnExecutor: kogen returns claudecode.New(Options{Home, HookCommand, Token})
// as an executor.Executor, the Build role backend whose methods are Describe and Start. The
// three options kogen sets keep their types.
func TestNewReturnsAnExecutor(t *testing.T) {
	t.Parallel()
	var exe executor.Executor = claudecode.New(claudecode.Options{Home: t.TempDir(), HookCommand: []string{"kogen", claudecode.HookSubcommand}, Token: "fake-token"})
	if exe == nil {
		t.Fatal("claudecode.New returned nil")
	}
	iface := reflect.TypeOf((*executor.Executor)(nil)).Elem()
	for _, name := range []string{"Describe", "Start"} {
		if _, ok := iface.MethodByName(name); !ok {
			t.Fatalf("executor.Executor has no method %s", name)
		}
	}
	opts := reflect.TypeOf(claudecode.Options{})
	for name, want := range map[string]reflect.Type{
		"Home":        reflect.TypeOf(""),
		"HookCommand": reflect.TypeOf([]string(nil)),
		"Token":       reflect.TypeOf(""),
	} {
		if f, ok := opts.FieldByName(name); !ok || f.Type != want {
			t.Fatalf("Options.%s = %v (present %v), want %s", name, f.Type, ok, want)
		}
	}
}

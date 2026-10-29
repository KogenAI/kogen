package tools

import (
	"context"
	"errors"
	"testing"
)

func TestTimeoutCustodyContextCalls(t *testing.T) {
	tt := &Tools{Root: t.TempDir(), Enabled: []string{ShellTool}}
	call := Call{Name: ShellTool, Arguments: `{"command":"printf exact"}`}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	// A live context must not impose policy on unbounded calls, and old nil wrappers
	// must retain exact ordinary bytes.
	for _, run := range []func() (Output, error){func() (Output, error) { return tt.RunContext(ctx, ShellTool, call.Args()) }, func() (Output, error) { return tt.CallContext(ctx, call) }, func() (Output, error) { return tt.Run(ShellTool, call.Args()) }, func() (Output, error) { return tt.Call(call) }} {
		out, err := run()
		if err != nil || out.Text != "exit status: 0\nexact" {
			t.Fatalf("%+v %v", out, err)
		}
	}
	// A context that is already done starts no shell: the call returns the context error
	// and publishes nothing.
	cancel()
	for _, run := range []func() (Output, error){func() (Output, error) { return tt.RunContext(ctx, ShellTool, call.Args()) }, func() (Output, error) { return tt.CallContext(ctx, call) }} {
		out, err := run()
		if !errors.Is(err, context.Canceled) || out.Text != "" {
			t.Fatalf("%+v %v", out, err)
		}
	}
}

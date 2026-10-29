package loop

import (
	"context"
	"errors"
	"testing"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
)

type custodyFake struct{}

func (custodyFake) Request(ctx context.Context, r Request) (*provider.Response, []any, error) {
	return &provider.Response{Items: []map[string]any{{"type": "function_call", "name": "shell", "arguments": "{}"}}}, r.Input, nil
}

func TestTimeoutCustodyHookPrecedence(t *testing.T) {
	for _, hook := range []string{"BeforeCall", "HandleCall", "AfterCall"} {
		ctx, cancel := context.WithCancel(context.Background())
		s := sys.NewWith(nil, t.TempDir())
		want := errors.New("hook owns this failure")
		fail := func() error { cancel(); s.Interrupt("SIGINT"); return want }
		h := Hooks{}
		switch hook {
		case "BeforeCall":
			h.BeforeCall = func(context.Context, tools.Call, []any) error { return fail() }
		case "HandleCall":
			h.HandleCall = func(context.Context, tools.Call) (Handled, error) { return Handled{}, fail() }
		case "AfterCall":
			h.HandleCall = func(context.Context, tools.Call) (Handled, error) { return Handled{Handled: true}, nil }
			h.AfterCall = func(context.Context, tools.Call, tools.Output, bool, []any) error { return fail() }
		}
		_, err := Run(ctx, Round{Tools: &tools.Tools{Session: s}}, nil, custodyFake{}, h)
		cancel()
		if err != want {
			t.Fatalf("%s: %v", hook, err)
		}
	}
}

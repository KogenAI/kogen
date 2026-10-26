package conformance

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"kogen-loop/loop"
	"kogen-loop/provider"
	"kogen-loop/tools"
)

// A successful tool return does not imply the context is still live. In
// particular, killing a shell group at deadline can unblock its tool call.
func TestCancellationDuringCallDoesNotPublishResultOrRequestAgain(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	rq := &scripted{responses: []*provider.Response{
		respond("r1", fakeCall("c1", "shell", `{}`)),
	}}
	published, requests := 0, 0
	result, err := loop.Run(ctx, loop.Round{}, nil, rq, loop.Hooks{
		BeforeRequest: func(context.Context, []any) error {
			requests++
			return nil
		},
		HandleCall: func(context.Context, tools.Call) (loop.Handled, error) {
			cancel()
			return loop.Handled{Handled: true, Output: tools.Output{Text: "interrupted"}}, nil
		},
		AfterCall: func(context.Context, tools.Call, tools.Output, bool, []any) error {
			published++
			return nil
		},
	})
	if !errors.Is(err, context.Canceled) || result.Ending != "" {
		t.Fatalf("result %v, error %v", result, err)
	}
	if published != 0 || requests != 1 {
		t.Fatalf("published %d results and started %d requests", published, requests)
	}
}

func TestHookCancellationCannotEndTheRoundOrStartMoreWork(t *testing.T) {
	for _, phase := range []string{"AfterResponse", "BeforeCall", "HandleCall", "AfterCall", "AfterTerminal"} {
		t.Run(phase, func(t *testing.T) {
			w := newWorld(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			item := fakeCall("c1", "write_file", `{"path":"side-effect","content":"wrong"}`)
			if phase == "AfterResponse" {
				item = message("claim")
			} else if phase == "AfterTerminal" {
				item = fakeCall("c1", "finish", `{}`)
			}
			rq := &scripted{responses: []*provider.Response{respond("r1", item), respond("r2", message("claim"))}}
			published, requests := 0, 0
			hooks := loop.Hooks{
				BeforeRequest: func(context.Context, []any) error {
					requests++
					return nil
				},
				AfterResponse: func(context.Context, *provider.Response, []any) error {
					if phase == "AfterResponse" {
						cancel()
					}
					return nil
				},
				BeforeCall: func(context.Context, tools.Call, []any) error {
					if phase == "BeforeCall" {
						cancel()
					}
					return nil
				},
				HandleCall: func(context.Context, tools.Call) (loop.Handled, error) {
					if phase == "HandleCall" {
						cancel()
					}
					return loop.Handled{}, nil
				},
				AfterCall: func(context.Context, tools.Call, tools.Output, bool, []any) error {
					published++
					if phase == "AfterCall" || phase == "AfterTerminal" {
						cancel()
					}
					return nil
				},
			}
			res, err := loop.Run(ctx, roundWith(t, w), nil, rq, hooks)
			if !errors.Is(err, context.Canceled) || res.Ending != "" || res.Terminal != nil {
				t.Fatalf("cancelled round returned result %+v, error %v", res, err)
			}
			if requests != 1 {
				t.Fatalf("started %d requests after cancellation", requests)
			}
			if phase == "BeforeCall" || phase == "HandleCall" {
				if _, err := os.Stat(filepath.Join(w.root, "side-effect")); !errors.Is(err, os.ErrNotExist) {
					t.Fatalf("tool executed after hook cancellation: stat error %v", err)
				}
				if published != 0 {
					t.Fatal("published a cancelled tool result")
				}
			}
		})
	}
}

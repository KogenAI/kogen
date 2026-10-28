package loop

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen-loop/provider"
	"kogen-loop/tools"
)

type lcutFake struct{ inputs [][]any }

func (f *lcutFake) Request(ctx context.Context, r Request) (*provider.Response, []any, error) {
	f.inputs = append(f.inputs, r.Input)
	if len(f.inputs) == 1 {
		return &provider.Response{Items: []map[string]any{{"type": "function_call", "name": "read_file", "call_id": "c1", "arguments": `{"path":"big.txt"}`}}}, r.Input, nil
	}
	return &provider.Response{Items: []map[string]any{{"type": "function_call", "name": "finish", "call_id": "c2", "arguments": "{}"}}}, r.Input, nil
}

func TestLCutLoopDelivery(t *testing.T) {
	root := t.TempDir()
	text := strings.Repeat("0123456789", 4000)
	if err := os.WriteFile(filepath.Join(root, "big.txt"), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	run := func(tl *tools.Tools, h Hooks) (*lcutFake, string, error) {
		f := &lcutFake{}
		_, err := Run(context.Background(), Round{Tools: tl}, nil, f, h)
		return f, "", err
	}
	var after string
	tl, err := tools.New(tools.Tools{Root: root, Enabled: []string{tools.ReadFileTool}, ResultBound: 32768, ResultHead: 8192})
	if err != nil {
		t.Fatal(err)
	}
	f, _, err := run(tl, Hooks{AfterCall: func(_ context.Context, c tools.Call, o tools.Output, term bool, _ []any) error {
		if !term {
			after = o.Text
		}
		return nil
	}})
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := tl.Run(tools.ReadFileTool, map[string]any{"path": "big.txt"})
	want := tl.Cut(raw).Text
	if after != want || len(after) > 32768 || !strings.HasPrefix(after, raw.Text[:8192]+"\n[... ") {
		t.Fatalf("AfterCall output %d bytes not the configured cut (raw %d)", len(after), len(raw.Text))
	}
	last := f.inputs[1][len(f.inputs[1])-1].(map[string]any)
	if last["output"] != want {
		t.Errorf("next request carries %T, not the configured cut", last["output"])
	}

	// Host-owned interception is not cut.
	host := strings.Repeat("h", 40000)
	var got string
	_, err = Run(context.Background(), Round{Tools: tl}, nil, &lcutFake{}, Hooks{
		HandleCall: func(context.Context, tools.Call) (Handled, error) {
			return Handled{Handled: true, Output: tools.Output{Text: host}}, nil
		},
		AfterCall: func(_ context.Context, _ tools.Call, o tools.Output, term bool, _ []any) error {
			if !term {
				got = o.Text
			}
			return nil
		},
	})
	if err != nil || got != host {
		t.Errorf("intercepted output changed: %v %d", err, len(got))
	}

	// Invalid literal is refused before any tool executes.
	bad := &tools.Tools{Root: root, Enabled: []string{tools.ReadFileTool}, ResultBound: 127}
	called := false
	fb := &lcutFake{}
	_, err = Run(context.Background(), Round{Tools: bad}, nil, fb, Hooks{BeforeRequest: func(context.Context, []any) error { called = true; return nil }, AfterCall: func(context.Context, tools.Call, tools.Output, bool, []any) error { called = true; return nil }})
	if err == nil || !strings.Contains(err.Error(), "ResultBound") || called || len(fb.inputs) != 0 {
		t.Errorf("invalid literal: err %v, executed %v", err, called)
	}
}

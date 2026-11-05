package tools

import (
	"context"
	"testing"

	"github.com/KogenAI/kogen-loop/api"
)

func TestSearchTextRejectsNULPatterns(t *testing.T) {
	_, root := newRepo(t)
	write(t, root, "a.txt", "alpha only\n")
	write(t, root, "b.txt", "beta only\n")
	commitAll(t, root)
	tl := newTools(root, SearchTextTool)
	for _, tc := range []struct{ pattern, want string }{
		{"alpha\x00beta", "error: pattern contains a NUL character"},
		{"\x00beta", "error: pattern contains a NUL character"},
		{"(", "error: invalid pattern: missing closing ): `(`"},
	} {
		t.Run(tc.pattern, func(t *testing.T) {
			args := map[string]any{"pattern": tc.pattern}
			out, err := tl.RunContext(context.Background(), SearchTextTool, args)
			if err != nil || out.Typed() || out.Text != tc.want {
				t.Fatalf("RunContext = %+v, %v; want %q", out, err, tc.want)
			}
			classified, err := tl.RunClassified(context.Background(), SearchTextTool, args)
			if err != nil || classified.Text != tc.want || classified.ErrorKind != api.ToolErrorGit {
				t.Errorf("RunClassified = %+v, %v; want %q and %q", classified, err, tc.want, api.ToolErrorGit)
			}
		})
	}
}

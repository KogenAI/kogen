package tools

import (
	"os"
	"testing"

	"github.com/KogenAI/kogen-loop/sys"
)

func TestShellEmptyHandleSelection(t *testing.T) {
	root := t.TempDir()
	tl := &Tools{Root: root, Session: sys.NewWith(os.Environ(), root), Enabled: []string{ShellTool}}
	defer tl.EndShellRound()
	for _, tc := range []struct {
		name string
		args map[string]any
		want string
	}{
		{"absent", map[string]any{"command": "printf ok"}, "exit status: 0\nok"},
		{"null", map[string]any{"command": "printf ok", "handle": nil}, "exit status: 0\nok"},
		{"empty", map[string]any{"command": "printf ok", "handle": ""}, "exit status: 0\nok"},
		{"space", map[string]any{"command": "printf ok", "handle": "   "}, "exit status: 0\nok"},
		{"number", map[string]any{"command": "printf ok", "handle": 42}, "exit status: 0\nok"},
		{"boolean", map[string]any{"command": "printf ok", "handle": false}, "exit status: 0\nok"},
		{"array", map[string]any{"command": "printf ok", "handle": []any{}}, "exit status: 0\nok"},
		{"object", map[string]any{"command": "printf ok", "handle": map[string]any{}}, "exit status: 0\nok"},
		{"invalid command", map[string]any{"command": 42, "handle": ""}, "error: argument command must be a string"},
		{"conflict", map[string]any{"command": "printf no", "handle": " id "}, "error: supply exactly one of command or handle"},
		{"handle identity", map[string]any{"handle": " id "}, "error: unknown shell handle"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := run(t, tl, ShellTool, tc.args); got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

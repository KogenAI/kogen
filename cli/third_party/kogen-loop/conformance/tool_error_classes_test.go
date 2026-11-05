package conformance

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/KogenAI/kogen-loop/api"
	"github.com/KogenAI/kogen-loop/loop"
)

// Every tool error's tool.result carries "error_kind", every malformed call's carries
// "malformed_class", each from the fixed vocabulary; any other result carries neither, and
// tool.call keeps its fields.
func TestSessionToolResultNamesErrorKindAndMalformedClass(t *testing.T) {
	t.Parallel()
	w := newWorld(t).signIn()
	for name, content := range map[string]string{"a.txt": "alpha\n", "bad.png": "not a png"} {
		if err := os.WriteFile(filepath.Join(w.root, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(filepath.Join(w.root, "dir"), 0o755); err != nil {
		t.Fatal(err)
	}
	type want struct {
		name string
		args map[string]any
		kind string
		cls  string
	}
	cases := []want{
		{"read_file", map[string]any{"path": "a.txt"}, "", ""},
		{"read_file", map[string]any{"path": "gone is a folder; use list_files"}, api.ToolErrorNotFound, ""},
		{"read_file", map[string]any{"path": "dir"}, api.ToolErrorIsFolder, ""},
		{"read_file", map[string]any{"path": "../x"}, api.ToolErrorOutsideRoot, ""},
		{"read_file", map[string]any{"path": "a.txt/x"}, api.ToolErrorFile, ""},
		{"write_file", map[string]any{"path": "guard.txt", "content": "x"}, api.ToolErrorProtected, ""},
		{"write_file", map[string]any{"path": "a.txt/x", "content": "x"}, api.ToolErrorFile, ""},
		{"list_files", map[string]any{}, api.ToolErrorGit, ""},
		{"search_text", map[string]any{"pattern": "a"}, api.ToolErrorGit, ""},
		{"list_files", map[string]any{"path": "~"}, api.ToolErrorOutsideRoot, ""},
		{"search_text", map[string]any{"pattern": "a", "path": "a.txt/x"}, api.ToolErrorFile, ""},
		{"search_text", map[string]any{"pattern": "("}, api.ToolErrorGit, ""},
		{"search_text", map[string]any{"pattern": "(", "path": "../x"}, api.ToolErrorOutsideRoot, ""},
		{"shell", map[string]any{"handle": "nope"}, api.ToolErrorUnknownShellHandle, ""},
		{"shell", map[string]any{"command": "pkill -f nothing-at-all"}, api.ToolErrorForeignKill, ""},
		{"shell", map[string]any{"command": "exit 3"}, "", ""},
		{"view_image", map[string]any{"path": "bad.png"}, api.ToolErrorInvalidImage, ""},
		{"view_image", map[string]any{"path": "../x.png"}, api.ToolErrorOutsideRoot, ""},
		{"delete_file", map[string]any{"path": "a.txt"}, "", api.MalformedUnknownTool},
		{"documentation", map[string]any{"query": "x"}, "", api.MalformedUnknownTool},
		{"read_file", map[string]any{}, "", api.MalformedMissingArgument},
		{"read_file", map[string]any{"path": nil}, "", api.MalformedWrongArgumentType},
		{"write_file", map[string]any{"path": "b.txt"}, "", api.MalformedMissingArgument},
		{"write_file", map[string]any{"content": "x"}, "", api.MalformedMissingArgument},
		{"write_file", map[string]any{"path": "b.txt", "content": 7}, "", api.MalformedWrongArgumentType},
		{"search_text", map[string]any{}, "", api.MalformedMissingArgument},
		{"view_image", map[string]any{}, "", api.MalformedMissingArgument},
		{"view_image", map[string]any{"path": 3}, "", api.MalformedWrongArgumentType},
		{"shell", map[string]any{"command": "echo a", "handle": "h"}, "", api.MalformedConflictingArguments},
		{"shell", map[string]any{}, "", api.MalformedMissingArgument},
		{"shell", map[string]any{"command": "  "}, "", api.MalformedMissingArgument},
		{"shell", map[string]any{"command": 5}, "", api.MalformedWrongArgumentType},
	}
	var exchanges []exchange
	for i, c := range cases {
		id := "c" + string(rune('A'+i/26)) + string(rune('a'+i%26))
		exchanges = append(exchanges, exchange{Items: []map[string]any{call(id, c.name, c.args)}})
	}
	exchanges = append(exchanges, exchange{Items: []map[string]any{call("end", "finish", map[string]any{"summary": "done"})}})
	f := newFakeProvider(t, exchanges)
	var events []api.Event
	cfg := sessionConfig(w, f, &events)
	cfg.Protected = []string{"guard.txt"}
	cfg.Enabled = []string{"read_file", "write_file", "list_files", "search_text", "shell", "view_image"}
	s, err := loop.NewSession(cfg)
	if err != nil {
		t.Fatal(err)
	}
	res, err := s.Round(context.Background(), "open")
	if err != nil || res.Ending != loop.EndTerminal {
		t.Fatalf("%v %v", res, err)
	}
	var calls, results []map[string]any
	for _, e := range events {
		switch e.Type {
		case api.EventToolCall:
			calls = append(calls, e.Fields)
		case api.EventToolResult:
			results = append(results, e.Fields)
		}
	}
	if len(results) != len(cases) || len(calls) != len(cases)+1 {
		t.Fatalf("%d calls, %d results", len(calls), len(results))
	}
	for _, c := range calls {
		if len(c) != 3 {
			t.Errorf("tool.call fields %v", c)
		}
	}
	for i, c := range cases {
		r := results[i]
		kind, hasKind := r["error_kind"]
		cls, hasClass := r["malformed_class"]
		if (c.kind == "") == hasKind || (c.cls == "") == hasClass || (hasKind && kind != c.kind) || (hasClass && cls != c.cls) {
			t.Errorf("%s %v: error_kind %v, malformed_class %v; want %q, %q", c.name, c.args, kind, cls, c.kind, c.cls)
		}
		if c.kind == api.ToolErrorForeignKill && r["rule"] != "pkill-killall" {
			t.Errorf("foreign kill lost its rule: %v", r)
		}
	}
}

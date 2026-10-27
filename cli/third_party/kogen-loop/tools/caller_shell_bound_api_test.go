package tools

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestCallerShellBoundDefinitions(t *testing.T) {
	bytes := func(v any) string {
		b, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	for _, bound := range []time.Duration{-time.Second, 0, time.Nanosecond, 1500 * time.Millisecond, 2 * time.Second} {
		tool := &Tools{ShellTimeout: bound}
		for _, name := range []string{ShellTool, ReadFileTool, ViewImageTool, WriteFileTool, ListFilesTool, SearchTextTool, DocumentationTool, "unknown"} {
			base, known := Definition(name)
			got, ok := tool.Definition(name)
			if ok != known {
				t.Fatalf("known %s: %v", name, ok)
			}
			before := bytes(got)
			if bound <= 0 || name != ShellTool {
				if before != bytes(base) {
					t.Fatalf("changed default %s at %s", name, bound)
				}
			} else {
				want := strings.Replace(base["description"].(string), "Commands have no time limit.", "Each shell call has a caller-configured time limit of "+bound.String()+". A timed-out command's process group is stopped before a timed-out result is returned.", 1)
				if got["description"] != want {
					t.Fatalf("description: %v", got["description"])
				}
				got["description"] = base["description"]
				if bytes(got) != bytes(base) {
					t.Fatal("changed non-description fields")
				}
				got["description"] = want
			}
			again, _ := tool.Definition(name)
			if bytes(again) != before {
				t.Fatal("unstable definition")
			}
			tool.ShellTimeout = 3 * time.Second
			tool.Definition(name)
			if bytes(got) != before {
				t.Fatal("mutated previous definition")
			}
			tool.ShellTimeout = bound
		}
	}
}

func TestCallerShellBoundOrdinaryResults(t *testing.T) {
	for _, bound := range []time.Duration{-1, 0, time.Second} {
		tool := &Tools{Root: t.TempDir(), Enabled: []string{ShellTool}, ShellTimeout: bound}
		out, err := tool.Run(ShellTool, map[string]any{"command": "printf 'out\n'; printf 'err\n' >&2; exit 7"})
		if err != nil || out.Text != "exit status: 7\nout\nerr\n" {
			t.Fatalf("%s: %+v, %v", bound, out, err)
		}
	}
}

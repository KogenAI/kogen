package tools

import (
	"encoding/json"
	"kogen-loop/sys"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestShellYieldRetrievalScope(t *testing.T) {
	root := t.TempDir()
	tl := &Tools{Root: root, Session: sys.NewWith(os.Environ(), root), Enabled: []string{ShellTool}}
	defer tl.EndShellRound()
	decode := func(s string) map[string]any {
		t.Helper()
		var v map[string]any
		if err := json.Unmarshal([]byte(s), &v); err != nil {
			t.Fatalf("invalid JSON %q: %v", s, err)
		}
		return v
	}
	start := time.Now()
	v := decode(run(t, tl, ShellTool, map[string]any{"command": "printf one; while [ ! -f release ]; do sleep .05; done; printf two; exit 7"}))
	if v["status"] != "running" || v["output"] != "one" || time.Since(start) > 5*time.Second {
		t.Fatalf("yield: %v", v)
	}
	id, ok := v["handle"].(string)
	if !ok || id == "" {
		t.Fatal(v)
	}
	start = time.Now()
	v = decode(run(t, tl, ShellTool, map[string]any{"handle": id}))
	if v["status"] != "running" || time.Since(start) > 5*time.Second {
		t.Fatal(v)
	}
	if err := os.WriteFile(filepath.Join(root, "release"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		v = decode(run(t, tl, ShellTool, map[string]any{"handle": id}))
		if v["status"] != "completed" || v["exit_status"] != float64(7) || v["output"] != "onetwo" {
			t.Fatal(v)
		}
	}
	tl.EndShellRound()
	for _, a := range []map[string]any{{}, {"handle": id}, {"handle": "unknown"}, {"command": "touch bad", "handle": id}, {"handle": 42}} {
		if got := run(t, tl, ShellTool, a); !strings.HasPrefix(got, "error:") {
			t.Fatalf("%v: %s", a, got)
		}
	}
	if _, err := os.Stat(filepath.Join(root, "bad")); !os.IsNotExist(err) {
		t.Fatal("invalid call launched command")
	}
}

func TestShellYieldLargeJSON(t *testing.T) {
	for _, n := range []string{"16383", "16384", "16385", "200000"} {
		t.Run(n, func(t *testing.T) {
			root := t.TempDir()
			tl := &Tools{Root: root, Session: sys.NewWith(os.Environ(), root), Enabled: []string{ShellTool}}
			defer tl.EndShellRound()
			parse := func(s string) map[string]any {
				t.Helper()
				var v map[string]any
				if len(s) > maxResult || json.Unmarshal([]byte(s), &v) != nil {
					t.Fatalf("invalid envelope length %d", len(s))
				}
				return v
			}
			v := parse(run(t, tl, ShellTool, map[string]any{"command": "head -c " + n + " /dev/zero; while [ ! -f release ]; do sleep .05; done"}))
			if v["status"] != "running" {
				t.Fatal(v)
			}
			id := v["handle"]
			if err := os.WriteFile(filepath.Join(root, "release"), nil, 0600); err != nil {
				t.Fatal(err)
			}
			v = parse(run(t, tl, ShellTool, map[string]any{"handle": id}))
			if v["status"] != "completed" {
				t.Fatal(v)
			}
		})
	}
}

func TestShellYieldLargeMalformedOutput(t *testing.T) {
	root := t.TempDir()
	tl := &Tools{Root: root, Session: sys.NewWith(os.Environ(), root), Enabled: []string{ShellTool}}
	defer tl.EndShellRound()
	command := `printf '\377'; head -c 20000 /dev/zero | tr '\000' x; printf '\376'; while [ ! -f release ]; do sleep .05; done`
	check := func(s string, status string) {
		t.Helper()
		var v map[string]any
		if len(s) > maxResult || json.Unmarshal([]byte(s), &v) != nil || v["status"] != status {
			t.Fatalf("bad envelope: %q", s)
		}
		output, ok := v["output"].(string)
		if !ok || !strings.HasPrefix(output, "�xxx") || !strings.HasSuffix(output, "xxx�") || !strings.Contains(output, "bytes omitted") {
			t.Fatalf("lost retained output: %q", output)
		}
	}
	s := run(t, tl, ShellTool, map[string]any{"command": command})
	check(s, "running")
	var v map[string]any
	if err := json.Unmarshal([]byte(s), &v); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "release"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	check(run(t, tl, ShellTool, map[string]any{"handle": v["handle"]}), "completed")
}

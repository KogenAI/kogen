package tools_test

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"kogen-loop/tools"
)

func TestLTooldescCompact(t *testing.T) {
	names := []string{tools.ShellTool, tools.ViewImageTool, tools.ReadFileTool, tools.WriteFileTool, tools.ListFilesTool, tools.SearchTextTool, tools.DocumentationTool}
	marshal := func(v any) []byte {
		t.Helper()
		b, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	load := func(path string) map[string]any {
		t.Helper()
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var v map[string]any
		if err = json.Unmarshal(b, &v); err != nil {
			t.Fatal(err)
		}
		return v
	}
	fullGolden := load("testdata/defs_golden.json")
	compactGolden := load("testdata/defs_compact_golden.json")
	if len(compactGolden) != len(names) {
		t.Fatal("compact golden must have exactly seven entries")
	}
	full, compact := &tools.Tools{}, &tools.Tools{CompactDescriptions: true}
	defs := tools.Defs(names...)
	var fullArray, compactArray []map[string]any
	var strip func(any) any
	strip = func(v any) any {
		switch x := v.(type) {
		case map[string]any:
			m := map[string]any{}
			for k, e := range x {
				if k == "description" {
					if _, ok := e.(string); !ok {
						t.Fatalf("description is not string: %v", e)
					}
					m[k] = ""
				} else {
					m[k] = strip(e)
				}
			}
			return m
		case []any:
			a := make([]any, len(x))
			for i, e := range x {
				a[i] = strip(e)
			}
			return a
		default:
			return v
		}
	}
	for i, name := range names {
		if !bytes.Equal(marshal(defs[i]), marshal(fullGolden[name])) {
			t.Errorf("%s Defs differs from golden", name)
		}
		pkg, ok := tools.Definition(name)
		if !ok {
			t.Fatal(name)
		}
		f, ok := full.Definition(name)
		if !ok {
			t.Fatal(name)
		}
		c, ok := compact.Definition(name)
		if !ok {
			t.Fatal(name)
		}
		if !bytes.Equal(marshal(pkg), marshal(fullGolden[name])) || !bytes.Equal(marshal(f), marshal(fullGolden[name])) {
			t.Errorf("%s default differs from golden", name)
		}
		if !bytes.Equal(marshal(c), marshal(compactGolden[name])) {
			t.Errorf("%s compact differs from golden", name)
		}
		if !reflect.DeepEqual(strip(f), strip(c)) {
			t.Errorf("%s schema or description keys differ", name)
		}
		fullArray = append(fullArray, f)
		compactArray = append(compactArray, c)
	}
	if 100*len(marshal(compactArray)) > 70*len(marshal(fullArray)) {
		t.Errorf("insufficient reduction: compact %d full %d", len(marshal(compactArray)), len(marshal(fullArray)))
	}
	for _, isCompact := range []bool{false, true} {
		instance := &tools.Tools{CompactDescriptions: isCompact}
		old, _ := instance.Definition(tools.ShellTool)
		before := marshal(old)
		instance.ShellTimeout = 2 * time.Second
		timed, _ := instance.Definition(tools.ShellTool)
		desc := timed["description"].(string)
		if !strings.Contains(desc, "2s") || !strings.Contains(desc, "process group") || !strings.Contains(desc, "before") {
			t.Errorf("timeout description: %s", desc)
		}
		again, _ := instance.Definition(tools.ShellTool)
		if !bytes.Equal(marshal(timed), marshal(again)) || !bytes.Equal(before, marshal(old)) {
			t.Error("definition mutated or unstable")
		}
		other := &tools.Tools{CompactDescriptions: isCompact}
		untouched, _ := other.Definition(tools.ShellTool)
		if !bytes.Equal(before, marshal(untouched)) {
			t.Error("other instance changed")
		}
		instance.ShellTimeout = 0
		restored, _ := instance.Definition(tools.ShellTool)
		if !bytes.Equal(before, marshal(restored)) {
			t.Error("zero timeout not restored")
		}
	}
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "sample.txt"), []byte("hello\nworld\n"), 0600); err != nil {
		t.Fatal(err)
	}
	full.Root = root
	compact.Root = root
	full.Enabled = []string{tools.ReadFileTool}
	compact.Enabled = []string{tools.ReadFileTool}
	a, err := full.Run(tools.ReadFileTool, map[string]any{"path": "sample.txt"})
	if err != nil {
		t.Fatal(err)
	}
	b, err := compact.Run(tools.ReadFileTool, map[string]any{"path": "sample.txt"})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(a, b) || a.Text != "1\thello\n2\tworld" {
		t.Errorf("read results: %#v %#v", a, b)
	}
}

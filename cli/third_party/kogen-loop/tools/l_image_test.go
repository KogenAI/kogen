package tools_test

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"

	"kogen-loop/tools"
)

var lImageNames = []string{tools.ShellTool, tools.ViewImageTool, tools.ReadFileTool, tools.WriteFileTool, tools.ListFilesTool, tools.SearchTextTool, tools.DocumentationTool}

func lImageJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestLImageDefinitions(t *testing.T) {
	for _, compact := range []bool{false, true} {
		off := &tools.Tools{CompactDescriptions: compact}
		on := &tools.Tools{CompactDescriptions: compact, OmitViewImage: true}
		var offList, onList, expected []map[string]any
		for _, name := range lImageNames {
			d, ok := off.Definition(name)
			if !ok {
				t.Fatalf("off missing %s", name)
			}
			offList = append(offList, d)
			got, ok := on.Definition(name)
			if name == tools.ViewImageTool {
				if ok || got != nil {
					t.Fatalf("image present: %v %v", got, ok)
				}
				continue
			}
			if !ok {
				t.Fatalf("on missing %s", name)
			}
			onList = append(onList, got)
			expected = append(expected, d)
		}
		if !reflect.DeepEqual(onList, expected) {
			t.Errorf("remaining definitions changed or reordered")
		}
		offBytes, onBytes := len(lImageJSON(t, offList)), len(lImageJSON(t, onList))
		t.Logf("compact=%v serialized tool-list bytes off=%d on=%d", compact, offBytes, onBytes)
		if onBytes >= offBytes {
			t.Error("omission did not reduce bytes")
		}
	}
}

func TestLImageRefusal(t *testing.T) {
	instance := &tools.Tools{OmitViewImage: true, Enabled: []string{tools.ViewImageTool}}
	call := tools.Call{Name: tools.ViewImageTool, Arguments: `{}`}
	runs := map[string]func() (tools.Output, error){
		"Run": func() (tools.Output, error) { return instance.Run(tools.ViewImageTool, nil) },
		"RunContext": func() (tools.Output, error) {
			return instance.RunContext(context.Background(), tools.ViewImageTool, nil)
		},
		"Call":        func() (tools.Output, error) { return instance.Call(call) },
		"CallContext": func() (tools.Output, error) { return instance.CallContext(context.Background(), call) },
	}
	for name, run := range runs {
		t.Run(name, func(t *testing.T) {
			got, err := run()
			if err != nil || !reflect.DeepEqual(got, tools.Output{Text: "error: unknown tool view_image"}) {
				t.Fatalf("got %#v, %v", got, err)
			}
		})
	}
}

func TestLImageDefaults(t *testing.T) {
	data, err := os.ReadFile("testdata/defs_golden.json")
	if err != nil {
		t.Fatal(err)
	}
	var golden map[string]any
	if err := json.Unmarshal(data, &golden); err != nil {
		t.Fatal(err)
	}
	for _, instance := range []*tools.Tools{{}, {OmitViewImage: false}} {
		for _, name := range lImageNames {
			got, ok := instance.Definition(name)
			if !ok {
				t.Fatalf("missing %s", name)
			}
			want, ok := golden[name]
			if !ok {
				t.Fatalf("golden missing %s", name)
			}
			if !bytes.Equal(lImageJSON(t, got), lImageJSON(t, want)) {
				t.Errorf("%s differs from golden", name)
			}
		}
		instance.Enabled = []string{tools.ViewImageTool}
		out, err := instance.Run(tools.ViewImageTool, nil)
		if err != nil || !strings.Contains(out.Text, "path must be a string") {
			t.Errorf("default image dispatch: %#v, %v", out, err)
		}
	}
}

func TestLImagePackageDefaults(t *testing.T) {
	on := &tools.Tools{OmitViewImage: true}
	if d, ok := on.Definition(tools.ViewImageTool); ok || d != nil {
		t.Fatal("image not omitted")
	}
	off := &tools.Tools{}
	defs := tools.Defs(lImageNames...)
	for i, name := range lImageNames {
		pkg, ok := tools.Definition(name)
		if !ok {
			t.Fatalf("package missing %s", name)
		}
		instance, ok := off.Definition(name)
		if !ok {
			t.Fatalf("instance missing %s", name)
		}
		if !reflect.DeepEqual(pkg, instance) || !reflect.DeepEqual(defs[i], instance) {
			t.Errorf("%s differs", name)
		}
	}
}

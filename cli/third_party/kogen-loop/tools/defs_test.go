package tools

import (
	"bytes"
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

// genericNames are the definitions that live here; testdata/defs_golden.json also holds
// Kogen's workflow definitions (finish, report_blocker, probe, submit*, shape_batch,
// worker_result), which Kogen keeps and compares against its own copy of the golden file.
var genericNames = []string{ShellTool, ViewImageTool, ReadFileTool, WriteFileTool, ListFilesTool, SearchTextTool, DocumentationTool}

// TestGenericDefinitionsMatchTheGolden compares each generic definition with the JSON the
// Elixir functions returned (kept in the golden file), as parsed values.
func TestGenericDefinitionsMatchTheGolden(t *testing.T) {
	data, err := os.ReadFile("testdata/defs_golden.json")
	if err != nil {
		t.Fatal(err)
	}
	var want map[string]any
	if err := json.Unmarshal(data, &want); err != nil {
		t.Fatal(err)
	}
	for _, name := range genericNames {
		t.Run(name, func(t *testing.T) {
			def, ok := Definition(name)
			if !ok {
				t.Fatalf("no definition for %s", name)
			}
			var got any
			if err := json.Unmarshal(mustJSON(t, def), &got); err != nil {
				t.Fatal(err)
			}
			if _, ok := want[name]; !ok {
				t.Fatalf("golden has no %s", name)
			}
			if !reflect.DeepEqual(got, want[name]) {
				t.Errorf("definition differs\n got: %s\nwant: %s", mustJSON(t, got), mustJSON(t, want[name]))
			}
			inst, ok := (&Tools{}).Definition(name)
			if !ok || !bytes.Equal(mustJSON(t, inst), mustJSON(t, def)) {
				t.Errorf("instance definition differs from the default: %v", ok)
			}
		})
	}
}

// TestShellTimeoutChangesOnlyTheFullShellDescription checks that the caller-owned timeout is
// reflected in the full shell description, stably, without touching earlier definitions or
// another instance, and that a zero timeout restores the default bytes.
func TestShellTimeoutChangesOnlyTheFullShellDescription(t *testing.T) {
	instance := &Tools{}
	old, _ := instance.Definition(ShellTool)
	before := mustJSON(t, old)
	instance.ShellTimeout = 2 * time.Second
	timed, _ := instance.Definition(ShellTool)
	desc := timed["description"].(string)
	if !strings.Contains(desc, "2s") || !strings.Contains(desc, "process group") || !strings.Contains(desc, "before") {
		t.Errorf("timeout description: %s", desc)
	}
	again, _ := instance.Definition(ShellTool)
	if !bytes.Equal(mustJSON(t, timed), mustJSON(t, again)) || !bytes.Equal(before, mustJSON(t, old)) {
		t.Error("definition mutated or unstable")
	}
	untouched, _ := (&Tools{}).Definition(ShellTool)
	if !bytes.Equal(before, mustJSON(t, untouched)) {
		t.Error("other instance changed")
	}
	for _, name := range genericNames[1:] {
		def, _ := Definition(name)
		got, _ := instance.Definition(name)
		if !bytes.Equal(mustJSON(t, def), mustJSON(t, got)) {
			t.Errorf("%s changed by the shell timeout", name)
		}
	}
	instance.ShellTimeout = 0
	restored, _ := instance.Definition(ShellTool)
	if !bytes.Equal(before, mustJSON(t, restored)) {
		t.Error("zero timeout not restored")
	}
}

func TestDefinitionRefusesNamesThatAreNotGeneric(t *testing.T) {
	for _, name := range []string{ProbeTool, "finish", "report_blocker", "submit", "submit_review",
		"submit_refinement", "submit_configuration", "shape_batch", "worker_result", "bogus", ""} {
		if def, ok := Definition(name); ok || def != nil {
			t.Errorf("%q: %v %v", name, def, ok)
		}
	}
}

func TestDefsKeepTheOrderAskedFor(t *testing.T) {
	defs := Defs(ShellTool, ReadFileTool, DocumentationTool)
	var names []string
	for _, d := range defs {
		names = append(names, d["name"].(string))
	}
	if !reflect.DeepEqual(names, []string{"shell", "read_file", "documentation"}) {
		t.Errorf("names %v", names)
	}
	if got := Defs(); len(got) != 0 {
		t.Errorf("Defs() = %v", got)
	}
	list := AsAny(Defs(ShellTool), Defs(ListFilesTool, SearchTextTool))
	if len(list) != 3 || list[2].(map[string]any)["name"] != "search_text" {
		t.Errorf("AsAny = %v", list)
	}
}

func TestDefsPanicOnANameThatIsNotGeneric(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Error("Defs(finish) did not panic")
		}
	}()
	Defs("finish")
}

func TestEveryDefinitionIsPlainJSON(t *testing.T) {
	// Provider requests encode []any and map[string]any only through their own encoder; a
	// typed slice or a struct in a definition would be encoded differently.
	var walk func(path string, v any)
	walk = func(path string, v any) {
		switch x := v.(type) {
		case map[string]any:
			for k, e := range x {
				walk(path+"."+k, e)
			}
		case []any:
			for _, e := range x {
				walk(path+"[]", e)
			}
		case string, bool, int, int64, float64, nil:
		default:
			t.Errorf("%s is %T", path, v)
		}
	}
	for _, name := range genericNames {
		walk(name, Defs(name)[0])
	}
}

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

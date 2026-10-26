package tools

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
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
		})
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

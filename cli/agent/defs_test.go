package agent

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

// TestDefinitionsMatchTheElixirDefinitions compares every tool definition (Kogen.Tools.defs/1,
// the submit_* definitions of shape, review, refine and init, shape_batch and worker_result)
// with the JSON the Elixir functions return, as parsed values.
func TestDefinitionsMatchTheElixirDefinitions(t *testing.T) {
	data, err := os.ReadFile("testdata/defs_golden.json")
	if err != nil {
		t.Fatal(err)
	}
	var want map[string]any
	if err := json.Unmarshal(data, &want); err != nil {
		t.Fatal(err)
	}
	names := []string{ShellTool, ViewImageTool, ReadFileTool, WriteFileTool, ReportBlockerTool, FinishTool,
		ListFilesTool, SearchTextTool, ProbeTool, DocumentationTool, SubmitTool, SubmitReviewTool, SubmitRefinementTool,
		SubmitConfigurationTool, ShapeBatchTool, WorkerResultTool}
	if len(names) != len(want) {
		t.Fatalf("%d names, golden has %d", len(names), len(want))
	}
	for _, name := range names {
		t.Run(name, func(t *testing.T) {
			var got any
			if err := json.Unmarshal(mustJSON(t, Defs(name)[0]), &got); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, want[name]) {
				t.Errorf("definition differs\n got: %s\nwant: %s", mustJSON(t, got), mustJSON(t, want[name]))
			}
		})
	}
}

func TestDefsKeepTheOrderAskedFor(t *testing.T) {
	defs := Defs(ShellTool, ReadFileTool, FinishTool)
	var names []string
	for _, d := range defs {
		names = append(names, d["name"].(string))
	}
	if !reflect.DeepEqual(names, []string{"shell", "read_file", "finish"}) {
		t.Errorf("names %v", names)
	}
	if got := Defs(); len(got) != 0 {
		t.Errorf("Defs() = %v", got)
	}
	list := AsAny(Defs(ShellTool), Defs(FinishTool, ProbeTool))
	if len(list) != 3 || list[2].(map[string]any)["name"] != "probe" {
		t.Errorf("AsAny = %v", list)
	}
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
	for _, name := range []string{ShellTool, ViewImageTool, ReadFileTool, WriteFileTool, ReportBlockerTool, FinishTool,
		ListFilesTool, SearchTextTool, ProbeTool, DocumentationTool, SubmitTool, SubmitReviewTool, SubmitRefinementTool,
		SubmitConfigurationTool, ShapeBatchTool, WorkerResultTool} {
		walk(name, Defs(name)[0])
	}
}

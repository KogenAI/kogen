package agent

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"

	"kogen-loop/tools"
)

// everyTool is the seventeen definitions: kogen-loop's generic tools and Kogen's own.
var everyTool = []string{tools.ShellTool, tools.ViewImageTool, tools.ReadFileTool, tools.WriteFileTool, ReportBlockerTool, FinishTool,
	tools.ListFilesTool, tools.SearchTextTool, ProbeTool, tools.DocumentationTool, ProposeFilesTool, SubmitTool, SubmitReviewTool, SubmitRefinementTool,
	SubmitConfigurationTool, ShapeBatchTool, WorkerResultTool}

// TestDefinitionsMatchTheElixirDefinitions compares every Kogen-owned tool definition (finish,
// report_blocker, probe, propose_files, the submit_* definitions of shape, review, refine and
// init, shape_batch and worker_result) with testdata/defs_golden.json, as parsed values. A
// generic tool belongs to the pinned loop: the test checks that Kogen offers the definition
// tools.Definition returns, unchanged, and the golden holds none of them.
func TestDefinitionsMatchTheElixirDefinitions(t *testing.T) {
	data, err := os.ReadFile("testdata/defs_golden.json")
	if err != nil {
		t.Fatal(err)
	}
	var want map[string]any
	if err := json.Unmarshal(data, &want); err != nil {
		t.Fatal(err)
	}
	owned := 0
	for _, name := range everyTool {
		if _, loop := tools.Definition(name); !loop {
			owned++
		}
	}
	if owned != len(want) {
		t.Fatalf("%d Kogen-owned names, golden has %d", owned, len(want))
	}
	for _, name := range everyTool {
		t.Run(name, func(t *testing.T) {
			var got, expected any
			if err := json.Unmarshal(mustJSON(t, Defs(name)[0]), &got); err != nil {
				t.Fatal(err)
			}
			if pinned, loop := tools.Definition(name); loop {
				if _, stored := want[name]; stored {
					t.Fatalf("golden stores the loop-owned definition %s", name)
				}
				if err := json.Unmarshal(mustJSON(t, pinned), &expected); err != nil {
					t.Fatal(err)
				}
			} else {
				expected = want[name]
			}
			if !reflect.DeepEqual(got, expected) {
				t.Errorf("definition differs\n got: %s\nwant: %s", mustJSON(t, got), mustJSON(t, expected))
			}
		})
	}
}

func TestDefsKeepTheOrderAskedFor(t *testing.T) {
	defs := Defs(tools.ShellTool, tools.ReadFileTool, FinishTool)
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
	list := AsAny(Defs(tools.ShellTool), Defs(FinishTool, ProbeTool))
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
	for _, name := range everyTool {
		walk(name, Defs(name)[0])
	}
}

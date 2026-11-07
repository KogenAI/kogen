package consumes

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/KogenAI/kogen-verification/verify"
)

// kogen cli/engine.go and cli/readiness.go call `verify.ToolsFromInstall(job.root)` and pass the
// result on as a verify.Tools.
var _ func(string) verify.Tools = verify.ToolsFromInstall

// TestToolsFields pins the three strings kogen reads from verify.Tools: Node, Quint and Cucumber,
// the values cli/readiness/readiness.go turns into KOGEN_NODE, KOGEN_QUINT and KOGEN_CUCUMBER.
func TestToolsFields(t *testing.T) {
	tools := verify.Tools{Node: "n", Quint: "q", Cucumber: "c"}
	typ := reflect.TypeOf(tools)
	for name, want := range map[string]string{"Node": "n", "Quint": "q", "Cucumber": "c"} {
		f, ok := typ.FieldByName(name)
		if !ok || f.Type.Kind() != reflect.String {
			t.Fatalf("Tools.%s = %v (present %v), want a string", name, f.Type, ok)
		}
		if got := reflect.ValueOf(tools).FieldByName(name).String(); got != want {
			t.Fatalf("Tools.%s = %q, want %q", name, got, want)
		}
	}
}

// TestToolsFromInstallNamesTheNodeOfTheInstall: the Node is the path that the install's
// node-path file names, without its trailing line ending.
func TestToolsFromInstallNamesTheNodeOfTheInstall(t *testing.T) {
	root := t.TempDir()
	node := filepath.Join(t.TempDir(), "bin", "node")
	if err := os.WriteFile(filepath.Join(root, "node-path"), []byte(node+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := verify.ToolsFromInstall(root).Node; got != node {
		t.Fatalf("Node = %q, want %q", got, node)
	}
}

// TestToolsFromInstallWithoutNodePathFile: when node-path cannot be read, the Node is empty,
// so no other node runs.
func TestToolsFromInstallWithoutNodePathFile(t *testing.T) {
	root := t.TempDir()
	if got := verify.ToolsFromInstall(root).Node; got != "" {
		t.Fatalf("Node = %q, want empty", got)
	}
}

// TestToolsFromInstallLocatesQuintAndCucumberUnderLib: Quint is the installed cli.js and
// Cucumber the node_modules folder holding @cucumber/cucumber, both under the install root.
func TestToolsFromInstallLocatesQuintAndCucumberUnderLib(t *testing.T) {
	root := t.TempDir()
	got := verify.ToolsFromInstall(root)
	if want := filepath.Join(root, "lib", "quint", "node_modules", "@informalsystems", "quint", "dist", "src", "cli.js"); got.Quint != want {
		t.Fatalf("Quint = %q, want %q", got.Quint, want)
	}
	if want := filepath.Join(root, "lib", "cucumber", "node_modules"); got.Cucumber != want {
		t.Fatalf("Cucumber = %q, want %q", got.Cucumber, want)
	}
}

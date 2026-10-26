package agent

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen-loop/sys"
	"kogen-loop/tools"
)

// The generic tools and their tests live in kogen-loop/tools. These two keep the Kogen side
// of the seam: the names of Kogen's own workflow tools are not tools a Tools runs, and the
// probe is the shaper's callback.

// hermeticEnv is the process environment without the user's or the system's Git
// configuration, so Git's output is the same on every machine.
func hermeticEnv() []string {
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "GIT_") {
			env = append(env, kv)
		}
	}
	return append(env, "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
}

// newTools is Tools for root with the hermetic Git environment and these tools enabled.
func newTools(root string, enabled ...string) *tools.Tools {
	return &tools.Tools{Root: root, Session: sys.NewWith(hermeticEnv(), root), Enabled: enabled}
}

func run(t *testing.T, tl *tools.Tools, name string, args map[string]any) string {
	t.Helper()
	out, err := tl.Run(name, args)
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	if out.Typed() {
		t.Fatalf("%s: typed result", name)
	}
	return out.Text
}

func TestToolsRefuseNamesThatAreNotEnabled(t *testing.T) {
	root, _ := filepath.EvalSymlinks(t.TempDir())
	tl := newTools(root, tools.ReadFileTool)
	os.WriteFile(filepath.Join(root, "a"), []byte("x\n"), 0o644)
	for _, name := range []string{tools.ShellTool, tools.WriteFileTool, tools.ListFilesTool, tools.SearchTextTool, tools.ViewImageTool, ProbeTool, FinishTool, ReportBlockerTool, SubmitTool, "bogus", ""} {
		if got := run(t, tl, name, map[string]any{"command": "touch x", "path": "a", "content": "y", "pattern": "x"}); got != "error: unknown tool "+name {
			t.Errorf("%q: %q", name, got)
		}
	}
	if _, err := os.Stat(filepath.Join(root, "x")); err == nil {
		t.Error("a disabled shell ran")
	}
	if got := run(t, tl, tools.ReadFileTool, map[string]any{"path": "a"}); got != "1\tx" {
		t.Errorf("read_file: %q", got)
	}
	// An enabled name nothing implements (a terminal tool) is also unknown.
	tl.Enabled = append(tl.Enabled, FinishTool)
	if got := run(t, tl, FinishTool, nil); got != "error: unknown tool finish" {
		t.Errorf("finish: %q", got)
	}
}

func TestProbeBelongsToTheShaper(t *testing.T) {
	root, _ := filepath.EvalSymlinks(t.TempDir())
	tl := newTools(root, ProbeTool)
	if got := run(t, tl, ProbeTool, map[string]any{"command": "true"}); got != "error: probe is not available" {
		t.Errorf("without a probe: %q", got)
	}
	var gotCommand string
	var gotFiles any
	tl.Probe = func(command string, files any) (string, error) {
		gotCommand, gotFiles = command, files
		return "exit status: 0\ntimed_out: false\nwall: 0.1 s\n", nil
	}
	files := []any{map[string]any{"path": "a", "content": "b"}}
	if got := run(t, tl, ProbeTool, map[string]any{"command": "make", "files": files}); !strings.HasPrefix(got, "exit status: 0\n") {
		t.Errorf("%q", got)
	}
	if gotCommand != "make" || len(gotFiles.([]any)) != 1 {
		t.Errorf("probe got %q %v", gotCommand, gotFiles)
	}
	if got := run(t, tl, ProbeTool, map[string]any{"command": 5}); got != "error: argument command must be a string" {
		t.Errorf("invalid command: %q", got)
	}
	failure := errors.New("interrupted")
	tl.Probe = func(string, any) (string, error) { return "", failure }
	if _, err := tl.Run(ProbeTool, map[string]any{"command": "x"}); err != failure {
		t.Errorf("error %v", err)
	}
}

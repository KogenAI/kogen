package consumes

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"

	"github.com/KogenAI/kogen-executor/executor/claudecode"
)

// TestHookSubcommand: kogen's main runs the hook when its first argument is the hidden
// subcommand and passes everything after it to RunHook.
func TestHookSubcommand(t *testing.T) {
	t.Parallel()
	if claudecode.HookSubcommand != "__kogen_executor_hook" {
		t.Fatalf("HookSubcommand = %q", claudecode.HookSubcommand)
	}
}

// TestHookDenyAndAllow: kogen returns RunHook's code as its own exit code and the hook prints
// nothing but its answer. A write of a protected path is denied with exactly one line of
// PreToolUse deny JSON and exit 0; any other write prints nothing and exits 0.
func TestHookDenyAndAllow(t *testing.T) {
	t.Parallel()
	root := realDir(t)
	policy := writeJSON(t, filepath.Join(t.TempDir(), "hook-policy.json"), map[string]any{
		"root": root, "protected": []string{"protected/contract.txt"}, "log": filepath.Join(t.TempDir(), "hook-log.jsonl"), "nonce": "n0nce",
	})
	input := func(path string) string {
		return mustJSON(t, map[string]any{
			"cwd": root, "tool_name": "Write", "tool_use_id": "toolu_1", "tool_input": map[string]any{"file_path": path},
		})
	}
	args := []string{"pretool", "--policy", policy}

	var stdout, stderr bytes.Buffer
	code := claudecode.RunHook(args, strings.NewReader(input(filepath.Join(root, "protected", "contract.txt"))), &stdout, &stderr)
	if code != 0 || stderr.String() != "" {
		t.Fatalf("protected path: exit %d, stderr %q", code, stderr.String())
	}
	out := stdout.String()
	if strings.Count(out, "\n") != 1 || !strings.HasSuffix(out, "\n") {
		t.Fatalf("stdout %q is not exactly one line", out)
	}
	var answer map[string]map[string]any
	if err := json.Unmarshal([]byte(out), &answer); err != nil {
		t.Fatalf("deny answer %q is not a JSON object: %v", out, err)
	}
	special := answer["hookSpecificOutput"]
	if len(answer) != 1 || special["hookEventName"] != "PreToolUse" || special["permissionDecision"] != "deny" {
		t.Fatalf("deny answer = %q", out)
	}
	if reason, _ := special["permissionDecisionReason"].(string); !strings.Contains(reason, "protected path") {
		t.Fatalf("deny reason %q does not name the protected path", reason)
	}

	stdout.Reset()
	stderr.Reset()
	code = claudecode.RunHook(args, strings.NewReader(input(filepath.Join(root, "src", "main.go"))), &stdout, &stderr)
	if code != 0 || stdout.String() != "" || stderr.String() != "" {
		t.Fatalf("unprotected path: exit %d, stdout %q, stderr %q", code, stdout.String(), stderr.String())
	}
}

// TestHookFailuresExitTwo: a hook that cannot decide blocks the tool call, with the documented
// exit 2 and nothing on stdout.
func TestHookFailuresExitTwo(t *testing.T) {
	t.Parallel()
	root := realDir(t)
	policy := writeJSON(t, filepath.Join(t.TempDir(), "hook-policy.json"), map[string]any{
		"root": root, "protected": []string{"protected/contract.txt"}, "log": filepath.Join(t.TempDir(), "log"), "nonce": "n",
	})
	stdin := mustJSON(t, map[string]any{"cwd": root, "tool_name": "Write", "tool_use_id": "t", "tool_input": map[string]any{"file_path": filepath.Join(root, "a")}})
	for name, args := range map[string][]string{
		"unreadable policy": {"pretool", "--policy", filepath.Join(root, "missing.json")},
		"no arguments":      {},
		"missing file":      {"pretool", "--policy"},
		"unknown mode":      {"midtool", "--policy", policy},
	} {
		var stdout, stderr bytes.Buffer
		if code := claudecode.RunHook(args, strings.NewReader(stdin), &stdout, &stderr); code != 2 || stdout.String() != "" {
			t.Fatalf("%s: exit %d, stdout %q; want exit 2 and no output", name, code, stdout.String())
		}
	}
}

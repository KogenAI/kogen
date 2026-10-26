package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"kogen/executor/claudecode"
)

// hookFixture is a checkout with a protected file and the hook policy Claude Code's hooks
// would read.
func hookFixture(t *testing.T) (policy, root string) {
	t.Helper()
	tmp := t.TempDir()
	if r, err := filepath.EvalSymlinks(tmp); err == nil {
		tmp = r
	}
	root = filepath.Join(tmp, "repo")
	if err := os.MkdirAll(filepath.Join(root, "protected"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "protected", "contract.txt"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	policy = filepath.Join(tmp, "policy.json")
	b, _ := json.Marshal(map[string]any{
		"root": root, "protected": []string{"protected/contract.txt"}, "log": filepath.Join(tmp, "hook-log.jsonl"), "nonce": "n1",
	})
	if err := os.WriteFile(policy, b, 0o600); err != nil {
		t.Fatal(err)
	}
	return policy, root
}

func hookInput(root, path string) string {
	b, _ := json.Marshal(map[string]any{
		"cwd": root, "tool_name": "Write", "tool_use_id": "toolu_1", "tool_input": map[string]any{"file_path": path, "content": "c"},
	})
	return string(b)
}

func checkDeny(t *testing.T, stdout string) {
	t.Helper()
	var out struct {
		Hook struct {
			Event    string `json:"hookEventName"`
			Decision string `json:"permissionDecision"`
			Reason   string `json:"permissionDecisionReason"`
		} `json:"hookSpecificOutput"`
	}
	if err := json.Unmarshal([]byte(stdout), &out); err != nil {
		t.Fatalf("stdout is not the deny JSON: %q (%v)", stdout, err)
	}
	if out.Hook.Event != "PreToolUse" || out.Hook.Decision != "deny" || !strings.Contains(out.Hook.Reason, "protected path") {
		t.Fatalf("deny %+v", out.Hook)
	}
	if strings.Count(stdout, "\n") != 1 {
		t.Fatalf("stdout carries more than the deny JSON: %q", stdout)
	}
}

func TestExecutorHookRouteDeniesAProtectedWrite(t *testing.T) {
	policy, root := hookFixture(t)
	var stdout, stderr bytes.Buffer
	code, handled := executorHook([]string{claudecode.HookSubcommand, "pretool", "--policy", policy},
		strings.NewReader(hookInput(root, "protected/contract.txt")), &stdout, &stderr)
	if !handled || code != 0 {
		t.Fatalf("handled %v code %d", handled, code)
	}
	checkDeny(t, stdout.String())
	if stderr.Len() != 0 {
		t.Fatalf("stderr %q", stderr.String())
	}
}

func TestExecutorHookRouteLeavesEveryOtherCommandLineAlone(t *testing.T) {
	for _, args := range [][]string{nil, {"version"}, {"intent", "build", "x"}, {"__kogen_supervise"}, {"hook"}} {
		var out bytes.Buffer
		if code, handled := executorHook(args, strings.NewReader(""), &out, &out); handled || code != 0 || out.Len() != 0 {
			t.Errorf("%v: handled %v code %d output %q", args, handled, code, out.String())
		}
	}
}

func TestInstalledBinaryAnswersTheHookBeforeAnyOtherStartup(t *testing.T) {
	// The program, as Claude Code starts it for every tool call: only the answer is printed,
	// with no installation lookup, supervision or usage text, and a failing hook exits 2.
	bin := filepath.Join(t.TempDir(), "kogen")
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("go build: %v\n%s", err, out)
	}
	policy, root := hookFixture(t)
	run := func(stdin string, args ...string) (int, string, string) {
		cmd := exec.Command(bin, args...)
		cmd.Stdin = strings.NewReader(stdin)
		cmd.Dir = t.TempDir()
		cmd.Env = []string{"HOME=" + t.TempDir(), "PATH=" + os.Getenv("PATH")}
		var so, se bytes.Buffer
		cmd.Stdout, cmd.Stderr = &so, &se
		err := cmd.Run()
		code := 0
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else if err != nil {
			t.Fatal(err)
		}
		return code, so.String(), se.String()
	}
	code, stdout, stderr := run(hookInput(root, "protected/contract.txt"), claudecode.HookSubcommand, "pretool", "--policy", policy)
	if code != 0 || stderr != "" {
		t.Fatalf("deny: exit %d stderr %q", code, stderr)
	}
	checkDeny(t, stdout)
	code, stdout, stderr = run(hookInput(root, "src/ok.txt"), claudecode.HookSubcommand, "pretool", "--policy", policy)
	if code != 0 || stdout != "" || stderr != "" {
		t.Fatalf("allow: exit %d stdout %q stderr %q", code, stdout, stderr)
	}
	code, stdout, _ = run("{}", claudecode.HookSubcommand, "pretool", "--policy", filepath.Join(root, "absent.json"))
	if code != 2 || stdout != "" {
		t.Fatalf("a hook that cannot read its policy: exit %d stdout %q", code, stdout)
	}
	code, stdout, _ = run("{}", claudecode.HookSubcommand)
	if code != 2 || stdout != "" {
		t.Fatalf("a malformed hook command line: exit %d stdout %q", code, stdout)
	}
}

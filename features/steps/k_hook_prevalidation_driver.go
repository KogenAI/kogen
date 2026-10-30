package build

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"kogen-loop/sys"
	"kogen/executor"
	"kogen/executor/claudecode"
	"kogen/project"
)

// Observation only: it mounts as a test with go -overlay and changes no production source. It
// runs the real Build over the real Claude Code adapter and the adapter's real PreToolUse hook,
// against this test binary re-executed as a scripted fake `claude` (never the real claude).

const (
	khpIncidentID = "toolu_014z3hLJe9neZ1V8rmXgJRRi"
	khpRejection  = "<tool_use_error>File has been modified since read, either by the user or by a linter. Read it again before attempting to write it.</tool_use_error>"
	khpNotebookNo = "<tool_use_error>Notebook file does not exist.</tool_use_error>"
)

// init turns a re-executed test binary into the fake claude or into the real hook entry point,
// before the package's TestMain runs.
func init() {
	switch os.Getenv("KOGEN_KHP_AS") {
	case "hook":
		os.Exit(claudecode.RunHook(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
	case "claude":
		os.Exit(khpClaude(os.Args[1:]))
	}
}

func khpClaude(args []string) int {
	if len(args) == 1 && args[0] == "--version" {
		fmt.Println("2.1.314 (Claude Code)")
		return 0
	}
	if len(args) >= 2 && args[0] == "auth" && args[1] == "status" {
		fmt.Println(`{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}`)
		return 0
	}
	if len(args) < 1 || args[0] != "-p" {
		fmt.Fprintln(os.Stderr, "fake claude: unexpected argv")
		return 64
	}
	flag := func(name string) string {
		for i, a := range args {
			if a == name && i+1 < len(args) {
				return args[i+1]
			}
		}
		return ""
	}
	state := os.Getenv("KOGEN_KHP_STATE")
	n := 1
	if b, err := os.ReadFile(filepath.Join(state, "calls")); err == nil {
		n, _ = strconv.Atoi(strings.TrimSpace(string(b)))
		n++
	}
	os.WriteFile(filepath.Join(state, "calls"), []byte(strconv.Itoa(n)), 0o600)
	io.ReadAll(os.Stdin)
	sid := flag("--session-id")
	if sid == "" {
		sid = flag("--resume")
	}
	cwd, _ := os.Getwd()
	cwd, _ = filepath.EvalSymlinks(cwd)
	w := bufio.NewWriter(os.Stdout)
	out := func(m map[string]any) {
		m["session_id"] = sid
		j, _ := json.Marshal(m)
		w.Write(append(j, '\n'))
		w.Flush()
	}
	out(map[string]any{"type": "system", "subtype": "init", "cwd": cwd, "mcp_servers": []any{}, "model": "claude-sonnet-5-5",
		"permissionMode": "acceptEdits", "apiKeySource": "none", "claude_code_version": "2.1.314"})
	toolUse := func(id, name string, input map[string]any) {
		out(map[string]any{"type": "assistant", "message": map[string]any{"role": "assistant", "model": "claude-sonnet-5-5",
			"content": []any{map[string]any{"type": "tool_use", "id": id, "name": name, "input": input}}}})
	}
	toolResult := func(id, content string, isErr bool) {
		out(map[string]any{"type": "user", "message": map[string]any{"role": "user",
			"content": []any{map[string]any{"type": "tool_result", "tool_use_id": id, "content": content, "is_error": isErr}}}})
	}
	// pretool runs the PreToolUse hook the --settings file names, as Claude Code does.
	pretool := func(id, name string, input map[string]any) bool {
		var settings struct {
			Hooks map[string][]struct {
				Hooks []struct {
					Command string   `json:"command"`
					Args    []string `json:"args"`
				} `json:"hooks"`
			} `json:"hooks"`
		}
		sb, _ := os.ReadFile(flag("--settings"))
		json.Unmarshal(sb, &settings)
		list := settings.Hooks["PreToolUse"]
		if len(list) == 0 || len(list[0].Hooks) == 0 {
			return false
		}
		h := list[0].Hooks[0]
		in, _ := json.Marshal(map[string]any{"session_id": sid, "cwd": cwd, "hook_event_name": "PreToolUse", "permission_mode": "acceptEdits",
			"tool_name": name, "tool_input": input, "tool_use_id": id})
		cmd := exec.Command(h.Command, h.Args...)
		cmd.Env = append(os.Environ(), "KOGEN_KHP_AS=hook")
		cmd.Stdin = bytes.NewReader(in)
		var so bytes.Buffer
		cmd.Stdout = &so
		err := cmd.Run()
		return err == nil && !strings.Contains(so.String(), `"permissionDecision":"deny"`)
	}
	app := filepath.Join(cwd, "app.txt")
	if n == 1 {
		mode := os.Getenv("KOGEN_KHP_MODE")
		bash := "printf 'changed by bash\\n' > app.txt"
		toolUse("toolu_khp_bash", "Bash", map[string]any{"command": bash})
		sh := exec.Command("/bin/sh", "-c", bash)
		sh.Dir = cwd
		co, _ := sh.CombinedOutput()
		toolResult("toolu_khp_bash", string(co), false)

		write := map[string]any{"file_path": app, "content": "candidate\n"}
		toolUse(khpIncidentID, "Write", write)
		if mode == "written-without-hook" {
			// Give Kogen ample time to read the tool_use line first, then write without the hook.
			time.Sleep(time.Second)
			os.WriteFile(app, []byte("candidate\n"), 0o644)
		}
		toolResult(khpIncidentID, khpRejection, true)

		nb := map[string]any{"notebook_path": filepath.Join(cwd, "analysis.ipynb"), "new_source": "print(1)", "cell_id": "c1"}
		toolUse("toolu_khp_notebook", "NotebookEdit", nb)
		toolResult("toolu_khp_notebook", khpNotebookNo, true)

		toolUse("toolu_khp_read", "Read", map[string]any{"file_path": app})
		cur, _ := os.ReadFile(app)
		toolResult("toolu_khp_read", "     1\t"+string(cur), false)

		toolUse("toolu_khp_retry", "Write", write)
		if pretool("toolu_khp_retry", "Write", write) {
			os.WriteFile(app, []byte("candidate\n"), 0o644)
			toolResult("toolu_khp_retry", "The file "+app+" has been updated successfully.", false)
		} else {
			toolResult("toolu_khp_retry", "PreToolUse:Write hook error: denied", true)
		}
	}
	out(map[string]any{"type": "result", "subtype": "success", "is_error": false, "num_turns": 6,
		"result": "app.txt holds the candidate", "terminal_reason": "completed", "stop_reason": "end_turn", "permission_denials": []any{}})
	return 0
}

func TestKHookPrevalidationObservation(t *testing.T) {
	mode := os.Getenv("KOGEN_KHP_MODE")
	if mode != "rejected-before-hook" && mode != "written-without-hook" {
		t.Fatalf("unknown mode %q", mode)
	}
	e := newEnv(t)
	e.useExecutor("    max_rounds: 2\n")
	start := e.head()
	state := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(state, 0o700); err != nil {
		t.Fatal(err)
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	env := append(append([]string{}, e.git...), "KOGEN_KHP_AS=claude", "KOGEN_KHP_MODE="+mode, "KOGEN_KHP_STATE="+state)
	x := claudecode.New(claudecode.Options{Binary: exe, HookCommand: []string{exe}, Env: env, KillGrace: 2 * time.Second})
	a := e.build(func(in *Input) {
		in.External = func(role project.Role) (executor.Executor, error) { return x, nil }
	})

	out := map[string]any{"mode": mode, "exit": a.exit, "stdout": a.shown(), "err_class": "", "err_reason": ""}
	if se, ok := sys.AsError(a.err); ok {
		out["err_class"], out["err_reason"] = se.Class, se.Reason
	}
	calls, _ := os.ReadFile(filepath.Join(state, "calls"))
	out["calls"] = strings.TrimSpace(string(calls))
	out["commits"] = e.gitOut("rev-list", "--count", start+"..HEAD")
	out["committed_app"] = ""
	if out["commits"] == "1" {
		out["committed_app"] = e.run("git", "show", "HEAD:app.txt")
	}
	out["app"] = e.read("app.txt")
	_, nerr := os.Stat(filepath.Join(e.root, "analysis.ipynb"))
	out["notebook_exists"] = nerr == nil
	id := e.onlyRun()
	out["outcome"] = fmt.Sprint(e.result(id)["outcome"])
	failed, tools, hooks := []any{}, []any{}, []any{}
	for _, ev := range e.events(id) {
		switch ev["event"] {
		case "executor_round_failed":
			failed = append(failed, map[string]any{"reason": ev["reason"], "detail": ev["detail"]})
		case "executor_tool":
			tools = append(tools, map[string]any{"name": ev["name"], "tool_use_id": ev["tool_use_id"], "denied": ev["denied"], "rejected_before_hook": ev["rejected_before_hook"]})
		case "executor_hook":
			hooks = append(hooks, map[string]any{"tool_use_id": ev["tool_use_id"], "decision": ev["decision"], "hook": ev["hook"]})
		}
	}
	out["round_failed"], out["tool_events"], out["hook_events"] = failed, tools, hooks
	raw, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(os.Getenv("KOGEN_KHP_OUTPUT"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
}

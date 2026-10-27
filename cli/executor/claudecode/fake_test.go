package claudecode

import (
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

	"kogen/executor"
	"kogen/executor/conformance"
)

// The fake claude is this test binary re-executed: KOGEN_FAKE_CLAUDE=<config.json> makes it
// answer like Claude Code (--version, auth status, -p stream-json modelled on the recorded
// receipts), and KOGEN_TEST_HOOK=1 makes it the real hook entry point (RunHook), so the hooks
// the fake invokes from the --settings file are the real adapter hooks.
func TestMain(m *testing.M) {
	if os.Getenv("KOGEN_TEST_HOOK") == "1" {
		os.Exit(RunHook(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
	}
	if cfg := os.Getenv("KOGEN_FAKE_CLAUDE"); cfg != "" {
		os.Exit(fakeClaude(cfg, os.Args[1:]))
	}
	os.Exit(m.Run())
}

// fakeConfig scripts one fake claude installation.
type fakeConfig struct {
	Script conformance.Script `json:"script"`
	State  string             `json:"state"`
	// Version is the `claude --version` output (default "2.1.306 (Claude Code)").
	Version string `json:"version"`
	// Auth is the raw `auth status --json` output (default: signed in with claude.ai).
	Auth string `json:"auth"`
	// Init is merged into the init event; a null value deletes the key.
	Init map[string]any `json:"init"`
	// Result is merged into the result event; a null value deletes the key.
	Result map[string]any `json:"result"`
	// UsageRaw replaces result.usage when set.
	UsageRaw map[string]any `json:"usage_raw"`
	// TotalCosts are the cumulative total_cost_usd values per round (default: derived).
	TotalCosts []float64 `json:"total_costs"`
	// SkipHook makes write tools run without invoking the PreToolUse hook.
	SkipHook bool `json:"skip_hook"`
	// IgnoreDeny makes a denied write run anyway, reported as a success.
	IgnoreDeny bool `json:"ignore_deny"`
	// NoResult ends the stream after init with exit code ExitCode.
	NoResult bool `json:"no_result"`
	ExitCode int  `json:"exit_code"`
	// TrailingEvent emits one more event after the result.
	TrailingEvent bool `json:"trailing_event"`
	// LingerSeconds keeps the process alive after the result (background work).
	LingerSeconds float64 `json:"linger_seconds"`
	// ExitBeforeStdin exits with ExitCode without reading the prompt or emitting any event.
	ExitBeforeStdin bool `json:"exit_before_stdin"`
}

const goodAuth = `{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max","email":"person@example.invalid","orgId":"org-secret-id","orgName":"Secret Org","configDirectory":"/x"}`

func fakeClaude(cfgPath string, args []string) int {
	var cfg fakeConfig
	b, err := os.ReadFile(cfgPath)
	if err != nil || json.Unmarshal(b, &cfg) != nil {
		fmt.Fprintln(os.Stderr, "fake claude: bad config")
		return 70
	}
	out := func(m map[string]any) {
		j, _ := json.Marshal(m)
		os.Stdout.Write(append(j, '\n'))
	}
	if len(args) == 1 && args[0] == "--version" {
		v := cfg.Version
		if v == "" {
			v = "2.1.306 (Claude Code)"
		}
		fmt.Println(v)
		return 0
	}
	if len(args) >= 2 && args[0] == "auth" && args[1] == "status" {
		a := cfg.Auth
		if a == "" {
			a = goodAuth
		}
		fmt.Println(a)
		return 0
	}
	// The prompt arrives on stdin: a positional prompt after -p locks the old transport out.
	if len(args) < 2 || args[0] != "-p" || !strings.HasPrefix(args[1], "--") {
		fmt.Fprintln(os.Stderr, "fake claude: unexpected argv (the prompt must come from stdin)")
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
	n := 1
	if cb, err := os.ReadFile(filepath.Join(cfg.State, "calls")); err == nil {
		n, _ = strconv.Atoi(strings.TrimSpace(string(cb)))
		n++
	}
	os.WriteFile(filepath.Join(cfg.State, "calls"), []byte(strconv.Itoa(n)), 0o600)
	aj, _ := json.Marshal(args)
	os.WriteFile(filepath.Join(cfg.State, fmt.Sprintf("argv-%d.json", n)), aj, 0o600)
	ej, _ := json.Marshal(os.Environ())
	os.WriteFile(filepath.Join(cfg.State, fmt.Sprintf("env-%d.json", n)), ej, 0o600)
	if cfg.ExitBeforeStdin {
		fmt.Fprintln(os.Stderr, "fake claude: dying before reading the prompt")
		return cfg.ExitCode
	}
	promptBytes, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "fake claude: cannot read the prompt from stdin")
		return 65
	}
	os.WriteFile(filepath.Join(cfg.State, fmt.Sprintf("prompt-%d.bin", n)), promptBytes, 0o600)
	sessionID := flag("--session-id")
	if sessionID == "" {
		sessionID = flag("--resume")
		f, _ := os.OpenFile(filepath.Join(cfg.State, "feedback.jsonl"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		pj, _ := json.Marshal(string(promptBytes))
		f.Write(append(pj, '\n'))
		f.Close()
	}
	rounds := cfg.Script.Rounds
	rs := conformance.RoundScript{End: "finish"}
	if len(rounds) > 0 {
		rs = rounds[min(n-1, len(rounds)-1)]
	}
	cwd, _ := os.Getwd()
	cwd, _ = filepath.EvalSymlinks(cwd)

	init := map[string]any{
		"type": "system", "subtype": "init", "cwd": cwd, "session_id": sessionID, "mcp_servers": []any{},
		"model": "claude-sonnet-5-5", "permissionMode": "acceptEdits", "apiKeySource": "none",
		"claude_code_version": "2.1.306", "uuid": "00000000-0000-4000-8000-000000000001",
	}
	if rs.APIKeyAuth {
		init["apiKeySource"] = "ANTHROPIC_API_KEY"
	}
	merge(init, cfg.Init)
	out(init)
	if rs.APIKeyAuth {
		time.Sleep(time.Second) // the adapter must have killed us before we act
	}
	if rs.Malformed {
		fmt.Println("this is not json {")
		return 0
	}
	if cfg.NoResult {
		return cfg.ExitCode
	}

	var settings struct {
		Hooks map[string][]struct {
			Hooks []struct {
				Command string   `json:"command"`
				Args    []string `json:"args"`
			} `json:"hooks"`
		} `json:"hooks"`
	}
	if sb, err := os.ReadFile(flag("--settings")); err == nil {
		json.Unmarshal(sb, &settings)
	}
	runHook := func(event string, in map[string]any) (stdout string, code int) {
		list := settings.Hooks[event]
		if len(list) == 0 || len(list[0].Hooks) == 0 {
			return "", 0
		}
		h := list[0].Hooks[0]
		in["session_id"], in["cwd"], in["hook_event_name"], in["permission_mode"] = sessionID, cwd, event, "acceptEdits"
		inj, _ := json.Marshal(in)
		cmd := exec.Command(h.Command, h.Args...)
		cmd.Env = append(os.Environ(), "KOGEN_TEST_HOOK=1")
		cmd.Stdin = bytes.NewReader(inj)
		var so bytes.Buffer
		cmd.Stdout = &so
		err := cmd.Run()
		code = 0
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else if err != nil {
			code = 127
		}
		return so.String(), code
	}
	toolUse := func(id, name string, input map[string]any) {
		out(map[string]any{"type": "assistant", "session_id": sessionID, "message": map[string]any{
			"model": "claude-sonnet-5-5", "role": "assistant",
			"content": []any{map[string]any{"type": "tool_use", "id": id, "name": name, "input": input}},
		}})
	}
	toolResult := func(id, content string, isErr bool, decision string) {
		out(map[string]any{"type": "user", "session_id": sessionID, "message": map[string]any{
			"role": "user", "content": []any{map[string]any{"type": "tool_result", "tool_use_id": id, "content": content, "is_error": isErr}},
		}, "tool_result_meta": []any{map[string]any{"id": id, "permission_decision": map[string]any{"decision": decision}}}})
	}
	denials := []any{}
	for i, a := range rs.Actions {
		id := fmt.Sprintf("toolu_%d_%d", n, i)
		switch {
		case a.Write != nil:
			abs := filepath.Join(cwd, a.Write.Path)
			in := map[string]any{"file_path": abs, "content": a.Write.Content}
			toolUse(id, "Write", in)
			denied := false
			if !cfg.SkipHook {
				out(map[string]any{"type": "system", "subtype": "hook_started", "hook_event": "PreToolUse", "hook_name": "PreToolUse:Write"})
				so, code := runHook("PreToolUse", map[string]any{"tool_name": "Write", "tool_input": in, "tool_use_id": id})
				out(map[string]any{"type": "system", "subtype": "hook_response", "hook_event": "PreToolUse", "hook_name": "PreToolUse:Write", "stdout": so, "exit_code": code, "outcome": "success"})
				denied = code == 2 || strings.Contains(so, `"permissionDecision":"deny"`)
			}
			if denied && !cfg.IgnoreDeny {
				denials = append(denials, map[string]any{"tool_name": "Write", "tool_use_id": id, "tool_input": in})
				toolResult(id, "PreToolUse:Write hook error: denied", true, "reject")
				continue
			}
			os.MkdirAll(filepath.Dir(abs), 0o755)
			os.WriteFile(abs, []byte(a.Write.Content), 0o644)
			toolResult(id, "File created successfully at: "+abs, false, "accept")
		case a.Shell != "" || a.SpawnOrphan:
			command := a.Shell
			if a.SpawnOrphan {
				command = "mkdir -p .conformance && { sleep 300 >/dev/null 2>&1 & echo $! > .conformance/child.pid; }"
			}
			toolUse(id, "Bash", map[string]any{"command": command})
			cmd := exec.Command("/bin/sh", "-c", command)
			cmd.Dir = cwd
			co, _ := cmd.CombinedOutput()
			runHook("PostToolUse", map[string]any{"tool_name": "Bash", "tool_input": map[string]any{"command": command}, "tool_response": map[string]any{"stdout": string(co)}, "tool_use_id": id})
			toolResult(id, string(co), false, "accept")
		case a.SleepSeconds > 0:
			time.Sleep(time.Duration(a.SleepSeconds * float64(time.Second)))
		}
	}

	res := map[string]any{
		"type": "result", "subtype": "success", "is_error": false, "num_turns": 3, "session_id": sessionID,
		"result": rs.Claim, "terminal_reason": "completed", "stop_reason": "end_turn",
		"permission_denials": denials,
	}
	exit := 0
	switch {
	case rs.HarnessError:
		res["subtype"], res["is_error"], res["terminal_reason"] = "error_during_execution", true, "model_error"
		res["errors"] = []any{"boom"}
		exit = 1
	case rs.End == "no_call":
		res["subtype"], res["is_error"], res["terminal_reason"] = "error_max_turns", true, "max_turns"
		exit = 1
	}
	if len(rs.Structured) > 0 {
		var v any
		json.Unmarshal(rs.Structured, &v)
		res["structured_output"] = v
	}
	if rs.Usage != nil {
		res["usage"] = map[string]any{
			"input_tokens": rs.Usage.Input - rs.Usage.Cached, "cache_read_input_tokens": rs.Usage.Cached,
			"cache_creation_input_tokens": 0, "output_tokens": rs.Usage.Output,
		}
		cost := 0.0
		if cb, err := os.ReadFile(filepath.Join(cfg.State, "cost")); err == nil {
			cost, _ = strconv.ParseFloat(strings.TrimSpace(string(cb)), 64)
		}
		cost += float64(rs.Usage.Input+rs.Usage.Output) / 1e6
		os.WriteFile(filepath.Join(cfg.State, "cost"), []byte(strconv.FormatFloat(cost, 'g', -1, 64)), 0o600)
		res["total_cost_usd"] = cost
	}
	if cfg.UsageRaw != nil {
		res["usage"] = cfg.UsageRaw
	}
	if n-1 < len(cfg.TotalCosts) {
		res["total_cost_usd"] = cfg.TotalCosts[n-1]
	}
	merge(res, cfg.Result)
	out(res)
	if cfg.TrailingEvent {
		out(map[string]any{"type": "rate_limit_event"})
	}
	if cfg.LingerSeconds > 0 {
		time.Sleep(time.Duration(cfg.LingerSeconds * float64(time.Second)))
	}
	return exit
}

func merge(dst, src map[string]any) {
	for k, v := range src {
		if v == nil {
			delete(dst, k)
		} else {
			dst[k] = v
		}
	}
}

// fakeEnv is one prepared fake claude installation.
type fakeEnv struct {
	t      *testing.T
	cfg    fakeConfig
	cfgDir string
}

func newFake(t *testing.T, cfg fakeConfig) *fakeEnv {
	t.Helper()
	dir := t.TempDir()
	cfg.State = filepath.Join(dir, "state")
	if err := os.MkdirAll(cfg.State, 0o700); err != nil {
		t.Fatal(err)
	}
	f := &fakeEnv{t: t, cfg: cfg, cfgDir: dir}
	f.write()
	return f
}

func (f *fakeEnv) write() {
	b, _ := json.Marshal(f.cfg)
	if err := os.WriteFile(filepath.Join(f.cfgDir, "config.json"), b, 0o600); err != nil {
		f.t.Fatal(err)
	}
}

// options point the adapter at this test binary as claude and as the hook command.
func (f *fakeEnv) options(extraEnv ...string) Options {
	exe, err := os.Executable()
	if err != nil {
		f.t.Fatal(err)
	}
	env := append(os.Environ(), "KOGEN_FAKE_CLAUDE="+filepath.Join(f.cfgDir, "config.json"))
	return Options{Binary: exe, HookCommand: []string{exe}, Env: append(env, extraEnv...), KillGrace: 2 * time.Second}
}

func (f *fakeEnv) argv(round int) []string {
	f.t.Helper()
	var a []string
	b, err := os.ReadFile(filepath.Join(f.cfg.State, fmt.Sprintf("argv-%d.json", round)))
	if err != nil || json.Unmarshal(b, &a) != nil {
		f.t.Fatalf("no argv recorded for round %d: %v", round, err)
	}
	return a
}

// prompt is the exact stdin bytes the fake received in a round.
func (f *fakeEnv) prompt(round int) []byte {
	f.t.Helper()
	b, err := os.ReadFile(filepath.Join(f.cfg.State, fmt.Sprintf("prompt-%d.bin", round)))
	if err != nil {
		f.t.Fatalf("no prompt recorded for round %d: %v", round, err)
	}
	return b
}

func (f *fakeEnv) env(round int) []string {
	f.t.Helper()
	var a []string
	b, err := os.ReadFile(filepath.Join(f.cfg.State, fmt.Sprintf("env-%d.json", round)))
	if err != nil || json.Unmarshal(b, &a) != nil {
		f.t.Fatalf("no env recorded for round %d: %v", round, err)
	}
	return a
}

// prompts are the prompts of the resumed rounds as the fake received them.
func (f *fakeEnv) prompts() []string {
	b, _ := os.ReadFile(filepath.Join(f.cfg.State, "feedback.jsonl"))
	var out []string
	for _, line := range strings.Split(string(b), "\n") {
		var s string
		if json.Unmarshal([]byte(line), &s) == nil && line != "" {
			out = append(out, s)
		}
	}
	return out
}

// driver is the conformance driver of the Claude Code adapter.
type driver struct{ cur *fakeEnv }

func (d *driver) Name() string { return executor.ClaudeCode }

func (d *driver) Prepare(t *testing.T, root string, s conformance.Script) (executor.Executor, executor.Task) {
	f := newFake(t, fakeConfig{Script: s})
	d.cur = f
	return New(f.options()), executor.Task{
		Model: "claude-sonnet-5-5", Effort: "high", RunID: "run-1", MaxRounds: 6,
		Brief: executor.Brief{Stable: "STABLE brief", Dynamic: "DYNAMIC files"},
		Home:  t.TempDir(), Dir: filepath.Join(t.TempDir(), "executor"),
	}
}

func (d *driver) Feedback(t *testing.T) []string {
	var out []string
	for _, p := range d.cur.prompts() {
		out = append(out, strings.TrimPrefix(p, feedbackPreface+"\n\n"))
	}
	return out
}

func TestConformance(t *testing.T) {
	conformance.Run(t, &driver{})
}

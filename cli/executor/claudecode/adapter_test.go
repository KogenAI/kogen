package claudecode

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"

	"kogen-loop/sys"
	"kogen/executor"
	"kogen/executor/conformance"
)

type harness struct {
	t      *testing.T
	f      *fakeEnv
	root   string
	task   executor.Task
	events []map[string]any
}

func oneRound(r conformance.RoundScript) conformance.Script {
	return conformance.Script{Name: "unit", Rounds: []conformance.RoundScript{r}}
}

var finishRound = conformance.RoundScript{End: "finish", Claim: "done", Usage: &conformance.ScriptUsage{Input: 120, Cached: 20, Output: 30}}

func newHarness(t *testing.T, cfg fakeConfig) *harness {
	t.Helper()
	root := conformance.NewCheckout(t)
	h := &harness{t: t, f: newFake(t, cfg), root: root}
	h.task = executor.Task{
		Role: executor.RoleBuild, Root: root, Protected: []string{conformance.ProtectedPath},
		Model: "claude-sonnet-5-5", Effort: "high", RunID: "run-1", MaxRounds: 6,
		Brief: executor.Brief{Stable: "STABLE brief", Dynamic: "DYNAMIC files"},
		Home:  t.TempDir(), Dir: filepath.Join(t.TempDir(), "executor"),
	}
	return h
}

func (h *harness) start(opts Options) (executor.Session, error) {
	return New(opts).Start(context.Background(), h.task, func(e map[string]any) { h.events = append(h.events, e) })
}

func (h *harness) startOK() executor.Session {
	h.t.Helper()
	s, err := h.start(h.f.options())
	if err != nil {
		h.t.Fatalf("Start: %v", err)
	}
	h.t.Cleanup(func() { s.Close() })
	return s
}

func (h *harness) eventsNamed(name string) []map[string]any {
	var out []map[string]any
	for _, e := range h.events {
		if e["event"] == name {
			out = append(out, e)
		}
	}
	return out
}

func wantError(t *testing.T, err error, want string) *sys.Error {
	t.Helper()
	if err == nil {
		t.Fatalf("no error, want %s", want)
	}
	e, ok := sys.AsError(err)
	if !ok {
		t.Fatalf("error %v (%T) is not a *sys.Error, want %s", err, err, want)
	}
	if got := e.Class + "/" + e.Reason; got != want {
		t.Fatalf("error %s (%s), want %s", got, e.Detail, want)
	}
	return e
}

func TestDescribe(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{})
	d := New(h.f.options()).Describe()
	if err := d.Validate(); err != nil {
		t.Fatal(err)
	}
	want := executor.Capabilities{
		Roles: []string{"build"}, Resume: executor.ResumeNone, Continuation: true, Usage: executor.UsageHarness,
		Prevention: []string{executor.PreventPreToolWrite}, Blocker: false, Images: false, MaxRounds: 6,
	}
	if d.Name != executor.ClaudeCode || d.Contract != executor.Contract || !reflect.DeepEqual(d.Capabilities, want) {
		t.Fatalf("descriptor %+v", d)
	}
	if d.Version != "claude-code 2.1.306 (Claude Code)" {
		t.Fatalf("version %q", d.Version)
	}
}

func TestDescribeNeverFails(t *testing.T) {
	t.Parallel()
	d := New(Options{Binary: filepath.Join(t.TempDir(), "no-such-claude")}).Describe()
	if d.Version != "claude-code unknown" || d.Name != executor.ClaudeCode {
		t.Fatalf("descriptor %+v", d)
	}
}

func TestStartBinaryMissingIsUnavailable(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{})
	o := h.f.options()
	o.Binary = filepath.Join(t.TempDir(), "no-such-claude")
	_, err := h.start(o)
	wantError(t, err, "executor/unavailable")
}

func TestStartRequiresHookCommand(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{})
	o := h.f.options()
	o.HookCommand = nil
	_, err := h.start(o)
	wantError(t, err, "executor/unavailable")
}

func TestVersionGate(t *testing.T) {
	t.Parallel()
	cases := []struct {
		version string
		ok      bool
	}{
		{"2.1.294 (Claude Code)", false},
		{"2.1.295 (Claude Code)", true},
		{"2.1.306 (Claude Code)", true},
		{"2.2.0 (Claude Code)", true},
		{"3.0.0", true},
		{"2.0.999 (Claude Code)", false},
		{"1.9.9999", false},
		{"not a version", false},
		{" ", false},
	}
	for _, c := range cases {
		t.Run(c.version, func(t *testing.T) {
			t.Parallel()
			h := newHarness(t, fakeConfig{Version: c.version, Script: oneRound(finishRound)})
			s, err := h.start(h.f.options())
			if c.ok {
				if err != nil {
					t.Fatalf("Start: %v", err)
				}
				s.Close()
				return
			}
			wantError(t, err, "executor/unavailable")
		})
	}
}

func TestAuthGate(t *testing.T) {
	t.Parallel()
	cases := map[string]string{
		"logged out":    `{"loggedIn":false}`,
		"api key route": `{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty"}`,
		"console":       `{"loggedIn":true,"authMethod":"console","apiProvider":"firstParty"}`,
		"bedrock":       `{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"bedrock"}`,
		"not json":      `signed in as someone`,
		"empty":         `{}`,
	}
	for name, auth := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			h := newHarness(t, fakeConfig{Auth: auth, Script: oneRound(finishRound)})
			_, err := h.start(h.f.options())
			wantError(t, err, "executor/auth_refused")
			if len(h.eventsNamed("executor_started")) != 0 {
				t.Fatal("executor_started emitted for a refused route")
			}
		})
	}
}

func TestStartedEventKeepsOnlySafeAuthFields(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{Script: oneRound(finishRound)})
	s := h.startOK()
	started := h.eventsNamed("executor_started")
	if len(started) != 1 {
		t.Fatalf("events %v", h.events)
	}
	b, _ := json.Marshal(started[0])
	for _, secret := range []string{"person@example.invalid", "org-secret-id", "Secret Org", "email", "orgId"} {
		if strings.Contains(string(b), secret) {
			t.Fatalf("executor_started leaks %q: %s", secret, b)
		}
	}
	auth := started[0]["auth"].(map[string]any)
	if auth["auth_method"] != "claude.ai" || auth["api_provider"] != "firstParty" || auth["logged_in"] != true || auth["subscription_type"] != "max" {
		t.Fatalf("auth %v", auth)
	}
	if started[0]["claude_code_version"] != "2.1.306 (Claude Code)" || started[0]["session_id"] != s.Handle().SessionID {
		t.Fatalf("event %v", started[0])
	}
}

var uuidRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

func TestStartPreparesTaskDirectory(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{Script: oneRound(finishRound)})
	s := h.startOK()
	if fi, err := os.Stat(h.task.Dir); err != nil || fi.Mode().Perm() != 0o700 {
		t.Fatalf("task dir: %v %v", fi, err)
	}
	for _, name := range []string{"hook-policy.json", "claude-settings.json", "hook-log.jsonl"} {
		fi, err := os.Stat(filepath.Join(h.task.Dir, name))
		if err != nil || fi.Mode().Perm() != 0o600 {
			t.Fatalf("%s: %v %v", name, fi, err)
		}
	}
	hd := s.Handle()
	if !uuidRe.MatchString(hd.SessionID) || hd.Executor != executor.ClaudeCode || hd.Resume != executor.ResumeNone || hd.Version != "claude-code 2.1.306 (Claude Code)" {
		t.Fatalf("handle %+v", hd)
	}
	var pol policy
	b, _ := os.ReadFile(filepath.Join(h.task.Dir, "hook-policy.json"))
	if err := json.Unmarshal(b, &pol); err != nil || pol.Root != h.root || !reflect.DeepEqual(pol.Protected, []string{conformance.ProtectedPath}) || pol.Nonce == "" {
		t.Fatalf("policy %+v (%v)", pol, err)
	}
}

func TestSettingsFileShape(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{Script: oneRound(finishRound)})
	h.startOK()
	b, err := os.ReadFile(filepath.Join(h.task.Dir, "claude-settings.json"))
	if err != nil {
		t.Fatal(err)
	}
	policyPath := filepath.Join(h.task.Dir, "hook-policy.json")
	exe, _ := os.Executable()
	var got any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"hooks": map[string]any{
		"PreToolUse": []any{map[string]any{"matcher": "Write|Edit|MultiEdit|NotebookEdit", "hooks": []any{map[string]any{
			"type": "command", "command": exe, "args": []any{"pretool", "--policy", policyPath}, "timeout": float64(10), "onFailure": "block"}}}},
		"PostToolUse": []any{map[string]any{"matcher": "Bash", "hooks": []any{map[string]any{
			"type": "command", "command": exe, "args": []any{"posttool", "--policy", policyPath}, "timeout": float64(10)}}}},
	}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("settings\n got %s\nwant %v", b, want)
	}
}

func TestArgvRounds(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{Script: conformance.Script{Rounds: []conformance.RoundScript{finishRound, finishRound}}})
	s := h.startOK()
	if _, err := s.Round(context.Background(), executor.Input{}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Round(context.Background(), executor.Input{Feedback: "FIX THE TESTS"}); err != nil {
		t.Fatal(err)
	}
	sid := s.Handle().SessionID
	settings := filepath.Join(h.task.Dir, "claude-settings.json")
	common := func(resumeFlag string) []string {
		return []string{
			"-p", resumeFlag, sid,
			"--model", "claude-sonnet-5-5", "--effort", "high",
			"--output-format", "stream-json", "--verbose", "--include-hook-events",
			"--permission-mode", "acceptEdits", "--permission-prompts", "none",
			"--allowedTools", "Bash",
			"--settings", settings, "--setting-sources", "",
			"--strict-mcp-config", "--mcp-config", `{"mcpServers":{}}`,
			"--no-chrome", "--max-turns", "150",
		}
	}
	round1 := append(common("--session-id"), "--append-system-prompt", Constraints)
	round2 := common("--resume")
	if got := h.f.argv(1); !reflect.DeepEqual(got, round1) {
		t.Fatalf("round 1 argv\n got %q\nwant %q", got, round1)
	}
	if got := h.f.argv(2); !reflect.DeepEqual(got, round2) {
		t.Fatalf("round 2 argv\n got %q\nwant %q", got, round2)
	}
	for r := 1; r <= 2; r++ {
		for _, a := range h.f.argv(r) {
			switch a {
			case "--bare", "--dangerously-skip-permissions", "bypassPermissions", "--continue", "--max-budget-usd", "--system-prompt", "--agent", "--agents":
				t.Fatalf("round %d argv has forbidden %s", r, a)
			}
		}
	}
	if a := h.f.argv(1); a[0] != "-p" || !strings.HasPrefix(a[1], "--") {
		t.Fatalf("-p must be followed by a flag, not a positional prompt: %q", a[:2])
	}
	// The prompts arrive on stdin, exactly.
	if got, want := string(h.f.prompt(1)), Constraints+"\n\nSTABLE brief\n\nDYNAMIC files"; got != want {
		t.Fatalf("round 1 stdin %q, want %q", got, want)
	}
	if got, want := string(h.f.prompt(2)), "Kogen's independent verification of your previous round:\n\nFIX THE TESTS"; got != want {
		t.Fatalf("round 2 stdin %q, want %q", got, want)
	}
}

func TestArgvOptionalFlagsAndMaxTurns(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{Script: oneRound(finishRound)})
	h.task.Effort = ""
	o := h.f.options()
	o.MaxTurns, o.SettingSources = 7, "project,local"
	s, err := h.start(o)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := s.Round(context.Background(), executor.Input{}); err != nil {
		t.Fatal(err)
	}
	args := strings.Join(h.f.argv(1), "\x00")
	if strings.Contains(args, "--effort") {
		t.Fatal("--effort passed without an effort")
	}
	for _, want := range []string{"--max-turns\x007", "--setting-sources\x00project,local"} {
		if !strings.Contains(args, want) {
			t.Fatalf("argv lacks %q", want)
		}
	}
}

func TestPromptOverSanityBound(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{Script: oneRound(finishRound)})
	h.task.Brief.Stable = strings.Repeat("x", maxPromptBytes)
	s := h.startOK()
	_, err := s.Round(context.Background(), executor.Input{})
	wantError(t, err, "candidate/context_budget_exceeded")
}

// A brief far over any argv element limit reaches Claude Code byte-identical over stdin, in
// round 1 and in a feedback round.
func TestLargePromptsArriveOverStdin(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{Script: conformance.Script{Rounds: []conformance.RoundScript{finishRound, finishRound}}})
	h.task.Brief.Stable = strings.Repeat("Ünïcödé 日本語 ✓\n", 20000) // about 500 KiB, multi-byte
	h.task.Brief.Dynamic = strings.Repeat("file/é.go\n", 10000)
	feedback := strings.Repeat("tést ✗ failure\n", 20000) // about 300 KiB
	s := h.startOK()
	if _, err := s.Round(context.Background(), executor.Input{}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Round(context.Background(), executor.Input{Feedback: feedback}); err != nil {
		t.Fatal(err)
	}
	want1 := Constraints + "\n\n" + h.task.Brief.Stable + "\n\n" + h.task.Brief.Dynamic
	want2 := feedbackPreface + "\n\n" + feedback
	if len(want1) <= 128<<10 || len(want2) <= 128<<10 {
		t.Fatalf("prompts of %d and %d bytes are not large", len(want1), len(want2))
	}
	for round, want := range map[int]string{1: want1, 2: want2} {
		got := h.f.prompt(round)
		if sha256.Sum256(got) != sha256.Sum256([]byte(want)) || len(got) != len(want) {
			t.Fatalf("round %d: stdin %d bytes with another digest than the expected %d bytes", round, len(got), len(want))
		}
		for _, a := range h.f.argv(round) {
			if len(a) > 8192 {
				t.Fatalf("round %d: an argv element of %d bytes", round, len(a))
			}
		}
	}
	if p := h.f.prompts(); len(p) != 1 || p[0] != want2 {
		t.Fatalf("feedback prompts recorded: %d", len(p))
	}
}

// Claude Code dying without reading a large prompt is classified from its exit, never a hang or
// a write error.
func TestEarlyExitBeforeReadingStdin(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{ExitBeforeStdin: true, ExitCode: 3, Script: oneRound(finishRound)})
	h.task.Brief.Stable = strings.Repeat("x", 4<<20)
	s := h.startOK()
	done := make(chan error, 1)
	go func() {
		_, err := s.Round(context.Background(), executor.Input{})
		done <- err
	}()
	select {
	case err := <-done:
		e := wantError(t, err, "executor/failed")
		if !strings.Contains(e.Detail, "status 3") || strings.Contains(e.Detail, "send the prompt") {
			t.Fatalf("detail %q", e.Detail)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("Round hung after Claude Code exited without reading stdin")
	}
}

func TestEnvStripping(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{Script: oneRound(finishRound)})
	var extra []string
	for _, k := range stripEnv {
		extra = append(extra, k+"=must-not-reach-claude")
	}
	extra = append(extra, "KOGEN_KEEP_ME=1", "HOME=/ignored/home", "CLAUDE_CODE_DISABLE_AUTO_MEMORY=0")
	s, err := h.start(h.f.options(extra...))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := s.Round(context.Background(), executor.Input{}); err != nil {
		t.Fatal(err)
	}
	env := map[string]string{}
	for _, kv := range h.f.env(1) {
		k, v, _ := strings.Cut(kv, "=")
		env[k] = v
	}
	for _, k := range stripEnv {
		if _, ok := env[k]; ok {
			t.Errorf("%s reached the child", k)
		}
	}
	if env["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"] != "1" || env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] != "1" {
		t.Errorf("disable variables: %v %v", env["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"], env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"])
	}
	if env["KOGEN_KEEP_ME"] != "1" {
		t.Error("an unrelated variable was dropped")
	}
	if env["HOME"] != h.task.Home {
		t.Errorf("HOME %q, want task.Home %q", env["HOME"], h.task.Home)
	}
	var count int
	for _, kv := range h.f.env(1) {
		if strings.HasPrefix(kv, "HOME=") {
			count++
		}
	}
	if count != 1 {
		t.Errorf("%d HOME entries", count)
	}
}

func TestEnvStrippingInPreflight(t *testing.T) {
	t.Parallel()
	// The auth status and version probes must run without credentials too.
	got := childEnv([]string{"ANTHROPIC_API_KEY=k", "PATH=/bin", "CLAUDECODE=1"}, "")
	if !reflect.DeepEqual(got, []string{"PATH=/bin", "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY=1"}) {
		t.Fatalf("env %v", got)
	}
}

// These are independent examples of model cloud-route credentials, not derived from
// the production strip list: omissions from that list must not pass this regression.
func TestCloudCredentialsDoNotReachClaude(t *testing.T) {
	t.Parallel()
	keys := []string{
		"AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_SECURITY_TOKEN",
		"AWS_PROFILE", "AWS_DEFAULT_PROFILE", "AWS_SHARED_CREDENTIALS_FILE", "AWS_CONFIG_FILE",
		"AWS_WEB_IDENTITY_TOKEN_FILE", "AWS_BEARER_TOKEN_BEDROCK",
		"GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_ACCESS_TOKEN",
		"ANTHROPIC_FOUNDRY_API_KEY", "AZURE_CLIENT_SECRET", "AZURE_CLIENT_CERTIFICATE_PATH",
	}
	var extra []string
	for _, key := range keys {
		extra = append(extra, key+"=must-not-reach-claude")
	}
	h := newHarness(t, fakeConfig{Script: oneRound(finishRound)})
	s, err := h.start(h.f.options(extra...))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := s.Round(context.Background(), executor.Input{}); err != nil {
		t.Fatal(err)
	}
	for _, env := range [][]string{childEnv(extra, ""), h.f.env(1)} {
		for _, kv := range env {
			key, _, _ := strings.Cut(kv, "=")
			for _, forbidden := range keys {
				if key == forbidden {
					t.Errorf("%s reached the child environment", key)
				}
			}
		}
	}
}

func TestInitGateFailures(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		init map[string]any
		want string
	}{
		{"api key source", map[string]any{"apiKeySource": "ANTHROPIC_API_KEY"}, "executor/auth_refused"},
		{"api key source temporary", map[string]any{"apiKeySource": "/login managed key"}, "executor/auth_refused"},
		{"api key source missing", map[string]any{"apiKeySource": nil}, "executor/auth_refused"},
		{"other session", map[string]any{"session_id": "11111111-2222-4333-8444-555555555555"}, "executor/protocol"},
		{"permission mode", map[string]any{"permissionMode": "bypassPermissions"}, "executor/protocol"},
		{"permission mode default", map[string]any{"permissionMode": "default"}, "executor/protocol"},
		{"mcp servers", map[string]any{"mcp_servers": []any{map[string]any{"name": "x"}}}, "executor/protocol"},
		{"mcp servers unreported", map[string]any{"mcp_servers": nil}, "executor/protocol"},
		{"other cwd", map[string]any{"cwd": "/"}, "executor/protocol"},
		{"no cwd", map[string]any{"cwd": nil}, "executor/protocol"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			h := newHarness(t, fakeConfig{Init: c.init, Script: oneRound(conformance.RoundScript{
				Actions: []conformance.Action{{Write: &conformance.WriteAction{Path: "gate.txt", Content: "x\n"}}}, End: "finish",
			})})
			s := h.startOK()
			_, err := s.Round(context.Background(), executor.Input{})
			wantError(t, err, c.want)
			if len(h.eventsNamed("executor_round_failed")) != 1 {
				t.Fatalf("events %v", h.events)
			}
		})
	}
}

func TestInitNotFirst(t *testing.T) {
	t.Parallel()
	// A tool event before init is a protocol failure; documented startup hook events are fine.
	r := &roundRun{s: &session{sessionID: "s"}}
	err := r.line([]byte(`{"type":"assistant","message":{"content":[]}}`))
	wantError(t, err, "executor/protocol")
	r = &roundRun{s: &session{sessionID: "s"}}
	if err := r.line([]byte(`{"type":"system","subtype":"hook_started","hook_name":"SessionStart:startup"}`)); err != nil {
		t.Fatal(err)
	}
	wantError(t, r.line([]byte(`{"type":"result","subtype":"success"}`)), "executor/protocol")
	wantError(t, (&roundRun{s: &session{}}).line([]byte(`not json`)), "executor/protocol")
	wantError(t, (&roundRun{s: &session{}}).line([]byte(`[1]`)), "executor/protocol")
}

func TestLivenessFailure(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{SkipHook: true, Script: oneRound(conformance.RoundScript{
		Actions: []conformance.Action{{Write: &conformance.WriteAction{Path: "a.txt", Content: "a\n"}}}, End: "finish",
	})})
	s := h.startOK()
	_, err := s.Round(context.Background(), executor.Input{})
	e := wantError(t, err, "executor/protocol")
	if !strings.Contains(e.Detail, "hook did not run") {
		t.Fatalf("detail %q", e.Detail)
	}
	// The failed session refuses to continue.
	_, err = s.Round(context.Background(), executor.Input{Feedback: "again"})
	wantError(t, err, "executor/failed")
}

func TestDeniedWriteThatRanIsProtocolFailure(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{IgnoreDeny: true, Script: oneRound(conformance.RoundScript{
		Actions: []conformance.Action{{Write: &conformance.WriteAction{Path: conformance.ProtectedPath, Content: "tampered\n"}}}, End: "finish",
	})})
	s := h.startOK()
	_, err := s.Round(context.Background(), executor.Input{})
	wantError(t, err, "executor/protocol")
}

func TestHookLivenessIgnoresBashAndStaleLog(t *testing.T) {
	t.Parallel()
	// Bash calls are not guarded; a sentinel from another run (other nonce) does not count.
	r := &roundRun{s: &session{sessionID: "s", pol: policy{Log: filepath.Join(t.TempDir(), "log"), Nonce: "mine"}, emit: func(map[string]any) {}}, init: true}
	os.WriteFile(r.s.pol.Log, []byte(`{"nonce":"other","hook":"pretool","tool_use_id":"t1","decision":"allow"}`+"\n"), 0o600)
	r.line([]byte(`{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Edit"},{"type":"tool_use","id":"t2","name":"Bash"}]}}`))
	if err := r.line([]byte(`{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":false}]}}`)); err != nil {
		t.Fatalf("bash result: %v", err)
	}
	err := r.line([]byte(`{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":false}]}}`))
	wantError(t, err, "executor/protocol")
}

func TestUsageMappingRecordedResult(t *testing.T) {
	t.Parallel()
	// result.usage of the recorded receipt call1: per-invocation, cached separate from input.
	s := &session{}
	res, _ := decodeObject([]byte(`{"type":"result","total_cost_usd":0.0322255,"usage":{"input_tokens":4,"cache_creation_input_tokens":6400,"cache_read_input_tokens":28375,"output_tokens":378,"output_tokens_details":{"thinking_tokens":0}}}`))
	u := s.mapUsage(res, "claude-sonnet-5-5")
	if u.State != executor.UsageComplete || u.Source != executor.UsageHarness || u.Model != "claude-sonnet-5-5" {
		t.Fatalf("usage %+v", u)
	}
	if *u.Input != 4+6400+28375 || *u.Cached != 28375 || *u.Output != 378 || u.Reasoning != nil {
		t.Fatalf("usage %d %d %d %v", *u.Input, *u.Cached, *u.Output, u.Reasoning)
	}
	if u.CostUSD == nil || *u.CostUSD != 0.0322255 {
		t.Fatalf("cost %v", u.CostUSD)
	}
}

func TestUsageMappingStates(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name  string
		usage string
		state string
		input bool
	}{
		{"missing usage", ``, executor.UsageUnknown, false},
		{"empty usage", `"usage":{},`, executor.UsageUnknown, false},
		{"no cache creation", `"usage":{"input_tokens":4,"cache_read_input_tokens":3,"output_tokens":5},`, executor.UsagePartial, false},
		{"output only", `"usage":{"output_tokens":5},`, executor.UsagePartial, false},
		{"invalid output", `"usage":{"input_tokens":4,"cache_read_input_tokens":3,"cache_creation_input_tokens":0,"output_tokens":-1},`, executor.UsagePartial, true},
		{"fractional input", `"usage":{"input_tokens":1.5,"cache_read_input_tokens":3,"cache_creation_input_tokens":0,"output_tokens":1},`, executor.UsagePartial, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			res, err := decodeObject([]byte(`{` + c.usage + `"type":"result"}`))
			if err != nil {
				t.Fatal(err)
			}
			u := (&session{}).mapUsage(res, "m")
			if u.State != c.state || (u.Input != nil) != c.input {
				t.Fatalf("usage %+v", u)
			}
			if c.state == executor.UsageUnknown && (u.Input != nil || u.Cached != nil || u.Output != nil || u.CostUSD != nil) {
				t.Fatalf("unknown usage carries numbers: %+v", u)
			}
		})
	}
}

func TestCostIsCumulativeDelta(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{TotalCosts: []float64{0.0322255, 0.0387215}, Script: conformance.Script{Rounds: []conformance.RoundScript{finishRound, finishRound}}})
	s := h.startOK()
	r1, err := s.Round(context.Background(), executor.Input{})
	if err != nil {
		t.Fatal(err)
	}
	r2, err := s.Round(context.Background(), executor.Input{Feedback: "f"})
	if err != nil {
		t.Fatal(err)
	}
	if r1.Usage.CostUSD == nil || *r1.Usage.CostUSD != 0.0322255 {
		t.Fatalf("round 1 cost %v", r1.Usage.CostUSD)
	}
	if r2.Usage.CostUSD == nil || *r2.Usage.CostUSD != 0.006496 {
		t.Fatalf("round 2 cost %v, want the delta 0.006496", r2.Usage.CostUSD)
	}
	// finishRound reports Input 120 including 20 cached: the fake sends input_tokens 100.
	if *r1.Usage.Input != 120 || *r1.Usage.Cached != 20 || *r1.Usage.Output != 30 || r1.Usage.State != executor.UsageComplete {
		t.Fatalf("usage %+v", r1.Usage)
	}
}

func TestRoundResultsAndEvents(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{Script: oneRound(conformance.RoundScript{
		Actions: []conformance.Action{
			{Write: &conformance.WriteAction{Path: conformance.ProtectedPath, Content: "tampered\n"}},
			{Write: &conformance.WriteAction{Path: "ok.txt", Content: "ok\n"}},
			{Shell: "echo hi"},
		},
		End: "finish", Claim: "all done", Usage: &conformance.ScriptUsage{Input: 10, Cached: 0, Output: 2},
	})})
	s := h.startOK()
	res, err := s.Round(context.Background(), executor.Input{})
	if err != nil {
		t.Fatal(err)
	}
	if res.Ending != executor.EndFinish || res.Claim != "all done" || res.Handle != s.Handle() || res.Blocker != nil {
		t.Fatalf("result %+v", res)
	}
	if b, _ := os.ReadFile(filepath.Join(h.root, conformance.ProtectedPath)); string(b) != conformance.ProtectedContent {
		t.Fatalf("protected file changed: %q", b)
	}
	started := h.eventsNamed("executor_round_started")
	if len(started) != 1 || started[0]["round"] != 1 || started[0]["resume"] != false {
		t.Fatalf("round_started %v", started)
	}
	tools := h.eventsNamed("executor_tool")
	if len(tools) != 3 {
		t.Fatalf("tool events %v", tools)
	}
	if tools[0]["name"] != "Write" || tools[0]["denied"] != true || tools[1]["denied"] != false || tools[2]["name"] != "Bash" {
		t.Fatalf("tool events %v", tools)
	}
	hooks := h.eventsNamed("executor_hook")
	if len(hooks) != 2 || hooks[0]["decision"] != "deny" || hooks[1]["decision"] != "allow" || hooks[0]["tool_use_id"] == "" {
		t.Fatalf("hook events %v", hooks)
	}
	ended := h.eventsNamed("executor_round_ended")
	if len(ended) != 1 {
		t.Fatalf("events %v", h.events)
	}
	e := ended[0]
	if e["ending"] != "finish" || e["num_turns"] != 3 || e["permission_denials"] != 1 || e["session_id"] != s.Handle().SessionID ||
		e["model"] != "claude-sonnet-5-5" || e["claude_code_version"] != "2.1.306" {
		t.Fatalf("round_ended %v", e)
	}
	if u := e["usage"].(map[string]any); u["state"] != "complete" || u["source"] != "harness" || u["input"] != 10 {
		t.Fatalf("usage event %v", u)
	}
	for _, ev := range h.events {
		if !strings.HasPrefix(ev["event"].(string), "executor_") {
			t.Fatalf("event %v", ev)
		}
	}
}

func TestRawStreamAndStderrSaved(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{Script: oneRound(finishRound)})
	s := h.startOK()
	if _, err := s.Round(context.Background(), executor.Input{}); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(h.task.Dir, "round-1.jsonl")
	fi, err := os.Stat(p)
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("stream file: %v %v", fi, err)
	}
	b, _ := os.ReadFile(p)
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	if len(lines) < 2 || !strings.Contains(lines[0], `"subtype":"init"`) || !strings.Contains(lines[len(lines)-1], `"type":"result"`) {
		t.Fatalf("stream %q", b)
	}
	if fi, err := os.Stat(filepath.Join(h.task.Dir, "round-1.stderr")); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("stderr file: %v %v", fi, err)
	}
}

func TestResultFailures(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name   string
		cfg    fakeConfig
		want   string
		detail string
	}{
		{"during execution", fakeConfig{Result: map[string]any{"subtype": "error_during_execution", "is_error": true}}, "executor/failed", "error_during_execution"},
		{"budget", fakeConfig{Result: map[string]any{"subtype": "error_max_budget_usd", "is_error": true}}, "executor/failed", "error_max_budget_usd"},
		{"success with is_error", fakeConfig{Result: map[string]any{"is_error": true, "terminal_reason": "api_error"}}, "executor/failed", "api_error"},
		{"unknown subtype", fakeConfig{Result: map[string]any{"subtype": "surprise"}}, "executor/failed", "surprise"},
		{"nonzero exit no result", fakeConfig{NoResult: true, ExitCode: 3}, "executor/failed", "status 3"},
		{"no result clean exit", fakeConfig{NoResult: true}, "executor/protocol", "without a result"},
		{"other session result", fakeConfig{Result: map[string]any{"session_id": "zzz"}}, "executor/protocol", "session"},
		{"missing session result", fakeConfig{Result: map[string]any{"session_id": nil}}, "executor/protocol", "session"},
		{"malformed session result", fakeConfig{Result: map[string]any{"session_id": 1}}, "executor/protocol", "session"},
		{"missing error flag", fakeConfig{Result: map[string]any{"is_error": nil}}, "executor/protocol", "is_error"},
		{"malformed error flag", fakeConfig{Result: map[string]any{"is_error": "true"}}, "executor/protocol", "is_error"},
		{"missing claim", fakeConfig{Result: map[string]any{"result": nil}}, "executor/protocol", "result text"},
		{"malformed claim", fakeConfig{Result: map[string]any{"result": 1}}, "executor/protocol", "result text"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			c.cfg.Script = oneRound(conformance.RoundScript{End: "finish", Claim: "x"})
			h := newHarness(t, c.cfg)
			s := h.startOK()
			_, err := s.Round(context.Background(), executor.Input{})
			e := wantError(t, err, c.want)
			if !strings.Contains(e.Detail, c.detail) {
				t.Fatalf("detail %q lacks %q", e.Detail, c.detail)
			}
		})
	}
}

func TestEventAfterResultIsProtocolFailure(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{TrailingEvent: true, Script: oneRound(finishRound)})
	s := h.startOK()
	_, err := s.Round(context.Background(), executor.Input{})
	wantError(t, err, "executor/protocol")
}

func TestMaxTurnsIsNoCallClaim(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{Script: oneRound(conformance.RoundScript{End: "no_call", Claim: "ignored model text"})})
	s := h.startOK()
	res, err := s.Round(context.Background(), executor.Input{})
	if err != nil {
		t.Fatal(err)
	}
	if res.Ending != executor.EndNoCall || !strings.Contains(res.Claim, "turn limit of 150") || strings.Contains(res.Claim, "ignored") {
		t.Fatalf("result %+v", res)
	}
}

func TestClaimBounded(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{Script: oneRound(conformance.RoundScript{End: "finish", Claim: strings.Repeat("é", 20000)})})
	s := h.startOK()
	res, err := s.Round(context.Background(), executor.Input{})
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Claim) > claimBytes || !strings.HasSuffix(res.Claim, "[truncated]") {
		t.Fatalf("claim of %d bytes", len(res.Claim))
	}
	if strings.ContainsRune(res.Claim, '�') {
		t.Fatal("claim cut inside a rune")
	}
	if boundBytes("short", claimBytes) != "short" {
		t.Fatal("short text changed")
	}
}

func TestLingeringProcessAfterResultIsStopped(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{LingerSeconds: 30, Script: oneRound(finishRound)})
	o := h.f.options()
	o.KillGrace = 300 * time.Millisecond
	s, err := h.start(o)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	start := time.Now()
	res, err := s.Round(context.Background(), executor.Input{})
	if err != nil || res.Ending != executor.EndFinish {
		t.Fatalf("result %+v err %v", res, err)
	}
	if time.Since(start) > 10*time.Second {
		t.Fatal("round waited for the lingering process")
	}
}

func TestCancellationClassifiedByContext(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{Script: oneRound(conformance.RoundScript{Actions: []conformance.Action{{Shell: "sleep 30"}}, End: "finish"})})
	s := h.startOK()
	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(500*time.Millisecond, cancel)
	_, err := s.Round(ctx, executor.Input{})
	wantError(t, err, "executor/interrupted")

	h = newHarness(t, fakeConfig{Script: oneRound(conformance.RoundScript{Actions: []conformance.Action{{Shell: "sleep 30"}}, End: "finish"})})
	s = h.startOK()
	ctx, cancel = context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	_, err = s.Round(ctx, executor.Input{})
	wantError(t, err, "executor/deadline")
}

func TestSecondRoundNeedsFeedback(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{Script: conformance.Script{Rounds: []conformance.RoundScript{finishRound, finishRound}}})
	s := h.startOK()
	if _, err := s.Round(context.Background(), executor.Input{}); err != nil {
		t.Fatal(err)
	}
	_, err := s.Round(context.Background(), executor.Input{})
	wantError(t, err, "executor/failed")
}

func TestCloseRefusesRounds(t *testing.T) {
	t.Parallel()
	h := newHarness(t, fakeConfig{Script: oneRound(finishRound)})
	s := h.startOK()
	s.Close()
	_, err := s.Round(context.Background(), executor.Input{})
	wantError(t, err, "executor/failed")
}

func TestCleanProtected(t *testing.T) {
	t.Parallel()
	got := cleanProtected("/r", []string{"a/b.txt", " ./c ", "/r/d/e", "../x", "..", ".", "", "/elsewhere/f"})
	if !reflect.DeepEqual(got, []string{"a/b.txt", "c", "d/e"}) {
		t.Fatalf("got %q", got)
	}
}

func TestMalformedTrailingJSONIsProtocolFailure(t *testing.T) {
	t.Parallel()
	for _, suffix := range []string{"garbage", "[", "\"unterminated", "}", "{}"} {
		t.Run(suffix, func(t *testing.T) {
			t.Parallel()
			r := &roundRun{s: &session{sessionID: "s"}, init: true}
			err := r.line([]byte(`{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s"}` + suffix))
			wantError(t, err, "executor/protocol")
			if r.result != nil {
				t.Fatal("malformed JSON was retained as a result")
			}
		})
	}
	if _, err := decodeObject([]byte("{} \t\r\n")); err != nil {
		t.Fatalf("JSON followed only by whitespace: %v", err)
	}
}

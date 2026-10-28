// Package claudecode is the Claude Code executor adapter (docs/executor-contract.md): it runs
// the user's installed Claude Code CLI headless, on the user's own subscription sign-in, as
// Kogen's Build role. Every round is a claim: Kogen keeps the protected baseline, verification,
// review and the commit. The adapter is the only place that knows Claude Code's argv, event
// stream and hook protocol.
package claudecode

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"kogen/executor"
)

// MinVersion is the lowest qualified Claude Code version: hook onFailure:"block" needs 2.1.295.
const MinVersion = "2.1.295"

// Options configure the adapter. The zero value is production-ready except HookCommand.
type Options struct {
	// Binary is the Claude Code executable (default: `claude` resolved on PATH).
	Binary string
	// HookCommand is the Kogen binary and hidden subcommand that run the hooks, e.g.
	// [os.Executable(), HookSubcommand]. Required for prevention; Start refuses without it.
	HookCommand []string
	// MaxTurns is Claude Code's per-round turn limit (default 150).
	MaxTurns int
	// Env is the base environment of the child (default os.Environ()); the strip list is
	// applied on top.
	Env []string
	// Token is the stored Claude Code subscription token (`claude setup-token`), set as
	// fd 3 of every child that gets it; empty means none is stored.
	Token string
	// KillGrace is the wait between SIGTERM and SIGKILL of the process group (default 5s).
	KillGrace time.Duration
	// SettingSources is passed to --setting-sources. The default "" isolates the run from the
	// user's, project's and local Claude Code settings, hooks and CLAUDE.md.
	SettingSources string
}

// New returns the Claude Code executor.
func New(opts Options) executor.Executor {
	if opts.Binary == "" {
		opts.Binary = "claude"
	}
	if opts.MaxTurns <= 0 {
		opts.MaxTurns = 150
	}
	if opts.Env == nil {
		opts.Env = os.Environ()
	}
	if opts.KillGrace <= 0 {
		opts.KillGrace = 5 * time.Second
	}
	return &adapter{opts: opts}
}

type adapter struct {
	opts Options

	mu      sync.Mutex
	version string // exact `claude --version` output, trimmed
}

// Describe reports the executor's capabilities and exact version. It never fails: an
// unreadable version is "claude-code unknown".
func (a *adapter) Describe() executor.Descriptor {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	v := "unknown"
	if out, err := a.claudeVersion(ctx); err == nil {
		v = out
	}
	return executor.Descriptor{
		Name:             executor.ClaudeCode,
		Contract:         executor.Contract,
		Version:          "claude-code " + v,
		RoleCapabilities: roleCapabilities(),
		Capabilities: executor.Capabilities{
			Roles:        []string{executor.RoleBuild},
			Resume:       executor.ResumeNone,
			Continuation: true,
			Usage:        executor.UsageHarness,
			Prevention:   []string{executor.PreventPreToolWrite},
			Blocker:      true,
			Images:       false,
			MaxRounds:    6,
		},
	}
}

// roleCapabilities are the per-role capabilities of Claude Code as Kogen's source delivery
// provides them. Limitations are reported, never hidden: Claude's own Bash, research, images
// and subagents are not Kogen's scratch probe, documentation records, typed images or workers.
func roleCapabilities() map[string]executor.RoleCapabilities {
	common := []string{
		"no exact persistent resume: same-session continuation only within a running role invocation",
		"no Kogen-custodied typed images",
		"no Kogen scratch probe",
		"no native working-window replay",
	}
	shape := executor.RoleCapabilities{
		Resume: executor.ResumeNone, Continuation: true, Usage: executor.UsageHarness,
		Prevention: []string{executor.PreventPreToolWrite}, Structured: true, MaxRounds: 6,
		Limitations: append(append([]string{}, common...), "no Shape workers", "research by Claude tools is harness-observed only, not a Kogen documentation record"),
	}
	review := executor.RoleCapabilities{
		Resume: executor.ResumeNone, Continuation: true, Usage: executor.UsageHarness,
		Prevention: []string{executor.PreventPreToolWrite}, Structured: true, MaxRounds: 6,
		Limitations: append([]string{}, common...),
	}
	build := executor.RoleCapabilities{
		Resume: executor.ResumeNone, Continuation: true, Usage: executor.UsageHarness,
		Prevention: []string{executor.PreventPreToolWrite}, Blocker: true, MaxRounds: 6,
		Limitations: append([]string{}, common...),
	}
	return map[string]executor.RoleCapabilities{executor.RoleShape: shape, executor.RoleBuild: build, executor.RoleReview: review}
}

// binary resolves the executable.
func (a *adapter) binary() (string, error) {
	p, err := exec.LookPath(a.opts.Binary)
	if err != nil {
		return "", executor.Fail(executor.ReasonUnavailable, "the Claude Code executable ("+filepath.Base(a.opts.Binary)+") was not found; install Claude Code and sign in with `claude auth login`")
	}
	return p, nil
}

// claudeVersion is the cached exact `claude --version` output.
func (a *adapter) claudeVersion(ctx context.Context) (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.version != "" {
		return a.version, nil
	}
	bin, err := a.binary()
	if err != nil {
		return "", err
	}
	out, err := a.run(ctx, bin, nil, "", "--version")
	if err != nil {
		return "", err
	}
	v := strings.TrimSpace(string(out))
	if v == "" || strings.Contains(v, "\n") || len(v) > 200 {
		return "", executor.Fail(executor.ReasonUnavailable, "`claude --version` printed an unexpected answer")
	}
	a.version = v
	return v, nil
}

// redactMark replaces the stored token wherever Kogen would persist or print it.
const redactMark = "[redacted]"

// redact removes the stored token from s.
func (a *adapter) redact(s string) string {
	if a.opts.Token == "" {
		return s
	}
	return strings.ReplaceAll(s, a.opts.Token, redactMark)
}

// run runs a no-model-call claude subcommand with the stripped environment and a bounded output.
func (a *adapter) run(ctx context.Context, bin string, env []string, token string, args ...string) ([]byte, error) {
	if env == nil {
		env = childEnv(a.opts.Env, "", "")
	}
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.Env = env
	var buf, errBuf limitedBuffer
	cmd.Stdout, cmd.Stderr = &buf, &errBuf
	cmd.WaitDelay = 2 * time.Second
	err := startWithToken(cmd, token, cmd.Start)
	if err == nil {
		err = cmd.Wait()
	}
	if cmd.Process != nil {
		// Run has reaped the leader; stop any children it left behind, including
		// on a successful preflight or a child holding an output pipe open.
		exited := make(chan struct{})
		close(exited)
		killGroup(cmd.Process.Pid, exited)
	}
	if err != nil {
		if ctx.Err() != nil {
			return buf.Bytes(), classify(ctx)
		}
		return buf.Bytes(), executor.Fail(executor.ReasonUnavailable, "`claude "+strings.Join(args, " ")+"` failed: "+bound(a.redact(strings.TrimSpace(errBuf.String())), 300))
	}
	return buf.Bytes(), nil
}

// tokenPipe returns the read end of a fresh pipe holding exactly token, its write end closed.
func tokenPipe(token string) (*os.File, error) {
	r, w, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	_, err = w.WriteString(token)
	if cerr := w.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		r.Close()
		return nil, err
	}
	return r, nil
}

// startWithToken starts cmd through start. With a token the child gets it on fd 3; Kogen's
// read end is closed after the start, also when the start fails.
func startWithToken(cmd *exec.Cmd, token string, start func() error) error {
	if token == "" {
		return start()
	}
	r, err := tokenPipe(token)
	if err != nil {
		return executor.Fail(executor.ReasonFailed, "cannot create a pipe: "+err.Error())
	}
	defer r.Close()
	cmd.ExtraFiles = []*os.File{r}
	return start()
}

var versionRe = regexp.MustCompile(`^(\d+)\.(\d+)\.(\d+)`)

// versionAtLeast reports whether the output of `claude --version` starts with a version >= min.
func versionAtLeast(output, min string) bool {
	parse := func(s string) ([3]int, bool) {
		m := versionRe.FindStringSubmatch(strings.TrimSpace(s))
		var v [3]int
		if m == nil {
			return v, false
		}
		for i := range v {
			v[i], _ = strconv.Atoi(m[i+1])
		}
		return v, true
	}
	got, ok := parse(output)
	want, _ := parse(min)
	if !ok {
		return false
	}
	for i := range got {
		if got[i] != want[i] {
			return got[i] > want[i]
		}
	}
	return true
}

// authInfo is the only part of `claude auth status --json` the adapter keeps (never the
// account's email or organization).
type authInfo struct {
	LoggedIn         bool   `json:"loggedIn"`
	AuthMethod       string `json:"authMethod"`
	APIProvider      string `json:"apiProvider"`
	SubscriptionType string `json:"subscriptionType"`
}

// Start validates availability, version and the auth route without any model call, prepares the
// task directory (hook policy, settings) and returns the session.
func (a *adapter) Start(ctx context.Context, t executor.Task, emit executor.Sink) (executor.Session, error) {
	if emit == nil {
		emit = func(map[string]any) {}
	}
	if t.Role == "" {
		t.Role = executor.RoleBuild
	}
	if !executor.IsRole(t.Role) {
		return nil, executor.Fail(executor.ReasonUnavailable, "Claude Code does not serve the "+quoteBound(t.Role)+" role")
	}
	schema := BuildSchema
	if t.Role != executor.RoleBuild {
		var obj map[string]any
		if json.Unmarshal(t.Schema, &obj) != nil || obj == nil {
			return nil, executor.Fail(executor.ReasonUnavailable, "the "+t.Role+" role needs a JSON object schema for its structured submission")
		}
		schema = string(t.Schema)
	}
	if len(a.opts.HookCommand) == 0 || a.opts.HookCommand[0] == "" {
		return nil, executor.Fail(executor.ReasonUnavailable, "the Claude Code adapter has no hook command, so protected-path prevention cannot be installed")
	}
	if !t.Deadline.IsZero() {
		var cancel context.CancelFunc
		ctx, cancel = context.WithDeadline(ctx, t.Deadline)
		defer cancel()
	}
	if ctx.Err() != nil {
		return nil, classify(ctx)
	}
	bin, err := a.binary()
	if err != nil {
		return nil, err
	}
	version, err := a.claudeVersion(ctx)
	if err != nil {
		return nil, err
	}
	if !versionAtLeast(version, MinVersion) {
		return nil, executor.Fail(executor.ReasonUnavailable, "Claude Code "+version+" is older than the qualified minimum "+MinVersion)
	}
	env := childEnv(a.opts.Env, t.Home, a.opts.Token)
	if t.Role == executor.RoleShape {
		env = shapeEnv(env)
	}
	auth, err := a.authStatus(ctx, bin, env)
	if err != nil {
		return nil, err
	}

	root, err := filepath.EvalSymlinks(t.Root)
	if err != nil {
		return nil, executor.Fail(executor.ReasonUnavailable, "the checkout "+t.Root+" is not available: "+err.Error())
	}
	if fi, err := os.Stat(root); err != nil || !fi.IsDir() {
		return nil, executor.Fail(executor.ReasonUnavailable, "the checkout "+t.Root+" is not a directory")
	}
	if t.Dir == "" {
		return nil, executor.Fail(executor.ReasonUnavailable, "no executor artifact directory was given")
	}
	if err := os.MkdirAll(t.Dir, 0o700); err != nil {
		return nil, executor.Fail(executor.ReasonUnavailable, "cannot create the executor artifact directory: "+err.Error())
	}
	dir, err := filepath.Abs(t.Dir)
	if err != nil {
		return nil, executor.Fail(executor.ReasonUnavailable, "executor artifact directory: "+err.Error())
	}

	nonce, err := randomHex(16)
	if err != nil {
		return nil, executor.Fail(executor.ReasonFailed, "no randomness for the run nonce: "+err.Error())
	}
	sessionID, err := newUUID()
	if err != nil {
		return nil, executor.Fail(executor.ReasonFailed, "no randomness for the session id: "+err.Error())
	}
	pol := policy{Root: root, Protected: cleanProtected(root, t.Protected), Log: filepath.Join(dir, "hook-log.jsonl"), Nonce: nonce, ReadOnly: t.Role == executor.RoleShape}
	policyPath := filepath.Join(dir, "hook-policy.json")
	settingsPath := filepath.Join(dir, "claude-settings.json")
	if err := writePrivate(policyPath, mustJSON(pol)); err != nil {
		return nil, executor.Fail(executor.ReasonFailed, "cannot write the hook policy: "+err.Error())
	}
	if err := writePrivate(pol.Log, nil); err != nil {
		return nil, executor.Fail(executor.ReasonFailed, "cannot create the hook log: "+err.Error())
	}
	if err := writePrivate(settingsPath, mustJSON(hookSettings(a.opts.HookCommand, policyPath))); err != nil {
		return nil, executor.Fail(executor.ReasonFailed, "cannot write the hook settings: "+err.Error())
	}

	s := &session{
		a: a, task: t, emit: emit, bin: bin, env: env, root: root, dir: dir,
		sessionID: sessionID, version: version, settingsPath: settingsPath, pol: pol,
		role: t.Role, schema: schema,
	}
	emit(map[string]any{
		"event":               "executor_started",
		"executor":            executor.ClaudeCode,
		"contract":            executor.Contract,
		"version":             "claude-code " + version,
		"claude_code_version": version,
		"session_id":          sessionID,
		"run_id":              t.RunID,
		"role":                t.Role,
		"model":               t.Model,
		"effort":              t.Effort,
		"setting_sources":     a.opts.SettingSources,
		"max_turns":           a.opts.MaxTurns,
		"auth": map[string]any{
			"logged_in": auth.LoggedIn, "auth_method": auth.AuthMethod,
			"api_provider": auth.APIProvider, "subscription_type": auth.SubscriptionType,
		},
	})
	return s, nil
}

// tokenRefusedHint is the auth_refused detail when Claude Code does not accept the stored token.
const tokenRefusedHint = "Claude Code did not accept the stored token; run `claude setup-token` and `kogen provider login claude-code`"

// tokenAuthMethod is the auth method Claude Code reports for a CLAUDE_CODE_OAUTH_TOKEN sign-in.
const tokenAuthMethod = "oauth_token"

// authStatus runs `claude auth status --json` with the stripped env and requires the
// subscription sign-in on Anthropic's own API.
func (a *adapter) authStatus(ctx context.Context, bin string, env []string) (authInfo, error) {
	out, runErr := a.run(ctx, bin, env, a.opts.Token, "auth", "status", "--json")
	if ctx.Err() != nil {
		return authInfo{}, classify(ctx)
	}
	var info authInfo
	if err := json.Unmarshal(out, &info); err != nil {
		if runErr != nil {
			return info, executor.Fail(executor.ReasonUnavailable, "`claude auth status --json` failed; sign in with `claude auth login`")
		}
		return info, executor.Fail(executor.ReasonAuthRefused, "`claude auth status --json` did not answer with JSON")
	}
	switch {
	case !info.LoggedIn && a.opts.Token != "":
		return info, executor.Fail(executor.ReasonAuthRefused, tokenRefusedHint)
	case !info.LoggedIn:
		return info, executor.Fail(executor.ReasonAuthRefused, "Claude Code is not signed in; run `claude auth login` with your subscription")
	case info.AuthMethod != "claude.ai" && !(a.opts.Token != "" && info.AuthMethod == tokenAuthMethod):
		return info, executor.Fail(executor.ReasonAuthRefused, "Claude Code's sign-in route is "+quoteBound(info.AuthMethod)+", not the claude.ai subscription")
	case info.APIProvider != "firstParty":
		return info, executor.Fail(executor.ReasonAuthRefused, "Claude Code's API provider is "+quoteBound(info.APIProvider)+", not Anthropic's own (firstParty)")
	}
	if runErr != nil {
		return info, executor.Fail(executor.ReasonUnavailable, "`claude auth status --json` failed; sign in with `claude auth login`")
	}
	return info, nil
}

// hookSettings is the --settings JSON: a blocking PreToolUse guard on the file-writing tools
// and a PostToolUse Bash observation (never prevention).
func hookSettings(hookCmd []string, policyPath string) map[string]any {
	hook := func(sub string, block bool) map[string]any {
		args := append(append([]string{}, hookCmd[1:]...), sub, "--policy", policyPath)
		h := map[string]any{"type": "command", "command": hookCmd[0], "args": args, "timeout": 10}
		if block {
			h["onFailure"] = "block"
		}
		return h
	}
	return map[string]any{"hooks": map[string]any{
		"PreToolUse":  []any{map[string]any{"matcher": "Write|Edit|MultiEdit|NotebookEdit", "hooks": []any{hook("pretool", true)}}},
		"PostToolUse": []any{map[string]any{"matcher": "Bash", "hooks": []any{hook("posttool", false)}}},
	}}
}

// cleanProtected keeps the usable repository-relative protected paths (slash form).
func cleanProtected(root string, paths []string) []string {
	var out []string
	for _, p := range paths {
		p = filepath.Clean(filepath.FromSlash(strings.TrimSpace(p)))
		if filepath.IsAbs(p) {
			rel, err := filepath.Rel(root, p)
			if err != nil {
				continue
			}
			p = rel
		}
		if p == "." || p == ".." || strings.HasPrefix(p, ".."+string(filepath.Separator)) {
			continue
		}
		out = append(out, filepath.ToSlash(p))
	}
	return out
}

func writePrivate(path string, data []byte) error {
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}

func mustJSON(v any) []byte {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		panic(err)
	}
	return append(b, '\n')
}

func randomHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// newUUID is a random (version 4) UUID.
func newUUID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	h := hex.EncodeToString(b[:])
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:], nil
}

// classify is the executor error for a done context, by the context's state and never by an
// exit code (SIGINT exits 0). A sys.Interrupted cause keeps its own exit code.
func classify(ctx context.Context) error {
	if cause := context.Cause(ctx); cause != nil && !errors.Is(cause, context.Canceled) && !errors.Is(cause, context.DeadlineExceeded) {
		var te interface{ ExitCode() int }
		if errors.As(cause, &te) {
			return cause
		}
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return executor.Fail(executor.ReasonDeadline, "the Build deadline passed; Claude Code and its processes were stopped")
	}
	return executor.Fail(executor.ReasonInterrupted, "the round was interrupted; Claude Code and its processes were stopped")
}

// limitedBuffer keeps at most 1 MiB.
type limitedBuffer struct{ b bytes.Buffer }

func (l *limitedBuffer) Write(p []byte) (int, error) {
	if room := 1<<20 - l.b.Len(); room > 0 {
		l.b.Write(p[:min(len(p), room)])
	}
	return len(p), nil
}
func (l *limitedBuffer) Bytes() []byte  { return l.b.Bytes() }
func (l *limitedBuffer) String() string { return l.b.String() }

// bound shortens untrusted text to n bytes (on a rune boundary) for messages and events.
func bound(s string, n int) string {
	s = strings.Map(func(r rune) rune {
		if r < 0x20 && r != '\n' && r != '\t' {
			return ' '
		}
		return r
	}, s)
	if len(s) <= n {
		return s
	}
	cut := n
	for cut > 0 && !isRuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + "..."
}

func isRuneStart(b byte) bool { return b&0xC0 != 0x80 }

func quoteBound(s string) string { return strconv.Quote(bound(s, 60)) }

// VersionAtLeast reports whether the output of `claude --version` starts with a version >= min.
func VersionAtLeast(output, min string) bool { return versionAtLeast(output, min) }

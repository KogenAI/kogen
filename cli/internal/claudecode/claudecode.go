// Package claudecode is the Claude Code executor adapter (docs/executor-contract.md): it runs
// Kogen's own Claude Code (runtime.go: the compiled pin, or a newer version that passed Kogen's
// hook self-test, update.go and selftest.go) headless, on a subscription token Kogen saved, as
// Kogen's Build role. Every round is a claim: Kogen keeps the protected baseline, verification,
// review and the commit. The adapter is the only place that knows Claude Code's argv, event
// stream and hook protocol.
//
// The package is the adopted kogen-executor Claude Code adapter with the daily update added: the
// adopted component hard-codes one pinned version, and choosing, installing and self-testing
// another one has to happen where the runtime is resolved. The hook the executor wires into
// Claude Code stays the adopted component's (hook.go).
package claudecode

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/KogenAI/kogen-executor/executor"
)

// The fixed policy of every round.
const (
	// streamPersistBytes caps redacted stream payload per round. Overflow adds a
	// kogen_persistence_truncated JSON marker with cap_bytes, unpersisted_lines and
	// unpersisted_bytes. Terminal events report stream_persist_truncated and
	// stream_persist_unpersisted_bytes only on overflow.
	streamPersistBytes int64 = 64 << 20
	// stderrPersistBytes caps redacted stderr per round. Overflow adds a [kogen: stderr
	// persistence stopped at cap_bytes=...; unpersisted_bytes=...] marker. Terminal events
	// report stderr_persist_truncated and stderr_persist_unpersisted_bytes only on overflow or
	// when a failed or short write left stderr bytes unpersisted; stderr keeps draining after
	// such a failure.
	stderrPersistBytes int64 = 8 << 20
	// maxTurns is Claude Code's per-round turn limit.
	maxTurns = 150
	// killGrace is the wait between SIGTERM and SIGKILL of the process group.
	killGrace = 5 * time.Second
	// transcriptRetention is how long a Claude Code session transcript under the configuration
	// folder's projects directory is kept after its last modification. Every Start removes the
	// older ones, except its own session's.
	transcriptRetention = 24 * time.Hour
)

// Options configure the adapter. The zero value is production-ready except HookCommand.
type Options struct {
	// Home is the user's home directory: Kogen's Claude Code lives under <Home>/.kogen/claude-code.
	Home string
	// Stderr receives installation progress and lock-wait notices (default os.Stderr).
	Stderr io.Writer
	// HookCommand is the Kogen binary and hidden subcommand that run the hooks, e.g.
	// [os.Executable(), HookSubcommand]. Required for prevention; Start refuses without it.
	HookCommand []string
	// Env is the base environment of the child (default os.Environ()); the strip list is
	// applied on top.
	Env []string
	// Token is the stored Claude Code subscription token (`claude setup-token`), set as
	// fd 3 of every child that gets it; empty means none is stored.
	Token string
	// NoUpdate turns the daily update check at a role start off (Probe and SetupToken never
	// check).
	NoUpdate bool
}

// New returns the Claude Code executor.
func New(opts Options) executor.Executor {
	if opts.Env == nil {
		opts.Env = os.Environ()
	}
	return &adapter{opts: opts, goos: runtime.GOOS, goarch: runtime.GOARCH,
		killGrace: killGrace, streamCap: streamPersistBytes}
}

type adapter struct {
	opts               Options
	goos, goarch       string
	killGrace          time.Duration
	streamCap          int64
	downloadIdle       time.Duration
	downloadHeader     time.Duration
	downloadRetryDelay time.Duration
	sync               func(*os.File) error

	versionMu     sync.Mutex
	versionKnown  bool
	versionID     fileIdentity
	versionAnswer string
}

// Describe reports the executor's capabilities and exact version. It never fails: an
// unreadable version is "claude-code unknown".
func (a *adapter) Describe() executor.Descriptor {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	v := "unknown"
	if out, err := a.claudeVersion(ctx, a.selectRuntime(ctx)); err == nil {
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

// binary is the one executable Kogen runs, never resolved on PATH, accepted only when it passes
// the checks of inspectRuntime.
func (a *adapter) binary(rt runtimeRef) (string, error) {
	p, _, err := a.verifiedBinary(rt)
	return p, err
}

// verifiedBinary is binary together with the file's identity at the time of the checks.
func (a *adapter) verifiedBinary(rt runtimeRef) (string, fileIdentity, error) {
	if a.opts.Home == "" {
		return "", fileIdentity{}, unavailable("cannot locate your home directory for Kogen's Claude Code runtime")
	}
	p := rt.path
	info, present, err := a.inspectRuntime(rt)
	if err != nil {
		return "", fileIdentity{}, err
	}
	if !present {
		return "", fileIdentity{}, unavailable("Kogen's Claude Code " + rt.version + " is not installed at " + p)
	}
	return p, identityOf(info), nil
}

// fileIdentity is what a remembered version answer is bound to: the same file, size and
// modification time.
type fileIdentity struct {
	dev, ino uint64
	size     int64
	mtime    int64
}

func identityOf(info os.FileInfo) fileIdentity {
	id := fileIdentity{size: info.Size(), mtime: info.ModTime().UnixNano()}
	if st, ok := info.Sys().(*syscall.Stat_t); ok {
		id.dev, id.ino = uint64(st.Dev), uint64(st.Ino)
	}
	return id
}

// childEnv is the environment of every child: the existing rules plus Kogen's configuration
// directory and disabled updates.
func (a *adapter) childEnv(home, token string) []string {
	return childEnv(a.opts.Env, home, token, ConfigDir(a.opts.Home))
}

// claudeVersion is the answer of the currently managed executable. It is remembered only with
// the identity of the file that gave it, so a replaced executable is asked again.
func (a *adapter) claudeVersion(ctx context.Context, rt runtimeRef) (string, error) {
	bin, id, err := a.verifiedBinary(rt)
	if err != nil {
		return "", err
	}
	a.versionMu.Lock()
	defer a.versionMu.Unlock()
	if a.versionKnown && a.versionID == id {
		return a.versionAnswer, nil
	}
	a.versionKnown = false
	out, err := a.run(ctx, bin, nil, "", "--version")
	if err != nil {
		return "", err
	}
	v := strings.TrimSpace(string(out))
	if v == "" || strings.Contains(v, "\n") || len(v) > 200 {
		return "", executor.Fail(executor.ReasonUnavailable, "`claude --version` printed an unexpected answer")
	}
	a.versionKnown, a.versionID, a.versionAnswer = true, id, v
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
	out, end, stderr, ctxErr := a.runChild(ctx, bin, env, token, args...)
	if ctxErr != nil {
		return out, ctxErr
	}
	if end != "" {
		detail := "`claude " + strings.Join(args, " ") + "` failed: " + end
		if stderr != "" {
			detail += "; stderr: " + stderr
		}
		return out, executor.Fail(executor.ReasonUnavailable, detail)
	}
	return out, nil
}

// runChild runs the child and returns its output, the wording of how it ended (empty on
// success), its redacted, trimmed stderr bounded to 300 bytes and the caller's context error.
func (a *adapter) runChild(ctx context.Context, bin string, env []string, token string, args ...string) ([]byte, string, string, error) {
	return a.runChildIn(ctx, "", nil, bin, env, token, args...)
}

// runChildIn is runChild in a working directory (empty: this process's) with standard input.
func (a *adapter) runChildIn(ctx context.Context, dir string, stdin io.Reader, bin string, env []string, token string, args ...string) ([]byte, string, string, error) {
	if env == nil {
		env = a.childEnv("", "")
	}
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Dir = dir
	cmd.Stdin = stdin
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	desc := &descendants{}
	cmd.Cancel = func() error {
		desc.refresh()
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	cmd.Env = env
	var buf, errBuf limitedBuffer
	cmd.Stdout, cmd.Stderr = &buf, &errBuf
	cmd.WaitDelay = 2 * time.Second
	end := ""
	err := startWithToken(cmd, token, cmd.Start)
	endTracking := func() {}
	if err == nil {
		desc.begin(cmd.Process.Pid)
		endTracking = desc.track()
	}
	defer func() { endTracking() }()
	if err != nil {
		end = "could not start: " + err.Error()
	} else if err = cmd.Wait(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			var sig syscall.Signal
			if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
				sig = ws.Signal()
			}
			end = processEnd(sig, ee.ExitCode())
		} else {
			end = "failed while waiting: " + err.Error()
		}
	}
	if cmd.Process != nil {
		// Run has reaped the leader; stop any children it left behind, including
		// on a successful preflight or a child holding an output pipe open.
		exited := make(chan struct{})
		close(exited)
		killGroup(cmd.Process.Pid, exited, desc)
	}
	if err != nil {
		if ctx.Err() != nil {
			return buf.Bytes(), "", "", classify(ctx)
		}
		return buf.Bytes(), end, bound(a.redact(strings.TrimSpace(errBuf.String())), 300), nil
	}
	return buf.Bytes(), "", "", nil
}

// tokenPipe returns the read end of a fresh pipe holding exactly token, its write end closed.
// Limit the write to the POSIX minimum pipe capacity, so it cannot wait for a reader.
// Larger tokens are refused before creating a transport or starting the child.
const maxPipeTokenBytes = 512

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
	if len(token) > maxPipeTokenBytes {
		return executor.Fail(executor.ReasonFailed, "stored token is too large for private delivery")
	}
	r, err := tokenPipe(token)
	if err != nil {
		return executor.Fail(executor.ReasonFailed, "cannot create a pipe: "+err.Error())
	}
	defer r.Close()
	if len(cmd.ExtraFiles) == 0 {
		cmd.ExtraFiles = []*os.File{r}
	} else {
		cmd.ExtraFiles[0] = r
	}
	return start()
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
	// The structured submission is the phase's own: its schema comes with the task, for every
	// role, and is passed on byte for byte.
	var obj map[string]any
	if json.Unmarshal(t.Schema, &obj) != nil || obj == nil {
		return nil, executor.Fail(executor.ReasonUnavailable, "the "+t.Role+" role needs a JSON object schema for its structured submission")
	}
	schema := string(t.Schema)
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
	rt, err := a.prepareRuntime(ctx)
	if err != nil {
		return nil, err
	}
	bin, err := a.binary(rt)
	if err != nil {
		return nil, err
	}
	version, err := a.claudeVersion(ctx, rt)
	if err != nil {
		return nil, err
	}
	if !rt.reports(version) {
		return nil, unavailable(NotPinnedMessage(bin, version, rt.version) + "; remove " + rt.dir + " to reinstall it")
	}
	noteStarted(t.Role, version, rt)
	env := a.childEnv(t.Home, a.opts.Token)
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
	protected, dropped, count, fatal := classifyProtected(root, t.Protected)
	if fatal != nil {
		return nil, executor.Fail(executor.ReasonUnavailable, "protected path root_or_parent: "+fatal.Entry)
	}
	if t.Dir == "" {
		return nil, executor.Fail(executor.ReasonUnavailable, "no executor artifact directory was given")
	}
	dir, tightened, err := secureArtifactDir(t.Dir)
	if err != nil {
		return nil, err
	}

	realDir, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return nil, executor.Fail(executor.ReasonUnavailable, "executor artifact directory: "+err.Error())
	}
	dirInCheckout := within(root, realDir) || within(realDir, root)

	nonce, err := randomHex(16)
	if err != nil {
		return nil, executor.Fail(executor.ReasonFailed, "no randomness for the run nonce: "+err.Error())
	}
	sessionID, err := newUUID()
	if err != nil {
		return nil, executor.Fail(executor.ReasonFailed, "no randomness for the session id: "+err.Error())
	}
	pol := policy{Root: root, Protected: protected, Log: filepath.Join(dir, "hook-log.jsonl"), Nonce: nonce, ReadOnly: t.Role == executor.RoleShape, ProtectedIDs: protectedIDs(root, protected)}
	if dirInCheckout {
		pol.ArtifactDir = realDir
	}
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

	transcripts := pruneTranscripts(ConfigDir(a.opts.Home), time.Now(), transcriptRetention, sessionID).event()

	s := &session{
		a: a, task: t, emit: emit, bin: bin, env: env, root: root, dir: dir,
		sessionID: sessionID, version: version, settingsPath: settingsPath, pol: pol,
		role: t.Role, schema: schema,
	}
	started := map[string]any{
		"event":               "executor_started",
		"executor":            executor.ClaudeCode,
		"contract":            executor.Contract,
		"version":             "claude-code " + version,
		"claude_code_version": version,
		"claude_code_source":  rt.source(),
		"session_id":          sessionID,
		"run_id":              t.RunID,
		"role":                t.Role,
		"model":               t.Model,
		"effort":              t.Effort,
		"setting_sources":     "",
		"max_turns":           maxTurns,
		"auth": map[string]any{
			"logged_in": auth.LoggedIn, "auth_method": auth.AuthMethod,
			"api_provider": auth.APIProvider, "subscription_type": auth.SubscriptionType,
		},
	}
	if count > 0 {
		started["protected_dropped_count"] = count
		started["protected_dropped"] = dropped
	}
	if dirInCheckout {
		started["artifact_dir_in_checkout"] = true
	}
	if tightened {
		started["artifact_dir_mode_tightened"] = true
	}
	if transcripts != nil {
		started["transcripts"] = transcripts
	}
	emit(started)
	return s, nil
}

// artifactDirForeignOwner and artifactDirChmodFail are test-only seams. Production leaves them unset.
// They do not apply to a directory this Start created.
const (
	artifactDirForeignOwner = "KOGEN_ARTIFACT_DIR_FOREIGN_OWNER"
	artifactDirChmodFail    = "KOGEN_ARTIFACT_DIR_CHMOD_FAIL"
)

// secureArtifactDir chooses the session directory. An absent final component is created at 0700.
// A final-component symlink is resolved once and that directory is checked and used. An existing
// directory this user does not own is refused. Group or world access is tightened to 0700.
func secureArtifactDir(given string) (string, bool, error) {
	abs, err := filepath.Abs(given)
	if err != nil {
		return "", false, executor.Fail(executor.ReasonUnavailable, "executor artifact directory: "+err.Error())
	}
	fi, lerr := os.Lstat(abs)
	if os.IsNotExist(lerr) {
		if err := os.MkdirAll(abs, 0o700); err != nil {
			return "", false, executor.Fail(executor.ReasonUnavailable, "cannot create the executor artifact directory: "+err.Error())
		}
		return abs, false, nil
	}
	if lerr != nil {
		return "", false, executor.Fail(executor.ReasonUnavailable, "cannot create the executor artifact directory: "+lerr.Error())
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		target, rerr := os.Readlink(abs)
		if rerr != nil {
			return "", false, executor.Fail(executor.ReasonUnavailable, "cannot secure the executor artifact directory "+abs+": not a directory")
		}
		// filepath.Join appends an absolute target onto the link directory.
		// Keep an absolute target and resolve a relative one, once.
		resolved := target
		if !filepath.IsAbs(target) {
			resolved = filepath.Join(filepath.Dir(abs), target)
		}
		resolved = filepath.Clean(resolved)
		rfi, rerr := os.Lstat(resolved)
		if rerr != nil || !rfi.IsDir() || rfi.Mode()&os.ModeSymlink != 0 {
			return "", false, executor.Fail(executor.ReasonUnavailable, "cannot secure the executor artifact directory "+resolved+": not a directory")
		}
		return ownAndTightenArtifactDir(resolved, rfi)
	}
	if !fi.IsDir() {
		if err := os.MkdirAll(abs, 0o700); err != nil {
			return "", false, executor.Fail(executor.ReasonUnavailable, "cannot create the executor artifact directory: "+err.Error())
		}
		return abs, false, nil
	}
	return ownAndTightenArtifactDir(abs, fi)
}

func ownAndTightenArtifactDir(dir string, fi os.FileInfo) (string, bool, error) {
	if os.Getenv(artifactDirForeignOwner) != "" || !artifactDirOwned(fi) {
		return "", false, executor.Fail(executor.ReasonUnavailable, "cannot secure the executor artifact directory "+dir+": not owned by this user")
	}
	if fi.Mode().Perm()&0o077 == 0 {
		return dir, false, nil
	}
	if os.Getenv(artifactDirChmodFail) != "" {
		return "", false, executor.Fail(executor.ReasonUnavailable, "cannot secure the executor artifact directory "+dir+": cannot change its mode: operation not permitted")
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return "", false, executor.Fail(executor.ReasonUnavailable, "cannot secure the executor artifact directory "+dir+": cannot change its mode: "+err.Error())
	}
	return dir, true, nil
}

func artifactDirOwned(fi os.FileInfo) bool {
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return false
	}
	return st.Uid == uint32(os.Getuid())
}

// tokenRefusedHint is the auth_refused detail when Claude Code does not accept the stored token.
const tokenRefusedHint = "Claude Code did not accept the stored token; run `claude setup-token` and `kogen provider login claude-code`"

// kogenLogin is the one way to sign Kogen's own Claude Code in.
const kogenLogin = "make a token with `claude setup-token` and save it with `kogen provider login claude-code`"

// tokenAuthMethod is the auth method Claude Code reports for a CLAUDE_CODE_OAUTH_TOKEN sign-in.
const tokenAuthMethod = "oauth_token"

// authStatus runs `claude auth status --json` with the stripped env and requires the
// subscription sign-in on Anthropic's own API.
func (a *adapter) authStatus(ctx context.Context, bin string, env []string) (authInfo, error) {
	out, end, _, ctxErr := a.runChild(ctx, bin, env, a.opts.Token, "auth", "status", "--json")
	if ctx.Err() != nil {
		return authInfo{}, classify(ctx)
	}
	if ctxErr != nil {
		return authInfo{}, ctxErr
	}
	failed := executor.Fail(executor.ReasonUnavailable, "`claude auth status --json` failed ("+end+"); "+kogenLogin)
	var info authInfo
	if err := json.Unmarshal(out, &info); err != nil || !bytes.HasPrefix(bytes.TrimSpace(out), []byte("{")) {
		if end != "" {
			return info, failed
		}
		return info, executor.Fail(executor.ReasonUnavailable, unreadableStatusDetail(a.redact(string(out))))
	}
	switch {
	case !info.LoggedIn && a.opts.Token != "":
		return info, executor.Fail(executor.ReasonAuthRefused, tokenRefusedHint)
	case !info.LoggedIn:
		return info, executor.Fail(executor.ReasonAuthRefused, "Kogen's Claude Code is not signed in; "+kogenLogin)
	case info.AuthMethod != "claude.ai" && !(a.opts.Token != "" && info.AuthMethod == tokenAuthMethod):
		return info, executor.Fail(executor.ReasonAuthRefused, "Claude Code's sign-in route is "+quoteBound(info.AuthMethod)+", not the claude.ai subscription")
	case info.APIProvider != "firstParty":
		return info, executor.Fail(executor.ReasonAuthRefused, "Claude Code's API provider is "+quoteBound(info.APIProvider)+", not Anthropic's own (firstParty)")
	}
	if end != "" {
		return info, failed
	}
	return info, nil
}

// unreadableStatusDetail names a status answer that is not a JSON object and quotes a bounded
// excerpt of it (already redacted), or says it was empty.
func unreadableStatusDetail(redacted string) string {
	const head = "`claude auth status --json` gave an unreadable answer"
	excerpt := strings.TrimSpace(redacted)
	if excerpt == "" {
		return head + " (empty); " + kogenLogin
	}
	return head + ": " + strconv.Quote(bound(excerpt, 200))
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

type protectedDrop struct {
	Entry  string `json:"entry"`
	Reason string `json:"reason"`
}

// classifyProtected retains usable paths and reports ignored inputs in their original order.
func classifyProtected(root string, paths []string) (out []string, dropped []protectedDrop, count uint64, fatal *protectedDrop) {
	for _, original := range paths {
		p := strings.TrimSpace(original)
		reason := ""
		if p == "" {
			reason = "empty"
		} else {
			p = filepath.Clean(filepath.FromSlash(p))
			if filepath.IsAbs(p) {
				p, reason = classifyAbsolute(root, p)
			} else {
				reason = classifyRelative(p)
			}
		}
		if reason == "" {
			out = append(out, filepath.ToSlash(p))
			continue
		}
		entry := strings.ToValidUTF8(original, "\uFFFD")
		if len(entry) > 256 {
			cut := 256
			for cut > 0 && !utf8.RuneStart(entry[cut]) {
				cut--
			}
			entry = entry[:cut]
		}
		drop := protectedDrop{Entry: entry, Reason: reason}
		if reason == "root_or_parent" {
			return out, dropped, count, &drop
		}
		count++
		if len(dropped) < 20 {
			dropped = append(dropped, drop)
		}
	}
	return out, dropped, count, nil
}

// classifyRelative reports why a cleaned path relative to the root is unusable, or "".
func classifyRelative(p string) string {
	if p == "." {
		return "root_or_parent"
	}
	if p == ".." || strings.HasPrefix(p, ".."+string(filepath.Separator)) {
		for _, component := range strings.Split(p, string(filepath.Separator)) {
			if component != ".." {
				return "outside_checkout"
			}
		}
		return "root_or_parent"
	}
	return ""
}

// classifyAbsolute returns the root-relative form of a cleaned absolute entry and the reason it
// is unusable, or "". An entry lexically outside the root is retried through its symlinks: the
// remainder after the shortest leading prefix that resolves to the root keeps the entry's own
// spelling; otherwise the fully resolved entry is compared with the root.
func classifyAbsolute(root, p string) (string, string) {
	rel, err := filepath.Rel(root, p)
	if err != nil {
		return p, "outside_checkout"
	}
	reason := classifyRelative(rel)
	if reason == "root_or_parent" || reason == "" {
		return rel, reason
	}
	var prefixes []string
	for q := p; ; {
		prefixes = append(prefixes, q)
		parent := filepath.Dir(q)
		if parent == q {
			break
		}
		q = parent
	}
	for i := len(prefixes) - 1; i >= 0; i-- {
		if resolveReal(prefixes[i]) != root {
			continue
		}
		rem, err := filepath.Rel(prefixes[i], p)
		if err != nil {
			break
		}
		return rem, classifyRelative(rem)
	}
	rel, err = filepath.Rel(root, resolveReal(p))
	if err != nil {
		return p, "outside_checkout"
	}
	return rel, classifyRelative(rel)
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
// exit code. A sys.Interrupted cause keeps its own exit code.
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

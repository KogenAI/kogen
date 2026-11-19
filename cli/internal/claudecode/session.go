package claudecode

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/KogenAI/kogen-executor/executor"
	"github.com/KogenAI/kogen-loop/sys"
)

// maxLineBytes bounds one stream-json line.
// groupDrain bounds how long a pipe is read after the process group is terminated: a process
// that left the group may still hold the write end.
const groupDrain = 2 * time.Second

const maxLineBytes = 32 << 20

// claimBytes bounds the result text kept as the round's claim.
const claimBytes = 16384

type session struct {
	a            *adapter
	task         executor.Task
	emit         executor.Sink
	bin          string
	env          []string
	root, dir    string
	sessionID    string
	version      string
	settingsPath string
	pol          policy
	role         string // shape | build | review
	schema       string // JSON schema of the structured submission (shape, review)

	mu        sync.Mutex // one round at a time
	round     int
	promptLen int // bytes of the round's prompt, for a refusal's report
	failed    bool
	prevCost  float64
	costGap   bool
	modelBase map[string]map[string]float64 // raw model id -> field -> value in the last successful round's modelUsage
	model     string

	closed atomic.Bool
	live   atomic.Int64 // process group of the running round, 0 if none
}

// Handle identifies the session: Claude Code has no exact resume (Resume: none).
func (s *session) Handle() executor.Handle {
	return executor.Handle{Role: s.role, Executor: executor.ClaudeCode, Version: "claude-code " + s.version, SessionID: s.sessionID, Resume: executor.ResumeNone}
}

// Close stops a running round's process group, if any. Between rounds there is no process.
func (s *session) Close() error {
	s.closed.Store(true)
	if g := int(s.live.Load()); g > 0 {
		syscall.Kill(-g, syscall.SIGKILL)
	}
	return nil
}

// Round runs one Claude Code invocation: round 1 starts the session with --session-id, later
// rounds --resume it with Kogen's feedback. The result is a claim only.
func (s *session) Round(ctx context.Context, in executor.Input) (executor.RoundResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed.Load() {
		return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, "the executor session is closed")
	}
	if s.failed {
		return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, "the executor session cannot continue after a failed round")
	}
	s.round++
	n := s.round
	prompt := s.prompt(n, in)
	s.promptLen = len(prompt)
	if n > 1 && in.Feedback == "" {
		s.failed = true
		return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, "round "+strconv.Itoa(n)+" needs Kogen's feedback")
	}
	if len(prompt) > maxPromptBytes {
		s.failed = true
		return executor.RoundResult{}, sys.Fail("candidate", "context_budget_exceeded", "the "+s.role+" task text is "+strconv.Itoa(len(prompt))+" bytes, over the "+strconv.Itoa(maxPromptBytes)+"-byte limit for a Claude Code prompt; it was not clipped or sent", 1)
	}
	if !s.task.Deadline.IsZero() {
		var cancel context.CancelFunc
		ctx, cancel = context.WithDeadline(ctx, s.task.Deadline)
		defer cancel()
	}
	var remaining any
	if deadline, ok := ctx.Deadline(); ok {
		remaining = max(int64(0), time.Until(deadline).Milliseconds())
	}
	s.emit(map[string]any{"event": "executor_round_started", "role": s.role, "round": n, "session_id": s.sessionID, "resume": n > 1})
	rr := &roundRun{s: s, n: n, deadlineRemaining: remaining, started: time.Now()}
	res, err := s.runRound(ctx, n, prompt, rr)
	// A Cloudflare challenge is transient: run the same round again (a later round resumes the
	// session) after a bounded backoff, unless tool calls were left unfinished.
	for try := 0; isBlocked(err) && try < len(blockedBackoff) && len(rr.pending) == 0; try++ {
		s.emit(map[string]any{"event": "executor_round_retry", "role": s.role, "round": n, "reason": executor.ReasonProviderBlocked, "attempt": try + 2, "wait_ms": blockedBackoff[try].Milliseconds()})
		select {
		case <-time.After(blockedBackoff[try]):
		case <-ctx.Done():
			err = rr.classifyContext(ctx)
			continue // no longer blocked: the loop ends
		}
		rr = &roundRun{s: s, n: n, deadlineRemaining: remaining, started: time.Now()}
		res, err = s.runRound(ctx, n, prompt, rr)
	}
	if err != nil {
		s.failed = true
		reason, detail := "failed", err.Error()
		if e, ok := sys.AsError(err); ok {
			reason, detail = e.Reason, e.Detail
		}
		eventDetail := bound(detail, 400)
		if reason == executor.ReasonProviderUnavailable {
			eventDetail = detail
		}
		event := map[string]any{"event": "executor_round_failed", "role": s.role, "round": n, "reason": reason, "detail": eventDetail, "deadline_remaining_ms": remaining}
		if rr.hookCause != "" {
			event["hook_cause"] = rr.hookCause
			if rr.hookStderr != "" {
				event["hook_stderr"] = rr.hookStderr
			}
		}
		if rr.artifact != "" {
			event["artifact"] = rr.artifact
			event["kept_bytes"] = rr.keptBytes
		}
		if rr.interrupted {
			addInterruptCause(event, ctx)
		}
		rr.addModels(event)
		rr.addResult(event)
		rr.addRateLimit(event)
		rr.addProfile(event)
		rr.addPersistence(event)
		s.emit(event)
		return executor.RoundResult{}, err
	}
	return res, nil
}

// addInterruptCause observes the context that stopped the round without changing its error.
func addInterruptCause(event map[string]any, ctx context.Context) {
	var interrupted *sys.Interrupted
	switch {
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		event["interrupt_cause"] = "deadline"
	case errors.As(context.Cause(ctx), &interrupted):
		event["interrupt_cause"] = "signal"
		switch interrupted.Signal {
		case "SIGINT":
			event["signal"] = int(syscall.SIGINT)
		case "SIGTERM":
			event["signal"] = int(syscall.SIGTERM)
		case "SIGHUP":
			event["signal"] = int(syscall.SIGHUP)
		}
	default:
		event["interrupt_cause"] = "cancelled"
	}
}

func (r *roundRun) classifyContext(ctx context.Context) error {
	r.interrupted = true
	return classify(ctx)
}

// prompt is round 1's preface and task, or a later round's feedback.
func (s *session) prompt(n int, in executor.Input) string {
	if n == 1 {
		return firstPrompt(s.role, s.task.Brief)
	}
	return feedbackPreface + "\n\n" + in.Feedback
}

// firstPrompt is round 1's complete prompt for a role and brief: the role's framing, the stable
// authority and the dynamic evidence.
func firstPrompt(role string, brief executor.Brief) string {
	return constraintsFor(role) + promptSep + brief.Stable + promptSep + brief.Dynamic
}

const promptSep = "\n\n"

// FirstPromptBytes is the exact length of firstPrompt, the prompt a session writes to stdin in
// its first round (executor.PromptSizer).
func (a *adapter) FirstPromptBytes(role string, brief executor.Brief) int {
	return len(constraintsFor(role)) + len(promptSep) + len(brief.Stable) + len(promptSep) + len(brief.Dynamic)
}

// errArtifactWrite is the adapter's own detection of a failed retained-artifact write; the
// deferred block of runRound names the artifact.
var errArtifactWrite = executor.Fail(executor.ReasonFailed, "artifact write failed")

func (s *session) runRound(ctx context.Context, n int, prompt string, rr *roundRun) (result executor.RoundResult, roundErr error) {
	if ctx.Err() != nil {
		return executor.RoundResult{}, rr.classifyContext(ctx)
	}
	rawPath := filepath.Join(s.dir, "round-"+strconv.Itoa(n)+".jsonl")
	errPath := filepath.Join(s.dir, "round-"+strconv.Itoa(n)+".stderr")
	raw, err := os.OpenFile(rawPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, "cannot write the round stream: "+err.Error())
	}
	errf, err := os.OpenFile(errPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		raw.Close()
		return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, "cannot write the round stderr: "+err.Error())
	}
	defer raw.Close()
	defer errf.Close()
	streamFile := &retainedWriter{w: raw}
	stderrFile := &retainedWriter{w: errf}
	// Drain stderr through a bounded writer after streaming redaction.
	er, ew, perr := os.Pipe()
	if perr != nil {
		return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, "cannot create a pipe: "+perr.Error())
	}
	defer er.Close()
	defer ew.Close()
	stderr := ew
	capped := &stderrPersistence{w: stderrFile, cap: stderrPersistBytes}
	var errw *redactWriter
	var target io.Writer = capped
	if tok := s.a.opts.Token; tok != "" {
		errw = newRedactWriter(capped, tok, redactMark)
		target = errw
	}
	errCopied := make(chan struct{})
	stderrFailed := make(chan struct{}, 1)
	go func() { defer close(errCopied); copyRedacted(target, er, stderrFailed) }()
	var streamKept int64
	finalized := false
	finalize := func() {
		if finalized {
			return
		}
		finalized = true
		ew.Close()
		select {
		case <-errCopied:
		case <-time.After(groupDrain):
			er.Close()
			<-errCopied
		}
		if errw != nil {
			errw.Flush()
		}
		rr.stderrLostBytes = capped.lost
		if capped.lost > 0 {
			fmt.Fprintf(stderrFile, "\n[kogen: stderr persistence stopped at cap_bytes=%d; unpersisted_bytes=%d]\n", capped.cap, capped.lost)
		}
		if rr.streamLostLines > 0 {
			fmt.Fprintf(streamFile, "{\"type\":\"kogen_persistence_truncated\",\"cap_bytes\":%d,\"unpersisted_lines\":%d,\"unpersisted_bytes\":%d}\n", s.a.streamCap, rr.streamLostLines, rr.streamLostBytes)
		}
		if err := raw.Close(); streamFile.err == nil {
			streamFile.err = err
		}
		if err := errf.Close(); stderrFile.err == nil {
			stderrFile.err = err
		}
	}
	defer func() {
		finalize()
		if streamFile.err != nil {
			rr.artifact, rr.keptBytes = filepath.Base(rawPath), streamFile.kept
		} else if stderrFile.err != nil {
			rr.artifact, rr.keptBytes = filepath.Base(errPath), stderrFile.kept
		}
		// The failed artifact decides the error only when the round would otherwise have
		// succeeded or its only failure is the detection of that write; any other failure stays.
		if rr.artifact != "" && (roundErr == nil || roundErr == error(errArtifactWrite)) {
			result = executor.RoundResult{}
			roundErr = executor.Fail(executor.ReasonFailed, "cannot persist "+rr.artifact+" after "+strconv.FormatInt(rr.keptBytes, 10)+" bytes")
		}
	}()

	args := roleRoundArgs(s.role, s.schema, s.sessionID, n, s.task.Model, s.task.Effort, s.settingsPath)
	cmd := exec.Command(s.bin, args...)
	cmd.Dir = s.root
	cmd.Env = s.env
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	pr, pw, err := os.Pipe()
	if err != nil {
		return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, "cannot create a pipe: "+err.Error())
	}
	defer pr.Close()
	// The prompt travels over the child's stdin: no argv size limit, and it is never logged.
	sr, sw, err := os.Pipe()
	if err != nil {
		pw.Close()
		return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, "cannot create a pipe: "+err.Error())
	}
	cmd.Stdin, cmd.Stdout, cmd.Stderr = sr, pw, stderr
	retire, err := startCustodied(cmd, s.a.opts.Token)
	if err != nil {
		pw.Close()
		sr.Close()
		sw.Close()
		return executor.RoundResult{}, executor.Fail(executor.ReasonUnavailable, "cannot start Claude Code: "+bound(err.Error(), 200))
	}
	rr.procStarted = time.Now()
	pw.Close()
	sr.Close()
	stderr.Close() // the child holds the only write end now
	// The writer runs on its own goroutine so a full pipe can never block reading stdout. Round
	// closes sw and waits for it before returning, so it cannot outlive the round.
	writeErr := make(chan error, 1)
	writerDone := make(chan struct{})
	go func() {
		defer close(writerDone)
		_, err := io.WriteString(sw, prompt)
		if cerr := sw.Close(); err == nil {
			err = cerr
		}
		writeErr <- err
	}()
	defer func() {
		sw.Close() // unblocks a write stuck on a pipe nobody reads
		<-writerDone
	}()
	pgid := cmd.Process.Pid
	desc := &descendants{}
	desc.begin(pgid)
	endTracking := desc.track()
	defer func() {
		desc.refresh()
		syscall.Kill(-pgid, syscall.SIGKILL)
		desc.stop()
		endTracking()
		retire()
	}()
	s.live.Store(int64(pgid))
	defer s.live.Store(0)
	if s.closed.Load() {
		syscall.Kill(-pgid, syscall.SIGKILL)
	}

	exited := make(chan struct{})
	var waitErr error
	go func() {
		waitErr = cmd.Wait()
		close(exited)
	}()

	type lineMsg struct {
		line []byte
		err  error
	}
	lines := make(chan lineMsg)
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		defer close(lines)
		br := bufio.NewReaderSize(pr, 64<<10)
		for {
			line, err := readLine(br, maxLineBytes)
			if len(line) > 0 || err != nil && err != io.EOF {
				select {
				case lines <- lineMsg{line, err}:
				case <-stop:
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()

	killed := false // the adapter ended the process
	fail := func(err error) (executor.RoundResult, error) {
		killed = true
		killGroup(pgid, exited, desc)
		return executor.RoundResult{}, err
	}

	exitedCh := exited
	werrCh := (<-chan error)(writeErr)
	var drain <-chan time.Time
	lingering := false // the result is in but the process is still running
loop:
	for {
		select {
		case <-stderrFailed:
			return fail(errArtifactWrite)
		case <-ctx.Done():
			terminateGroup(pgid, exited, s.a.killGrace, desc)
			return executor.RoundResult{}, rr.classifyContext(ctx)
		case err := <-werrCh:
			werrCh = nil
			// A closed pipe means Claude Code stopped reading or died: its stream, exit status
			// and the init gate decide the outcome, not the write.
			if err != nil && !errors.Is(err, syscall.EPIPE) && !errors.Is(err, os.ErrClosed) {
				return fail(executor.Fail(executor.ReasonFailed, "cannot send the prompt to Claude Code: "+bound(err.Error(), 100)))
			}
		case m, ok := <-lines:
			if !ok {
				break loop
			}
			if m.err != nil && m.err != io.EOF {
				return fail(executor.Fail(executor.ReasonProtocol, "cannot read the event stream: "+bound(m.err.Error(), 100)))
			}
			rr.receive(time.Now())
			// Whole lines are redacted before they are persisted or parsed, so the token is
			// caught however the pipe chunked it and never reaches events or the claim.
			line := []byte(s.a.redact(string(m.line)))
			size := int64(len(line)) + 1
			if rr.streamLostLines > 0 || size > s.a.streamCap-streamKept {
				rr.streamLostLines++
				rr.streamLostBytes += size
			} else {
				streamFile.Write(line)
				streamFile.Write([]byte{'\n'})
				streamKept = streamFile.kept
				if streamFile.err != nil {
					return fail(errArtifactWrite)
				}
			}
			if err := rr.lineReceived(line, m.line); err != nil {
				return fail(err)
			}
			if rr.result != nil && drain == nil {
				// The result is the last line: give Claude Code KillGrace to exit on its own.
				drain = time.After(s.a.killGrace)
			}
		case <-exitedCh:
			// Claude Code is gone: stop what it left in its group (which may hold the
			// pipe open), then drain what was written.
			exitedCh = nil
			terminateGroup(pgid, exited, s.a.killGrace, desc)
			drain = time.After(groupDrain)
		case <-drain:
			lingering = exitedCh != nil
			break loop
		}
	}

	// All output read. Claude Code may linger after its result (background work): bound it.
	if lingering {
		killed = true
		terminateGroup(pgid, exited, s.a.killGrace, desc)
	}
	select {
	case <-exited:
	case <-ctx.Done():
		terminateGroup(pgid, exited, s.a.killGrace, desc)
		return executor.RoundResult{}, rr.classifyContext(ctx)
	case <-time.After(s.a.killGrace):
		killed = true
		terminateGroup(pgid, exited, s.a.killGrace, desc)
	}
	if groupAlive(pgid) {
		terminateGroup(pgid, exited, s.a.killGrace, desc)
	}
	select {
	case <-exited:
	case <-time.After(10 * time.Second):
		return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, "Claude Code did not exit")
	}
	if ctx.Err() != nil {
		return executor.RoundResult{}, rr.classifyContext(ctx)
	}
	exit := 0
	var ee *exec.ExitError
	if errors.As(waitErr, &ee) {
		exit = ee.ExitCode()
		if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			rr.endSignal = ws.Signal()
		}
	} else if waitErr != nil {
		exit = -1
	}
	finalize()
	// The result is classified even when an artifact failed: its own failure outranks the write.
	rr.persistFailed = streamFile.err != nil || stderrFile.err != nil
	result, err = rr.finish(exit, killed, errPath)
	if e, ok := sys.AsError(err); ok && e.Class == "executor" && e.Reason == executor.ReasonUsageLimit && groupAlive(pgid) {
		return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, "Claude Code process group did not exit; continuation is unsafe")
	}
	return result, err
}

// groupAlive reports whether any process is left in the group.
func groupAlive(pgid int) bool {
	err := syscall.Kill(-pgid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// waitGone waits until the leader is reaped and the group is empty, or the timeout passes.
func waitGone(pgid int, exited <-chan struct{}, timeout time.Duration) bool {
	end := time.Now().Add(timeout)
	for {
		select {
		case <-exited:
			if !groupAlive(pgid) {
				return true
			}
		default:
		}
		if time.Now().After(end) {
			return false
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// terminateGroup is the cancellation ladder: SIGTERM to the whole group, KillGrace, SIGKILL to
// the whole group, and a wait until nothing is left. Nothing is signalled to the group if it is
// gone; the recorded descendants outside it are stopped in every case.
func terminateGroup(pgid int, exited <-chan struct{}, grace time.Duration, desc *descendants) {
	desc.refresh()
	defer desc.stop()
	if !groupAlive(pgid) {
		select {
		case <-exited:
			return
		default:
		}
	}
	syscall.Kill(-pgid, syscall.SIGTERM)
	if waitGone(pgid, exited, grace) {
		return
	}
	killGroup(pgid, exited, desc)
}

// killGroup is SIGKILL to the whole group and a bounded wait for it to disappear, then SIGKILL
// to the descendants recorded below the leader (which may have left the group).
func killGroup(pgid int, exited <-chan struct{}, desc *descendants) {
	desc.refresh()
	syscall.Kill(-pgid, syscall.SIGKILL)
	waitGone(pgid, exited, 10*time.Second)
	desc.stop()
}

// readLine reads one line (without the newline), failing when it exceeds max bytes.
func readLine(br *bufio.Reader, max int) ([]byte, error) {
	var out []byte
	for {
		chunk, err := br.ReadSlice('\n')
		out = append(out, chunk...)
		if len(out) > max {
			return nil, errors.New("event line exceeds " + strconv.Itoa(max) + " bytes")
		}
		switch err {
		case nil:
			return trimEOL(out), nil
		case bufio.ErrBufferFull:
			continue
		default:
			return trimEOL(out), err
		}
	}
}

func trimEOL(b []byte) []byte {
	for len(b) > 0 && (b[len(b)-1] == '\n' || b[len(b)-1] == '\r') {
		b = b[:len(b)-1]
	}
	return b
}

// blockedBackoff are the waits before the second and third try of a round that met a Cloudflare
// challenge: three tries over three minutes.
var blockedBackoff = []time.Duration{time.Minute, 2 * time.Minute}

func isBlocked(err error) bool {
	e, ok := sys.AsError(err)
	return ok && e.Class == "executor" && e.Reason == executor.ReasonProviderBlocked
}

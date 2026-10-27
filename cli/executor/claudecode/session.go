package claudecode

import (
	"bufio"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"kogen-loop/sys"
	"kogen/executor"
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

	mu       sync.Mutex // one round at a time
	round    int
	failed   bool
	prevCost float64
	model    string

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
	s.emit(map[string]any{"event": "executor_round_started", "role": s.role, "round": n, "session_id": s.sessionID, "resume": n > 1})
	res, err := s.runRound(ctx, n, prompt)
	if err != nil {
		s.failed = true
		reason, detail := "failed", err.Error()
		if e, ok := sys.AsError(err); ok {
			reason, detail = e.Reason, e.Detail
		}
		s.emit(map[string]any{"event": "executor_round_failed", "role": s.role, "round": n, "reason": reason, "detail": bound(detail, 400)})
		return executor.RoundResult{}, err
	}
	return res, nil
}

// prompt is round 1's preface and task, or a later round's feedback.
func (s *session) prompt(n int, in executor.Input) string {
	if n == 1 {
		return constraintsFor(s.role) + "\n\n" + s.task.Brief.Stable + "\n\n" + s.task.Brief.Dynamic
	}
	return feedbackPreface + "\n\n" + in.Feedback
}

func (s *session) runRound(ctx context.Context, n int, prompt string) (executor.RoundResult, error) {
	if ctx.Err() != nil {
		return executor.RoundResult{}, classify(ctx)
	}
	rawPath := filepath.Join(s.dir, "round-"+strconv.Itoa(n)+".jsonl")
	errPath := filepath.Join(s.dir, "round-"+strconv.Itoa(n)+".stderr")
	raw, err := os.OpenFile(rawPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, "cannot write the round stream: "+err.Error())
	}
	defer raw.Close()
	errf, err := os.OpenFile(errPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, "cannot write the round stderr: "+err.Error())
	}
	defer errf.Close()
	// With a stored token stderr goes through a streaming replacer, so the token is never on disk.
	var errw *redactWriter
	var errRead *os.File
	var errCopied chan struct{}
	var stderr io.Writer = errf
	if tok := s.a.opts.Token; tok != "" {
		er, ew, perr := os.Pipe()
		if perr != nil {
			return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, "cannot create a pipe: "+perr.Error())
		}
		errRead, stderr = er, ew
		errw = newRedactWriter(errf, tok, redactMark)
		errCopied = make(chan struct{})
		defer er.Close()
		defer ew.Close()
		go func() {
			defer close(errCopied)
			copyRedacted(errw, er)
		}()
	}

	args := roleRoundArgs(s.a.opts, s.role, s.schema, s.sessionID, n, s.task.Model, s.task.Effort, s.settingsPath, s.a.opts.MaxTurns)
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
	if err := cmd.Start(); err != nil {
		pw.Close()
		sr.Close()
		sw.Close()
		return executor.RoundResult{}, executor.Fail(executor.ReasonUnavailable, "cannot start Claude Code: "+bound(err.Error(), 200))
	}
	pw.Close()
	sr.Close()
	if errw != nil {
		stderr.(*os.File).Close() // the child holds the only write end now
	}
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

	rr := &roundRun{s: s, n: n}
	killed := false // the adapter ended the process
	fail := func(err error) (executor.RoundResult, error) {
		killed = true
		killGroup(pgid, exited)
		return executor.RoundResult{}, err
	}

	exitedCh := exited
	werrCh := (<-chan error)(writeErr)
	var drain <-chan time.Time
	lingering := false // the result is in but the process is still running
loop:
	for {
		select {
		case <-ctx.Done():
			terminateGroup(pgid, exited, s.a.opts.KillGrace)
			return executor.RoundResult{}, classify(ctx)
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
			// Whole lines are redacted before they are persisted or parsed, so the token is
			// caught however the pipe chunked it and never reaches events or the claim.
			line := []byte(s.a.redact(string(m.line)))
			raw.Write(append(append([]byte{}, line...), '\n'))
			if err := rr.line(line); err != nil {
				return fail(err)
			}
			if rr.result != nil && drain == nil {
				// The result is the last line: give Claude Code KillGrace to exit on its own.
				drain = time.After(s.a.opts.KillGrace)
			}
		case <-exitedCh:
			// Claude Code is gone: stop what it left in its group (which may hold the
			// pipe open), then drain what was written.
			exitedCh = nil
			terminateGroup(pgid, exited, s.a.opts.KillGrace)
			drain = time.After(groupDrain)
		case <-drain:
			lingering = exitedCh != nil
			break loop
		}
	}

	// All output read. Claude Code may linger after its result (background work): bound it.
	if lingering {
		killed = true
		terminateGroup(pgid, exited, s.a.opts.KillGrace)
	}
	select {
	case <-exited:
	case <-ctx.Done():
		terminateGroup(pgid, exited, s.a.opts.KillGrace)
		return executor.RoundResult{}, classify(ctx)
	case <-time.After(s.a.opts.KillGrace):
		killed = true
		terminateGroup(pgid, exited, s.a.opts.KillGrace)
	}
	if groupAlive(pgid) {
		terminateGroup(pgid, exited, s.a.opts.KillGrace)
	}
	select {
	case <-exited:
	case <-time.After(10 * time.Second):
		return executor.RoundResult{}, executor.Fail(executor.ReasonFailed, "Claude Code did not exit")
	}
	if ctx.Err() != nil {
		return executor.RoundResult{}, classify(ctx)
	}
	exit := 0
	var ee *exec.ExitError
	if errors.As(waitErr, &ee) {
		exit = ee.ExitCode()
	} else if waitErr != nil {
		exit = -1
	}
	if errw != nil {
		select { // the copy ends when every holder of the write end is gone
		case <-errCopied:
		case <-time.After(groupDrain):
			errRead.Close()
			<-errCopied
		}
		errw.Flush()
	}
	return rr.finish(exit, killed, errPath)
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
// the whole group, and a wait until nothing is left. Nothing is signalled if the group is gone.
func terminateGroup(pgid int, exited <-chan struct{}, grace time.Duration) {
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
	killGroup(pgid, exited)
}

// killGroup is SIGKILL to the whole group and a bounded wait for it to disappear.
func killGroup(pgid int, exited <-chan struct{}) {
	syscall.Kill(-pgid, syscall.SIGKILL)
	waitGone(pgid, exited, 10*time.Second)
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

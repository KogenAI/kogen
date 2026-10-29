// Package sys is Kogen's base layer: errors shown to the user, the caller's terminal and
// environment, and project commands run as `/bin/sh -c` in a new process group with
// stdin closed, combined output capped at both ends, optional timeout, and cancellation
// on Ctrl-C (LOOP-5, CLI-7). Each command runs under a small supervisor (this same
// executable) that stops the command's process group when Kogen itself dies.
package sys

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// Session is one Kogen invocation: the caller's environment and working directory, the
// process groups it started and whether the caller interrupted.
type Session struct {
	Stdout, Stderr io.Writer
	Env            []string // KEY=VALUE, the caller's environment
	Cwd            string

	mu        sync.Mutex
	groups    map[int]bool
	finished  map[int]bool     // groups seen empty after their command ended; nothing is left to stop
	lifelines map[int]*os.File // supervisor lifelines held for groups that outlived their command
	cancelled string
	done      chan struct{}
	ctx       context.Context
	stop      context.CancelFunc
}

// New returns a Session for this process's environment and working directory.
func New() *Session {
	cwd, _ := os.Getwd()
	s := NewWith(os.Environ(), cwd)
	s.Stdout, s.Stderr = os.Stdout, os.Stderr
	return s
}

// NewWith returns a Session with an explicit environment and directory.
func NewWith(env []string, cwd string) *Session {
	ctx, stop := context.WithCancel(context.Background())
	return &Session{Stdout: io.Discard, Stderr: io.Discard, Env: env, Cwd: cwd, groups: map[int]bool{}, finished: map[int]bool{}, lifelines: map[int]*os.File{}, done: make(chan struct{}), ctx: ctx, stop: stop}
}

// Out writes text to stdout unchanged.
func (s *Session) Out(text string) { io.WriteString(s.Stdout, text) }

// Puts writes one line to stdout.
func (s *Session) Puts(line string) { s.Out(line + "\n") }

// Progress writes one progress or notice line to stderr (CLI-4).
func (s *Session) Progress(line string) { io.WriteString(s.Stderr, line+"\n") }

// Debug writes a `[debug] ` line to stderr when the caller set KOGEN_LOG_LEVEL=debug (CLI-4).
func (s *Session) Debug(line string) {
	if s.Getenv("KOGEN_LOG_LEVEL") == "debug" {
		io.WriteString(s.Stderr, "[debug] "+line+"\n")
	}
}

// Getenv returns the caller's value for key, or "".
func (s *Session) Getenv(key string) string {
	v, _ := s.LookupEnv(key)
	return v
}

// LookupEnv returns the caller's value for key and whether it is set.
func (s *Session) LookupEnv(key string) (string, bool) {
	for i := len(s.Env) - 1; i >= 0; i-- {
		if k, v, ok := strings.Cut(s.Env[i], "="); ok && k == key {
			return v, true
		}
	}
	return "", false
}

// Context is cancelled when the caller interrupts.
func (s *Session) Context() context.Context { return s.ctx }

// Interrupted is the error after the caller interrupted with Signal (SIGINT, SIGTERM, SIGHUP).
type Interrupted struct{ Signal string }

func (e *Interrupted) Error() string { return "interrupted by " + e.Signal }

// ExitCode is 130, 143 or 129.
func (e *Interrupted) ExitCode() int {
	return map[string]int{"SIGINT": 130, "SIGTERM": 143, "SIGHUP": 129}[e.Signal]
}

// Err returns *Interrupted once the caller has interrupted, else nil.
func (s *Session) Err() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cancelled != "" {
		return &Interrupted{s.cancelled}
	}
	return nil
}

// Interrupt records the caller's interrupt and stops every command group: SIGTERM, then
// SIGKILL after 5 seconds. Only the first interrupt counts.
func (s *Session) Interrupt(signal string) bool {
	s.mu.Lock()
	if s.cancelled != "" {
		s.mu.Unlock()
		return false
	}
	s.cancelled = signal
	groups := s.groupList()
	close(s.done)
	s.stop()
	s.mu.Unlock()
	go Terminate(groups)
	return true
}

// WatchSignals turns SIGINT, SIGTERM and SIGHUP into Interrupt until stop is called.
func (s *Session) WatchSignals() (stop func()) {
	sigs := make(chan os.Signal, 2)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	quit := make(chan struct{})
	go func() {
		for {
			select {
			case sig := <-sigs:
				s.Interrupt(map[os.Signal]string{syscall.SIGINT: "SIGINT", syscall.SIGTERM: "SIGTERM", syscall.SIGHUP: "SIGHUP"}[sig])
			case <-quit:
				return
			}
		}
	}()
	return func() { signal.Stop(sigs); close(quit) }
}

// Options are a command's optional settings.
type Options struct {
	Env     map[string]string // added to the caller's environment
	Timeout time.Duration     // nonpositive: no limit
	// Context cancels only a fired positive-timeout custody wait. Nil is unbounded.
	// The caller still owns overall execution custody (loop terminates its round groups).
	Context context.Context
	// FinishOnInterrupt waits for the command to end after an interrupt (git commit), so
	// Kogen sees what it left behind (CLI-7).
	FinishOnInterrupt bool
	// KillGroupOnExit sweeps the command's process group once its leader has ended:
	// SIGTERM, polling like Terminate, then SIGKILL; Run returns when the group has no
	// member. It changes no Status, Output or TimedOut and reaches no process that left
	// the group (setsid, double-fork daemons). Default false.
	KillGroupOnExit bool
	// RefuseForeignKill refuses, before anything starts, a command ForeignKill refuses:
	// Status 126, RefusalText as Output, Rule set, no error. Default false.
	RefuseForeignKill bool
}

// Result is a finished command: exit status (128+signal when killed), combined output
// (first and last 512 KiB) and whether the timeout stopped it.
type Result struct {
	Status   int
	Output   string
	TimedOut bool
	Rule     string // rule id of a refusal, "" otherwise
}

// Run runs `/bin/sh -c command` in dir like RunContext, with no context.
func (s *Session) Run(command, dir string, opts Options) (Result, error) {
	return s.RunContext(nil, command, dir, opts)
}

// startHook, when set by a test, is called at the shell-start boundary: "enter" before
// anything starts, "starting" after the process exists but before it is registered (the
// session is locked, so group queries wait), and "started" once it is registered.
var startHook func(stage string)

func hookStart(stage string) {
	if h := startHook; h != nil {
		h(stage)
	}
}

// RunContext runs `/bin/sh -c command` in dir. A done ctx (nil: never) stops the command:
// nothing starts once ctx is done, and a command that is starting or running has its whole
// group terminated (SIGTERM, then SIGKILL after the bounded wait) and joined before
// RunContext returns ctx.Err(). It returns *Interrupted when the caller
// interrupts; nothing starts after an interrupt. A fired positive Timeout waits
// for whole-group termination and disappearance before returning timeout feedback;
// an observed interrupt wins, then Options.Context, then ErrTimeoutObservation.
// Darwin and Linux observe native membership including zombies; other platforms
// return ErrTimeoutObservation after teardown. Options.Context does not change nonpositive
// Timeout or FinishOnInterrupt behavior. A command that leaves background processes in its
// group keeps its group until the caller stops it (Terminate, then Retire); groups left
// behind are not stopped by RunContext returning.
func (s *Session) RunContext(ctx context.Context, command, dir string, opts Options) (Result, error) {
	hookStart("enter")
	if opts.RefuseForeignKill {
		if rule, refused := ForeignKill(command, s.Owned); refused {
			return Result{Status: 126, Output: RefusalText(rule), Rule: rule}, nil
		}
	}
	s.Debug("command in " + dir + ": " + command)
	cmd, lifeline, err := supervised(command)
	if err != nil {
		return Result{Status: 127, Output: err.Error()}, nil
	}
	defer lifeline.release()
	cmd.Dir = dir
	cmd.Env = append([]string{}, s.Env...)
	for k, v := range opts.Env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	buf := &capBuffer{}
	cmd.Stdout, cmd.Stderr = buf, buf
	cmd.WaitDelay = time.Second

	s.mu.Lock()
	if s.cancelled != "" {
		sig := s.cancelled
		s.mu.Unlock()
		return Result{}, &Interrupted{sig}
	}
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			s.mu.Unlock()
			return Result{}, err
		}
	}
	if err := cmd.Start(); err != nil {
		s.mu.Unlock()
		return Result{Status: 127, Output: err.Error()}, nil
	}
	pgid := cmd.Process.Pid
	hookStart("starting")
	s.groups[pgid] = true
	s.mu.Unlock()
	hookStart("started")

	// Completion and the callback compete for ownership, not for timer.Stop's result.
	var owner commandLifecycle
	fired, teardown := make(chan struct{}), make(chan struct{})
	var timer *time.Timer
	if opts.Timeout > 0 {
		timer = time.AfterFunc(opts.Timeout, func() {
			if !owner.timeout() {
				return
			}
			close(fired)
			Terminate([]int{pgid})
			close(teardown)
		})
		defer timer.Stop()
	}
	waited := make(chan struct{})
	go func() { cmd.Wait(); owner.complete(); close(waited) }()
	select {
	case <-waited:
	case <-fired:
	case <-s.done:
		if opts.FinishOnInterrupt {
			<-waited
		}
		return Result{}, s.Err()
	case <-contextDone(ctx):
		// The group's stop is joined here, so a caller that returns on ctx has nothing
		// of this command left to race.
		Terminate([]int{pgid})
		<-waited
		return Result{}, ctx.Err()
	}
	timedOut := owner.timedOut()
	if timedOut {
		if err := s.timeoutCustody(opts.Context, pgid, teardown); err != nil {
			if opts.FinishOnInterrupt && s.Err() != nil {
				<-waited
			}
			return Result{}, err
		}
		select {
		case <-waited:
		case <-s.done:
			if opts.FinishOnInterrupt {
				<-waited
			}
			return Result{}, s.Err()
		case <-contextDone(opts.Context):
			return Result{}, s.timeoutStop(opts.Context)
		}
		if err := s.timeoutStop(opts.Context); err != nil {
			return Result{}, err
		}
	}
	if err := s.Err(); err != nil {
		return Result{}, err
	}
	if opts.KillGroupOnExit {
		sweepGroup(pgid)
	}
	s.afterCommand(pgid, lifeline)
	return Result{Status: exitStatus(cmd.ProcessState), Output: buf.String(), TimedOut: timedOut}, nil
}

// afterCommand records what an ended command left. A group that is already empty is
// finished (its number may be reused, so it is never signalled again); a group with
// members keeps the supervisor's lifeline, so that a dying caller still stops them.
func (s *Session) afterCommand(pgid int, l *lifeline) {
	if syscall.Kill(-pgid, 0) == syscall.ESRCH {
		s.mu.Lock()
		s.finished[pgid] = true
		s.mu.Unlock()
		return
	}
	if l == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lifelines[pgid] = l.keep()
}

// Retire ends the supervision of groups the caller has stopped on purpose: their
// lifelines close marked as retired, so no supervisor mistakes it for the caller's death.
func (s *Session) Retire(groups []int) {
	s.mu.Lock()
	var held []*os.File
	for _, g := range groups {
		if w := s.lifelines[g]; w != nil {
			held = append(held, w)
			delete(s.lifelines, g)
		}
	}
	s.mu.Unlock()
	for _, w := range held {
		w.Write([]byte{lifelineRetired})
		w.Close()
	}
}

// sweepGroup ends what the finished command left in its group and waits until the
// group has no member. A group that is already empty costs one failed kill (ESRCH).
func sweepGroup(pgid int) {
	Terminate([]int{pgid})
	for i := 0; i < 50 && syscall.Kill(-pgid, 0) != syscall.ESRCH; i++ {
		time.Sleep(20 * time.Millisecond)
	}
}

// commandLifecycle arbitrates the command's completion against a timer callback
// that may have been dispatched but not yet claimed teardown.
type commandLifecycle struct{ state atomic.Int32 }

func (l *commandLifecycle) complete()      { l.state.CompareAndSwap(0, 1) }
func (l *commandLifecycle) timeout() bool  { return l.state.CompareAndSwap(0, 2) }
func (l *commandLifecycle) timedOut() bool { return l.state.Load() == 2 }

// ErrTimeoutObservation means timeout signals were dispatched but whole-group
// absence could not be proven. It is a stopping error, never timeout feedback.
var ErrTimeoutObservation = errors.New("timeout custody observation failed")

func contextDone(ctx context.Context) <-chan struct{} {
	if ctx == nil {
		return nil
	}
	return ctx.Done()
}

func (s *Session) timeoutStop(ctx context.Context) error {
	if err := s.Err(); err != nil {
		return err
	}
	if ctx != nil {
		return ctx.Err()
	}
	return nil
}

type timeoutObservation struct {
	alive bool
	err   error
}

// A single worker owns observation for the entire wait. A blocked native query
// cannot gate signal dispatch or stop selection, nor accumulate per-poll workers.
func (s *Session) timeoutCustody(ctx context.Context, pgid int, teardown <-chan struct{}) error {
	observations := make(chan timeoutObservation)
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		for {
			alive, err := timeoutGroupAlive(pgid)
			select {
			case observations <- timeoutObservation{alive, err}:
			case <-stop:
				return
			}
			if err != nil || !alive {
				return
			}
			select {
			case <-time.After(10 * time.Millisecond):
			case <-stop:
				return
			}
		}
	}()
	return s.awaitTimeout(ctx, teardown, observations)
}

// Join teardown even on observation failure, unless a stopping signal wins.
func (s *Session) awaitTimeout(ctx context.Context, teardown <-chan struct{}, observations <-chan timeoutObservation) error {
	var observationErr error
	absent, joined := false, false
	for !joined || (!absent && observationErr == nil) {
		select {
		case <-s.done:
			return s.timeoutStop(ctx)
		case <-contextDone(ctx):
			return s.timeoutStop(ctx)
		case <-teardown:
			joined = true
			teardown = nil
		case o := <-observations:
			if o.err != nil {
				observationErr = fmt.Errorf("%w: %v", ErrTimeoutObservation, o.err)
			}
			absent = !o.alive && o.err == nil
		}
	}
	if err := s.timeoutStop(ctx); err != nil {
		return err
	}
	return observationErr
}

// Groups lists the process groups started so far.
func (s *Session) Groups() []int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.groupList()
}

// LiveGroups lists the started groups that may still have members: Groups without those
// seen empty after their command ended.
func (s *Session) LiveGroups() []int {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]int, 0, len(s.groups))
	for g := range s.groups {
		if !s.finished[g] {
			out = append(out, g)
		}
	}
	return out
}

func (s *Session) groupList() []int {
	out := make([]int, 0, len(s.groups))
	for g := range s.groups {
		out = append(out, g)
	}
	return out
}

// Terminate sends SIGTERM to each group, then SIGKILL after 5 seconds to those still alive.
func Terminate(groups []int) {
	var alive []int
	for _, g := range groups {
		if syscall.Kill(-g, syscall.SIGTERM) == nil {
			alive = append(alive, g)
		}
	}
	for i := 0; i < 50 && len(alive) > 0; i++ {
		time.Sleep(100 * time.Millisecond)
		var still []int
		for _, g := range alive {
			if syscall.Kill(-g, 0) == nil {
				still = append(still, g)
			}
		}
		alive = still
	}
	for _, g := range alive {
		syscall.Kill(-g, syscall.SIGKILL)
	}
}

func exitStatus(ps *os.ProcessState) int {
	if ps == nil {
		return -1
	}
	if ws, ok := ps.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return 128 + int(ws.Signal())
	}
	return ps.ExitCode()
}

// TmpPath is <tmp>/<prefix>-<16 hex>, a path no other Kogen process picks.
func TmpPath(prefix string) string {
	b := make([]byte, 8)
	rand.Read(b)
	return filepath.Join(os.TempDir(), prefix+"-"+hex.EncodeToString(b))
}

// ---- supervisor ----

// SuperviseArg is the hidden first argument with which Kogen runs itself as a command
// supervisor. cli main calls MaybeSupervise before anything else.
const SuperviseArg = "__kogen_supervise"

// lifeline is the pipe whose write end this process holds for a supervisor: the
// supervisor stops its group when that end closes unretired.
type lifeline struct {
	r, w *os.File
	kept bool
}

// release closes the supervisor's read end here and the write end unless it was kept.
func (l *lifeline) release() {
	if l == nil {
		return
	}
	l.r.Close()
	if !l.kept {
		l.w.Close()
	}
}

// keep hands the write end to the caller, who closes it with Retire.
func (l *lifeline) keep() *os.File {
	l.kept = true
	return l.w
}

// supervised returns a command that runs `/bin/sh -c command` under the supervisor, with
// the supervisor's lifeline (fd 3) held open by this process until release. The lifeline
// is nil when the command is not supervised.
func supervised(command string) (*exec.Cmd, *lifeline, error) {
	self, err := os.Executable()
	if err != nil || !supervisorAvailable(self) {
		return exec.Command("/bin/sh", "-c", command), nil, nil
	}
	r, w, err := os.Pipe()
	if err != nil {
		return nil, nil, err
	}
	cmd := exec.Command(self, SuperviseArg, command)
	cmd.ExtraFiles = []*os.File{r}
	return cmd, &lifeline{r: r, w: w}, nil
}

// supervisorAvailable is false in test binaries, which are not Kogen.
var supervisorAvailable = func(self string) bool { return supervisorEnabled.Load() }

var supervisorEnabled atomic.Bool

// EnableSupervisor makes Run start commands under the supervisor; cli main calls it.
func EnableSupervisor() { supervisorEnabled.Store(true) }

// MaybeSupervise runs the supervisor and exits when args start with SuperviseArg.
// The supervisor leads the command's process group, survives the terminal signals Kogen
// sends to the group, starts `/bin/sh -c command` in the same group, and stops the whole group
// (SIGTERM, then SIGKILL after 5 seconds) when its lifeline from Kogen closes. That stop
// is complete before the supervisor exits: it does not end with the direct shell, so a
// descendant that ignores SIGTERM still gets SIGKILL. When the command ends first and
// its group still has members, a small keeper stays in the group holding the lifeline,
// so Kogen's death still stops them; Retire, or the group emptying, ends the keeper.
func MaybeSupervise(args []string) {
	if len(args) == 1 && args[0] == lifelineArg {
		keeperMain()
		os.Exit(0)
	}
	if len(args) < 2 || args[0] != SuperviseArg {
		return
	}
	// Catch (not ignore) the signals: ignored dispositions would be inherited by the command.
	signal.Notify(make(chan os.Signal, 4), syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	lifeline := os.NewFile(3, "lifeline")
	cmd := exec.Command("/bin/sh", "-c", args[1])
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, os.Stdout, os.Stderr
	// sh starts with default signal handling, in the supervisor's process group.
	if err := cmd.Start(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(127)
	}
	// state: 0 command running, 1 command ended first, 2 the lifeline closed first.
	var mu sync.Mutex
	state := 0
	swept := make(chan struct{})
	pgid, self := syscall.Getpgrp(), os.Getpid()
	go func() {
		io.Copy(io.Discard, lifeline) // returns when Kogen dies or releases the lifeline
		mu.Lock()
		if state == 0 {
			state = 2
		}
		sweep := state == 2
		mu.Unlock()
		if sweep {
			sweepOwnGroup(pgid, self)
			close(swept)
		}
	}()
	cmd.Wait()
	status := exitStatus(cmd.ProcessState)
	if status < 0 {
		status = 127
	}
	mu.Lock()
	if state == 0 {
		state = 1
	}
	stopping := state == 2
	mu.Unlock()
	if stopping {
		<-swept
	} else if others, err := groupOthers(pgid, self); err != nil || others {
		leaveKeeper(lifeline)
	}
	os.Exit(status)
}

// capBuffer keeps the first and last 512 KiB of a command's output.
type capBuffer struct {
	mu      sync.Mutex
	head    []byte
	tail    []byte
	dropped int
}

const capHalf = 512 << 10

func (b *capBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	n := len(p)
	if room := capHalf - len(b.head); room > 0 {
		k := min(room, len(p))
		b.head = append(b.head, p[:k]...)
		p = p[k:]
	}
	b.tail = append(b.tail, p...)
	if over := len(b.tail) - capHalf; over > 0 {
		b.dropped += over
		b.tail = append(b.tail[:0], b.tail[over:]...)
	}
	return n, nil
}

func (b *capBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.dropped == 0 {
		return string(b.head) + string(b.tail)
	}
	return fmt.Sprintf("%s\n[... %s bytes omitted ...]\n%s", b.head, strconv.Itoa(b.dropped), b.tail)
}

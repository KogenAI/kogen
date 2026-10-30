package verify

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"kogen-loop/sys"
	"kogen/project"
)

// StepTimeout is the bound of every command an approval attempt executes: each step is
// bounded on its own, so a collection of individually timely steps may take longer than this
// overall. The bound is the historical 120 seconds, not a setting.
const StepTimeout = 120 * time.Second

// AttemptStep is one executed step of an approval attempt. Steps that were not reached are
// never recorded as steps: they are only named in NotRun.
type AttemptStep struct {
	Name       string `json:"name"`
	Kind       string `json:"kind"` // git, setup, feasibility, model, acceptance, check
	Command    string `json:"command,omitempty"`
	Status     string `json:"status"` // passed, failed, timed_out
	Exit       *int   `json:"exit,omitempty"`
	TimedOut   bool   `json:"timed_out"`
	StartMS    int64  `json:"start_ms"`
	DurationMS int64  `json:"duration_ms"`
	// Output is the redacted combined stdout and stderr of a step that did not pass, capped
	// like the run log (1 MiB, the middle cut out).
	Output string `json:"output,omitempty"`
}

// Attempt is the account of one approval's readiness check: the steps that actually ran,
// their wall times and statuses, and, when the check is refused, the private local evidence
// kept for inspection. It is diagnostic custody only: it never makes a task ready and is
// never read as readiness evidence.
type Attempt struct {
	// Redactor masks secrets in everything the attempt shows or keeps; nil masks only labeled ones.
	Redactor *Redactor

	root, slug string
	timeout    time.Duration
	started    time.Time
	mu         sync.Mutex
	steps      []*AttemptStep
	plan       []string
	blamed     string
}

// NewAttempt starts the account of one approval of slug in the checkout at root.
func NewAttempt(root, slug string, red *Redactor) *Attempt {
	return &Attempt{Redactor: red, root: root, slug: slug, timeout: StepTimeout, started: time.Now()}
}

type attemptKey struct{}
type stepKey struct{}

type stepLabel struct{ name, kind string }

// Into returns ctx carrying the attempt: commands run under it are bounded and recorded.
func (a *Attempt) Into(ctx context.Context) context.Context {
	return context.WithValue(ctx, attemptKey{}, a)
}

func attemptFrom(ctx context.Context) *Attempt {
	a, _ := ctx.Value(attemptKey{}).(*Attempt)
	return a
}

// withStep names the command run under ctx and the kind of step it is.
func withStep(ctx context.Context, name, kind string) context.Context {
	return context.WithValue(ctx, stepKey{}, stepLabel{name, kind})
}

func stepFrom(ctx context.Context) stepLabel {
	if l, ok := ctx.Value(stepKey{}).(stepLabel); ok {
		return l
	}
	return stepLabel{"command", "check"}
}

// Redact masks secrets in text; a nil Attempt masks only labeled ones.
func (a *Attempt) Redact(text string) string {
	if a == nil {
		return (*Redactor)(nil).Redact(text)
	}
	return a.Redactor.Redact(text)
}

// Plan names the steps the check is about to run, in order, so a refusal can name the ones it
// never reached. A name "model" stands for every model check step.
func (a *Attempt) Plan(names ...string) {
	a.mu.Lock()
	a.plan = append([]string(nil), names...)
	a.mu.Unlock()
}

// blame names the step a refusal is attributed to; a nil Attempt records nothing.
func (a *Attempt) blame(name string) {
	if a == nil {
		return
	}
	a.mu.Lock()
	a.blamed = name
	a.mu.Unlock()
}

func (a *Attempt) add(st *AttemptStep, began time.Time, elapsed time.Duration) {
	st.StartMS = began.Sub(a.started).Milliseconds()
	st.DurationMS = elapsed.Milliseconds()
	a.mu.Lock()
	a.steps = append(a.steps, st)
	a.mu.Unlock()
}

// stepTimeout is the error of a step that exceeded its bound. Refuse turns it into the refusal.
type stepTimeout struct {
	step *AttemptStep
	// unknown: the group's disappearance could not be observed after the stop.
	unknown bool
}

func (e *stepTimeout) Error() string { return "step " + e.step.Name + " timed out" }

// run runs one command as the step named by ctx, bounded by the attempt's step timeout. A
// step that exceeds the bound is stopped with its whole process group and returned as a
// *stepTimeout; interrupts and cancellations are returned unchanged and recorded as nothing.
func (a *Attempt) run(ctx context.Context, s *sys.Session, command, dir string, env map[string]string) (sys.Result, error) {
	label := stepFrom(ctx)
	st := &AttemptStep{Name: label.name, Kind: label.kind, Command: a.Redact(command)}
	began := time.Now()
	res, err := s.Run(command, dir, sys.Options{Env: env, KillGroupOnExit: true, Timeout: a.timeout, Context: ctx})
	elapsed := time.Since(began)
	if errors.Is(err, sys.ErrTimeoutObservation) {
		st.Status, st.TimedOut = "timed_out", true
		a.add(st, began, elapsed)
		return sys.Result{}, &stepTimeout{step: st, unknown: true}
	}
	if err != nil {
		return sys.Result{}, err
	}
	res.Output = a.Redact(res.Output)
	exit := res.Status
	st.Exit = &exit
	switch {
	case res.TimedOut:
		st.Status, st.TimedOut = "timed_out", true
	case res.Status != 0:
		st.Status = "failed"
	default:
		st.Status = "passed"
	}
	if st.Status != "passed" {
		st.Output = Cap(res.Output)
	}
	a.add(st, began, elapsed)
	if res.TimedOut {
		return res, &stepTimeout{step: st}
	}
	return res, nil
}

// Observe runs fn as a step that has no command and no bound, such as a Git phase, recording
// its wall time and whether it failed.
func (a *Attempt) Observe(name, kind string, fn func() error) error {
	if a == nil {
		return fn()
	}
	began := time.Now()
	err := fn()
	a.record(name, kind, began, err)
	return err
}

// record notes a step without a command that ran from began until now and failed when err is not nil.
func (a *Attempt) record(name, kind string, began time.Time, err error) {
	if a == nil {
		return
	}
	st := &AttemptStep{Name: name, Kind: kind, Status: "passed"}
	if err != nil {
		st.Status = "failed"
	}
	a.add(st, began, time.Since(began))
}

func (a *Attempt) executed(name string) bool {
	for _, st := range a.steps {
		if st.Name == name || name == "model" && st.Kind == "model" {
			return true
		}
	}
	return false
}

func fmtSeconds(ms int64) string { return fmt.Sprintf("%.1fs", float64(ms)/1000) }

// attemptRecord is the retained evidence of a refused attempt, `attempt.json` in its own
// private folder under .kogen/local/readiness/attempts. Its kind and outcome tell it apart
// from the version 3 readiness record `<slug>.json`, which it never is.
type attemptRecord struct {
	Version         int            `json:"version"`
	Kind            string         `json:"kind"`
	Outcome         string         `json:"outcome"`
	Slug            string         `json:"slug"`
	StartedAt       string         `json:"started_at"`
	StepTimeoutSecs int            `json:"step_timeout_seconds"`
	ElapsedMS       int64          `json:"elapsed_ms"`
	Steps           []*AttemptStep `json:"steps"`
	NotRun          []string       `json:"not_run"`
	Failure         attemptFailure `json:"failure"`
	Note            string         `json:"note"`
}

type attemptFailure struct {
	Class    string   `json:"class"`
	Reason   string   `json:"reason"`
	Detail   string   `json:"detail"`
	Step     string   `json:"step,omitempty"`
	TimedOut bool     `json:"timed_out"`
	Lines    []string `json:"lines,omitempty"`
}

// ContentionNote is the honest limit of what elapsed time shows.
const ContentionNote = "Elapsed time alone cannot tell host contention from a hang, so Kogen names no cause for the stop."

// attemptsDir holds one private folder per refused attempt.
func attemptsDir(root string) string {
	return filepath.Join(root, ".kogen/local/readiness/attempts")
}

// Refuse turns an error of the readiness check into the refusal of the attempt: the steps
// that ran with their wall times and statuses, the steps never reached, the failing command's
// bounded redacted output and the path of the retained evidence. The evidence is written
// before Refuse returns. Interrupts, cancellations, errors before any step ran and errors that
// are not refusals are returned unchanged.
func (a *Attempt) Refuse(err error) error {
	var timeout *stepTimeout
	var refusal *sys.Error
	var interrupted *sys.Interrupted
	switch {
	case errors.As(err, &interrupted), errors.Is(err, context.Canceled):
		return err
	case errors.As(err, &timeout):
		refusal = sys.Fail("environment", "step_timeout", "", 3)
		st := timeout.step
		if timeout.unknown {
			refusal.Detail = fmt.Sprintf("Approval step %s timed out after %s and was stopped, but its process group could not be observed to end, so the step's result is unknown (the step limit is %ds for each step on its own).", st.Name, fmtSeconds(st.DurationMS), int(a.timeout/time.Second))
		} else {
			refusal.Detail = fmt.Sprintf("Approval step %s timed out after %s and was stopped with its process group (the step limit is %ds for each step on its own).", st.Name, fmtSeconds(st.DurationMS), int(a.timeout/time.Second))
		}
	case errors.As(err, &refusal):
		if len(a.commandSteps()) == 0 && a.blamed == "" {
			return err
		}
		copy := *refusal
		refusal = &copy
		refusal.Lines = append([]string(nil), refusal.Lines...)
	default:
		return err
	}

	a.mu.Lock()
	steps := append([]*AttemptStep(nil), a.steps...)
	blamed := a.blamed
	var notRun []string
	for _, name := range a.plan {
		if !a.executed(name) {
			notRun = append(notRun, name)
		}
	}
	a.mu.Unlock()
	if timeout != nil {
		blamed = timeout.step.Name
	} else if blamed == "" {
		for _, st := range steps {
			if st.Status != "passed" {
				blamed = st.Name
			}
		}
	}

	var failing *AttemptStep
	for _, st := range steps {
		if st.Name == blamed {
			failing = st
		}
	}
	lines := append([]string(nil), refusal.Lines...)
	if timeout != nil {
		lines = append(lines, "Command: "+Cut(failing.Command))
		if out := strings.TrimSpace(failing.Output); out != "" {
			lines = append(lines, "Its output before it was stopped (stdout and stderr, secrets masked):")
			lines = append(lines, strings.Split(Diagnostic(out), "\n")...)
		} else {
			lines = append(lines, "It wrote no output before it was stopped.")
		}
	}
	lines = append(lines, "Steps that ran, with wall time (each step has its own "+fmt.Sprintf("%ds", int(a.timeout/time.Second))+" limit):")
	var total int64
	for _, st := range steps {
		total += st.DurationMS
		lines = append(lines, "  "+stepLine(st))
	}
	lines = append(lines, "Time in these steps: "+fmtSeconds(total))
	if len(notRun) > 0 {
		lines = append(lines, "Not run: "+strings.Join(notRun, ", "))
	}
	if timeout != nil {
		lines = append(lines, ContentionNote)
	}
	for i, l := range lines {
		lines[i] = a.Redact(l)
	}
	refusal.Detail = a.Redact(refusal.Detail)

	path, werr := a.retain(refusal, steps, notRun, blamed, timeout != nil, lines)
	if werr != nil {
		lines = append(lines, "Evidence not retained: "+werr.Error())
	} else {
		lines = append(lines, "Evidence: "+path)
	}
	refusal.Lines = lines
	return refusal
}

func (a *Attempt) commandSteps() []*AttemptStep {
	a.mu.Lock()
	defer a.mu.Unlock()
	var out []*AttemptStep
	for _, st := range a.steps {
		if st.Kind != "git" {
			out = append(out, st)
		}
	}
	return out
}

func stepLine(st *AttemptStep) string {
	switch {
	case st.TimedOut:
		return fmt.Sprintf("%s: timed out after %s and was stopped", st.Name, fmtSeconds(st.DurationMS))
	case st.Exit != nil && st.Status == "failed":
		return fmt.Sprintf("%s: failed with exit %d after %s", st.Name, *st.Exit, fmtSeconds(st.DurationMS))
	}
	return fmt.Sprintf("%s: %s in %s", st.Name, strings.ReplaceAll(st.Status, "_", " "), fmtSeconds(st.DurationMS))
}

// retain writes the attempt's evidence to a new private folder and returns the file's path.
func (a *Attempt) retain(refusal *sys.Error, steps []*AttemptStep, notRun []string, blamed string, timedOut bool, lines []string) (string, error) {
	if notRun == nil {
		notRun = []string{}
	}
	var suffix [4]byte
	if _, err := rand.Read(suffix[:]); err != nil {
		return "", err
	}
	id := a.slug + "-" + a.started.UTC().Format("20060102T150405Z") + "-" + hex.EncodeToString(suffix[:])
	for _, dir := range []string{filepath.Join(a.root, ".kogen"), filepath.Join(a.root, ".kogen/local"), filepath.Join(a.root, ".kogen/local/readiness")} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return "", err
		}
	}
	for _, dir := range []string{attemptsDir(a.root), filepath.Join(attemptsDir(a.root), id)} {
		if err := os.Mkdir(dir, 0o700); err != nil && !errors.Is(err, fs.ErrExist) {
			return "", err
		}
		if err := os.Chmod(dir, 0o700); err != nil {
			return "", err
		}
	}
	rec := attemptRecord{
		Version: 1, Kind: "approval_attempt", Outcome: "refused", Slug: a.slug,
		StartedAt:       a.started.UTC().Format(time.RFC3339),
		StepTimeoutSecs: int(a.timeout / time.Second),
		ElapsedMS:       time.Since(a.started).Milliseconds(),
		Steps:           steps, NotRun: notRun,
		Failure: attemptFailure{Class: refusal.Class, Reason: refusal.Reason, Detail: refusal.Detail, Step: blamed, TimedOut: timedOut, Lines: lines},
		Note:    "Private local diagnostic evidence of a refused approval check; it is not readiness evidence and not approval. " + ContentionNote,
	}
	b, err := project.EncodeJSON(rec)
	if err != nil {
		return "", err
	}
	path := filepath.Join(attemptsDir(a.root), id, "attempt.json")
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return "", err
	}
	_, werr := f.Write(append(b, '\n'))
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	if werr != nil {
		return "", werr
	}
	return path, nil
}

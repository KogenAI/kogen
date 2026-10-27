package verify

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"syscall"
	"time"

	"kogen-loop/sys"
)

// ProbeResult is one probe: the command's exit status, whether the 5-minute limit stopped
// it, its combined output and wall time in seconds (SHP-10). InputChanges names declared
// evidence inputs the command changed in its scratch copy.
type ProbeResult struct {
	Status       int      `json:"status"`
	TimedOut     bool     `json:"timed_out"`
	Output       string   `json:"output"`
	Wall         float64  `json:"wall"`
	InputChanges []string `json:"input_changes,omitempty"`
}

// ProbeTimeout is how long a probe may run (SHP-10).
const ProbeTimeout = 5 * time.Minute

// probeDeadline is the deadline probes run under: ProbeTimeout, except while a test has
// contracted it with ContractProbeDeadline. It is not a user-visible setting.
var probeDeadline = ProbeTimeout

// probeRun runs the probe command; tests replace it with ContractProbeRun.
var probeRun = (*sys.Session).Run

// ContractProbeRun is a test hook: probes run fn instead of the session's Run, until the
// returned function restores the production runner.
func ContractProbeRun(fn func(s *sys.Session, command, dir string, o sys.Options) (sys.Result, error)) (restore func()) {
	prev := probeRun
	probeRun = fn
	return func() { probeRun = prev }
}

// probeObserver, when set by ObserveProbes, hears about every probe that ran.
var probeObserver func(ProbeObservation)

// ProbeObservation is what one probe run did, for the test that contracts the deadline.
type ProbeObservation struct {
	Command  string
	Scratch  string        // the scratch folder the command ran in
	Deadline time.Duration // the deadline the command ran under
	Group    int           // process group of the command, 0 if it did not start
	Result   ProbeResult
}

// ContractProbeDeadline is a test hook: it makes probes run under d instead of ProbeTimeout
// and returns the production deadline in force before, with a function that restores it.
// observe, if not nil, hears about every probe that ran meanwhile.
func ContractProbeDeadline(d time.Duration, observe func(ProbeObservation)) (production time.Duration, restore func()) {
	production, observer := probeDeadline, probeObserver
	probeDeadline, probeObserver = d, observe
	return production, func() { probeDeadline, probeObserver = production, observer }
}

// CopyTree copies the working tree at root into scratch for a probe: every file including
// ignored ones, without `.git` and `.kogen/local`, cloned copy-on-write where the file
// system supports it.
func CopyTree(root, scratch string) error {
	type pair struct{ src, dst string }
	var entries []pair
	top, err := os.ReadDir(root)
	if err != nil {
		return err
	}
	for _, e := range top {
		if e.Name() != ".git" && e.Name() != ".kogen" {
			entries = append(entries, pair{filepath.Join(root, e.Name()), filepath.Join(scratch, e.Name())})
		}
	}
	kogen := filepath.Join(root, ".kogen")
	if st, err := os.Stat(kogen); err == nil && st.IsDir() {
		if err := os.MkdirAll(filepath.Join(scratch, ".kogen"), 0o755); err != nil {
			return err
		}
		sub, err := os.ReadDir(kogen)
		if err != nil {
			return err
		}
		for _, e := range sub {
			if e.Name() != "local" {
				entries = append(entries, pair{filepath.Join(kogen, e.Name()), filepath.Join(scratch, ".kogen", e.Name())})
			}
		}
	}
	flags := []string{"-a", "--reflink=auto"}
	if runtime.GOOS == "darwin" {
		flags = []string{"-cRp"}
	}
	for _, e := range entries {
		if out, err := exec.Command("cp", append(slices.Clone(flags), e.src, e.dst)...).CombinedOutput(); err != nil {
			return fmt.Errorf("copying %s for a probe failed: %s", e.src, out)
		}
	}
	return nil
}

// ProbeFile is a file a probe adds to (or replaces in) its scratch copy before the command
// runs, relative to the copy.
type ProbeFile struct{ Path, Content string }

// Probe is one disposable probe (SHP-10): Command runs in a scratch copy of the working tree
// at Root with Files laid over it, under the 5-minute limit.
type Probe struct {
	Root    string
	Command string
	Files   []ProbeFile
	// Inputs maps repository-relative paths to the lowercase SHA-256 of the bytes the check
	// is bound to; the result's InputChanges names those the command replaced, removed or
	// re-moded in its copy, so final declared evidence cannot qualify other bytes.
	Inputs map[string]string
	Tools  Tools // KOGEN_NODE, KOGEN_QUINT and KOGEN_CUCUMBER for the command, when set
}

// ProbeFileError is the refusal of a probe whose files do not stay in the scratch copy.
type ProbeFileError struct{ Problems []string }

func (e *ProbeFileError) Error() string { return "error: " + strings.Join(e.Problems, "; ") }

// RunProbe runs command in a scratch copy of the working tree at root, deleted afterwards
// (SHP-10). inputs maps repository-relative paths to the lowercase SHA-256 of the bytes the
// check is bound to; the result's InputChanges names those the command replaced, removed or
// re-moded in its copy, so final declared evidence cannot qualify other bytes.
func RunProbe(ctx context.Context, s *sys.Session, root, command string, inputs map[string]string) (ProbeResult, error) {
	return Probe{Root: root, Command: command, Inputs: inputs}.Run(ctx, s)
}

// Run runs the probe. Files that would leave the scratch copy or be written through a
// symlink refuse it with a *ProbeFileError before the command starts.
func (pr Probe) Run(ctx context.Context, s *sys.Session) (ProbeResult, error) {
	scratch := filepath.Join(os.TempDir(), "kogen-probe-"+randomHex(6))
	if err := os.MkdirAll(scratch, 0o755); err != nil {
		return ProbeResult{}, err
	}
	defer os.RemoveAll(scratch)
	if err := CopyTree(pr.Root, scratch); err != nil {
		return ProbeResult{}, err
	}
	var problems []string
	for _, f := range pr.Files {
		problems = append(problems, writeScratch(scratch, f)...)
	}
	if len(problems) > 0 {
		return ProbeResult{}, &ProbeFileError{problems}
	}
	t0 := time.Now()
	before := map[string]inputState{}
	for p := range pr.Inputs {
		before[p] = probeInput(scratch, p)
	}
	if err := ctx.Err(); err != nil {
		if ie := s.Err(); ie != nil {
			return ProbeResult{}, ie
		}
		return ProbeResult{}, err
	}
	deadline, observer := probeDeadline, probeObserver
	var started []int
	if observer != nil {
		started = s.Groups()
	}
	r, err := probeRun(s, pr.Command, scratch, sys.Options{Context: ctx, Timeout: deadline, Env: pr.Tools.env()})
	if errors.Is(err, sys.ErrTimeoutObservation) {
		return ProbeResult{}, fmt.Errorf("probe failed: the timeout observation failed, so the probe's result is unknown: %w", err)
	}
	if err != nil {
		return ProbeResult{}, err
	}
	wall := math.Round(time.Since(t0).Seconds()*10) / 10
	var changes []string
	for p, hash := range pr.Inputs {
		if st := before[p]; !st.ok || st.hash != hash || probeInput(scratch, p) != st {
			changes = append(changes, p)
		}
	}
	slices.Sort(changes)
	result := ProbeResult{Status: r.Status, TimedOut: r.TimedOut, Output: r.Output, Wall: wall, InputChanges: changes}
	if observer != nil {
		group := 0
		for _, g := range s.Groups() {
			if !slices.Contains(started, g) {
				group = g
			}
		}
		observer(ProbeObservation{Command: pr.Command, Scratch: scratch, Deadline: deadline, Group: group, Result: result})
	}
	return result, nil
}

func randomHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// writeScratch lays one file over the scratch copy: no `..` out of it and no copied symlink
// on the way. The returned problems are the reasons it was not written.
func writeScratch(scratch string, f ProbeFile) []string {
	dest := f.Path
	if !filepath.IsAbs(dest) {
		dest = filepath.Join(scratch, dest)
	}
	dest = filepath.Clean(dest)
	rel, ok := strings.CutPrefix(dest, scratch+"/")
	if !ok {
		return []string{f.Path + " is outside the scratch copy"}
	}
	cur := scratch
	for _, part := range strings.Split(rel, "/") {
		cur = filepath.Join(cur, part)
		if st, err := os.Lstat(cur); err == nil && st.Mode()&os.ModeSymlink != 0 {
			return []string{f.Path + " would be written through a symlink"}
		}
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return []string{f.Path + ": " + posix(err)}
	}
	if err := os.WriteFile(dest, []byte(f.Content), 0o666); err != nil {
		return []string{f.Path + ": " + posix(err)}
	}
	return nil
}

// posix names an error as Erlang names its POSIX reason (`eisdir`, `enotdir`, ...).
func posix(err error) string {
	var errno syscall.Errno
	if errors.As(err, &errno) {
		if name, ok := posixNames[errno]; ok {
			return name
		}
	}
	return strings.ToLower(err.Error())
}

var posixNames = map[syscall.Errno]string{
	syscall.ENOENT: "enoent", syscall.EISDIR: "eisdir", syscall.ENOTDIR: "enotdir", syscall.EACCES: "eacces",
	syscall.EEXIST: "eexist", syscall.ENOSPC: "enospc", syscall.EPERM: "eperm", syscall.EROFS: "erofs",
	syscall.ENAMETOOLONG: "enametoolong", syscall.ELOOP: "eloop", syscall.EINVAL: "einval",
}

type inputState struct {
	ok   bool
	exec uint32
	hash string
}

// probeInput is the regular file at path under root, reached without symlinks, as its
// executable bits and hash.
func probeInput(root, path string) inputState {
	cur := root
	for _, part := range strings.Split(path, "/") {
		if part == "" {
			continue
		}
		cur = filepath.Join(cur, part)
		st, err := os.Lstat(cur)
		if err != nil || !(st.Mode().IsRegular() || st.IsDir()) {
			return inputState{}
		}
	}
	st, err := os.Lstat(cur)
	if err != nil || !st.Mode().IsRegular() {
		return inputState{}
	}
	bytes, err := os.ReadFile(cur)
	if err != nil {
		return inputState{}
	}
	sum := sha256.Sum256(bytes)
	return inputState{ok: true, exec: uint32(st.Mode().Perm()) & 0o111, hash: hex.EncodeToString(sum[:])}
}

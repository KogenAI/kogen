package claudecode

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/KogenAI/kogen-loop/sys"
)

// The daily update of Kogen's Claude Code. Kogen keeps running its pinned version until a newer
// one has passed Kogen's own hook self-test (selftest.go); the version it then runs is the
// content of the `active` file in the Claude Code folder. `harness.json` in the same folder
// remembers when the last check ended, how it ended and which versions failed.
const (
	// SourcePinned and SourceUpdated are the values of claude_code_source in a Build's result:
	// the compiled pin, or the version the active file selected.
	SourcePinned  = "pinned"
	SourceUpdated = "updated"

	// ActiveFile holds the active version text; HarnessFile is the check record.
	ActiveFile  = "active"
	HarnessFile = "harness.json"

	// CheckInterval is how old the last check may be before a role start runs the next one.
	CheckInterval = 24 * time.Hour
	// LookupLimit bounds the one request for the latest version.
	LookupLimit = 60 * time.Second
)

var versionRe = regexp.MustCompile(`^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$`)

// parseVersion is the three numbers of a version text; ok is false for any other text.
func parseVersion(v string) (n [3]int, ok bool) {
	if !versionRe.MatchString(v) {
		return n, false
	}
	for i, part := range strings.Split(v, ".") {
		n[i], _ = strconv.Atoi(part)
	}
	return n, true
}

// newer reports whether version a is newer than version b; both must be valid versions.
func newer(a, b string) bool {
	x, okA := parseVersion(a)
	y, okB := parseVersion(b)
	if !okA || !okB {
		return false
	}
	for i := range x {
		if x[i] != y[i] {
			return x[i] > y[i]
		}
	}
	return false
}

// Harness is harness.json: when the last check ended, how it ended, and the failed versions
// with the failing check of each.
type Harness struct {
	CheckedAt  string            `json:"checked_at,omitempty"`
	LastResult string            `json:"last_result,omitempty"`
	Failed     map[string]string `json:"failed,omitempty"`
}

// due reports whether the last check ended more than CheckInterval before now, or never.
func (h Harness) due(now time.Time) bool {
	t, err := time.Parse(time.RFC3339, h.CheckedAt)
	return err != nil || now.Sub(t) > CheckInterval
}

// readHarness is the record; a missing or unreadable file is an empty record.
func readHarness(root string) Harness {
	var h Harness
	b, err := os.ReadFile(filepath.Join(root, HarnessFile))
	if err == nil && json.Unmarshal(b, &h) != nil {
		h = Harness{}
	}
	return h
}

// writeFile replaces path with data by a private temporary file renamed into place.
func writeFile(path string, data []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".write-")
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(f.Name(), path)
	}
	if err != nil {
		os.Remove(f.Name())
	}
	return err
}

func writeHarness(root string, h Harness) error {
	b, err := json.MarshalIndent(h, "", "  ")
	if err != nil {
		return err
	}
	return writeFile(filepath.Join(root, HarnessFile), append(b, '\n'))
}

// readActive is the version text of the active file; "" when it is missing or not a version.
func readActive(root string) string {
	b, err := os.ReadFile(filepath.Join(root, ActiveFile))
	if err != nil {
		return ""
	}
	v := strings.TrimSpace(string(b))
	if _, ok := parseVersion(v); !ok {
		return ""
	}
	return v
}

// selectRuntime is the runtime a role start runs: the active version when it is newer than the
// pin and its folder holds a runtime whose `--version` first field names it, otherwise the pin.
func (a *adapter) selectRuntime(ctx context.Context) runtimeRef {
	pin := pinnedRef(a.opts.Home)
	if a.opts.Home == "" {
		return pin
	}
	v := readActive(Root(a.opts.Home))
	if v == "" || !newer(v, Version) {
		return pin
	}
	rt := refFor(a.opts.Home, v)
	if _, present, err := a.inspectRuntime(rt); err != nil || !present {
		return pin
	}
	if answer, err := a.claudeVersion(ctx, rt); err != nil || !rt.reports(answer) {
		return pin
	}
	return rt
}

// RuntimeUse is what one role start ran.
type RuntimeUse struct {
	Role    string
	Version string // the first field of the runtime's own `--version` answer
	Source  string // SourcePinned or SourceUpdated
	Path    string
}

var (
	usesMu sync.Mutex
	uses   []RuntimeUse
)

// noteStarted remembers the executable a role start runs.
func noteStarted(role, answer string, rt runtimeRef) {
	usesMu.Lock()
	defer usesMu.Unlock()
	uses = append(uses, RuntimeUse{Role: role, Version: FirstField(answer), Source: rt.source(), Path: rt.path})
}

// Uses are the role starts of this process, in order.
func Uses() []RuntimeUse {
	usesMu.Lock()
	defer usesMu.Unlock()
	return append([]RuntimeUse(nil), uses...)
}

// tryLockInstall takes the exclusive install lock when no other Kogen holds it.
func tryLockInstall(path string) (*os.File, bool, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, false, unavailable("cannot open the install lock " + path + ": " + err.Error())
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if err == syscall.EWOULDBLOCK {
			return nil, false, nil
		}
		return nil, false, unavailable("cannot lock " + path + ": " + err.Error())
	}
	return f, true, nil
}

// checkResult is how one check ended.
type checkResult struct {
	// line is the verdict Kogen prints when a candidate passed or failed; empty otherwise.
	line string
	// info is a plain sentence for the update command when there is no verdict.
	info string
	// problem is why the check could not reach a verdict (an unreachable origin, a malformed
	// answer, a timeout, a failed installation); the check changed nothing then.
	problem string
}

// dailyCheck runs the check a role start owes: when the last one ended more than a day ago, or
// never. It never stops a role: every problem is recorded in harness.json and the active
// version stays. Only the caller's own cancellation ends it with an error.
func (a *adapter) dailyCheck(ctx context.Context) error {
	root := Root(a.opts.Home)
	if !readHarness(root).due(time.Now()) {
		return nil
	}
	res, err := a.check(ctx, false)
	if err != nil {
		return err
	}
	if res.line != "" {
		fmt.Fprintln(a.stderr(), res.line)
	}
	return nil
}

// check runs one check under the install lock. Without force it first looks again at the
// record, which another Kogen may just have refreshed, and gives up on a lock that is held.
func (a *adapter) check(ctx context.Context, force bool) (checkResult, error) {
	root := Root(a.opts.Home)
	lockPath := filepath.Join(root, "install.lock")
	var lock *os.File
	if force {
		var err error
		if lock, err = lockInstall(ctx, lockPath, a.stderr()); err != nil {
			return checkResult{}, err
		}
	} else {
		var got bool
		var err error
		if lock, got, err = tryLockInstall(lockPath); err != nil || !got {
			return checkResult{}, nil
		}
	}
	defer lock.Close()
	h := readHarness(root)
	if !force && !h.due(time.Now()) {
		return checkResult{}, nil
	}
	res := a.checkLocked(ctx, &h)
	if ctx.Err() != nil {
		return checkResult{}, classify(ctx)
	}
	h.CheckedAt = time.Now().UTC().Format(time.RFC3339)
	// The active file always names the version role starts run: the first check that ends
	// without one writes the version it found running.
	if readActive(root) == "" {
		_ = writeFile(filepath.Join(root, ActiveFile), []byte(a.selectRuntime(ctx).version+"\n"))
	}
	// A record that cannot be written only makes the next role start check again.
	_ = writeHarness(root, h)
	return res, nil
}

// checkLocked is the check itself: one lookup, and for a newer version that did not fail
// before, its installation and self-test. It records how it ended in h.
func (a *adapter) checkLocked(ctx context.Context, h *Harness) checkResult {
	root := Root(a.opts.Home)
	current := a.selectRuntime(ctx).version
	problem := func(text string) checkResult {
		h.LastResult = text
		return checkResult{problem: text}
	}
	latest, why := a.lookupLatest(ctx)
	if why != "" {
		return problem(why)
	}
	switch {
	case !newer(latest, current):
		h.LastResult = "unchanged: latest " + latest + " is not newer than " + current
		return checkResult{info: "kogen: Claude Code " + current + " is current (latest is " + latest + ")"}
	case h.Failed[latest] != "":
		h.LastResult = "unchanged: " + latest + " failed Kogen's hook self-test (" + h.Failed[latest] + ")"
		return checkResult{info: "kogen: Claude Code " + latest + " failed Kogen's hook self-test earlier (" + h.Failed[latest] + "); staying on " + current}
	}
	candidate := refFor(a.opts.Home, latest)
	// A folder of this version that is not active is what an interrupted check left.
	if err := os.RemoveAll(candidate.dir); err != nil {
		return problem("install failed: cannot remove " + candidate.dir + ": " + cause(err))
	}
	if err := a.installLocked(ctx, latest, true); err != nil {
		return problem("install failed: " + detail(err))
	}
	failing, err := a.selfTest(ctx, candidate)
	if err != nil {
		os.RemoveAll(candidate.dir)
		return problem("self-test could not run: " + detail(err))
	}
	if failing != "" {
		if err := os.RemoveAll(candidate.dir); err != nil {
			return problem("install failed: cannot remove " + candidate.dir + ": " + cause(err))
		}
		if h.Failed == nil {
			h.Failed = map[string]string{}
		}
		h.Failed[latest] = failing
		h.LastResult = "failed: " + latest + " (" + failing + ")"
		return checkResult{line: "kogen: Claude Code " + latest + " failed Kogen's hook self-test (" + failing + "); staying on " + current}
	}
	if err := writeFile(filepath.Join(root, ActiveFile), []byte(latest+"\n")); err != nil {
		os.RemoveAll(candidate.dir)
		return problem("install failed: cannot write the active file: " + cause(err))
	}
	h.LastResult = "updated: " + latest + " passed Kogen's hook self-test"
	return checkResult{line: "kogen: Claude Code " + latest + " passed Kogen's hook self-test; now active (was " + current + ")"}
}

// detail is the text of an error without its class.
func detail(err error) string {
	if se, ok := sys.AsError(err); ok {
		return se.Detail
	}
	return err.Error()
}

// lookupLatest is the one GET of `latest`, which answers a version text. why is empty on
// success and otherwise the record of the problem: `unreachable: ...` for an origin that does
// not answer, `malformed answer: ...` and `timeout: ...`.
func (a *adapter) lookupLatest(ctx context.Context) (version, why string) {
	origin, seam, err := seamOrigin()
	if err != nil {
		return "", "unreachable: " + detail(err)
	}
	base := downloadBase
	if seam {
		base = origin
	}
	source := base + "/latest"
	lookup, cancel := context.WithTimeout(ctx, LookupLimit)
	defer cancel()
	timedOut := func() string {
		return "timeout: no answer from " + source + " within " + strconv.Itoa(int(LookupLimit/time.Second)) + " seconds"
	}
	req, err := http.NewRequestWithContext(lookup, http.MethodGet, source, nil)
	if err != nil {
		return "", "unreachable: " + err.Error()
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		if ctx.Err() == nil && errors.Is(lookup.Err(), context.DeadlineExceeded) {
			return "", timedOut()
		}
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return "", "unreachable: " + source + ": " + err.Error()
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", "unreachable: " + source + ": HTTP " + resp.Status
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 257))
	if err != nil {
		if ctx.Err() == nil && errors.Is(lookup.Err(), context.DeadlineExceeded) {
			return "", timedOut()
		}
		return "", "unreachable: " + source + ": " + err.Error()
	}
	answer := strings.TrimSpace(string(body))
	if _, ok := parseVersion(answer); !ok {
		if len(answer) > 40 {
			answer = answer[:40] + "..."
		}
		return "", "malformed answer: " + source + " did not answer a version like 2.1.319: " + strconv.Quote(answer)
	}
	return answer, ""
}

// Update runs one check at once, whatever the age of the last one (`kogen provider update
// claude-code`), and writes its outcome to out. An error means the check could not reach a
// verdict: the reason is recorded in harness.json and the active version is unchanged.
func Update(ctx context.Context, opts Options, out io.Writer) error {
	a := New(opts).(*adapter)
	if _, ok := pinFor(a.goos, a.goarch); !ok {
		return unavailable(UnsupportedMessage(a.goos, a.goarch))
	}
	if err := a.ensureDirs(); err != nil {
		return err
	}
	res, err := a.check(ctx, true)
	if err != nil {
		return err
	}
	switch {
	case res.problem != "":
		return sys.Fail("environment", "claude_code_update_unfinished", "the Claude Code update check did not finish: "+res.problem+"; the active version is unchanged", 3)
	case res.line != "":
		fmt.Fprintln(out, res.line)
	default:
		fmt.Fprintln(out, res.info)
	}
	return nil
}

// Active is the version a role start would run now and where its executable is: the active
// version when it is newer than the pin and its folder holds an executable, otherwise the pin.
// It runs nothing; a role start still checks the runtime's own `--version`.
func Active(home string) (version, path string) {
	if v := readActive(Root(home)); v != "" && newer(v, Version) {
		rt := refFor(home, v)
		if info, err := os.Stat(rt.path); err == nil && info.Mode().IsRegular() {
			return rt.version, rt.path
		}
	}
	rt := pinnedRef(home)
	return rt.version, rt.path
}

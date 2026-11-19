package claudecode

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/KogenAI/kogen-executor/executor"
	"github.com/KogenAI/kogen-loop/sys"
)

// Version is the Claude Code version Kogen's binary pins: the one it installs itself and runs
// unless a newer version has passed Kogen's own hook self-test and is recorded in the `active`
// file (update.go).
const Version = "2.1.318"

// SeamEnv is the test-only download origin (http://127.0.0.1:<port> or http://localhost:<port>).
const SeamEnv = "KOGEN_CLAUDE_CODE_URL"

const downloadIdleTimeout = 30 * time.Second

// downloadHeaderTimeout bounds the wait for a response's complete headers; the idle bound
// takes over once they have arrived.
const downloadHeaderTimeout = 30 * time.Second
const downloadAttempts = 3
const downloadRetryDelay = 100 * time.Millisecond

func (a *adapter) setDownloadRetryDelayForTest(d time.Duration) { a.downloadRetryDelay = d }

func (a *adapter) setDownloadIdleTimeoutForTest(d time.Duration) { a.downloadIdle = d }

func (a *adapter) setDownloadHeaderTimeoutForTest(d time.Duration) { a.downloadHeader = d }

func (a *adapter) setSyncForTest(sync func(*os.File) error) { a.sync = sync }

// syncFile flushes f to stable storage.
func (a *adapter) syncFile(f *os.File) error {
	if a.sync != nil {
		return a.sync(f)
	}
	return f.Sync()
}

// cause is the system's wording of a failed file operation.
func cause(err error) string {
	var pe *os.PathError
	if errors.As(err, &pe) {
		return pe.Err.Error()
	}
	return err.Error()
}

// localWriteFailure is the refusal of a failed create, write or close of the partial file.
func localWriteFailure(action, file string, err error) error {
	return unavailable("local write failure: cannot " + action + " " + file + ": " + cause(err) + "; nothing was installed")
}

// flushFile opens path and flushes it to stable storage, then closes it.
func (a *adapter) flushFile(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	err = a.syncFile(f)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// doBounded sends req, whose context is cancelled by cancel, and gives up with
// "the server did not answer" when the complete response headers do not arrive within the
// header bound. A cancellation from the caller's ctx is never reported as that failure.
func (a *adapter) doBounded(ctx context.Context, cancel context.CancelFunc, req *http.Request) (*http.Response, error) {
	bound := a.downloadHeader
	if bound == 0 {
		bound = downloadHeaderTimeout
	}
	timer := time.AfterFunc(bound, cancel)
	resp, err := http.DefaultClient.Do(req)
	// A timer that already fired has cancelled, or is about to cancel, the request.
	if !timer.Stop() && ctx.Err() == nil {
		if resp != nil {
			resp.Body.Close()
		}
		return nil, errNoAnswer
	}
	return resp, err
}

var errNoAnswer = errors.New("the server did not answer")

// cancelBody releases the request's context when its body is closed.
type cancelBody struct {
	io.ReadCloser
	cancel context.CancelFunc
}

func (b cancelBody) Close() error {
	err := b.ReadCloser.Close()
	b.cancel()
	return err
}

const downloadBase = "https://downloads.claude.ai/claude-code-releases"

// pin is what Anthropic's native-installer manifest of Version lists for one platform.
type pin struct {
	platform string
	sha256   string
	size     int64
}

// pinFor is the pin of a GOOS/GOARCH; ok is false for an unsupported platform.
func pinFor(goos, goarch string) (pin, bool) {
	switch goos + "/" + goarch {
	case "darwin/arm64":
		return pin{"darwin-arm64", "677a2ea7bf576cedd20e191d973914ed8a41796f53a63b1923381ddc4d5b5e7d", 319598464}, true
	case "linux/amd64":
		return pin{"linux-x64", "708c77b204db30086ff6f1ed34577bda03e1be74ced80557cbf7b54249ebf0bd", 337814032}, true
	}
	return pin{}, false
}

// Supported is the pin of this machine's platform; ok is false when Kogen's runtime does not
// support it.
func Supported() (platform string, ok bool) {
	p, ok := pinFor(runtime.GOOS, runtime.GOARCH)
	return p.platform, ok
}

// RuntimeSize is the pinned executable size of this machine's platform; ok is false when the
// platform is unsupported.
func RuntimeSize() (size int64, ok bool) {
	p, ok := pinFor(runtime.GOOS, runtime.GOARCH)
	return p.size, ok
}

// UnsupportedMessage is the refusal on any other platform.
func UnsupportedMessage(goos, goarch string) string {
	return "Kogen's Claude Code runtime supports macOS on Apple Silicon and Linux x86-64 only, not " + goos + "/" + goarch
}

// Root is <home>/.kogen/claude-code, the folder Kogen owns for its Claude Code.
func Root(home string) string { return filepath.Join(home, ".kogen", "claude-code") }

// RuntimeDir is the folder of the pinned version.
func RuntimeDir(home string) string { return filepath.Join(Root(home), Version) }

// RuntimePath is the one executable Kogen runs.
func RuntimePath(home string) string { return filepath.Join(RuntimeDir(home), "claude") }

// ConfigDir is Kogen's own Claude Code configuration directory.
func ConfigDir(home string) string { return filepath.Join(Root(home), "config") }

// Pinned reports whether the answer of `claude --version` has the pinned version as its first
// whitespace-separated field.
func Pinned(answer string) bool { return FirstField(answer) == Version }

// FirstField is the first whitespace-separated field of the answer of `claude --version`: the
// version.
func FirstField(answer string) string {
	f := strings.Fields(answer)
	if len(f) == 0 {
		return ""
	}
	return f[0]
}

// NotPinnedMessage says that the runtime at path reports another version than want, which is
// the pinned one unless the runtime came from the active file.
func NotPinnedMessage(path, answer, want string) string {
	if want == Version {
		return "Kogen's Claude Code at " + path + " reports " + answer + ", not the pinned " + Version
	}
	return "Kogen's Claude Code at " + path + " reports " + answer + ", not the active " + want
}

// runtimeRef names one installed runtime: the pinned one or the one the active file selects.
type runtimeRef struct {
	version, dir, path string
}

func refFor(home, version string) runtimeRef {
	dir := filepath.Join(Root(home), version)
	return runtimeRef{version: version, dir: dir, path: filepath.Join(dir, "claude")}
}

func pinnedRef(home string) runtimeRef { return refFor(home, Version) }

func (r runtimeRef) pinned() bool { return r.version == Version }

// source is how the receipt names where the runtime came from.
func (r runtimeRef) source() string {
	if r.pinned() {
		return SourcePinned
	}
	return SourceUpdated
}

// reports reports whether the answer of `claude --version` names this runtime's version.
func (r runtimeRef) reports(answer string) bool { return FirstField(answer) == r.version }

func unavailable(msg string) error { return executor.Fail(executor.ReasonUnavailable, msg) }

var seamRe = regexp.MustCompile(`^http://(127\.0\.0\.1|localhost):[0-9]+$`)
var checksumRe = regexp.MustCompile(`^[0-9a-f]{64}$`)

// seamOrigin is the test download origin; ok is false when none is set.
func seamOrigin() (origin string, set bool, err error) {
	v, set := os.LookupEnv(SeamEnv)
	if !set {
		return "", false, nil
	}
	if !seamRe.MatchString(v) {
		return "", true, unavailable(SeamEnv + " must be http://127.0.0.1:<port> or http://localhost:<port>")
	}
	return v, true, nil
}

// ownerModeProblem names what is wrong with a path owned by owner with the given mode, or ""
// when only uid owns it and nobody else can write it.
func ownerModeProblem(uid, owner uint32, mode os.FileMode) string {
	switch {
	case owner != uid:
		return "owned by another user"
	case mode.Perm()&0o020 != 0:
		return "writable by group"
	case mode.Perm()&0o002 != 0:
		return "writable by others"
	}
	return ""
}

// ownershipProblem is ownerModeProblem of an existing path, with links followed.
func ownershipProblem(path string, info os.FileInfo) (string, error) {
	if info == nil {
		var err error
		if info, err = os.Stat(path); err != nil {
			return "", err
		}
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return "", errors.New("the owner is not readable")
	}
	return ownerModeProblem(uint32(os.Geteuid()), st.Uid, info.Mode()), nil
}

// inspectRuntime, the resolved file's info when present, distinguishes an absent entry from one that requires user intervention. A
// present runtime is the one definition shared by install and use: a regular, executable,
// non-empty file of the pinned size (unless the test origin is set), owned by the current user
// with its version folder and the managed root, none of them writable by group or others.
func (a *adapter) inspectRuntime(rt runtimeRef) (os.FileInfo, bool, error) {
	home := a.opts.Home
	p := rt.path
	dir := rt.dir
	remedy := "; remove " + dir + " and run again"
	info, err := os.Lstat(p)
	if errors.Is(err, os.ErrNotExist) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, unavailable("cannot inspect " + p + ": " + err.Error())
	}
	if info.Mode()&os.ModeSymlink != 0 {
		info, err = os.Stat(p)
		if errors.Is(err, os.ErrNotExist) {
			return nil, false, unavailable("Kogen's Claude Code at " + p + " is a dangling symlink" + remedy)
		}
		if err != nil {
			return nil, false, unavailable("cannot inspect " + p + ": " + err.Error())
		}
	}
	kind := ""
	switch {
	case info.IsDir():
		kind = "a directory"
	case !info.Mode().IsRegular():
		kind = "not a regular file"
	case info.Size() == 0:
		kind = "empty"
	case info.Mode().Perm()&0o111 == 0:
		kind = "not executable"
	}
	if kind != "" {
		return nil, false, unavailable("Kogen's Claude Code at " + p + " is " + kind + remedy)
	}
	if _, seam := os.LookupEnv(SeamEnv); !seam && rt.pinned() {
		if want, ok := pinFor(a.goos, a.goarch); ok && info.Size() != want.size {
			return nil, false, unavailable(fmt.Sprintf("Kogen's Claude Code at %s is %d bytes, expected %d%s", p, info.Size(), want.size, remedy))
		}
	}
	for _, c := range []struct {
		what, path string
		info       os.FileInfo
	}{
		{"Kogen's Claude Code at " + p, p, info},
		{"Kogen's Claude Code folder " + dir, dir, nil},
		{"Kogen's Claude Code root " + Root(home), Root(home), nil},
	} {
		problem, err := ownershipProblem(c.path, c.info)
		if err != nil {
			return nil, false, unavailable("cannot inspect " + c.path + ": " + err.Error())
		}
		if problem != "" {
			return nil, false, unavailable(c.what + " is " + problem + remedy)
		}
	}
	return info, true, nil
}

// ensureDirs makes Kogen's Claude Code root and configuration directory exist, private.
func (a *adapter) ensureDirs() error {
	if a.opts.Home == "" {
		return unavailable("cannot locate your home directory for Kogen's Claude Code runtime")
	}
	root := Root(a.opts.Home)
	for _, dir := range []string{root, ConfigDir(a.opts.Home)} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return unavailable("cannot create " + dir + ": " + err.Error())
		}
		if dir != root {
			info, err := os.Lstat(dir)
			if err != nil {
				return unavailable("cannot secure " + dir + ": " + err.Error())
			}
			if info.Mode()&os.ModeSymlink != 0 {
				continue
			}
		}
		if err := os.Chmod(dir, 0o700); err != nil {
			return unavailable("cannot secure " + dir + ": " + err.Error())
		}
	}
	return nil
}

// ensureRuntime makes the pinned runtime and Kogen's configuration directory exist before the
// first child of a role start, installing the runtime when it is not there.
func (a *adapter) ensureRuntime(ctx context.Context) error {
	if _, ok := pinFor(a.goos, a.goarch); !ok {
		return unavailable(UnsupportedMessage(a.goos, a.goarch))
	}
	if a.opts.Home == "" {
		return unavailable("cannot locate your home directory for Kogen's Claude Code runtime")
	}
	if err := a.ensureDirs(); err != nil {
		return err
	}
	if _, present, err := a.inspectRuntime(pinnedRef(a.opts.Home)); err != nil || present {
		return err
	}
	return a.install(ctx)
}

// prepareRuntime is what a role start does before its first child: the daily update check (it
// never stops the role), the choice between the active runtime and the pin, and the pin's
// installation when the pin is the choice.
func (a *adapter) prepareRuntime(ctx context.Context) (runtimeRef, error) {
	if _, ok := pinFor(a.goos, a.goarch); !ok {
		return runtimeRef{}, unavailable(UnsupportedMessage(a.goos, a.goarch))
	}
	if err := a.ensureDirs(); err != nil {
		return runtimeRef{}, err
	}
	if !a.opts.NoUpdate {
		if err := a.dailyCheck(ctx); err != nil {
			return runtimeRef{}, err
		}
	}
	rt := a.selectRuntime(ctx)
	if rt.pinned() {
		if err := a.ensureRuntime(ctx); err != nil {
			return runtimeRef{}, err
		}
	}
	return rt, nil
}

// install downloads, verifies and installs the pinned runtime under the install lock.
func (a *adapter) install(ctx context.Context) error {
	lock, err := lockInstall(ctx, filepath.Join(Root(a.opts.Home), "install.lock"), a.stderr())
	if err != nil {
		return err
	}
	defer lock.Close()
	return a.installLocked(ctx, Version, false)
}

// installLocked downloads, verifies and installs one version into its own folder; the caller
// holds the install lock. The pinned version is checked against the size and SHA-256 Kogen pins
// (against the test origin's manifest when it is set); any other version, a candidate of the
// daily update, is checked against the size and SHA-256 of its manifest on the origin.
func (a *adapter) installLocked(ctx context.Context, version string, candidate bool) error {
	want, _ := pinFor(a.goos, a.goarch)
	origin, seam, err := seamOrigin()
	if err != nil {
		return err
	}
	base := downloadBase
	if seam {
		base = origin
	}
	root := Root(a.opts.Home)
	rt := refFor(a.opts.Home, version)
	// Leftovers of interrupted installations; no other installation runs while the lock is held.
	leftovers, _ := filepath.Glob(filepath.Join(root, ".partial-*"))
	for _, p := range leftovers {
		if err := os.RemoveAll(p); err != nil {
			return unavailable("cannot remove the unfinished installation " + p + ": " + err.Error())
		}
	}
	if !candidate {
		if _, present, err := a.inspectRuntime(rt); err != nil || present {
			return err
		}
	}
	partial, err := os.MkdirTemp(root, ".partial-")
	if err != nil {
		return unavailable("cannot create an installation directory in " + root + ": " + err.Error())
	}
	installed := false
	defer func() {
		if !installed {
			os.RemoveAll(partial)
		}
	}()
	fmt.Fprintf(a.stderr(), "kogen: installing Claude Code %s into %s\n", version, rt.dir)

	if seam || candidate {
		manifestURL := base + "/" + version + "/manifest.json"
		checksum, size, err := a.fetchManifest(ctx, version, manifestURL, want.platform)
		if err != nil {
			return err
		}
		want.sha256, want.size = checksum, size
	}
	source := base + "/" + version + "/" + want.platform + "/claude"
	file := filepath.Join(partial, "claude")
	var digest string
	for attempt := 1; attempt <= downloadAttempts; attempt++ {
		var retry bool
		digest, retry, err = a.downloadBinary(ctx, version, source, file, want)
		if ctx.Err() != nil {
			return classify(ctx)
		}
		if err == nil {
			break
		}
		if !retry {
			return err
		}
		if attempt == downloadAttempts {
			return unavailable(fmt.Sprintf("%s; %d attempts", err.(*sys.Error).Detail, downloadAttempts))
		}
		fmt.Fprintf(a.stderr(), "kogen: download attempt %d failed: %s; retry after pause\n", attempt, err)
		delay := a.downloadRetryDelay
		if delay == 0 {
			delay = downloadRetryDelay
		}
		timer := time.NewTimer(time.Duration(attempt) * delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return classify(ctx)
		case <-timer.C:
		}
	}
	if err := os.Chmod(file, 0o755); err != nil {
		return unavailable("cannot make " + file + " executable: " + err.Error())
	}
	reported, err := a.run(ctx, file, nil, "", "--version")
	if ctx.Err() != nil {
		return classify(ctx)
	}
	if err != nil {
		return unavailable("the downloaded Claude Code does not run: " + err.Error() + "; nothing was installed")
	}
	if answer := strings.TrimSpace(string(reported)); !rt.reports(answer) {
		return unavailable("the downloaded Claude Code reports " + answer + ", not " + version + "; nothing was installed")
	}
	dir := rt.dir
	// An empty version directory (no executable in it) is no installation; Rename replaces it.
	if err := os.Rename(partial, dir); err != nil {
		return unavailable("cannot install Claude Code " + version + " into " + dir + ": " + err.Error() + "; remove " + dir + " and run again")
	}
	installed = true
	if err := a.flushFile(root); err != nil {
		detail := "cannot flush " + root + " to disk: " + cause(err)
		if rerr := os.RemoveAll(dir); rerr != nil {
			return unavailable(detail + ": " + cause(rerr) + "; remove " + dir + " and run again")
		}
		return unavailable(detail + "; nothing was installed")
	}
	fmt.Fprintf(a.stderr(), "kogen: installed Claude Code %s (sha256 %s)\n", version, digest)
	return nil
}

// downloadBinary performs one clean attempt. Only transport failures and transient
// HTTP responses are retryable; local writes and completed pin mismatches are not.
func (a *adapter) downloadBinary(ctx context.Context, version, source, file string, want pin) (string, bool, error) {
	fail := func(detail string) error {
		return unavailable("cannot download Claude Code " + version + " from " + source + ": " + detail)
	}
	downloadCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	req, err := http.NewRequestWithContext(downloadCtx, http.MethodGet, source, nil)
	if err != nil {
		return "", false, fail(err.Error())
	}
	resp, err := a.doBounded(ctx, cancel, req)
	if err != nil {
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return "", true, fail(err.Error())
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", resp.StatusCode == 429 || resp.StatusCode >= 500 && resp.StatusCode <= 599, fail("HTTP " + resp.Status)
	}
	if resp.ContentLength >= 0 && resp.ContentLength != want.size {
		return "", false, fail(fmt.Sprintf("the response announces %d bytes, expected %d; nothing was installed", resp.ContentLength, want.size))
	}
	out, err := os.OpenFile(file, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o700)
	if err != nil {
		return "", false, localWriteFailure("create", file, err)
	}
	idle := a.downloadIdle
	if idle == 0 {
		idle = downloadIdleTimeout
	}
	reader := newIdleReader(resp.Body, idle, cancel)
	hash := sha256.New()
	writer := &downloadWriter{w: io.MultiWriter(out, hash)}
	n, copyErr := io.Copy(writer, io.LimitReader(reader, want.size+1))
	stalled := reader.stop()
	closeErr := out.Close()
	if ctx.Err() != nil {
		return "", false, classify(ctx)
	}
	if stalled && (copyErr != nil || n < want.size) {
		return "", false, fail("connection stalled")
	}
	if writer.err != nil {
		return "", false, localWriteFailure("write", file, writer.err)
	}
	if closeErr != nil {
		return "", false, localWriteFailure("close", file, closeErr)
	}
	if copyErr != nil {
		return "", true, fail(copyErr.Error())
	}
	digest := hex.EncodeToString(hash.Sum(nil))
	if n < want.size {
		return "", false, unavailable(fmt.Sprintf("the downloaded Claude Code %s is shorter than its pinned size: received %d bytes, expected %d; nothing was installed", version, n, want.size))
	}
	if n > want.size {
		return "", false, unavailable(fmt.Sprintf("the downloaded Claude Code %s is longer than its pinned size: received %d bytes, expected %d; nothing was installed", version, n, want.size))
	}
	if digest != want.sha256 {
		return "", false, unavailable("the downloaded Claude Code " + version + " does not match its pinned SHA-256; nothing was installed")
	}
	if err := a.flushFile(file); err != nil {
		return "", false, unavailable("cannot flush " + file + " to disk: " + cause(err) + "; nothing was installed")
	}
	return digest, false, nil
}

type downloadWriter struct {
	w   io.Writer
	err error
}

func (w *downloadWriter) Write(p []byte) (int, error) {
	n, err := w.w.Write(p)
	w.err = err
	return n, err
}

// idleReader cancels the request when no body bytes arrive for an idle interval.
type idleReader struct {
	io.Reader
	mu               sync.Mutex
	timer            *time.Timer
	last             time.Time
	interval         time.Duration
	cancel           context.CancelFunc
	stopped, stalled bool
}

func newIdleReader(r io.Reader, interval time.Duration, cancel context.CancelFunc) *idleReader {
	b := &idleReader{Reader: r, interval: interval, cancel: cancel, last: time.Now()}
	b.timer = time.AfterFunc(interval, b.expire)
	return b
}
func (b *idleReader) expire() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.stopped {
		return
	}
	if remaining := b.interval - time.Since(b.last); remaining > 0 {
		b.timer.Reset(remaining)
		return
	}
	b.stalled = true
	b.cancel()
}
func (b *idleReader) Read(p []byte) (int, error) {
	n, err := b.Reader.Read(p)
	if n > 0 {
		b.mu.Lock()
		if !b.stalled && !b.stopped {
			b.last = time.Now()
			b.timer.Reset(b.interval)
		}
		b.mu.Unlock()
	}
	return n, err
}
func (b *idleReader) stop() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.stopped = true
	b.timer.Stop()
	return b.stalled
}

// get is one HTTP GET whose response headers are bounded; anything but 200 is a refusal.
// Closing the returned body releases the request.
func (a *adapter) get(ctx context.Context, version, source string) (*http.Response, error) {
	fail := func(detail string) error {
		return unavailable("cannot download Claude Code " + version + " from " + source + ": " + detail)
	}
	reqCtx, cancel := context.WithCancel(ctx)
	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, source, nil)
	if err != nil {
		cancel()
		return nil, fail(err.Error())
	}
	resp, err := a.doBounded(ctx, cancel, req)
	if err != nil {
		cancel()
		if ctx.Err() != nil {
			return nil, classify(ctx)
		}
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return nil, fail(err.Error())
	}
	resp.Body = cancelBody{resp.Body, cancel}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		return nil, fail("HTTP " + resp.Status)
	}
	return resp, nil
}

// fetchManifest reads the official manifest shape from the test seam.
func (a *adapter) fetchManifest(ctx context.Context, version, source, platform string) (checksum string, size int64, err error) {
	resp, err := a.get(ctx, version, source)
	if err != nil {
		return "", 0, err
	}
	defer resp.Body.Close()
	var m struct {
		Platforms map[string]struct {
			Checksum string `json:"checksum"`
			Size     int64  `json:"size"`
		} `json:"platforms"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&m); err != nil {
		if ctx.Err() != nil {
			return "", 0, classify(ctx)
		}
		return "", 0, unavailable("cannot download Claude Code " + version + " from " + source + ": " + err.Error())
	}
	p := m.Platforms[platform]
	if !checksumRe.MatchString(p.Checksum) || p.Size <= 0 {
		return "", 0, unavailable("cannot download Claude Code " + version + " from " + source + ": no checksum and size for " + platform)
	}
	return p.Checksum, p.Size, nil
}

// lockInstall takes the exclusive lock on path, waiting for another Kogen's installation.
func lockInstall(ctx context.Context, path string, stderr io.Writer) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, unavailable("cannot open the install lock " + path + ": " + err.Error())
	}
	noticed := false
	for {
		err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return f, nil
		}
		if err != syscall.EWOULDBLOCK && err != syscall.EINTR {
			f.Close()
			return nil, unavailable("cannot lock " + path + ": " + err.Error())
		}
		if err == syscall.EWOULDBLOCK && !noticed {
			fmt.Fprint(stderr, "kogen: another Claude Code installation is in progress; waiting\n")
			noticed = true
		}
		select {
		case <-ctx.Done():
			f.Close()
			return nil, classify(ctx)
		case <-time.After(50 * time.Millisecond):
		}
	}
}

func (a *adapter) stderr() io.Writer {
	if a.opts.Stderr != nil {
		return a.opts.Stderr
	}
	return os.Stderr
}

// Probe runs a no-model-call subcommand (--version, auth status --json) of the managed runtime
// with the child environment, installing nothing.
func Probe(ctx context.Context, home string, args ...string) ([]byte, error) {
	a := New(Options{Home: home}).(*adapter)
	bin, err := a.binary(a.selectRuntime(ctx))
	if err != nil {
		return nil, err
	}
	return a.run(ctx, bin, nil, a.opts.Token, args...)
}

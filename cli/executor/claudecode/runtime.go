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
	"syscall"
	"time"

	"kogen/executor"
)

// Version is the one Claude Code version Kogen runs. Kogen's binary carries it as the only
// version source: a newer Kogen release pins a newly tested version, nothing selects another.
const Version = "2.1.312"

// SeamEnv is the test-only download origin (http://127.0.0.1:<port> or http://localhost:<port>).
const SeamEnv = "KOGEN_CLAUDE_CODE_URL"

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
		return pin{"darwin-arm64", "6b5ec691195e551b02c41df9f7d723f4ea61eaa03c2df90acefe3736f1aeb620", 275988512}, true
	case "linux/amd64":
		return pin{"linux-x64", "4f4178ce41d83e23341ebfbaecdbcf8ea6bf7baea0690025abe49eeec3a5d01d", 293592432}, true
	}
	return pin{}, false
}

// Supported is the pin of this machine's platform; ok is false when Kogen's runtime does not
// support it.
func Supported() (platform string, ok bool) {
	p, ok := pinFor(runtime.GOOS, runtime.GOARCH)
	return p.platform, ok
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
func Pinned(answer string) bool {
	f := strings.Fields(answer)
	return len(f) > 0 && f[0] == Version
}

// NotPinnedMessage says that the runtime at path reports another version.
func NotPinnedMessage(path, answer string) string {
	return "Kogen's Claude Code at " + path + " reports " + answer + ", not the pinned " + Version
}

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

// ensureRuntime makes the pinned runtime and Kogen's configuration directory exist before the
// first child of a role start, installing the runtime when it is not there.
func (a *adapter) ensureRuntime(ctx context.Context) error {
	if _, ok := pinFor(a.goos, a.goarch); !ok {
		return unavailable(UnsupportedMessage(a.goos, a.goarch))
	}
	if a.opts.Home == "" {
		return unavailable("cannot locate your home directory for Kogen's Claude Code runtime")
	}
	root := Root(a.opts.Home)
	for _, dir := range []string{root, ConfigDir(a.opts.Home)} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return unavailable("cannot create " + dir + ": " + err.Error())
		}
		if err := os.Chmod(dir, 0o700); err != nil {
			return unavailable("cannot secure " + dir + ": " + err.Error())
		}
	}
	if _, err := os.Lstat(RuntimePath(a.opts.Home)); err == nil {
		return nil
	}
	return a.install(ctx)
}

// install downloads, verifies and installs the pinned runtime under the install lock.
func (a *adapter) install(ctx context.Context) error {
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
	lock, err := lockInstall(ctx, filepath.Join(root, "install.lock"))
	if err != nil {
		return err
	}
	defer lock.Close()
	// Leftovers of interrupted installations; no other installation runs while the lock is held.
	leftovers, _ := filepath.Glob(filepath.Join(root, ".partial-*"))
	for _, p := range leftovers {
		if err := os.RemoveAll(p); err != nil {
			return unavailable("cannot remove the unfinished installation " + p + ": " + err.Error())
		}
	}
	if _, err := os.Lstat(RuntimePath(a.opts.Home)); err == nil {
		return nil
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
	fmt.Fprintf(a.stderr(), "kogen: installing Claude Code %s into %s\n", Version, RuntimeDir(a.opts.Home))

	if seam {
		manifestURL := base + "/" + Version + "/manifest.json"
		checksum, size, err := a.fetchManifest(ctx, manifestURL, want.platform)
		if err != nil {
			return err
		}
		want.sha256, want.size = checksum, size
	}
	source := base + "/" + Version + "/" + want.platform + "/claude"
	resp, err := a.get(ctx, source)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	file := filepath.Join(partial, "claude")
	out, err := os.OpenFile(file, os.O_CREATE|os.O_WRONLY|os.O_EXCL, 0o700)
	if err != nil {
		return unavailable("cannot create " + file + ": " + err.Error())
	}
	hash := sha256.New()
	n, err := io.Copy(io.MultiWriter(out, hash), io.LimitReader(resp.Body, want.size+1))
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		if ctx.Err() != nil {
			return classify(ctx)
		}
		return unavailable("cannot download Claude Code " + Version + " from " + source + ": " + err.Error())
	}
	digest := hex.EncodeToString(hash.Sum(nil))
	if n != want.size || digest != want.sha256 {
		return unavailable("the downloaded Claude Code " + Version + " does not match its pinned SHA-256; nothing was installed")
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
	if answer := strings.TrimSpace(string(reported)); !Pinned(answer) {
		return unavailable("the downloaded Claude Code reports " + answer + ", not " + Version + "; nothing was installed")
	}
	dir := RuntimeDir(a.opts.Home)
	// An empty version directory (no executable in it) is no installation; Rename replaces it.
	if err := os.Rename(partial, dir); err != nil {
		return unavailable("cannot install Claude Code " + Version + " into " + dir + ": " + err.Error() + "; remove " + dir + " and run again")
	}
	installed = true
	fmt.Fprintf(a.stderr(), "kogen: installed Claude Code %s (sha256 %s)\n", Version, digest)
	return nil
}

// get is one HTTP GET with no timeout of its own; anything but 200 is a refusal.
func (a *adapter) get(ctx context.Context, source string) (*http.Response, error) {
	fail := func(detail string) error {
		return unavailable("cannot download Claude Code " + Version + " from " + source + ": " + detail)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, source, nil)
	if err != nil {
		return nil, fail(err.Error())
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return nil, classify(ctx)
		}
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return nil, fail(err.Error())
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		return nil, fail("HTTP " + resp.Status)
	}
	return resp, nil
}

// fetchManifest reads the official manifest shape from the test seam.
func (a *adapter) fetchManifest(ctx context.Context, source, platform string) (checksum string, size int64, err error) {
	resp, err := a.get(ctx, source)
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
		return "", 0, unavailable("cannot download Claude Code " + Version + " from " + source + ": " + err.Error())
	}
	p := m.Platforms[platform]
	if !checksumRe.MatchString(p.Checksum) || p.Size <= 0 {
		return "", 0, unavailable("cannot download Claude Code " + Version + " from " + source + ": no checksum and size for " + platform)
	}
	return p.Checksum, p.Size, nil
}

// lockInstall takes the exclusive lock on path, waiting for another Kogen's installation.
func lockInstall(ctx context.Context, path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, unavailable("cannot open the install lock " + path + ": " + err.Error())
	}
	for {
		err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return f, nil
		}
		if err != syscall.EWOULDBLOCK && err != syscall.EINTR {
			f.Close()
			return nil, unavailable("cannot lock " + path + ": " + err.Error())
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
	bin, err := a.binary()
	if err != nil {
		return nil, err
	}
	return a.run(ctx, bin, nil, a.opts.Token, args...)
}

package consumes

import (
	"context"
	"encoding/json"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"

	"github.com/KogenAI/kogen-executor/executor"
	"github.com/KogenAI/kogen-executor/executor/claudecode"
	"kogen-loop/sys"
)

// TestRuntimeLayout: kogen's provider list and uninstall use Root, kogen's list and readiness
// use RuntimePath and RuntimeDir, all under the caller's home, and the list prints the pinned
// Version.
func TestRuntimeLayout(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	if !regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`).MatchString(claudecode.Version) {
		t.Fatalf("Version = %q, want a dotted version", claudecode.Version)
	}
	if got, want := claudecode.Root(home), filepath.Join(home, ".kogen", "claude-code"); got != want {
		t.Fatalf("Root = %q, want %q", got, want)
	}
	if got, want := claudecode.RuntimeDir(home), filepath.Join(claudecode.Root(home), claudecode.Version); got != want {
		t.Fatalf("RuntimeDir = %q, want %q", got, want)
	}
	if got, want := claudecode.RuntimePath(home), filepath.Join(claudecode.RuntimeDir(home), "claude"); got != want {
		t.Fatalf("RuntimePath = %q, want %q", got, want)
	}
}

// TestSupportedAndUnsupportedMessage: kogen's readiness refuses an unsupported platform with
// UnsupportedMessage(GOOS, GOARCH). Supported agrees with the two platforms Kogen's runtime
// supports, whichever one the tests run on.
func TestSupportedAndUnsupportedMessage(t *testing.T) {
	t.Parallel()
	platform, ok := claudecode.Supported()
	wantOK := runtime.GOOS == "darwin" && runtime.GOARCH == "arm64" || runtime.GOOS == "linux" && runtime.GOARCH == "amd64"
	if ok != wantOK {
		t.Fatalf("Supported = %q, %v on %s/%s, want %v", platform, ok, runtime.GOOS, runtime.GOARCH, wantOK)
	}
	if ok && platform == "" {
		t.Fatal("Supported is ok with an empty platform")
	}
	const want = "Kogen's Claude Code runtime supports macOS on Apple Silicon and Linux x86-64 only, not windows/amd64"
	if got := claudecode.UnsupportedMessage("windows", "amd64"); got != want {
		t.Fatalf("UnsupportedMessage = %q, want %q", got, want)
	}
}

// TestPinnedAndNotPinnedMessage: kogen's readiness accepts the runtime only when the first
// field of `--version` is the pinned version, and otherwise reports NotPinnedMessage with the
// runtime's path and answer.
func TestPinnedAndNotPinnedMessage(t *testing.T) {
	t.Parallel()
	if !claudecode.Pinned(claudecode.Version + " (Claude Code)") {
		t.Fatalf("Pinned refuses the pinned version %s", claudecode.Version)
	}
	for _, answer := range []string{"", "2.1.300 (Claude Code)", "x" + claudecode.Version + " (Claude Code)", "Claude Code " + claudecode.Version} {
		if claudecode.Pinned(answer) {
			t.Fatalf("Pinned accepts %q", answer)
		}
	}
	got := claudecode.NotPinnedMessage("/x/claude", "2.1.300 (Claude Code)")
	want := "Kogen's Claude Code at /x/claude reports 2.1.300 (Claude Code), not the pinned " + claudecode.Version
	if got != want {
		t.Fatalf("NotPinnedMessage = %q, want %q", got, want)
	}
}

// TestProbeRunsTheInstalledRuntime: kogen's readiness probes the managed runtime without a
// model call: `--version` (judged by Pinned) and `auth status --json` (parsed for loggedIn and
// authMethod). A missing runtime is an error whose text kogen shows as the answer.
func TestProbeRunsTheInstalledRuntime(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	fakeRuntime(t, home, claudecode.Version+" (Claude Code)")
	out, err := claudecode.Probe(context.Background(), home, "--version")
	if err != nil {
		t.Fatalf("Probe --version: %v", err)
	}
	if answer := strings.TrimSpace(string(out)); !claudecode.Pinned(answer) || answer != claudecode.Version+" (Claude Code)" {
		t.Fatalf("answer = %q", answer)
	}
	out, err = claudecode.Probe(context.Background(), home, "auth", "status", "--json")
	if err != nil {
		t.Fatalf("Probe auth status --json: %v", err)
	}
	var info struct {
		LoggedIn   bool   `json:"loggedIn"`
		AuthMethod string `json:"authMethod"`
	}
	if err := json.Unmarshal(out, &info); err != nil || !info.LoggedIn || info.AuthMethod != "claude.ai" {
		t.Fatalf("auth status = %q (%v)", out, err)
	}

	// Another version is judged not pinned, with kogen's message naming the runtime path.
	other := t.TempDir()
	otherPath := fakeRuntime(t, other, "2.1.300 (Claude Code)")
	out, err = claudecode.Probe(context.Background(), other, "--version")
	if err != nil || claudecode.Pinned(strings.TrimSpace(string(out))) {
		t.Fatalf("answer %q, err %v: want a runtime that is not pinned", out, err)
	}
	if msg := claudecode.NotPinnedMessage(otherPath, strings.TrimSpace(string(out))); !strings.Contains(msg, otherPath) || !strings.Contains(msg, "2.1.300") {
		t.Fatalf("NotPinnedMessage = %q", msg)
	}
}

func TestProbeInstallsNothing(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	out, err := claudecode.Probe(context.Background(), home, "--version")
	e, ok := sys.AsError(err)
	if !ok || e.Class != "executor" || e.Reason != executor.ReasonUnavailable {
		t.Fatalf("Probe of a missing runtime = %q, %v; want executor/unavailable", out, err)
	}
	if err.Error() == "" {
		t.Fatal("the error has no text for kogen to show")
	}
	if m, _ := filepath.Glob(claudecode.Root(home) + "/*"); len(m) != 0 {
		t.Fatalf("Probe installed %v", m)
	}
}

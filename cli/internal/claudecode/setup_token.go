package claudecode

import (
	"bytes"
	"context"
	"io"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/KogenAI/kogen-executor/executor"
	"github.com/KogenAI/kogen-loop/sys"
)

// setupTokenRetry is the tail of every SetupToken error: the one way to try again.
const setupTokenRetry = "; run `kogen provider login claude-code` to retry"

// tokenMarker starts the success screen of `claude setup-token`; the token follows it and is
// never written to out.
const tokenMarker = "Your OAuth token"

// SetupToken signs Kogen's own Claude Code in: it installs the pinned runtime when it is missing
// (the installer of the first role, its progress going to out), runs the runtime's `setup-token`
// with its own browser sign-in and Kogen's configuration directory, passes the terminal through
// and writes the runtime's prompts, sign-in URL and standard error to out. It returns the token
// the runtime printed, trimmed; the token itself is never written to out or to an error.
func SetupToken(ctx context.Context, home string, out io.Writer) (string, error) {
	if out == nil {
		out = io.Discard
	}
	a := New(Options{Home: home, Stderr: out}).(*adapter)
	if err := a.ensureRuntime(ctx); err != nil {
		detail := err.Error()
		if se, ok := sys.AsError(err); ok {
			detail = se.Detail
		}
		return "", setupTokenFail("cannot install Kogen's Claude Code: " + detail)
	}
	bin, err := a.binary(pinnedRef(home))
	if err != nil {
		return "", setupTokenFail("cannot install Kogen's Claude Code: " + err.Error())
	}

	var mu sync.Mutex
	var captured limitedBuffer
	screen := &tokenScreen{mu: &mu, out: out, captured: &captured}
	cmd := exec.CommandContext(ctx, bin, "setup-token")
	cmd.Env = a.childEnv("", "")
	cmd.Stdin = os.Stdin
	cmd.Stdout = screen
	cmd.Stderr = &lockedWriter{mu: &mu, w: out}
	cmd.WaitDelay = 2 * time.Second
	if err := cmd.Run(); err != nil {
		return "", setupTokenFail("Kogen's Claude Code `setup-token` failed: " + err.Error())
	}
	screen.flush()
	token := parseSetupToken(captured.String())
	if token == "" {
		return "", setupTokenFail("Kogen's Claude Code `setup-token` printed no token")
	}
	return token, nil
}

func setupTokenFail(detail string) error {
	return executor.Fail(executor.ReasonUnavailable, detail+setupTokenRetry)
}

// lockedWriter serializes writes to w under mu; a failing w never fails the child.
type lockedWriter struct {
	mu *sync.Mutex
	w  io.Writer
}

func (l *lockedWriter) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.w.Write(p)
	return len(p), nil
}

// tokenScreen is the runtime's standard output: captured whole, and passed on to out as it
// arrives up to the first tokenMarker. It holds back only a trailing part that could still turn
// into the marker.
type tokenScreen struct {
	mu       *sync.Mutex
	out      io.Writer
	captured *limitedBuffer
	held     []byte
	cut      bool
}

func (s *tokenScreen) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.captured.Write(p)
	if s.cut {
		return len(p), nil
	}
	data := append(s.held, p...)
	s.held = nil
	if i := bytes.Index(data, []byte(tokenMarker)); i >= 0 {
		s.cut = true
		s.out.Write(data[:i])
		return len(p), nil
	}
	keep := 0
	for n := min(len(data), len(tokenMarker)-1); n > 0; n-- {
		if string(data[len(data)-n:]) == tokenMarker[:n] {
			keep = n
			break
		}
	}
	s.out.Write(data[:len(data)-keep])
	s.held = append([]byte(nil), data[len(data)-keep:]...)
	return len(p), nil
}

// flush writes out what was held back when the marker never came.
func (s *tokenScreen) flush() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.cut && len(s.held) > 0 {
		s.out.Write(s.held)
	}
	s.held = nil
}

var terminalEscapes = regexp.MustCompile("\x1b\\[[0-?]*[ -/]*[@-~]|\x1b\\][^\x07\x1b]*(?:\x07|\x1b\\\\)")
var tokenRe = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// parseSetupToken is the token on the success screen in the runtime's standard output: the
// non-blank lines after the line holding tokenMarker, trimmed and joined (a long token may be
// wrapped), up to a blank line or the "Store this token securely" line. It is empty unless
// that is made of ASCII letters, digits, '-' and '_'.
func parseSetupToken(stdout string) string {
	text := strings.ReplaceAll(terminalEscapes.ReplaceAllString(stdout, ""), "\r", "")
	lines := strings.Split(text, "\n")
	start := -1
	for i, line := range lines {
		if strings.Contains(line, tokenMarker) {
			start = i + 1
			break
		}
	}
	if start < 0 {
		return ""
	}
	var parts []string
	for _, line := range lines[start:] {
		line = strings.TrimSpace(line)
		if line == "" {
			if len(parts) == 0 {
				continue
			}
			break
		}
		if strings.HasPrefix(line, "Store this token securely") {
			break
		}
		parts = append(parts, line)
	}
	token := strings.Join(parts, "")
	if !tokenRe.MatchString(token) {
		return ""
	}
	return token
}

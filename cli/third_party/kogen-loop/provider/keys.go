package provider

import (
	"bufio"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/KogenAI/kogen-loop/sys"
)

// Input is where a key login reads the secret from: Reader is stdin; when Terminal is set
// the echo is turned off with stty while the key is typed and the saved terminal state is
// restored on every path out (success, error, interrupt).
type Input struct {
	Reader   io.Reader
	Terminal bool
	// Stty runs stty against the terminal and returns its output; nil runs the system's
	// stty with Reader as its standard input.
	Stty func(args ...string) (string, error)
}

// StdinInput is the process's standard input; it is a terminal only when the terminal
// driver says so (/dev/null, a closed standard input, pipes and files are not).
func StdinInput() Input {
	return Input{
		Reader:   os.Stdin,
		Terminal: isTerminal(os.Stdin),
		Stty: func(args ...string) (string, error) {
			cmd := exec.Command("stty", args...)
			cmd.Stdin = os.Stdin
			out, err := cmd.Output()
			return string(out), err
		},
	}
}

// secretInputLimit is the most bytes of credential a non-terminal input may supply, a
// trailing line ending included: more than 100 times a real API key or Claude Code token.
const secretInputLimit = 16 << 10

// secret is one secret read. ok is false when the input could not be read as text (the
// terminal could not be silenced, a read error, invalid UTF-8): the login is then
// "interrupted" and keeps the saved key. tooLong is true when a non-terminal input holds
// more than secretInputLimit bytes; no part of it is returned and the login refuses it as
// an invalid value. empty is true when the input ended before any byte was read (zero bytes
// and EOF, terminal or not); the login then names standard input. The read asks the input
// for at most secretInputLimit+1 bytes in total.
func (in Input) secret(ctx context.Context) (value string, ok, tooLong, empty bool, err error) {
	if in.Terminal {
		stty := in.Stty
		if stty == nil {
			stty = StdinInput().Stty
		}
		state, serr := stty("-g")
		if serr != nil {
			return "", false, false, false, nil
		}
		defer stty(strings.TrimSpace(state))
		if _, serr := stty("-echo"); serr != nil {
			return "", false, false, false, nil
		}
	}
	type read struct {
		data []byte
		err  error
	}
	got := make(chan read, 1)
	go func() {
		var data []byte
		var err error
		if in.Terminal {
			var line string
			line, err = bufio.NewReader(in.Reader).ReadString('\n')
			data = []byte(line)
		} else {
			data, err = io.ReadAll(io.LimitReader(in.Reader, secretInputLimit+1))
		}
		got <- read{data, err}
	}()
	select {
	case r := <-got:
		if !in.Terminal && len(r.data) > secretInputLimit {
			return "", false, true, false, nil
		}
		ended := r.err == nil || r.err == io.EOF
		if ended && len(r.data) == 0 && (!in.Terminal || r.err == io.EOF) {
			return "", true, false, true, nil
		}
		return string(r.data), ended && utf8.Valid(r.data), false, false, nil
	case <-ctx.Done():
		return "", false, false, false, ctx.Err()
	}
}

// apiKey is the key a saved login holds: provider and api_key, the key nonempty, valid
// UTF-8 and free of control characters (Anthropic keys also not blank).
func (c credentials) apiKey(p Info) (string, bool) {
	if c["provider"] != p.Name {
		return "", false
	}
	key, ok := c["api_key"].(string)
	if !ok || !validKey(key) || (p.Name == "anthropic" && strings.TrimSpace(key) == "") {
		return "", false
	}
	return key, true
}

func validKey(s string) bool {
	if s == "" || !utf8.ValidString(s) {
		return false
	}
	for _, r := range s {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

// storedKey is the saved API key or the login refusal that names the login command.
func storedKey(home string, p Info) (string, error) {
	if key, ok := readCredentials(home, p).apiKey(p); ok {
		return key, nil
	}
	return "", providerFail("login", "no usable "+p.Label+" key; "+loginHint(p))
}

// loginReason is the reason of a key login's failures: OpenCode Go says login_failed,
// Anthropic login.
func loginReason(p Info) string {
	if p.Name == "anthropic" {
		return "login"
	}
	return "login_failed"
}

// loginKey saves the key read from the input privately (`kogen provider login
// opencode-go|anthropic`): nothing is verified and no request is made. Whatever goes
// wrong, the previous credential keeps its bytes. A non-empty origin is saved with the key.
func (k *call) loginKey(in Input, origin string) error {
	p := k.info
	fail := func(detail string) error { return providerFail(loginReason(p), detail) }
	value, ok, tooLong, empty, err := in.secret(k.ctx)
	if err != nil {
		if ie := k.interrupted(); ie != nil {
			return ie
		}
		return err
	}
	if tooLong {
		return fail("invalid " + p.Label + " key input; saved login unchanged")
	}
	if empty {
		return fail("no " + p.Label + " key input was read from standard input; pipe the key: printf '%s' \"$KEY\" | kogen provider login " + p.Name + "; saved login unchanged")
	}
	if !ok {
		return fail(p.Label + " input interrupted; saved login unchanged")
	}
	// One terminating line ending goes; any other line break is not a key.
	value = strings.TrimSuffix(strings.TrimSuffix(value, "\n"), "\r")
	if strings.ContainsAny(value, "\r\n") {
		return fail("invalid " + p.Label + " key input; saved login unchanged")
	}
	key := strings.TrimFunc(value, unicode.IsSpace)
	if key == "" {
		return fail("no " + p.Label + " key supplied; saved login unchanged")
	}
	if !validKey(key) {
		return fail("invalid " + p.Label + " key input; saved login unchanged")
	}
	if err := k.saveKey(key, origin); err != nil {
		var stop *sys.Interrupted
		if errors.As(err, &stop) {
			return err
		}
		// Whatever failed (a held lock included) is one message and never carries the key.
		return fail("could not save " + p.Label + " key; saved login unchanged")
	}
	k.s.Puts(p.Name + ": key saved (not verified)")
	return nil
}

// saveKey replaces the credential file atomically under the provider's lock; a held lock
// refuses instead of waiting.
func (k *call) saveKey(key, origin string) error {
	if err := privateDirs(k.home); err != nil {
		return err
	}
	lock, err := k.c.Locker.Acquire(lockPath(k.home, k.info))
	if err != nil {
		return err
	}
	defer lock.Release()
	saved := credentials{"provider": k.info.Name, "api_key": key}
	if origin != "" {
		saved["origin"] = origin
	}
	return writePrivate(k.home, k.info, saved, k.interrupted)
}

// ClaudeCodeName is the name `kogen provider login` accepts for the Claude Code executor's
// stored subscription token (made with `claude setup-token`). It is not a model provider.
const ClaudeCodeName = "claude-code"

var claudeCodeInfo = Info{Name: ClaudeCodeName, Label: "Claude Code", key: true}

// ClaudeCodeToken is the saved Claude Code token; ok is false when none is saved or the
// file holds no usable token.
func ClaudeCodeToken(home string) (string, bool) {
	key, ok := readCredentials(home, claudeCodeInfo).apiKey(claudeCodeInfo)
	if !ok || !validToken(key) {
		return "", false
	}
	return key, true
}

func validToken(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '.' || r == '_' || r == '-') {
			return false
		}
	}
	return true
}

// loginToken saves the token read from the input privately (`kogen provider login
// claude-code`): nothing is verified and no request is made. Refusals never carry the input.
func (k *call) loginToken(in Input) error {
	fail := func(detail string) error { return providerFail("login_failed", detail+"; saved login unchanged") }
	const invalidToken = "invalid Claude Code token input: the token must be one line of letters, digits, dot, underscore and hyphen only"
	value, ok, tooLong, empty, err := in.secret(k.ctx)
	if err != nil {
		if ie := k.interrupted(); ie != nil {
			return ie
		}
		return err
	}
	if tooLong {
		return fail(invalidToken)
	}
	if empty {
		return fail("no Claude Code token input was read from standard input; pipe the token: printf '%s' \"$TOKEN\" | kogen provider login claude-code")
	}
	if !ok {
		return fail("Claude Code token input interrupted")
	}
	token := strings.TrimFunc(value, unicode.IsSpace)
	if token == "" {
		return fail("no Claude Code token supplied (the input was empty)")
	}
	if !validToken(token) {
		return fail(invalidToken)
	}
	if err := k.saveKey(token, ""); err != nil {
		var stop *sys.Interrupted
		if errors.As(err, &stop) {
			return err
		}
		return fail("could not save the Claude Code token")
	}
	k.s.Puts(ClaudeCodeName + ": token saved (not verified)")
	return nil
}

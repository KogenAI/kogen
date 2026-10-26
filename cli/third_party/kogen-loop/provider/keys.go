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

	"kogen-loop/sys"
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

// StdinInput is the process's standard input; it is a terminal when it is a character device.
func StdinInput() Input {
	info, err := os.Stdin.Stat()
	return Input{
		Reader:   os.Stdin,
		Terminal: err == nil && info.Mode()&os.ModeCharDevice != 0,
		Stty: func(args ...string) (string, error) {
			cmd := exec.Command("stty", args...)
			cmd.Stdin = os.Stdin
			out, err := cmd.Output()
			return string(out), err
		},
	}
}

// secret is one secret read. ok is false when the input could not be read as text (the
// terminal could not be silenced, a read error, invalid UTF-8): the login is then
// "interrupted" and keeps the saved key.
func (in Input) secret(ctx context.Context) (value string, ok bool, err error) {
	if in.Terminal {
		stty := in.Stty
		if stty == nil {
			stty = StdinInput().Stty
		}
		state, serr := stty("-g")
		if serr != nil {
			return "", false, nil
		}
		defer stty(strings.TrimSpace(state))
		if _, serr := stty("-echo"); serr != nil {
			return "", false, nil
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
			data, err = io.ReadAll(in.Reader)
		}
		got <- read{data, err}
	}()
	select {
	case r := <-got:
		return string(r.data), (r.err == nil || r.err == io.EOF) && utf8.Valid(r.data), nil
	case <-ctx.Done():
		return "", false, ctx.Err()
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
// wrong, the previous credential keeps its bytes.
func (k *call) loginKey(in Input) error {
	p := k.info
	fail := func(detail string) error { return providerFail(loginReason(p), detail) }
	value, ok, err := in.secret(k.ctx)
	if err != nil {
		if ie := k.interrupted(); ie != nil {
			return ie
		}
		return err
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
	if err := k.saveKey(key); err != nil {
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
func (k *call) saveKey(key string) error {
	if err := privateDirs(k.home); err != nil {
		return err
	}
	lock, err := k.c.Locker.Acquire(lockPath(k.home, k.info))
	if err != nil {
		return err
	}
	defer lock.Release()
	return writePrivate(k.home, k.info, credentials{"provider": k.info.Name, "api_key": key}, k.interrupted)
}

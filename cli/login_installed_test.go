package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// ExUnit: test/integration/open_code_go_login_test.exs, "installed #{@provider} piped login
// rejects invalid UTF-8 instead of saving a replacement key" and "installed #{@provider}
// terminal input never echoes and restores state on success, error and each signal": the
// real kogen binary under a real pseudo-terminal, for both key providers (and the optional key
// of openai-compatible). The Python drivers are the ExUnit ones, unchanged.

const pipedLoginScript = `
import os, subprocess, sys
binary, home, provider = sys.argv[1:]
env = {**os.environ, 'HOME': home}
path = os.path.join(home, '.kogen/credentials/'+provider+'.json')
command = [binary, 'provider', 'login', provider]
first = subprocess.run(command, input=b'SYNTHETIC_ORIGINAL_KEY\n', capture_output=True, env=env, timeout=15)
assert first.returncode == 0, (first.stdout, first.stderr)
before = open(path, 'rb').read()
invalid = subprocess.run(command, input=b'SYNTHETIC_INVALID_\xff\n', capture_output=True, env=env, timeout=15)
assert invalid.returncode == 4, (invalid.returncode, invalid.stdout, invalid.stderr)
assert ('provider/login' if provider == 'anthropic' else 'provider/login_failed').encode() in invalid.stdout + invalid.stderr
assert b'SYNTHETIC_INVALID_' not in invalid.stdout + invalid.stderr
assert open(path, 'rb').read() == before
print('invalid piped input preserved login')
`

const terminalLoginScript = `
import os, pty, signal, subprocess, sys, termios, time, select
binary, home, provider = sys.argv[1:]
env = {**os.environ, 'HOME': home}
path = os.path.join(home, '.kogen/credentials/'+provider+'.json')
for mode, expected in [('success',0),('empty',4),('SIGINT',130),('SIGTERM',143),('SIGHUP',129)]:
    master, slave = pty.openpty()
    before = termios.tcgetattr(slave)
    saved = open(path,'rb').read() if os.path.exists(path) else None
    p = subprocess.Popen([binary,'provider','login',provider], stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    try:
        deadline = time.monotonic()+10
        while termios.tcgetattr(slave)[3] & termios.ECHO:
            assert p.poll() is None, 'login exited before private input'
            assert time.monotonic() < deadline, 'login never disabled echo'
            time.sleep(.01)
        if mode == 'success': os.write(master,b'SYNTHETIC_TERMINAL_KEY\n')
        elif mode == 'empty': os.write(master,b'\n')
        else: p.send_signal(getattr(signal,mode))
        out, err = p.communicate(timeout=15)
        assert p.returncode == expected, (mode,p.returncode,out,err)
        assert termios.tcgetattr(slave) == before, 'terminal was not restored'
        assert b'SYNTHETIC_TERMINAL_KEY' not in out+err
        if select.select([master],[],[],.05)[0]:
            assert b'SYNTHETIC_TERMINAL_KEY' not in os.read(master,4096), 'key was echoed'
        if mode != 'success': assert open(path,'rb').read() == saved
    finally:
        if p.poll() is None: p.kill(); p.wait()
        termios.tcsetattr(slave,termios.TCSANOW,before)
        os.close(master); os.close(slave)
print('terminal custody passed')
`

func TestInstalledKeyLoginUnderPipesAndATerminal(t *testing.T) {
	python, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 is not available")
	}
	bin := filepath.Join(t.TempDir(), "kogen")
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("go build: %v\n%s", err, out)
	}
	for _, provider := range []string{"opencode-go", "anthropic"} { // openai-compatible: its login now takes a base URL first (K-CRED-ORIGIN, same landing)
		for _, c := range []struct{ name, script, want string }{
			{"piped invalid UTF-8", pipedLoginScript, "invalid piped input preserved login\n"},
			{"terminal", terminalLoginScript, "terminal custody passed\n"},
		} {
			t.Run(provider+" "+c.name, func(t *testing.T) {
				home := t.TempDir()
				cmd := exec.Command(python, "-I", "-c", c.script, bin, home, provider)
				cmd.Env = append(os.Environ(), "HOME="+home)
				out, err := cmd.CombinedOutput()
				if err != nil || string(out) != c.want {
					t.Fatalf("%v\n%s", err, strings.TrimSpace(string(out)))
				}
			})
		}
	}
}

//go:build darwin || linux

package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// ExUnit: test/integration/open_code_go_login_test.exs, "installed #{@provider} piped login
// rejects invalid UTF-8 instead of saving a replacement key" and "installed #{@provider}
// terminal input never echoes and restores state on success, error and each signal": the
// real kogen binary under a real pseudo-terminal, for the key providers. openai-compatible reads
// its base URL line first (K-CRED-ORIGIN), so its drivers supply https://a.example/v1 before each
// key; the other providers' drivers are the ExUnit ones, unchanged. The drivers use only the Go
// standard library: no interpreter, shell or network is involved.

const loginTimeout = 15 * time.Second

func loginEnv(home string) []string { return append(os.Environ(), "HOME="+home) }

func credentialPath(home, provider string) string {
	return filepath.Join(home, ".kogen", "credentials", provider+".json")
}

func readFileOrNil(t *testing.T, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func pipedLogin(t *testing.T, bin, home, provider, url string) {
	t.Helper()
	path := credentialPath(home, provider)
	var line []byte
	if url != "" {
		line = []byte(url + "\n")
	}
	login := func(input []byte) (int, []byte, []byte) {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), loginTimeout)
		defer cancel()
		cmd := exec.CommandContext(ctx, bin, "provider", "login", provider)
		cmd.Env = loginEnv(home)
		cmd.Stdin = bytes.NewReader(input)
		var stdout, stderr bytes.Buffer
		cmd.Stdout, cmd.Stderr = &stdout, &stderr
		err := cmd.Run()
		if ctx.Err() != nil {
			t.Fatalf("login timed out after %v\nstdout: %q\nstderr: %q", loginTimeout, stdout.Bytes(), stderr.Bytes())
		}
		var exit *exec.ExitError
		if err != nil && !errors.As(err, &exit) {
			t.Fatal(err)
		}
		return cmd.ProcessState.ExitCode(), stdout.Bytes(), stderr.Bytes()
	}
	code, stdout, stderr := login(append(append([]byte{}, line...), "SYNTHETIC_ORIGINAL_KEY\n"...))
	if code != 0 {
		t.Fatalf("first login: exit %d\nstdout: %q\nstderr: %q", code, stdout, stderr)
	}
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if url != "" && !(bytes.Contains(before, []byte(`"origin":"https://a.example"`)) && bytes.Contains(before, []byte("SYNTHETIC_ORIGINAL_KEY"))) {
		t.Fatalf("saved credential lacks the origin and the key: %q", before)
	}
	code, stdout, stderr = login(append(append([]byte{}, line...), "SYNTHETIC_INVALID_\xff\n"...))
	if code != 4 {
		t.Fatalf("invalid login: exit %d, want 4\nstdout: %q\nstderr: %q", code, stdout, stderr)
	}
	combined := append(append([]byte{}, stdout...), stderr...)
	want := "provider/login_failed"
	if provider == "anthropic" {
		want = "provider/login"
	}
	if !bytes.Contains(combined, []byte(want)) {
		t.Fatalf("invalid login output lacks %q\nstdout: %q\nstderr: %q", want, stdout, stderr)
	}
	if bytes.Contains(combined, []byte("SYNTHETIC_INVALID_")) {
		t.Fatalf("invalid login output leaks the key\nstdout: %q\nstderr: %q", stdout, stderr)
	}
	if after := readFileOrNil(t, path); !bytes.Equal(after, before) {
		t.Fatalf("invalid login changed the saved credential: before %q after %q", before, after)
	}
}

func terminalLogin(t *testing.T, bin, home, provider, url string) {
	t.Helper()
	path := credentialPath(home, provider)
	var line []byte
	if url != "" {
		line = []byte(url + "\n")
	}
	key := []byte("SYNTHETIC_TERMINAL_KEY")
	for _, c := range []struct {
		mode     string
		expected int
		signal   syscall.Signal
	}{
		{"success", 0, 0}, {"empty", 4, 0}, {"SIGINT", 130, syscall.SIGINT},
		{"SIGTERM", 143, syscall.SIGTERM}, {"SIGHUP", 129, syscall.SIGHUP},
	} {
		func() {
			master, slave, err := openPTY()
			if err != nil {
				t.Fatal(err)
			}
			before, err := getTermios(slave)
			if err != nil {
				t.Fatal(err)
			}
			saved := readFileOrNil(t, path)
			cmd := exec.Command(bin, "provider", "login", provider)
			cmd.Env = loginEnv(home)
			cmd.Stdin = slave
			var stdout, stderr bytes.Buffer
			cmd.Stdout, cmd.Stderr = &stdout, &stderr
			if err := cmd.Start(); err != nil {
				setTermios(slave, before)
				syscall.Close(master)
				slave.Close()
				t.Fatal(err)
			}
			done := make(chan struct{})
			go func() { cmd.Wait(); close(done) }()
			defer func() {
				select {
				case <-done:
				default:
					cmd.Process.Kill()
					<-done
				}
				setTermios(slave, before)
				syscall.Close(master)
				slave.Close()
			}()
			if _, err := syscall.Write(master, line); err != nil {
				t.Fatal(err)
			}
			deadline := time.Now().Add(10 * time.Second)
			for {
				state, err := getTermios(slave)
				if err != nil {
					t.Fatal(err)
				}
				if state.Lflag&syscall.ECHO == 0 {
					break
				}
				select {
				case <-done:
					t.Fatalf("%s: login exited before private input", c.mode)
				default:
				}
				if time.Now().After(deadline) {
					t.Fatalf("%s: login never disabled echo", c.mode)
				}
				time.Sleep(10 * time.Millisecond)
			}
			switch c.mode {
			case "success":
				syscall.Write(master, append(append([]byte{}, key...), '\n'))
			case "empty":
				syscall.Write(master, []byte("\n"))
			default:
				cmd.Process.Signal(c.signal)
			}
			select {
			case <-done:
			case <-time.After(loginTimeout):
				t.Fatalf("%s: login still running after %v\nstdout: %q\nstderr: %q", c.mode, loginTimeout, stdout.Bytes(), stderr.Bytes())
			}
			if code := cmd.ProcessState.ExitCode(); code != c.expected {
				t.Fatalf("%s: exit %d, want %d\nstdout: %q\nstderr: %q", c.mode, code, c.expected, stdout.Bytes(), stderr.Bytes())
			}
			if after, err := getTermios(slave); err != nil || after != before {
				t.Fatalf("%s: terminal was not restored: %v", c.mode, err)
			}
			if bytes.Contains(append(stdout.Bytes(), stderr.Bytes()...), key) {
				t.Fatalf("%s: login output leaks the key\nstdout: %q\nstderr: %q", c.mode, stdout.Bytes(), stderr.Bytes())
			}
			if readable(master, 50*time.Millisecond) {
				buf := make([]byte, 4096)
				n, _ := syscall.Read(master, buf)
				if n > 0 && bytes.Contains(buf[:n], key) {
					t.Fatalf("%s: key was echoed", c.mode)
				}
			}
			after := readFileOrNil(t, path)
			if c.mode != "success" && !bytes.Equal(after, saved) {
				t.Fatalf("%s: login changed the saved credential: before %q after %q", c.mode, saved, after)
			}
			if c.mode == "success" && url != "" && !(bytes.Contains(after, []byte(`"origin":"https://a.example"`)) && bytes.Contains(after, key)) {
				t.Fatalf("%s: saved credential lacks the origin and the key: %q", c.mode, after)
			}
		}()
	}
}

// Catches login custody of the built binary under pipes and a terminal: invalid UTF-8 saved as a
// replacement key, a terminal not restored, an echoed key and changed saved credentials.
func TestInstalledKeyLoginUnderPipesAndATerminal(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "kogen")
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("go build: %v\n%s", err, out)
	}
	ran := map[string]int{}
	for _, provider := range []string{"opencode-go", "anthropic", "openai-compatible"} {
		url := ""
		if provider == "openai-compatible" {
			url = "https://a.example/v1"
		}
		for _, c := range []struct {
			name string
			run  func(t *testing.T, bin, home, provider, url string)
		}{
			{"piped invalid UTF-8", pipedLogin},
			{"terminal", terminalLogin},
		} {
			t.Run(provider+" "+c.name, func(t *testing.T) {
				ran[provider]++
				c.run(t, bin, t.TempDir(), provider, url)
			})
		}
	}
	// The compatible subtests must have executed their drivers, not just let the parent pass.
	if ran["openai-compatible"] != 2 {
		t.Fatalf("openai-compatible installed subtests ran %d times, want 2", ran["openai-compatible"])
	}
}

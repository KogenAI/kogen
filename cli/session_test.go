package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

const coreFixtureScript = `#!/bin/sh
set -eu
mode="${KOGEN_TEST_CORE_MODE}"
log="${KOGEN_TEST_CORE_LOG}"
record() { printf '%s\n' "$1" >> "$log"; }
read_msg() { IFS= read -r line; }
hello_exchange() {
  read_msg
  record "$line"
  [ "$line" = '{"type":"hello"}' ] || exit 91
  printf '%s\n' '{"type":"hello"}'
  read_msg
  record "$line"
}

case "$mode" in
  nohello) exit 7 ;;
  silent)
    read_msg
    record "$line"
    exec sleep 600
    ;;
esac

hello_exchange
case "$mode" in
  hello)
    printf '%s\n' '{"type":"out","text":"hello from core\n"}'
    printf '%s\n' '{"type":"exit","code":0}'
    ;;
  crash)
    printf '{"type":"build_started","root":"%s","start_head":"%s","run_log":"%s"}\n' \
      "$KOGEN_TEST_REPO" "$KOGEN_TEST_HEAD" "$KOGEN_TEST_RUN_LOG"
    exit "${KOGEN_TEST_CORE_STATUS}"
    ;;
  cancel|cancel_child)
    if [ "$mode" = cancel_child ]; then
      printf '%s\n' '{"type":"exec","id":"group","command":"exec \"$KOGEN_TEST_CHILD\" \"-test.run=^TestProcessGroupChild$\"","cwd":".","env":{"KOGEN_PROCESS_GROUP_MODE":"ignore-term"}}'
    fi
    while IFS= read -r line; do
      record "$line"
      case "$line" in
        *'"type":"cancel"'*)
          if [ "$mode" = cancel_child ]; then
            printf '%s\n' '{"type":"exit","code":130}'
            exit 0
          fi
          printf '%s\n' '{"type":"exec","id":"after-cancel","command":"touch \"$KOGEN_TEST_SHOULD_NOT_RUN\"","cwd":".","env":{}}'
          ;;
        *'"type":"exec_done"'*)
          status=$(printf '%s\n' "$line" | sed -E 's/.*"status":([0-9]+).*/\1/')
          printf '{"type":"exit","code":%s}\n' "$status"
          exit 0
          ;;
      esac
    done
    ;;
  output)
    printf '%s\n' '{"type":"exec","id":"output","command":"exec \"$KOGEN_TEST_CHILD\" \"-test.run=^TestProcessGroupChild$\"","cwd":".","env":{"KOGEN_PROCESS_GROUP_MODE":"write-output"}}'
    while IFS= read -r line; do
      record "$line"
      case "$line" in
        *'"type":"exec_done"'*)
          printf '%s\n' '{"type":"exit","code":0}'
          exit 0
          ;;
      esac
    done
    ;;
  probe)
    printf '%s\n' '{"type":"exec","id":"probe","command":"exec sleep 30","cwd":".","env":{},"timeout_ms":200}'
    while IFS= read -r line; do
      record "$line"
      case "$line" in
        *'"type":"exec_done"'*)
          printf '%s\n' '{"type":"exit","code":0}'
          exit 0
          ;;
      esac
    done
    ;;
  *) exit 92 ;;
esac
`

// TestSessionProcess runs the actual session in a child test process so signal delivery and
// fail's process exit can be observed at the OS boundary.
func TestSessionProcess(t *testing.T) {
	if os.Getenv("KOGEN_TEST_SESSION_HELPER") != "1" {
		return
	}
	code := newSession(os.Getenv("KOGEN_TEST_ROOT")).run(map[string]any{"type": "run", "command": "demo"})
	os.Exit(code)
}

// TestProcessGroupChild is invoked by session.exec as a real command process. In ignore-term
// mode it records SIGTERM and stays alive until the session sends SIGKILL.
func TestProcessGroupChild(t *testing.T) {
	switch os.Getenv("KOGEN_PROCESS_GROUP_MODE") {
	case "write-output":
		for _, chunk := range []struct {
			byte byte
			size int
		}{{'H', 2 << 20}, {'M', 64 << 10}, {'T', 2 << 20}} {
			if err := writeRepeated(os.Stdout, chunk.byte, chunk.size); err != nil {
				os.Exit(2)
			}
		}
		os.Exit(0)
	case "ignore-term":
		marker := os.Getenv("KOGEN_PROCESS_GROUP_MARKER")
		signals := make(chan os.Signal, 1)
		signal.Notify(signals, syscall.SIGTERM)
		defer signal.Stop(signals)
		if err := os.WriteFile(marker, []byte("ready\n"), 0o600); err != nil {
			os.Exit(3)
		}
		for range signals {
			f, err := os.OpenFile(marker, os.O_APPEND|os.O_WRONLY, 0o600)
			if err != nil {
				os.Exit(4)
			}
			_, writeErr := f.WriteString("SIGTERM\n")
			closeErr := f.Close()
			if writeErr != nil || closeErr != nil {
				os.Exit(5)
			}
		}
	}
}

func TestSessionStartHandshakeAndUnavailableCLI9(t *testing.T) {
	t.Run("hello both ways", func(t *testing.T) {
		root := installFixtureCore(t)
		log := filepath.Join(t.TempDir(), "protocol.log")
		cmd, stdout, stderr := startSessionProcess(t, root, map[string]string{
			"KOGEN_TEST_CORE_MODE": "hello",
			"KOGEN_TEST_CORE_LOG":  log,
		})
		waitErr := waitCommand(t, cmd, 3*time.Second)
		assertExitCode(t, cmd, waitErr, 0)
		if stdout.String() != "hello from core\n" {
			t.Fatalf("stdout = %q, want the result sent after hello", stdout.String())
		}
		if stderr.Len() != 0 {
			t.Fatalf("stderr = %q, want empty", stderr.String())
		}
		got := readProtocolLog(t, log)
		want := []string{`{"type":"hello"}`, `{"command":"demo","type":"run"}`}
		if !equalStrings(got, want) {
			t.Fatalf("core received protocol lines %q, want %q", got, want)
		}
	})

	t.Run("core exits without answering hello", func(t *testing.T) {
		root := installFixtureCore(t)
		log := filepath.Join(t.TempDir(), "protocol.log")
		cmd, stdout, stderr := startSessionProcess(t, root, map[string]string{
			"KOGEN_TEST_CORE_MODE": "nohello",
			"KOGEN_TEST_CORE_LOG":  log,
		})
		waitErr := waitCommand(t, cmd, 3*time.Second)
		assertExitCode(t, cmd, waitErr, 3)
		want := "environment/core_unavailable: the core did not answer hello (the core exited); reinstall Kogen\n"
		if stdout.String() != want {
			t.Fatalf("stdout = %q, want %q", stdout.String(), want)
		}
		if stderr.Len() != 0 {
			t.Fatalf("stderr = %q, want empty", stderr.String())
		}
	})
}

func TestSessionCoreCrashReportCLI8(t *testing.T) {
	baseEnv := isolatedTestEnv(t)
	repo, head := createGitRepo(t, baseEnv)
	root := installFixtureCore(t)
	log := filepath.Join(t.TempDir(), "protocol.log")
	runLog := filepath.Join(repo, ".kogen", "local", "runs", "1234abcd", "log.jsonl")
	cmd, stdout, _ := startSessionProcess(t, root, map[string]string{
		"KOGEN_TEST_CORE_MODE":   "crash",
		"KOGEN_TEST_CORE_LOG":    log,
		"KOGEN_TEST_CORE_STATUS": "23",
		"KOGEN_TEST_REPO":        repo,
		"KOGEN_TEST_HEAD":        head,
		"KOGEN_TEST_RUN_LOG":     runLog,
	})
	waitErr := waitCommand(t, cmd, 3*time.Second)
	assertExitCode(t, cmd, waitErr, 70)
	want := fmt.Sprintf("  kogen intent inspect 1234abcd --project %s\ncontroller/internal_error: the Kogen core stopped unexpectedly (status 23); nothing was committed; run log: %s\n", shellQuote(repo), runLog)
	if stdout.String() != want {
		t.Fatalf("stdout = %q, want %q", stdout.String(), want)
	}
}

func TestSessionSignalExitMappingCLI5CLI7(t *testing.T) {
	tests := []struct {
		name     string
		signal   syscall.Signal
		sigName  string
		wantCode int
	}{
		{name: "SIGINT", signal: syscall.SIGINT, sigName: "SIGINT", wantCode: 130},
		{name: "SIGTERM", signal: syscall.SIGTERM, sigName: "SIGTERM", wantCode: 143},
		{name: "SIGHUP", signal: syscall.SIGHUP, sigName: "SIGHUP", wantCode: 129},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			root := installFixtureCore(t)
			log := filepath.Join(t.TempDir(), "protocol.log")
			notRun := filepath.Join(t.TempDir(), "command-ran")
			cmd, stdout, stderr := startSessionProcess(t, root, map[string]string{
				"KOGEN_TEST_CORE_MODE":      "cancel",
				"KOGEN_TEST_CORE_LOG":       log,
				"KOGEN_TEST_SHOULD_NOT_RUN": notRun,
			})
			waitForFileContains(t, log, `"command":"demo","type":"run"`, 3*time.Second)
			if err := cmd.Process.Signal(tt.signal); err != nil {
				t.Fatalf("send %s to session process: %v", tt.sigName, err)
			}
			waitErr := waitCommand(t, cmd, 3*time.Second)
			assertExitCode(t, cmd, waitErr, tt.wantCode)
			if stdout.Len() != 0 || stderr.Len() != 0 {
				t.Fatalf("cancel output = stdout %q, stderr %q; want both empty", stdout.String(), stderr.String())
			}
			if _, err := os.Stat(notRun); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("command requested after cancellation ran or could not be checked: stat error %v", err)
			}

			foundCancel, foundSkippedExec := false, false
			for _, line := range readProtocolLog(t, log) {
				var msg struct {
					Type   string `json:"type"`
					Signal string `json:"signal"`
					Status int    `json:"status"`
				}
				if err := json.Unmarshal([]byte(line), &msg); err != nil {
					t.Fatalf("parse protocol line %q: %v", line, err)
				}
				if msg.Type == "cancel" && msg.Signal == tt.sigName {
					foundCancel = true
				}
				if msg.Type == "exec_done" && msg.Status == tt.wantCode {
					foundSkippedExec = true
				}
			}
			if !foundCancel || !foundSkippedExec {
				t.Fatalf("protocol log does not show cancel %s and skipped exec status %d: %q", tt.sigName, tt.wantCode, readProtocolLog(t, log))
			}
		})
	}
}

func TestSessionStopsCommandProcessGroupCLI7(t *testing.T) {
	root := installFixtureCore(t)
	log := filepath.Join(t.TempDir(), "protocol.log")
	marker := filepath.Join(t.TempDir(), "child.log")
	cmd, stdout, stderr := startSessionProcess(t, root, map[string]string{
		"KOGEN_TEST_CORE_MODE":       "cancel_child",
		"KOGEN_TEST_CORE_LOG":        log,
		"KOGEN_TEST_CHILD":           testBinaryPath(t),
		"KOGEN_PROCESS_GROUP_MARKER": marker,
	})
	waitForFileContains(t, marker, "ready", 3*time.Second)
	waitForFileContains(t, log, `"type":"exec_started"`, 3*time.Second)
	pgid := processGroupIDFromLog(t, log)

	start := time.Now()
	if err := cmd.Process.Signal(syscall.SIGINT); err != nil {
		t.Fatalf("send SIGINT to session process: %v", err)
	}
	waitErr := waitCommand(t, cmd, 14*time.Second)
	elapsed := time.Since(start)
	assertExitCode(t, cmd, waitErr, 130)
	if elapsed < 4500*time.Millisecond || elapsed >= 15*time.Second {
		t.Fatalf("interrupted session exited after %v, want SIGTERM grace period before SIGKILL and exit within 15 seconds", elapsed)
	}
	if stdout.Len() != 0 || stderr.Len() != 0 {
		t.Fatalf("interrupted session output = stdout %q, stderr %q; want both empty", stdout.String(), stderr.String())
	}
	contents, err := os.ReadFile(marker)
	if err != nil {
		t.Fatalf("read process marker: %v", err)
	}
	if !strings.Contains(string(contents), "ready\n") || !strings.Contains(string(contents), "SIGTERM\n") {
		t.Fatalf("child marker = %q, want ready and SIGTERM before SIGKILL", contents)
	}
	waitForProcessGroupGone(t, pgid, 2*time.Second)
}

func TestSessionOutputCaptureKeepsHeadTailAndMarkerCLI4CLI9(t *testing.T) {
	root := installFixtureCore(t)
	log := filepath.Join(t.TempDir(), "protocol.log")
	cmd, stdout, stderr := startSessionProcess(t, root, map[string]string{
		"KOGEN_TEST_CORE_MODE": "output",
		"KOGEN_TEST_CORE_LOG":  log,
		"KOGEN_TEST_CHILD":     testBinaryPath(t),
	})
	// A hang guard only: streaming 4 MiB under -race takes seconds on a loaded host.
	waitErr := waitCommand(t, cmd, 30*time.Second)
	assertExitCode(t, cmd, waitErr, 0)
	if stdout.Len() != 0 || stderr.Len() != 0 {
		t.Fatalf("exec capture output leaked to session streams: stdout %q stderr %q", stdout.String(), stderr.String())
	}

	var execOutput string
	for _, line := range readProtocolLog(t, log) {
		var msg struct {
			Type   string `json:"type"`
			Output string `json:"output"`
		}
		if err := json.Unmarshal([]byte(line), &msg); err != nil {
			t.Fatalf("parse protocol line: %v", err)
		}
		if msg.Type == "exec_done" {
			execOutput = msg.Output
		}
	}

	marker := regexp.MustCompile(`\n\[\.\.\. ([0-9]+) bytes omitted \.\.\.\]\n`)
	match := marker.FindStringSubmatchIndex(execOutput)
	if match == nil {
		t.Fatalf("exec output has no omitted-bytes marker: len=%d", len(execOutput))
	}
	if !strings.HasPrefix(execOutput, strings.Repeat("H", 256)) {
		t.Fatal("captured output did not keep its head")
	}
	if !strings.HasSuffix(execOutput, strings.Repeat("T", 256)) {
		t.Fatal("captured output did not keep its tail")
	}
	omitted, err := strconv.Atoi(execOutput[match[2]:match[3]])
	if err != nil || omitted <= 0 {
		t.Fatalf("omitted byte count = %q, parse error %v; want a positive count", execOutput[match[2]:match[3]], err)
	}
	retained := len(execOutput) - (match[1] - match[0])
	wantTotal := 2*(2<<20) + (64 << 10)
	if omitted+retained != wantTotal {
		t.Fatalf("captured head (%d) + omitted (%d) + tail does not account for %d source bytes", retained, omitted, wantTotal)
	}
}

func installFixtureCore(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	bin := filepath.Join(root, "lib", "release", "bin", "kogen")
	if err := os.MkdirAll(filepath.Dir(bin), 0o755); err != nil {
		t.Fatalf("create core fixture directory: %v", err)
	}
	if err := os.WriteFile(bin, []byte(coreFixtureScript), 0o755); err != nil {
		t.Fatalf("write core fixture: %v", err)
	}
	return root
}

func startSessionProcess(t *testing.T, root string, extra map[string]string) (*exec.Cmd, *bytes.Buffer, *bytes.Buffer) {
	t.Helper()
	binary := testBinaryPath(t)
	env := isolatedTestEnv(t)
	overrides := map[string]string{
		"KOGEN_TEST_SESSION_HELPER": "1",
		"KOGEN_TEST_ROOT":           root,
	}
	for key, value := range extra {
		overrides[key] = value
	}
	env = mergeEnv(env, overrides)
	cmd := exec.Command(binary, "-test.run=^TestSessionProcess$")
	cmd.Env = env
	stdout, stderr := &bytes.Buffer{}, &bytes.Buffer{}
	cmd.Stdout, cmd.Stderr = stdout, stderr
	if err := cmd.Start(); err != nil {
		t.Fatalf("start session test process: %v", err)
	}
	t.Cleanup(func() {
		if cmd.ProcessState == nil {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
		}
	})
	return cmd, stdout, stderr
}

func isolatedTestEnv(t *testing.T) []string {
	t.Helper()
	base := t.TempDir()
	home := filepath.Join(base, "home")
	if err := os.MkdirAll(home, 0o700); err != nil {
		t.Fatalf("create temporary HOME: %v", err)
	}
	globalConfig := filepath.Join(base, "gitconfig")
	if err := os.WriteFile(globalConfig, nil, 0o600); err != nil {
		t.Fatalf("create isolated Git config: %v", err)
	}
	values := map[string]string{
		"GIT_CONFIG_GLOBAL":   globalConfig,
		"GIT_CONFIG_NOSYSTEM": "1",
		"HOME":                home,
		"PATH":                os.Getenv("PATH"),
		"TMPDIR":              os.TempDir(),
	}
	return mergeEnv(nil, values)
}

func mergeEnv(base []string, additions map[string]string) []string {
	values := make(map[string]string, len(base)+len(additions))
	for _, item := range base {
		key, value, ok := strings.Cut(item, "=")
		if ok {
			values[key] = value
		}
	}
	for key, value := range additions {
		values[key] = value
	}
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	env := make([]string, 0, len(keys))
	for _, key := range keys {
		env = append(env, key+"="+values[key])
	}
	return env
}

func testBinaryPath(t *testing.T) string {
	t.Helper()
	binary, err := os.Executable()
	if err != nil {
		t.Fatalf("locate test binary: %v", err)
	}
	return binary
}

func waitCommand(t *testing.T, cmd *exec.Cmd, timeout time.Duration) error {
	t.Helper()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		return err
	case <-time.After(timeout):
		_ = cmd.Process.Kill()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
		}
		t.Fatalf("session process did not exit within %v", timeout)
		return nil
	}
}

func assertExitCode(t *testing.T, cmd *exec.Cmd, waitErr error, want int) {
	t.Helper()
	if waitErr != nil {
		var exitErr *exec.ExitError
		if !errors.As(waitErr, &exitErr) {
			t.Fatalf("wait for session process: %v", waitErr)
		}
	}
	if cmd.ProcessState == nil || cmd.ProcessState.ExitCode() != want {
		code := -1
		if cmd.ProcessState != nil {
			code = cmd.ProcessState.ExitCode()
		}
		t.Fatalf("session process exit code = %d, want %d (wait error %v)", code, want, waitErr)
	}
}

func waitForFileContains(t *testing.T, path, text string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		contents, err := os.ReadFile(path)
		if err == nil && strings.Contains(string(contents), text) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	contents, err := os.ReadFile(path)
	t.Fatalf("file %s did not contain %q before timeout (contents %q, read error %v)", path, text, contents, err)
}

func readProtocolLog(t *testing.T, path string) []string {
	t.Helper()
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read protocol log: %v", err)
	}
	text := strings.TrimSuffix(string(contents), "\n")
	if text == "" {
		return nil
	}
	return strings.Split(text, "\n")
}

func processGroupIDFromLog(t *testing.T, path string) int {
	t.Helper()
	for _, line := range readProtocolLog(t, path) {
		var msg struct {
			Type string `json:"type"`
			PGID int    `json:"pgid"`
		}
		if err := json.Unmarshal([]byte(line), &msg); err != nil {
			t.Fatalf("parse protocol line %q: %v", line, err)
		}
		if msg.Type == "exec_started" {
			if msg.PGID <= 0 {
				t.Fatalf("exec_started process group id = %d", msg.PGID)
			}
			return msg.PGID
		}
	}
	t.Fatal("protocol log has no exec_started message")
	return 0
}

func waitForProcessGroupGone(t *testing.T, pgid int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		err := syscall.Kill(-pgid, 0)
		if errors.Is(err, syscall.ESRCH) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	err := syscall.Kill(-pgid, 0)
	t.Fatalf("process group %d is still present after termination (kill error %v)", pgid, err)
}

func createGitRepo(t *testing.T, env []string) (string, string) {
	t.Helper()
	repo := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(repo, 0o755); err != nil {
		t.Fatalf("create repository directory: %v", err)
	}
	runGit(t, env, "init", "--quiet", repo)
	runGit(t, env, "-C", repo, "config", "user.name", "Kogen Test")
	runGit(t, env, "-C", repo, "config", "user.email", "kogen-test@example.invalid")
	if err := os.WriteFile(filepath.Join(repo, "seed.txt"), []byte("seed\n"), 0o600); err != nil {
		t.Fatalf("write repository seed: %v", err)
	}
	runGit(t, env, "-C", repo, "add", "seed.txt")
	runGit(t, env, "-C", repo, "commit", "--quiet", "-m", "baseline")
	head := strings.TrimSpace(string(runGit(t, env, "-C", repo, "rev-parse", "HEAD")))
	return repo, head
}

func runGit(t *testing.T, env []string, args ...string) []byte {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Env = env
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %q failed: %v\n%s", args, err, output)
	}
	return output
}

func writeRepeated(w io.Writer, b byte, size int) error {
	block := bytes.Repeat([]byte{b}, 64<<10)
	for size > 0 {
		chunk := block
		if size < len(chunk) {
			chunk = block[:size]
		}
		written, err := w.Write(chunk)
		if err != nil {
			return err
		}
		if written == 0 {
			return io.ErrShortWrite
		}
		size -= written
	}
	return nil
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// CLI-7: Ctrl-C works while a core that never answers hello is starting.
func TestSessionInterruptDuringSilentStartupCLI7(t *testing.T) {
	root := installFixtureCore(t)
	log := filepath.Join(t.TempDir(), "protocol.log")
	cmd, _, _ := startSessionProcess(t, root, map[string]string{
		"KOGEN_TEST_CORE_MODE": "silent",
		"KOGEN_TEST_CORE_LOG":  log,
	})
	waitForFileContains(t, log, `{"type":"hello"}`, 3*time.Second)
	if err := cmd.Process.Signal(syscall.SIGINT); err != nil {
		t.Fatalf("send SIGINT to session process: %v", err)
	}
	waitErr := waitCommand(t, cmd, 3*time.Second)
	assertExitCode(t, cmd, waitErr, 130)
}

// SHP-10: a probe still running at its timeout is stopped and reported as timed out (run with
// -race: the timer and the command result share that state).
func TestSessionProbeTimeoutReportsTimedOutSHP10(t *testing.T) {
	root := installFixtureCore(t)
	log := filepath.Join(t.TempDir(), "protocol.log")
	cmd, _, _ := startSessionProcess(t, root, map[string]string{
		"KOGEN_TEST_CORE_MODE": "probe",
		"KOGEN_TEST_CORE_LOG":  log,
	})
	waitErr := waitCommand(t, cmd, 15*time.Second)
	assertExitCode(t, cmd, waitErr, 0)
	found := false
	for _, line := range readProtocolLog(t, log) {
		var msg struct {
			Type     string `json:"type"`
			TimedOut bool   `json:"timed_out"`
		}
		if err := json.Unmarshal([]byte(line), &msg); err == nil && msg.Type == "exec_done" && msg.TimedOut {
			found = true
		}
	}
	if !found {
		t.Fatalf("protocol log has no exec_done with timed_out true: %q", readProtocolLog(t, log))
	}
}

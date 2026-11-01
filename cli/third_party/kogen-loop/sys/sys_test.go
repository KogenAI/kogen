package sys

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestMain(m *testing.M) {
	MaybeSupervise(os.Args[1:])
	if os.Getenv("PROC_TEST_HELPER") == "run-sleep" {
		EnableSupervisor()
		s := New()
		s.Run("echo $$ > "+os.Getenv("PROC_TEST_PIDFILE")+"; exec sleep 60", s.Cwd, Options{})
		os.Exit(0)
	}
	EnableSupervisor()
	code := m.Run()
	if custodyBuildDir != "" {
		os.RemoveAll(custodyBuildDir)
	}
	os.Exit(code)
}

func session(t *testing.T) *Session {
	t.Helper()
	return NewWith([]string{"PATH=" + os.Getenv("PATH"), "A=1", "A=3"}, t.TempDir())
}

func TestRunStatusOutputEnv(t *testing.T) {
	t.Parallel()
	s := session(t)
	r, err := s.Run(`printf "$A-$X"; echo err >&2; exit 7`, s.Cwd, Options{Env: map[string]string{"X": "x"}})
	if err != nil || r.Status != 7 || r.Output != "3-xerr\n" || r.TimedOut {
		t.Fatalf("Run = %+v, %v", r, err)
	}
	if s.Getenv("A") != "3" {
		t.Fatal(s.Getenv("A"))
	}
}

func TestRunStdinClosedOwnGroup(t *testing.T) {
	t.Parallel()
	s := session(t)
	r, _ := s.Run(`read x; echo "read=$?"; ps -o pgid= -p $$`, s.Cwd, Options{})
	f := strings.Fields(r.Output)
	if len(f) != 2 || f[0] != "read=1" || f[1] == strconv.Itoa(syscall.Getpgrp()) {
		t.Fatalf("output %q", r.Output)
	}
}

func TestRunTimeout(t *testing.T) {
	t.Parallel()
	s := session(t)
	start := time.Now()
	r, err := s.Run("sleep 30", s.Cwd, Options{Timeout: 200 * time.Millisecond})
	if err != nil || !r.TimedOut || r.Status != 143 || time.Since(start) > 6*time.Second {
		t.Fatalf("Run = %+v, %v after %v", r, err, time.Since(start))
	}
}

// runWhenReady joins Run even if readiness fails; the marker is written by the
// command only after its signal disposition has been installed.
func runWhenReady(t *testing.T, s *Session, command string, opts Options, signal func()) (error, int) {
	t.Helper()
	ready := filepath.Join(s.Cwd, "ready")
	done := make(chan error, 1)
	go func() { _, err := s.Run(command, s.Cwd, opts); done <- err }()
	joined := false
	defer func() {
		if !joined {
			s.Interrupt("SIGINT")
			Terminate(s.Groups())
			<-done
		}
	}()
	deadline := time.NewTimer(10 * time.Second)
	defer deadline.Stop()
	for {
		if _, err := os.Stat(ready); err == nil {
			break
		}
		select {
		case err := <-done:
			joined = true
			t.Fatalf("command exited before readiness: %v", err)
		case <-deadline.C:
			t.Fatal("command did not become ready")
		case <-time.After(10 * time.Millisecond):
		}
	}
	groups := s.Groups()
	if len(groups) != 1 {
		t.Fatalf("ready command groups: %v", groups)
	}
	signal()
	err := <-done
	joined = true
	return err, groups[0]
}

func TestInterruptStopsAndRefuses(t *testing.T) {
	t.Parallel()
	s := session(t)
	marker := filepath.Join(s.Cwd, "after")
	err, pgid := runWhenReady(t, s, "echo ready > ready; sleep 30; touch "+marker, Options{}, func() { s.Interrupt("SIGINT") })
	var in *Interrupted
	if !errors.As(err, &in) || in.ExitCode() != 130 || s.Context().Err() == nil {
		t.Fatalf("Run error %v", err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for syscall.Kill(-pgid, 0) == nil && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if err := syscall.Kill(-pgid, 0); err != syscall.ESRCH {
		t.Fatalf("interrupted group remains: %v", err)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("interrupted command kept running")
	}
	if _, err := s.Run("true", s.Cwd, Options{}); !errors.As(err, &in) {
		t.Fatalf("Run after interrupt: %v", err)
	}
	if s.Interrupt("SIGTERM") {
		t.Fatal("second interrupt counted")
	}
}

func TestFinishOnInterruptWaits(t *testing.T) {
	t.Parallel()
	s := session(t)
	marker := filepath.Join(s.Cwd, "trap")
	err, _ := runWhenReady(t, s, `trap 'sleep 0.5; touch `+marker+`; exit 1' TERM; echo ready > ready; sleep 30 & wait`, Options{FinishOnInterrupt: true}, func() { s.Interrupt("SIGTERM") })
	var in *Interrupted
	if !errors.As(err, &in) || in.ExitCode() != 143 {
		t.Fatal(err)
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatal("returned before the command ended")
	}
}

// When Kogen itself is killed, the supervisor stops the command's process group.
func TestKilledKogenStopsCommands(t *testing.T) {
	t.Parallel()
	pidfile := filepath.Join(t.TempDir(), "pid")
	cmd := exec.Command(os.Args[0])
	cmd.Env = append(os.Environ(), "PROC_TEST_HELPER=run-sleep", "PROC_TEST_PIDFILE="+pidfile)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	var pid int
	for i := 0; i < 100 && pid == 0; i++ {
		time.Sleep(50 * time.Millisecond)
		b, _ := os.ReadFile(pidfile)
		pid, _ = strconv.Atoi(strings.TrimSpace(string(b)))
	}
	if pid == 0 {
		cmd.Process.Kill()
		t.Fatal("command did not start")
	}
	cmd.Process.Kill()
	cmd.Wait()
	for i := 0; i < 100; i++ {
		if syscall.Kill(pid, 0) != nil {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	syscall.Kill(pid, syscall.SIGKILL)
	t.Fatal("the command outlived Kogen")
}

func TestCapBuffer(t *testing.T) {
	t.Parallel()
	b := &capBuffer{}
	b.Write([]byte(strings.Repeat("a", capHalf)))
	b.Write([]byte("MIDDLE"))
	b.Write([]byte(strings.Repeat("z", capHalf)))
	if s := b.String(); !strings.Contains(s, "\n[... 6 bytes omitted ...]\n") || strings.Contains(s, "MIDDLE") {
		t.Fatal("cap")
	}
}

// CLI-5, CLI-7: the caller's SIGINT, SIGTERM and SIGHUP end a running command and map to the
// exits 130, 143 and 129; the command's group is stopped and nothing starts afterwards.
// Serial: these subtests signal the parent process and share its signal handlers.
func TestWatchedSignalsMapToExitCodes(t *testing.T) {
	for _, tt := range []struct {
		sig  syscall.Signal
		code int
	}{{syscall.SIGINT, 130}, {syscall.SIGTERM, 143}, {syscall.SIGHUP, 129}} {
		t.Run(tt.sig.String(), func(t *testing.T) {
			s := session(t)
			stop := s.WatchSignals()
			defer stop()
			notRun := filepath.Join(s.Cwd, "ran")
			err, _ := runWhenReady(t, s, "echo ready > ready; sleep 30", Options{}, func() { syscall.Kill(os.Getpid(), tt.sig) })
			var in *Interrupted
			if !errors.As(err, &in) || in.ExitCode() != tt.code {
				t.Fatalf("Run error %v, want exit %d", err, tt.code)
			}
			if _, err := s.Run("touch "+notRun, s.Cwd, Options{}); !errors.As(err, &in) || in.ExitCode() != tt.code {
				t.Fatalf("Run after the signal: %v", err)
			}
			if _, err := os.Stat(notRun); err == nil {
				t.Fatal("a command started after the interrupt")
			}
		})
	}
}

// CLI-7: an interrupt sends SIGTERM to the command's group, and SIGKILL after five seconds
// to a group that ignores it.
func TestInterruptKillsAGroupThatIgnoresSIGTERM(t *testing.T) {
	t.Parallel()
	s := session(t)
	start := time.Now()
	err, pgid := runWhenReady(t, s, "trap '' TERM; echo ready > ready; while :; do sleep 1; done", Options{}, func() { s.Interrupt("SIGINT") })
	t.Cleanup(func() { syscall.Kill(-pgid, syscall.SIGKILL) })
	var in *Interrupted
	if !errors.As(err, &in) || in.ExitCode() != 130 {
		t.Fatal(err)
	}
	time.Sleep(time.Second)
	if syscall.Kill(-pgid, 0) != nil {
		t.Fatalf("the group ended after SIGTERM alone, %v after the start", time.Since(start))
	}
	for i := 0; i < 100 && syscall.Kill(-pgid, 0) == nil; i++ {
		time.Sleep(100 * time.Millisecond)
	}
	if syscall.Kill(-pgid, 0) == nil {
		syscall.Kill(-pgid, syscall.SIGKILL)
		t.Fatal("the group outlived SIGKILL")
	}
	if elapsed := time.Since(start); elapsed < 4500*time.Millisecond {
		t.Fatalf("the group was killed after %v, before the SIGTERM grace period ended", elapsed)
	}
}

// LOOP-5: a command's output is kept at both ends; the middle becomes an omitted-bytes marker.
func TestRunKeepsHeadAndTailOfLargeOutput(t *testing.T) {
	t.Parallel()
	s := session(t)
	r, err := s.Run(`for spec in H:2097152 M:65536 T:2097152; do head -c "${spec#*:}" /dev/zero | tr '\0' "${spec%%:*}"; done`, s.Cwd, Options{})
	if err != nil || r.Status != 0 {
		t.Fatalf("Run = %d, %v", r.Status, err)
	}
	m := regexp.MustCompile(`\n\[\.\.\. ([0-9]+) bytes omitted \.\.\.\]\n`).FindStringSubmatchIndex(r.Output)
	if m == nil {
		t.Fatalf("no omitted-bytes marker in %d bytes of output", len(r.Output))
	}
	if !strings.HasPrefix(r.Output, strings.Repeat("H", 256)) || !strings.HasSuffix(r.Output, strings.Repeat("T", 256)) {
		t.Fatal("the output did not keep its head and tail")
	}
	omitted, _ := strconv.Atoi(r.Output[m[2]:m[3]])
	if retained := len(r.Output) - (m[1] - m[0]); omitted <= 0 || omitted+retained != 2*(2<<20)+(64<<10) {
		t.Fatalf("retained %d + omitted %d does not account for the source bytes", len(r.Output)-(m[1]-m[0]), omitted)
	}
}

// CLI-9: output of a command is kept byte for byte whatever the caller's locale; an invalid
// byte stays in the captured text (it becomes U+FFFD only when text is encoded for a provider).
func TestRunKeepsOutputBytesWhateverTheLocale(t *testing.T) {
	t.Parallel()
	for _, env := range [][]string{
		{"PATH=" + os.Getenv("PATH"), "LANG=en_US.UTF-8", "LC_ALL=en_US.UTF-8"},
		{"PATH=" + os.Getenv("PATH")},
		{"PATH=" + os.Getenv("PATH"), "LC_ALL=C"},
	} {
		s := NewWith(env, t.TempDir())
		r, err := s.Run(`printf '\303\251 \342\202\254 \377 caf\303\251'`, s.Cwd, Options{})
		if err != nil || r.Output != "é € \xff café" {
			t.Fatalf("env %v: output %q, %v", env[1:], r.Output, err)
		}
	}
}

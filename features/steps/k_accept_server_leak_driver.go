package verify

// K-ACCEPT-SERVER-LEAK observation driver. The acceptance step file mounts it into package verify with
// `go test -overlay` and runs only TestKAcceptServerLeakObservation. It runs the acceptance command through
// RunAcceptance, the one path Shape readiness, approval readiness and Build verification share, three times:
// a passing command (the Build route, no approval attempt), a failing command (the approval route with its
// normal per-step bound) and a command that outlives a contracted 3-second approval bound. Each command puts
// `python3 -m http.server` in the background in its own session, so the server leaves the command's process
// group. A server started by the driver itself, outside every run, is the unrelated process. The driver only
// records what it observed (one JSON file per mode in $KOGEN_KASL_OUTPUT); the step file judges it.

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"kogen-loop/sys"
)

// kaslStarter starts the server in a new session, checks that it is still running half a second later and
// writes "<server pid> <server pgid> <command group>" to argv[1].
const kaslStarter = `import os, subprocess, sys, time
p = subprocess.Popen([sys.argv[2], "-m", "http.server", "0", "--bind", "127.0.0.1"], start_new_session=True,
    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.5)
if p.poll() is not None:
    sys.exit(3)
open(sys.argv[1], "w").write("%d %d %d" % (p.pid, os.getpgid(p.pid), os.getpgrp()))
`

func kaslQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// kaslAlive reports whether pid still exists, a zombie included.
func kaslAlive(pid int) bool { return pid > 0 && syscall.Kill(pid, 0) != syscall.ESRCH }

// kaslGone waits up to five seconds for pid to disappear and reports whether it did.
func kaslGone(pid int) bool {
	for deadline := time.Now().Add(5 * time.Second); ; time.Sleep(50 * time.Millisecond) {
		if !kaslAlive(pid) {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
	}
}

func kaslWrite(t *testing.T, dir, name string, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, name+".json"), b, 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestKAcceptServerLeakObservation(t *testing.T) {
	out := os.Getenv("KOGEN_KASL_OUTPUT")
	if out == "" {
		t.Fatal("KOGEN_KASL_OUTPUT is not set")
	}
	python := os.Getenv("KOGEN_TEST_PYTHON_BIN")
	if python == "" {
		python = "python3"
	}
	root := t.TempDir()
	const slug = "kasl"
	feature := filepath.Join(root, ".kogen/intents", slug, "acceptance.feature")
	if err := os.MkdirAll(filepath.Dir(feature), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(feature, []byte("Feature: kasl\n  Scenario: kasl\n    Then kasl\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// The unrelated server: started here, outside every acceptance run, in its own session.
	unrelated := exec.Command(python, "-m", "http.server", "0", "--bind", "127.0.0.1")
	unrelated.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := unrelated.Start(); err != nil {
		t.Fatalf("cannot start the unrelated %s -m http.server: %v", python, err)
	}
	exited := make(chan struct{})
	go func() { unrelated.Wait(); close(exited) }()
	defer func() { syscall.Kill(-unrelated.Process.Pid, syscall.SIGKILL); <-exited }()
	running := func() bool {
		select {
		case <-exited:
			return false
		default:
			return true
		}
	}
	time.Sleep(500 * time.Millisecond)
	unrelatedBefore := running()

	s := sys.NewWith(os.Environ(), root)
	modes := []struct {
		name, tail string
		attempt    bool
		timeout    time.Duration
	}{
		{"passed", "exit 0", false, 0},
		{"failed", "exit 1", true, 0},
		{"timed_out", "exec sleep 60", true, 3 * time.Second},
	}
	for _, m := range modes {
		pidFile := filepath.Join(root, m.name+".pids")
		command := kaslQuote(python) + " -c " + kaslQuote(kaslStarter) + " " + kaslQuote(pidFile) + " " + kaslQuote(python) + " && " + m.tail
		ctx := context.Background()
		if m.attempt {
			a := NewAttempt(root, slug, nil)
			if m.timeout > 0 {
				a.timeout = m.timeout
			}
			ctx = a.Into(ctx)
		}
		began := time.Now()
		acc, err := RunAcceptance(ctx, s, root, Tools{}, slug, command, filepath.Join(root, m.name+".ndjson"), nil, nil)
		elapsed := time.Since(began)
		obs := map[string]any{"mode": m.name, "status": acc.Status, "elapsed_ms": elapsed.Milliseconds(), "error": "", "step_timeout": false}
		if err != nil {
			obs["error"] = err.Error()
			var st *stepTimeout
			obs["step_timeout"] = errors.As(err, &st)
		}
		fields := []int{}
		if b, rerr := os.ReadFile(pidFile); rerr == nil {
			for _, f := range strings.Fields(string(b)) {
				n, _ := strconv.Atoi(f)
				fields = append(fields, n)
			}
		}
		if len(fields) == 3 {
			pid := fields[0]
			obs["server_pid"], obs["server_pgid"], obs["command_group"] = pid, fields[1], fields[2]
			obs["server_alive_at_return"] = kaslAlive(pid)
			obs["server_gone_within_5s"] = kaslGone(pid)
			// Whatever the outcome, nothing this driver caused may stay on the host.
			syscall.Kill(pid, syscall.SIGKILL)
		} else {
			obs["server_pid"] = 0
			obs["output"] = acc.Output
		}
		kaslWrite(t, out, m.name, obs)
	}
	kaslWrite(t, out, "unrelated", map[string]any{"mode": "unrelated", "pid": unrelated.Process.Pid, "running_before": unrelatedBefore, "running_after": running()})
}

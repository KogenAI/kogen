package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// spec/check.sh runs its independent Quint invocations in parallel lanes but reports them in a
// fixed order, and the first failure in that order decides the result, as in a sequential run.
// The Quint here is a stub that records how many invocations overlap, so no Node is needed.

const stubQuint = `#!/bin/sh
log="$KOGEN_STUB_LOG"
if [ "$1" = "--version" ]; then echo 0.33.0; exit 0; fi
mkdir -p "$log/active"
: > "$log/active/$$"
if [ -n "$KOGEN_STUB_HANG" ]; then echo $$ >> "$log/pids"; sleep 30 & echo $! >> "$log/pids"; wait; fi
echo "$(ls "$log/active" | wc -l)" >> "$log/overlap"
sleep 0.2
rm -f "$log/active/$$"
case "$1" in
typecheck) exit 0 ;;
test) echo "  7 passing (1ms)"; exit 0 ;;
esac
file=""; inv=""
while [ $# -gt 0 ]; do
  case "$1" in quint/*.qnt) file="$1" ;; --invariant) inv="$2" ;; esac
  shift
done
if [ "$inv" = Safety ]; then
  if [ "$file" = quint/$KOGEN_STUB_FAIL ]; then echo "[violation] Found an issue"; echo "error: Invariant violated"; exit 1; fi
  echo "[ok] No violation found (1ms at 1 traces/second)."; exit 0
fi
echo "[violation] Found an issue"; echo "error: Invariant violated"; exit 1
`

func specCheckCmd(t *testing.T, fail string, extraEnv ...string) (cmd *exec.Cmd, log string) {
	t.Helper()
	dir := t.TempDir()
	copyScript(t, "spec/check.sh", filepath.Join(dir, "spec", "check.sh"))
	for path, body := range map[string]string{
		"spec/tools/check.mjs":         "",
		"spec/node_modules/.bin/quint": stubQuint,
		"bin/node":                     "#!/bin/sh\nexit 0\n",
	} {
		full := filepath.Join(dir, path)
		if mkErr := os.MkdirAll(filepath.Dir(full), 0o755); mkErr != nil {
			t.Fatal(mkErr)
		}
		if wErr := os.WriteFile(full, []byte(body), 0o755); wErr != nil {
			t.Fatal(wErr)
		}
	}
	log = filepath.Join(dir, "log")
	cmd = exec.Command("sh", "check.sh")
	cmd.Dir = filepath.Join(dir, "spec")
	cmd.Env = append(append(os.Environ(), "PATH="+filepath.Join(dir, "bin")+string(os.PathListSeparator)+os.Getenv("PATH"),
		"KOGEN_STUB_LOG="+log, "KOGEN_STUB_FAIL="+fail, "KOGEN_SPEC_JOBS=4", "KOGEN_SPEC_NODE_MODULES="), extraEnv...)
	return cmd, log
}

func runSpecCheck(t *testing.T, fail string) (output string, err error, maxOverlap int) {
	t.Helper()
	cmd, log := specCheckCmd(t, fail)
	out, err := cmd.CombinedOutput()
	if b, rErr := os.ReadFile(filepath.Join(log, "overlap")); rErr == nil {
		for _, f := range strings.Fields(string(b)) {
			if n, _ := strconv.Atoi(f); n > maxOverlap {
				maxOverlap = n
			}
		}
	}
	return string(out), err, maxOverlap
}

func TestSpecCheckRunsQuintInParallelAndReportsInOrder(t *testing.T) {
	out, err, overlap := runSpecCheck(t, "")
	if err != nil {
		t.Fatalf("check.sh failed: %v\n%s", err, out)
	}
	if overlap < 2 {
		t.Errorf("Quint invocations never overlapped (max %d at once); check.sh runs them one by one", overlap)
	}
	order := []string{
		"== quint typecheck + test shaping.qnt", "== quint typecheck + test build.qnt", "== quint typecheck + test run_control.qnt",
		"== quint run shaping.qnt --invariant Safety", "== quint run build.qnt --invariant Safety", "== quint run run_control.qnt --invariant Safety",
		"== non-vacuity ok: shaping.qnt reaches not(st != Building)", "== non-vacuity ok: build.qnt reaches not(phase != Done)",
		"== non-vacuity ok: run_control.qnt reaches not(refusal != \"build_running\")", "spec checks: all ok",
	}
	at := 0
	for _, want := range order {
		i := strings.Index(out[at:], want)
		if i < 0 {
			t.Fatalf("%q is missing or out of order after offset %d:\n%s", want, at, out)
		}
		at += i + len(want)
	}
}

func TestSpecCheckFailureIsTheFirstFailureInOrder(t *testing.T) {
	out, err, _ := runSpecCheck(t, "build.qnt")
	if err == nil {
		t.Fatalf("check.sh passed although the Safety run of build.qnt fails:\n%s", out)
	}
	if !strings.HasSuffix(out, "check: invariant Safety violated in build.qnt\n") {
		t.Errorf("the output does not end with the failing invariant:\n%s", out)
	}
	if strings.Contains(out, "non-vacuity ok") || strings.Contains(out, "spec checks: all ok") {
		t.Errorf("results after the first failure were printed:\n%s", out)
	}
}

func TestSpecCheckInterruptLeavesNoProcessesRunning(t *testing.T) {
	cmd, log := specCheckCmd(t, "", "KOGEN_STUB_HANG=1")
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	var pids []int
	for deadline := time.Now().Add(20 * time.Second); len(pids) < 8 && time.Now().Before(deadline); time.Sleep(50 * time.Millisecond) {
		pids = pids[:0]
		if b, err := os.ReadFile(filepath.Join(log, "pids")); err == nil {
			for _, f := range strings.Fields(string(b)) {
				if n, err := strconv.Atoi(f); err == nil {
					pids = append(pids, n)
				}
			}
		}
	}
	if len(pids) < 8 {
		_ = cmd.Process.Kill()
		t.Fatalf("the Quint runs did not start in parallel lanes (pids %v):\n%s", pids, out.String())
	}
	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err == nil {
			t.Error("check.sh exited 0 after SIGTERM")
		}
	case <-time.After(20 * time.Second):
		_ = cmd.Process.Kill()
		t.Fatal("check.sh did not exit after SIGTERM")
	}
	time.Sleep(200 * time.Millisecond)
	for _, pid := range pids {
		if syscall.Kill(pid, 0) == nil {
			_ = syscall.Kill(pid, syscall.SIGKILL)
			t.Errorf("process %d is still running after check.sh was interrupted", pid)
		}
	}
}

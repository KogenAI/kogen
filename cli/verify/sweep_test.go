package verify

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"kogen-loop/sys"
)

func TestAcceptanceTargets(t *testing.T) {
	const me, self = 1000, 50
	procs := []procEntry{
		{pid: 1, ppid: 0, uid: 0},
		{pid: 40, ppid: 1, uid: me},    // an ancestor of Kogen carrying the value
		{pid: self, ppid: 40, uid: me}, // Kogen itself
		{pid: 60, ppid: self, uid: me}, // marked
		{pid: 61, ppid: 60, uid: me},   // descendant of a marked process
		{pid: 62, ppid: 61, uid: me, zombie: true},
		{pid: 63, ppid: 61, uid: 0},     // another user's descendant
		{pid: 70, ppid: 1, uid: me},     // unrelated
		{pid: 71, ppid: 70, uid: me},    // unrelated child
		{pid: 80, ppid: 1, uid: me + 1}, // marked, but another user's
		{pid: 90, ppid: self, uid: me},  // not marked, Kogen's own child
		{pid: 91, ppid: self, uid: me},  // marked, a Kogen child
		{pid: 92, ppid: 91, uid: me},    // its child
		{pid: 100, ppid: 1, uid: me, zombie: true},
	}
	marked := map[int]bool{40: true, self: true, 60: true, 80: true, 91: true, 100: true}
	got := acceptanceTargets(procs, me, self, func(pid int) bool { return marked[pid] })
	if want := []int{60, 61, 91, 92}; !slices.Equal(got, want) {
		t.Fatalf("targets = %v, want %v", got, want)
	}
}

func sweepAlive(pid int) bool { return pid > 0 && syscall.Kill(pid, 0) != syscall.ESRCH }

func sweepGoneSoon(pid int) bool {
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(25 * time.Millisecond) {
		if !sweepAlive(pid) {
			return true
		}
	}
	return false
}

func sweepRoot(t *testing.T) (root, slug string) {
	t.Helper()
	root, slug = t.TempDir(), "sweep"
	feature := filepath.Join(root, ".kogen/intents", slug, "acceptance.feature")
	if err := os.MkdirAll(filepath.Dir(feature), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(feature, []byte("Feature: sweep\n  Scenario: sweep\n    Then sweep\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return root, slug
}

func sweepPython(t *testing.T) string {
	t.Helper()
	p, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 is not available")
	}
	return p
}

func sweepPIDs(t *testing.T, file string, n int) []int {
	t.Helper()
	b, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	var pids []int
	for _, f := range strings.Fields(string(b)) {
		pid, _ := strconv.Atoi(f)
		pids = append(pids, pid)
	}
	if len(pids) != n {
		t.Fatalf("%s holds %q, want %d pids", file, b, n)
	}
	t.Cleanup(func() {
		for _, pid := range pids {
			syscall.Kill(pid, syscall.SIGKILL)
		}
	})
	return pids
}

// A process that dropped the marker but whose parent still carries it when the command ends is
// stopped with that parent.
func TestAcceptanceStopsMarkerlessChildOfMarkedProcess(t *testing.T) {
	python := sweepPython(t)
	root, slug := sweepRoot(t)
	pidFile := filepath.Join(root, "pids")
	// The child hangs under a marked parent that is itself in a new session.
	script := `import subprocess, sys
parent = subprocess.Popen([sys.executable, "-c", "import os, subprocess, sys, time\nenv = dict(os.environ)\nenv.pop('KOGEN_ACCEPTANCE_RUN')\nc = subprocess.Popen(['sleep', '300'], env=env, start_new_session=True)\nprint(c.pid, flush=True)\ntime.sleep(300)"], stdout=subprocess.PIPE, start_new_session=True)
child = int(parent.stdout.readline())
open(sys.argv[1], "w").write("%d %d" % (parent.pid, child))
`
	s := sys.NewWith(os.Environ(), root)
	command := python + " -c '" + strings.ReplaceAll(script, "'", `'\''`) + "' " + pidFile
	if _, err := RunAcceptance(context.Background(), s, root, Tools{}, slug, command, filepath.Join(root, "r.ndjson"), nil, nil); err != nil {
		t.Fatal(err)
	}
	for _, pid := range sweepPIDs(t, pidFile, 2) {
		if !sweepGoneSoon(pid) {
			t.Errorf("process %d is still running after the acceptance run", pid)
		}
	}
}

// A process carrying another run's value (an enclosing or concurrent run) is not touched.
func TestAcceptanceLeavesOtherRunsProcessesAlone(t *testing.T) {
	root, slug := sweepRoot(t)
	other := exec.Command("sleep", "300")
	other.Env = append(os.Environ(), acceptanceMarker+"=0123456789abcdef0123456789abcdef")
	other.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := other.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { other.Process.Kill(); other.Wait() }()
	s := sys.NewWith(os.Environ(), root)
	if _, err := RunAcceptance(context.Background(), s, root, Tools{}, slug, "exit 0", filepath.Join(root, "r.ndjson"), nil, nil); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	if !sweepAlive(other.Process.Pid) {
		t.Fatal("a process carrying another run's value was stopped")
	}
}

// Every run gets its own value, replacing one inherited from the caller.
func TestAcceptanceRunValueIsFreshPerRun(t *testing.T) {
	root, slug := sweepRoot(t)
	inherited := "inherited-by-an-enclosing-run"
	s := sys.NewWith(append(os.Environ(), acceptanceMarker+"="+inherited), root)
	var seen []string
	for i := 0; i < 2; i++ {
		out := filepath.Join(root, "value"+strconv.Itoa(i))
		if _, err := RunAcceptance(context.Background(), s, root, Tools{}, slug, `printf %s "$KOGEN_ACCEPTANCE_RUN" > '`+out+`'`, filepath.Join(root, "r.ndjson"), nil, nil); err != nil {
			t.Fatal(err)
		}
		b, err := os.ReadFile(out)
		if err != nil {
			t.Fatal(err)
		}
		seen = append(seen, string(b))
	}
	hex := regexp.MustCompile(`^[0-9a-f]{32,}$`)
	for _, v := range seen {
		if v == inherited || !hex.MatchString(v) {
			t.Fatalf("acceptance command saw %q, want a fresh lowercase hex value of at least 128 bits", v)
		}
	}
	if seen[0] == seen[1] {
		t.Fatalf("two runs saw the same value %q", seen[0])
	}
	if got, _ := s.LookupEnv(acceptanceMarker); got != inherited {
		t.Fatalf("the session environment changed to %q", got)
	}
}

package verify

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"slices"
	"syscall"
	"time"
)

// acceptanceMarker is the environment variable that names one acceptance run. Kogen adds it to
// the acceptance command with a fresh random value per run and never carries it itself.
const acceptanceMarker = "KOGEN_ACCEPTANCE_RUN"

// sweepGrace is how long a SIGTERMed process may take to leave before it gets SIGKILL; it
// matches the grace of sys.Terminate.
const sweepGrace = 5 * time.Second

func newAcceptanceRunID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// procEntry is one row of a process table snapshot.
type procEntry struct {
	pid, ppid, uid int
	zombie         bool
}

// acceptanceTargets selects, from one snapshot, the processes of the current user that carry
// the run's marker (marked) and every process that descends from one of them by parent pid.
// Kogen's own process (self), its ancestors, zombies and processes of other users are never
// selected. marked is asked only about processes that could be selected.
func acceptanceTargets(procs []procEntry, uid, self int, marked func(pid int) bool) []int {
	byPID := make(map[int]procEntry, len(procs))
	children := map[int][]int{}
	for _, p := range procs {
		byPID[p.pid] = p
		children[p.ppid] = append(children[p.ppid], p.pid)
	}
	protected := map[int]bool{self: true}
	for pid, hops := byPID[self].ppid, 0; pid > 0 && !protected[pid] && hops <= len(procs); hops++ {
		protected[pid] = true
		pid = byPID[pid].ppid
	}
	seen := map[int]bool{}
	var out []int
	var visit func(pid int)
	visit = func(pid int) {
		if seen[pid] {
			return
		}
		seen[pid] = true
		p := byPID[pid]
		if !protected[pid] && !p.zombie && p.uid == uid {
			out = append(out, pid)
		}
		for _, c := range children[pid] {
			if !protected[c] {
				visit(c)
			}
		}
	}
	for _, p := range procs {
		if protected[p.pid] || p.zombie || p.uid != uid || seen[p.pid] {
			continue
		}
		if marked(p.pid) {
			visit(p.pid)
		}
	}
	slices.Sort(out)
	return out
}

// stopAcceptanceProcesses stops every process the acceptance run with this value started:
// SIGTERM to the processes carrying it and their descendants, SIGKILL to those still present
// after the grace, then SIGKILL for any newly matching process until a snapshot finds none. A
// process table that cannot be read ends the sweep without an error for the run; it is
// returned only so the caller can log it.
func stopAcceptanceProcesses(value string) error {
	uid, self := os.Getuid(), os.Getpid()
	marker := acceptanceMarker + "=" + value
	snapshot := func() ([]int, error) {
		procs, err := listProcs()
		if err != nil {
			return nil, err
		}
		return acceptanceTargets(procs, uid, self, func(pid int) bool { return procMarked(pid, marker) }), nil
	}
	targets, err := snapshot()
	if err != nil || len(targets) == 0 {
		return err
	}
	// A process that cannot be signaled (it changed identity) is not waited for again.
	refused := map[int]bool{}
	signal := func(pids []int, sig syscall.Signal) {
		for _, pid := range pids {
			if err := syscall.Kill(pid, sig); err == syscall.EPERM {
				refused[pid] = true
			}
		}
	}
	signal(targets, syscall.SIGTERM)
	for deadline := time.Now().Add(sweepGrace); time.Now().Before(deadline); time.Sleep(50 * time.Millisecond) {
		if len(present(targets, refused)) == 0 {
			break
		}
	}
	signal(present(targets, refused), syscall.SIGKILL)
	for {
		targets, err = snapshot()
		if err != nil {
			return err
		}
		targets = slices.DeleteFunc(targets, func(pid int) bool { return refused[pid] })
		if len(targets) == 0 {
			return nil
		}
		signal(targets, syscall.SIGKILL)
		time.Sleep(50 * time.Millisecond)
	}
}

// present returns those of pids that are still running (a zombie counts as gone).
func present(pids []int, skip map[int]bool) []int {
	procs, err := listProcs()
	if err != nil {
		return nil
	}
	running := map[int]bool{}
	for _, p := range procs {
		if !p.zombie {
			running[p.pid] = true
		}
	}
	var out []int
	for _, pid := range pids {
		if running[pid] && !skip[pid] {
			out = append(out, pid)
		}
	}
	return out
}

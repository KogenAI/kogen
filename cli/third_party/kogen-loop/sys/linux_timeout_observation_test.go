package sys

import (
	"errors"
	"fmt"
	"io/fs"
	"syscall"
	"testing"
	"testing/fstest"
)

// lobProc serves stat files from a map and injects read errors per entry.
type lobProc struct {
	stats   map[string]string
	faults  map[string]error
	listing error
}

func (p lobProc) Open(name string) (fs.File, error) { return nil, syscall.ENOSYS }

func (p lobProc) ReadDir(string) ([]fs.DirEntry, error) {
	if p.listing != nil {
		return nil, p.listing
	}
	m := fstest.MapFS{"self/stat": {}, "cpuinfo": {}}
	for n := range p.stats {
		m[n+"/stat"] = &fstest.MapFile{}
	}
	for n := range p.faults {
		m[n+"/stat"] = &fstest.MapFile{}
	}
	return fs.ReadDir(m, ".")
}

func (p lobProc) ReadFile(name string) ([]byte, error) {
	entry := name[:len(name)-len("/stat")]
	if err := p.faults[entry]; err != nil {
		return nil, &fs.PathError{Op: "read", Path: name, Err: err}
	}
	if s, ok := p.stats[entry]; ok {
		return []byte(s), nil
	}
	return nil, fs.ErrNotExist
}

func lobStat(group int) string { return fmt.Sprintf("123 (a b) (c) Z 1 %d 0", group) }

// lobSyntheticGroup is only passed to injected kill probes, never to the OS.
const lobSyntheticGroup = 4242

func lobKill(result error) func(pid, sig int) error {
	return func(pid, sig int) error {
		if pid != -lobSyntheticGroup || sig != 0 {
			return fmt.Errorf("unexpected probe kill(%d, %d)", pid, sig)
		}
		return result
	}
}

func TestLinuxTimeoutObservationDecisions(t *testing.T) {
	gone := lobSyntheticGroup
	cases := []struct {
		name  string
		kill  error
		proc  lobProc
		alive bool
		errno error
		fail  bool
	}{
		{name: "kill EPERM reused pgid", kill: syscall.EPERM, proc: lobProc{faults: map[string]error{"10": syscall.EACCES}, listing: syscall.EMFILE}, alive: true},
		{name: "kill success", kill: nil, proc: lobProc{faults: map[string]error{"10": syscall.EACCES}, listing: syscall.EMFILE}, alive: true},
		{name: "kill ESRCH absent", kill: syscall.ESRCH, proc: lobProc{}},
		{name: "zombie member after ESRCH", kill: syscall.ESRCH, proc: lobProc{stats: map[string]string{"10": lobStat(gone)}}, alive: true},
		{name: "vanished entries", kill: syscall.ESRCH, proc: lobProc{stats: map[string]string{"20": lobStat(gone + 1)}, faults: map[string]error{"10": syscall.ENOENT, "11": syscall.ESRCH}}},
		{name: "unreadable EPERM", kill: syscall.ESRCH, proc: lobProc{faults: map[string]error{"10": syscall.EPERM}}, errno: syscall.EPERM},
		{name: "unreadable EACCES", kill: syscall.ESRCH, proc: lobProc{faults: map[string]error{"10": syscall.EACCES}}, errno: syscall.EACCES},
		{name: "member beats earlier error", kill: syscall.ESRCH, proc: lobProc{faults: map[string]error{"10": syscall.EPERM}, stats: map[string]string{"20": lobStat(gone)}}, alive: true},
		{name: "malformed", kill: syscall.ESRCH, proc: lobProc{stats: map[string]string{"10": "broken"}}, fail: true},
		{name: "short", kill: syscall.ESRCH, proc: lobProc{stats: map[string]string{"10": "1 (x) Z 1"}}, fail: true},
		{name: "listing", kill: syscall.ESRCH, proc: lobProc{listing: syscall.EMFILE}, errno: syscall.EMFILE},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			alive, err := linuxTimeoutGroupAliveWith(gone, c.proc, lobKill(c.kill))
			if alive != c.alive {
				t.Fatalf("alive=%v want %v (err %v)", alive, c.alive, err)
			}
			switch {
			case c.errno != nil:
				if !errors.Is(err, c.errno) {
					t.Fatalf("err=%v want %v", err, c.errno)
				}
			case c.fail:
				if err == nil {
					t.Fatal("expected observation error")
				}
			case err != nil:
				t.Fatal(err)
			}
		})
	}
}

func TestLinuxTimeoutObservationGuard(t *testing.T) {
	for _, pgid := range []int{1, 0, -1} {
		if alive, err := linuxTimeoutGroupAlive(pgid, lobProc{}); alive || err == nil {
			t.Fatalf("pgid %d: %v %v", pgid, alive, err)
		}
	}
}

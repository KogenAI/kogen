package sys

import (
	"errors"
	"fmt"
	"io/fs"
	"os/exec"
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

// lobGoneGroup returns a process group id that this test allocated and reaped.
func lobGoneGroup(t *testing.T) int {
	t.Helper()
	c := exec.Command("/bin/sh", "-c", "exit 0")
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := c.Run(); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Kill(-c.Process.Pid, 0); !errors.Is(err, syscall.ESRCH) {
		t.Fatalf("reaped group still visible: %v", err)
	}
	return c.Process.Pid
}

func TestLinuxTimeoutObservationDecisions(t *testing.T) {
	gone := lobGoneGroup(t)
	cases := []struct {
		name  string
		proc  lobProc
		alive bool
		errno error
		fail  bool
	}{
		{name: "zombie member after ESRCH", proc: lobProc{stats: map[string]string{"10": lobStat(gone)}}, alive: true},
		{name: "vanished entries", proc: lobProc{stats: map[string]string{"20": lobStat(gone + 1)}, faults: map[string]error{"10": syscall.ENOENT, "11": syscall.ESRCH}}},
		{name: "unreadable EPERM", proc: lobProc{faults: map[string]error{"10": syscall.EPERM}}, errno: syscall.EPERM},
		{name: "unreadable EACCES", proc: lobProc{faults: map[string]error{"10": syscall.EACCES}}, errno: syscall.EACCES},
		{name: "member beats earlier error", proc: lobProc{faults: map[string]error{"10": syscall.EPERM}, stats: map[string]string{"20": lobStat(gone)}}, alive: true},
		{name: "malformed", proc: lobProc{stats: map[string]string{"10": "broken"}}, fail: true},
		{name: "short", proc: lobProc{stats: map[string]string{"10": "1 (x) Z 1"}}, fail: true},
		{name: "listing", proc: lobProc{listing: syscall.EMFILE}, errno: syscall.EMFILE},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			alive, err := linuxTimeoutGroupAlive(gone, c.proc)
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

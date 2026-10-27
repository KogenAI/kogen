package sys

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Timeout feedback must observe individual disappearance, not just a vanished
// process group (which can exclude still-observable zombies on Darwin).
func TestCallerShellBoundCustody(t *testing.T) {
	for _, mode := range []string{"exits", "ignores"} {
		t.Run(mode, func(t *testing.T) {
			s := session(t)
			readyPath := filepath.Join(s.Cwd, "ready")
			if err := syscall.Mkfifo(readyPath, 0600); err != nil {
				t.Fatal(err)
			}
			ready, err := os.OpenFile(readyPath, os.O_RDWR, 0600)
			if err != nil {
				t.Fatal(err)
			}
			defer ready.Close()
			events := make(chan bool, 1)
			go func() { events <- bufio.NewScanner(ready).Scan() }()
			t.Cleanup(func() { Terminate(s.Groups()) })
			trap := `trap 'exit 0' TERM; `
			if mode == "ignores" {
				trap = `trap '' TERM; `
			}
			command := trap + `echo $$ > leader; printf 'partial\n'; sh -c 'trap "" TERM; echo $$ > child; sleep 600 & echo $! > grandchild; echo ready > ready; wait' & wait`
			type outcome struct {
				result Result
				err    error
			}
			done := make(chan outcome, 1)
			go func() { r, err := s.Run(command, s.Cwd, Options{Timeout: time.Second}); done <- outcome{r, err} }()
			select {
			case ok := <-events:
				if !ok {
					t.Fatal("readiness stream ended")
				}
			case <-time.After(10 * time.Second):
				t.Fatal("no readiness event")
			}
			var pids []int
			for _, name := range []string{"leader", "child", "grandchild"} {
				b, err := os.ReadFile(filepath.Join(s.Cwd, name))
				if err != nil {
					t.Fatal(err)
				}
				pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
				if err != nil {
					t.Fatal(err)
				}
				pids = append(pids, pid)
			}
			var got outcome
			select {
			case got = <-done:
			case <-time.After(15 * time.Second):
				t.Fatal("timeout did not finish custody")
			}
			wantStatus := 0
			if mode == "ignores" {
				wantStatus = 137
			}
			if got.err != nil || !got.result.TimedOut || got.result.Status != wantStatus || got.result.Output != "partial\n" {
				t.Fatalf("Run = %+v, %v", got.result, got.err)
			}
			for _, pid := range pids {
				if err := syscall.Kill(pid, 0); err != syscall.ESRCH {
					t.Errorf("PID %d observable at feedback: %v", pid, err)
				}
			}
		})
	}
}

package sys

import (
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

// lifelineArg is the hidden first argument with which a supervisor, whose command has
// ended but whose group still has members, leaves a small keeper behind. The keeper holds
// the lifeline until the caller retires the group or dies; only a death stops the group.
const lifelineArg = "__kogen_lifeline"

// lifelineRetired is the byte the caller writes to a lifeline before closing it on purpose.
// A lifeline that closes without it means the caller died.
const lifelineRetired = 'R'

// sweepEscalation is the bounded interval between SIGTERM and SIGKILL of every sweep.
const sweepEscalation = 5 * time.Second

// groupOthers reports whether the process group pgid has a live member other than self.
// Zombies are not members: nothing is left in them to stop. A failed observation is an
// error and callers treat it as presence.
func groupOthers(pgid, self int) (bool, error) {
	if data, err := os.ReadFile("/proc/self/stat"); err == nil && len(data) > 0 {
		return procGroupOthers(pgid, self)
	}
	out, err := exec.Command("ps", "-A", "-o", "pid=,pgid=,stat=").Output()
	if err != nil {
		return false, err
	}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 3 {
			continue
		}
		pid, e1 := strconv.Atoi(f[0])
		group, e2 := strconv.Atoi(f[1])
		if e1 == nil && e2 == nil && group == pgid && pid != self && !strings.HasPrefix(f[2], "Z") {
			return true, nil
		}
	}
	return false, nil
}

func procGroupOthers(pgid, self int) (bool, error) {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return false, err
	}
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid == self {
			continue
		}
		data, err := os.ReadFile("/proc/" + entry.Name() + "/stat")
		if err != nil {
			continue // the process ended while scanning
		}
		// state and pgrp follow the final ')' because comm may contain anything.
		end := strings.LastIndexByte(string(data), ')')
		if end < 0 {
			continue
		}
		f := strings.Fields(string(data[end+1:]))
		if len(f) < 3 || f[0] == "Z" {
			continue
		}
		if group, err := strconv.Atoi(f[2]); err == nil && group == pgid {
			return true, nil
		}
	}
	return false, nil
}

// sweepOwnGroup stops the whole process group of the caller: SIGTERM, a poll until no live
// member other than self is left (at most sweepEscalation), then SIGKILL. The final
// SIGKILL reaches self too, so nothing runs after it.
func sweepOwnGroup(pgid, self int) {
	syscall.Kill(-pgid, syscall.SIGTERM)
	for deadline := time.Now().Add(sweepEscalation); time.Now().Before(deadline); time.Sleep(100 * time.Millisecond) {
		if others, err := groupOthers(pgid, self); err == nil && !others {
			break
		}
	}
	syscall.Kill(-pgid, syscall.SIGKILL)
}

// leaveKeeper starts the keeper for a group whose leader (the supervisor) is about to exit.
func leaveKeeper(lifeline *os.File) {
	self, err := os.Executable()
	if err != nil {
		return
	}
	// Standard streams stay closed: the keeper must not hold the command's output open.
	cmd := exec.Command(self, lifelineArg)
	cmd.ExtraFiles = []*os.File{lifeline}
	if cmd.Start() == nil {
		cmd.Process.Release()
	}
}

// keeperMain is the keeper process. It leaves when the group has no other member, when
// the caller retires the group, or after stopping the group when the caller died.
func keeperMain() {
	signals := make(chan os.Signal, 4)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	var sweeping atomic.Bool
	go func() {
		for range signals {
			// A group stop from the caller (or the sweep's own SIGTERM) is not a reason to
			// linger: the keeper is a group member too.
			if !sweeping.Load() {
				os.Exit(0)
			}
		}
	}()
	pgid, self := syscall.Getpgrp(), os.Getpid()
	lifeline := os.NewFile(3, "lifeline")
	closed := make(chan bool, 1)
	go func() {
		n, _ := io.Copy(io.Discard, lifeline)
		closed <- n > 0
	}()
	tick := time.NewTicker(200 * time.Millisecond)
	for {
		if others, err := groupOthers(pgid, self); err == nil && !others {
			os.Exit(0)
		}
		select {
		case retired := <-closed:
			if !retired {
				sweeping.Store(true)
				sweepOwnGroup(pgid, self)
			}
			os.Exit(0)
		case <-tick.C:
		}
	}
}

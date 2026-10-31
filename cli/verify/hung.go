package verify

import (
	"fmt"
	"syscall"
	"time"

	"kogen-loop/sys"
)

// noLiveGrace is how long a command's process group may have no member while the command's
// result still has not arrived before Kogen stops waiting for it (a fixed value; only tests
// shorten it).
var noLiveGrace = time.Minute

// outcome is what the runner returned for one command.
type outcome struct {
	res sys.Result
	err error
}

// RunWatched runs one project command through run, which starts it on s and returns its
// result, and watches it. Commands that end normally return exactly run's result and error.
// A command whose process group has had no member for a minute while its result has not
// arrived is no longer waited for: the stop is environment/command_no_progress, the wait is
// abandoned, not joined. A live command is never stopped, however long it is silent.
func RunWatched(s *sys.Session, name, command string, l Logger, run func() (sys.Result, error)) (sys.Result, error) {
	before := groupSet(s)
	done := make(chan outcome, 1)
	go func() {
		res, err := run()
		done <- outcome{res, err}
	}()
	return awaitResult(s, before, name, command, l, done)
}

func groupSet(s *sys.Session) map[int]bool {
	set := map[int]bool{}
	for _, g := range s.Groups() {
		set[g] = true
	}
	return set
}

// awaitResult waits for the result of a command that was started after the session had the
// groups in before. The command's group is its new entry in the session's groups; it is
// checked at least once per second. Without a new group (the start failed, or a number was
// reused) the rule does not apply and the wait is for the result alone.
func awaitResult(s *sys.Session, before map[int]bool, name, command string, l Logger, result <-chan outcome) (sys.Result, error) {
	grace := noLiveGrace
	tick := time.NewTicker(max(5*time.Millisecond, min(time.Second, grace/4)))
	defer tick.Stop()
	pgid := 0
	var emptySince time.Time
	for {
		select {
		case o := <-result:
			return o.res, o.err
		case <-tick.C:
		}
		if pgid == 0 {
			for _, g := range s.Groups() {
				if !before[g] {
					pgid = g
					break
				}
			}
			if pgid == 0 {
				continue
			}
		}
		if syscall.Kill(-pgid, 0) != syscall.ESRCH {
			emptySince = time.Time{}
			continue
		}
		now := time.Now()
		if emptySince.IsZero() {
			emptySince = now
		}
		if now.Sub(emptySince) < grace {
			continue
		}
		// The result may have arrived while the last check ran.
		select {
		case o := <-result:
			return o.res, o.err
		default:
		}
		logEvent(l, map[string]any{"event": "command_no_progress", "name": name, "command": command,
			"rule": "no_live_process", "after_ms": grace.Milliseconds()})
		return sys.Result{}, sys.Fail("environment", "command_no_progress",
			fmt.Sprintf("%s had no live process for %s but its result never reached Kogen; stopped waiting for: %s", name, grace, command), 1)
	}
}

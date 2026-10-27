package sys

import (
	"os"
	"strconv"
	"strings"
	"testing"
)

func TestForeignKillTable(t *testing.T) {
	owned := func(pid int) bool { return pid == 4242 || pid == -4242 }
	refused := map[string]string{
		"pkill -f x":                  RulePkillKillall,
		"sudo pkill x":                RulePkillKillall,
		"/usr/bin/killall x":          RulePkillKillall,
		"echo a; pkill x":             RulePkillKillall,
		"nohup pkill x &":             RulePkillKillall,
		"env A=1 timeout 5 killall x": RulePkillKillall,
		"time exec pkill x":           RulePkillKillall,
		"true && (pkill x)":           RulePkillKillall,
		`echo "do not pkill"`:         RulePkillKillall,
		`echo 'unterminated; pkill x`: RulePkillKillall,
		`eval "pkill x"`:              RulePkillKillall,
		"echo $(pkill x)":             RulePkillKillall,
		"pgrep x | xargs kill":        RuleKillForeignPid,
		"ps aux | xargs -n1 kill -9":  RuleKillForeignPid,
		"kill $(pgrep x)":             RuleKillForeignPid,
		"kill -9 $(pidof beam.smp)":   RuleKillForeignPid,
		"kill `lsof -t -i :80`":       RuleKillForeignPid,
		"kill -9 -1":                  RuleKillForeignPid,
		"kill 0":                      RuleKillForeignPid,
		"kill 1234":                   RuleKillForeignPid,
		"/bin/kill -s TERM 1234":      RuleKillForeignPid,
		"kill -KILL -1234":            RuleKillForeignPid,
		"sleep 1 & kill $! 1234":      RuleKillForeignPid,
		"sudo kill -TERM 77":          RuleKillForeignPid,
	}
	for cmd, want := range refused {
		if rule, ok := ForeignKill(cmd, owned); !ok || rule != want {
			t.Errorf("%q: rule %q refused %v, want %q", cmd, rule, ok, want)
		}
	}
	allowed := []string{
		"", "grep -n pkill file", "kill $!", "kill %1", "PID=$!; kill $PID", "pgrep -f x", "ps aux",
		"pkillall", "mypkill.sh", "kill 4242", "kill -9 4242", "kill -9 -4242", "kill -l",
		"sleep 9 & echo $! > f; kill $(cat f)", "kill $UNKNOWN", "ls | wc -l", "echo hi", "echo $(date)",
		"echo $! | xargs kill",
	}
	for _, cmd := range allowed {
		if rule, ok := ForeignKill(cmd, owned); ok {
			t.Errorf("%q refused with %q", cmd, rule)
		}
	}
	if !strings.Contains(RefusalText(RulePkillKillall), "(rule: no pkill or killall; kill only pids this run created)") ||
		!strings.Contains(RefusalText(RuleKillForeignPid), "(rule: kill only pids this run created)") {
		t.Error("refusal text")
	}
}

func TestSessionOwnedAndRefusal(t *testing.T) {
	dir := t.TempDir()
	s := NewWith(os.Environ(), dir)
	t.Cleanup(func() { Terminate(s.Groups()) })
	if _, err := s.Run("sleep 600 >/dev/null 2>&1 & echo $! > c.pid; sh -c 'sleep 601 >/dev/null 2>&1 & echo $! > d.pid'", dir, Options{}); err != nil {
		t.Fatal(err)
	}
	read := func(f string) int {
		b, err := os.ReadFile(dir + "/" + f)
		if err != nil {
			t.Fatal(err)
		}
		n, _ := strconv.Atoi(strings.TrimSpace(string(b)))
		return n
	}
	child, desc, g := read("c.pid"), read("d.pid"), s.Groups()[0]
	for _, id := range []int{child, desc, g, -g} {
		if !s.Owned(id) {
			t.Errorf("Owned(%d) false", id)
		}
	}
	if s.Owned(os.Getpid()) || s.Owned(1) || s.Owned(0) {
		t.Error("unrelated pid owned")
	}
	n := len(s.Groups())
	res, err := s.Run("pkill -f nothing-at-all", dir, Options{RefuseForeignKill: true})
	if err != nil || res.Status != 126 || res.Rule != RulePkillKillall || res.TimedOut || res.Output != RefusalText(RulePkillKillall) || len(s.Groups()) != n {
		t.Errorf("refusal: %+v %v groups %d", res, err, len(s.Groups()))
	}
	res, err = s.Run("kill "+strconv.Itoa(child), dir, Options{RefuseForeignKill: true})
	if err != nil || res.Status != 0 || res.Rule != "" {
		t.Errorf("own kill: %+v %v", res, err)
	}
}

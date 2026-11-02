//go:build linux

package verify

import (
	"bytes"
	"os"
	"strconv"
	"syscall"
)

// listProcs reads the process table from /proc/<pid>/stat (parent pid, state) and the owner
// of /proc/<pid>.
func listProcs() ([]procEntry, error) {
	dirs, err := os.ReadDir("/proc")
	if err != nil {
		return nil, err
	}
	var out []procEntry
	for _, d := range dirs {
		pid, err := strconv.Atoi(d.Name())
		if err != nil {
			continue
		}
		stat, err := os.ReadFile("/proc/" + d.Name() + "/stat")
		if err != nil {
			continue // gone since the listing
		}
		// pid (comm) state ppid ...; comm may hold spaces and parentheses.
		i := bytes.LastIndexByte(stat, ')')
		if i < 0 {
			continue
		}
		fields := bytes.Fields(stat[i+1:])
		if len(fields) < 2 {
			continue
		}
		ppid, err := strconv.Atoi(string(fields[1]))
		if err != nil {
			continue
		}
		info, err := os.Stat("/proc/" + d.Name())
		if err != nil {
			continue
		}
		st, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			continue
		}
		state := string(fields[0])
		out = append(out, procEntry{pid: pid, ppid: ppid, uid: int(st.Uid), zombie: state == "Z" || state == "X"})
	}
	return out, nil
}

// procMarked reports whether pid's initial environment holds exactly entry. An environment
// that cannot be read does not match.
func procMarked(pid int, entry string) bool {
	env, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/environ")
	if err != nil {
		return false
	}
	want := []byte(entry)
	for _, kv := range bytes.Split(env, []byte{0}) {
		if bytes.Equal(kv, want) {
			return true
		}
	}
	return false
}

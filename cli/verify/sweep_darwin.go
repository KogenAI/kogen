//go:build darwin

package verify

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

// listProcs reads the process table with /bin/ps.
func listProcs() ([]procEntry, error) {
	out, err := exec.Command("/bin/ps", "-axo", "pid=,ppid=,uid=,stat=").Output()
	if err != nil {
		return nil, err
	}
	var procs []procEntry
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 4 {
			continue
		}
		pid, e1 := strconv.Atoi(f[0])
		ppid, e2 := strconv.Atoi(f[1])
		uid, e3 := strconv.Atoi(f[2])
		if e1 != nil || e2 != nil || e3 != nil {
			continue
		}
		procs = append(procs, procEntry{pid: pid, ppid: ppid, uid: uid, zombie: strings.HasPrefix(f[3], "Z")})
	}
	if len(procs) == 0 {
		return nil, fmt.Errorf("empty process table")
	}
	return procs, nil
}

// procargs2 returns the raw kern.procargs2 data of pid.
func procargs2(pid int) ([]byte, error) {
	mib := [3]int32{1 /* CTL_KERN */, 49 /* KERN_PROCARGS2 */, int32(pid)}
	query := func(data unsafe.Pointer, size *uintptr) error {
		_, _, errno := syscall.Syscall6(syscall.SYS___SYSCTL, uintptr(unsafe.Pointer(&mib[0])), 3, uintptr(data), uintptr(unsafe.Pointer(size)), 0, 0)
		if errno != 0 {
			return errno
		}
		return nil
	}
	var size uintptr
	if err := query(nil, &size); err != nil {
		return nil, err
	}
	for try := 0; try < 3; try++ {
		buf := make([]byte, size+4096)
		n := uintptr(len(buf))
		err := query(unsafe.Pointer(&buf[0]), &n)
		if err == nil {
			return buf[:n], nil
		}
		if err != syscall.ENOMEM {
			return nil, err
		}
		size = uintptr(len(buf)) * 2
	}
	return nil, syscall.ENOMEM
}

// procMarked reports whether pid's environment (kern.procargs2) holds exactly entry. An
// environment that cannot be read does not match.
func procMarked(pid int, entry string) bool {
	data, err := procargs2(pid)
	if err != nil || len(data) < 4 {
		return false
	}
	argc := int(int32(binary.LittleEndian.Uint32(data)))
	rest := data[4:]
	// The executable path, its padding NULs, then argc arguments, then the environment.
	i := bytes.IndexByte(rest, 0)
	if i < 0 {
		return false
	}
	rest = bytes.TrimLeft(rest[i:], "\x00")
	for ; argc > 0; argc-- {
		i := bytes.IndexByte(rest, 0)
		if i < 0 {
			return false
		}
		rest = rest[i+1:]
	}
	want := []byte(entry)
	for _, kv := range bytes.Split(rest, []byte{0}) {
		if bytes.Equal(kv, want) {
			return true
		}
	}
	return false
}

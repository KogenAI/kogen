//go:build darwin

package sys

import (
	"encoding/binary"
	"fmt"
	"syscall"
	"unsafe"
)

// kinfoProcSize is sizeof(struct kinfo_proc) on darwin arm64 and amd64. kp_proc.p_stat is
// the byte at kinfoStatOffset and kp_proc.p_pid the little-endian int32 at kinfoPidOffset.
const (
	kinfoProcSize   = 648
	kinfoStatOffset = 36
	kinfoPidOffset  = 40
	procZombie      = 5 // SZOMB
)

// groupRecords returns the kernel's kinfo_proc records for the process group pgid,
// unreaped zombies included. Size queries reserve slack; only the length reported by a
// successful data query is the answer.
func groupRecords(pgid int) ([]byte, error) {
	mib := [4]int32{1, 14, 2, int32(pgid)}
	var size uintptr
	query := func(data unsafe.Pointer) error {
		_, _, errno := syscall.Syscall6(syscall.SYS___SYSCTL, uintptr(unsafe.Pointer(&mib[0])), 4, uintptr(data), uintptr(unsafe.Pointer(&size)), 0, 0)
		if errno != 0 {
			return errno
		}
		return nil
	}
	if err := query(nil); err != nil {
		return nil, err
	}
	// Always perform a data query, even if the size query reported zero.
	data := make([]byte, max(size, 1))
	size = uintptr(len(data))
	if err := query(unsafe.Pointer(&data[0])); err != nil {
		return nil, err
	}
	if size > uintptr(len(data)) {
		return nil, fmt.Errorf("truncated group query")
	}
	return data[:size], nil
}

// kernelGroupOthers is groupOthers over the kernel's group records. A failed query is an
// error, never absence.
func kernelGroupOthers(pgid, self int, records func(pgid int) ([]byte, error)) (bool, error) {
	data, err := records(pgid)
	if err != nil {
		return false, err
	}
	if len(data)%kinfoProcSize != 0 {
		return false, fmt.Errorf("group query returned %d bytes, not whole records", len(data))
	}
	for off := 0; off < len(data); off += kinfoProcSize {
		rec := data[off : off+kinfoProcSize]
		pid := int(int32(binary.LittleEndian.Uint32(rec[kinfoPidOffset:])))
		if pid != self && rec[kinfoStatOffset] != procZombie {
			return true, nil
		}
	}
	return false, nil
}

// platformGroupOthers answers from the kernel without reading /proc or starting a process.
func platformGroupOthers(pgid, self int) (others, handled bool, err error) {
	others, err = kernelGroupOthers(pgid, self, groupRecords)
	return others, true, err
}

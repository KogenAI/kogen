//go:build darwin

package sys

import (
	"fmt"
	"syscall"
	"unsafe"
)

// The numeric group query includes unreaped zombies. Size queries reserve slack;
// only the actual length from a successful data query proves absence.
func timeoutGroupAlive(pgid int) (bool, error) {
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
		return false, err
	}
	// Always perform a data query, even if the size query reported zero.
	data := make([]byte, max(size, 1))
	size = uintptr(len(data))
	if err := query(unsafe.Pointer(&data[0])); err != nil {
		return false, err
	}
	if size > uintptr(len(data)) {
		return false, fmt.Errorf("truncated group query")
	}
	return size != 0, nil
}

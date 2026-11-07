package provider

import (
	"os"
	"syscall"
	"unsafe"
)

// isTerminal reports whether f is a terminal: the terminal driver answers TIOCGETA. A
// character device that is no terminal (/dev/null) does not.
func isTerminal(f *os.File) bool {
	var t syscall.Termios
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), syscall.TIOCGETA, uintptr(unsafe.Pointer(&t)))
	return errno == 0
}

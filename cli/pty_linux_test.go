//go:build linux

package main

import (
	"fmt"
	"os"
	"syscall"
	"time"
	"unsafe"
)

func ioctl(fd int, request, arg uintptr) error {
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), request, arg); errno != 0 {
		return errno
	}
	return nil
}

// openPTY returns a pseudo-terminal master descriptor and its slave, from /dev/ptmx through
// TIOCSPTLCK and TIOCGPTN, opening /dev/pts/N.
func openPTY() (int, *os.File, error) {
	master, err := syscall.Open("/dev/ptmx", syscall.O_RDWR|syscall.O_NOCTTY|syscall.O_CLOEXEC, 0)
	if err != nil {
		return -1, nil, err
	}
	var unlock int32
	if err := ioctl(master, syscall.TIOCSPTLCK, uintptr(unsafe.Pointer(&unlock))); err != nil {
		syscall.Close(master)
		return -1, nil, fmt.Errorf("TIOCSPTLCK: %v", err)
	}
	var number uint32
	if err := ioctl(master, syscall.TIOCGPTN, uintptr(unsafe.Pointer(&number))); err != nil {
		syscall.Close(master)
		return -1, nil, fmt.Errorf("TIOCGPTN: %v", err)
	}
	path := fmt.Sprintf("/dev/pts/%d", number)
	slave, err := syscall.Open(path, syscall.O_RDWR|syscall.O_NOCTTY|syscall.O_CLOEXEC, 0)
	if err != nil {
		syscall.Close(master)
		return -1, nil, err
	}
	return master, os.NewFile(uintptr(slave), path), nil
}

func getTermios(f *os.File) (syscall.Termios, error) {
	var t syscall.Termios
	err := ioctl(int(f.Fd()), syscall.TCGETS, uintptr(unsafe.Pointer(&t)))
	return t, err
}

func setTermios(f *os.File, t syscall.Termios) error {
	return ioctl(int(f.Fd()), syscall.TCSETS, uintptr(unsafe.Pointer(&t)))
}

// readable reports whether fd has data to read within d.
func readable(fd int, d time.Duration) bool {
	var set syscall.FdSet
	bits := int(unsafe.Sizeof(set.Bits[0])) * 8
	set.Bits[fd/bits] |= 1 << (uint(fd) % uint(bits))
	timeout := syscall.NsecToTimeval(int64(d))
	n, err := syscall.Select(fd+1, &set, nil, nil, &timeout)
	return err == nil && n > 0
}

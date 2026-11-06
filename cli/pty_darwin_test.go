//go:build darwin

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
// TIOCPTYGRANT, TIOCPTYUNLK and TIOCPTYGNAME.
func openPTY() (int, *os.File, error) {
	master, err := syscall.Open("/dev/ptmx", syscall.O_RDWR|syscall.O_NOCTTY|syscall.O_CLOEXEC, 0)
	if err != nil {
		return -1, nil, err
	}
	if err := ioctl(master, syscall.TIOCPTYGRANT, 0); err != nil {
		syscall.Close(master)
		return -1, nil, fmt.Errorf("TIOCPTYGRANT: %v", err)
	}
	if err := ioctl(master, syscall.TIOCPTYUNLK, 0); err != nil {
		syscall.Close(master)
		return -1, nil, fmt.Errorf("TIOCPTYUNLK: %v", err)
	}
	var name [128]byte
	if err := ioctl(master, syscall.TIOCPTYGNAME, uintptr(unsafe.Pointer(&name[0]))); err != nil {
		syscall.Close(master)
		return -1, nil, fmt.Errorf("TIOCPTYGNAME: %v", err)
	}
	path := string(name[:])
	for i, c := range name {
		if c == 0 {
			path = string(name[:i])
			break
		}
	}
	slave, err := syscall.Open(path, syscall.O_RDWR|syscall.O_NOCTTY|syscall.O_CLOEXEC, 0)
	if err != nil {
		syscall.Close(master)
		return -1, nil, err
	}
	return master, os.NewFile(uintptr(slave), path), nil
}

func getTermios(f *os.File) (syscall.Termios, error) {
	var t syscall.Termios
	err := ioctl(int(f.Fd()), syscall.TIOCGETA, uintptr(unsafe.Pointer(&t)))
	return t, err
}

func setTermios(f *os.File, t syscall.Termios) error {
	return ioctl(int(f.Fd()), syscall.TIOCSETA, uintptr(unsafe.Pointer(&t)))
}

// readable reports whether fd has data to read within d.
func readable(fd int, d time.Duration) bool {
	var set syscall.FdSet
	bits := int(unsafe.Sizeof(set.Bits[0])) * 8
	set.Bits[fd/bits] |= 1 << (uint(fd) % uint(bits))
	timeout := syscall.NsecToTimeval(int64(d))
	return syscall.Select(fd+1, &set, nil, nil, &timeout) == nil && set.Bits[fd/bits]&(1<<(uint(fd)%uint(bits))) != 0
}

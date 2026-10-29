package sys

import (
	"errors"
	"fmt"
	"io/fs"
	"strconv"
	"strings"
	"syscall"
)

// linuxTimeoutGroupAlive decides group membership. A successful or EPERM
// kill(-pgid, 0) is a monotone presence witness. ESRCH never proves absence on
// its own: it only licenses a zombie-inclusive scan of proc, and absence requires
// that scan to complete without any remembered error. A membership witness wins
// over remembered errors.
func linuxTimeoutGroupAlive(pgid int, proc fs.FS) (bool, error) {
	return linuxTimeoutGroupAliveWith(pgid, proc, func(pid, sig int) error { return syscall.Kill(pid, syscall.Signal(sig)) })
}

// linuxTimeoutGroupAliveWith is linuxTimeoutGroupAlive with the kill syscall
// supplied by the caller.
func linuxTimeoutGroupAliveWith(pgid int, proc fs.FS, kill func(pid, sig int) error) (bool, error) {
	if pgid <= 1 {
		return false, fmt.Errorf("invalid process group %d", pgid)
	}
	err := kill(-pgid, 0)
	if err == nil || errors.Is(err, syscall.EPERM) {
		return true, nil
	}
	if !errors.Is(err, syscall.ESRCH) {
		return false, err
	}
	entries, err := fs.ReadDir(proc, ".")
	if err != nil {
		return false, err
	}
	var remembered error
	for _, entry := range entries {
		if _, err := strconv.Atoi(entry.Name()); err != nil {
			continue
		}
		data, err := fs.ReadFile(proc, entry.Name()+"/stat")
		if err != nil {
			if errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ESRCH) || errors.Is(err, fs.ErrNotExist) {
				continue
			}
			remembered = err
			continue
		}
		// comm may contain spaces and parentheses; state, ppid, pgrp follow the
		// final ')'. Zombie state Z counts as membership.
		end := strings.LastIndexByte(string(data), ')')
		if end < 0 {
			remembered = fmt.Errorf("invalid proc stat")
			continue
		}
		fields := strings.Fields(string(data[end+1:]))
		if len(fields) < 3 {
			remembered = fmt.Errorf("short proc stat")
			continue
		}
		group, err := strconv.Atoi(fields[2])
		if err != nil {
			remembered = err
			continue
		}
		if group == pgid {
			return true, nil
		}
	}
	return false, remembered
}

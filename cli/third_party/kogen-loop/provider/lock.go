package provider

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// Locker takes the exclusive lock files Kogen uses for credentials (and builds). A lock
// is a nonempty directory published atomically with a unique owner file that holds the
// owner's PID; recovery removes only the observed owner's file, so rmdir can never
// remove a new owner's nonempty directory. Old PID-file locks stay readable and are
// replaced when their owner is gone.
type Locker struct {
	// PID is written into lock files; 0 means this process.
	PID int
	// Alive reports whether a process exists; nil uses signal 0.
	Alive func(pid int) bool
}

// Lock is a held lock. Only the holder's Release removes it.
type Lock struct {
	path, token string
	// Stale is the PID of a dead owner whose lock was removed to take this one ("" if none).
	Stale string
}

// HeldError is returned by Acquire while a live process owns the lock.
type HeldError struct{ PID string }

func (e *HeldError) Error() string { return "lock held by process " + e.PID }

// Acquire takes the lock at path, or returns *HeldError when a live owner has it.
func (l Locker) Acquire(path string) (*Lock, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o777); err != nil {
		return nil, err
	}
	raw := make([]byte, 12)
	rand.Read(raw)
	token := hex.EncodeToString(raw)
	tmp := path + "." + token
	if err := os.Mkdir(tmp, 0o777); err != nil {
		return nil, err
	}
	pid := l.PID
	if pid == 0 {
		pid = os.Getpid()
	}
	defer func() {
		os.Remove(filepath.Join(tmp, token))
		os.Remove(tmp)
	}()
	if err := os.WriteFile(filepath.Join(tmp, token), []byte(strconv.Itoa(pid)+"\n"), 0o666); err != nil {
		return nil, err
	}
	stale := ""
	for {
		err := os.Rename(tmp, path)
		if err == nil {
			return &Lock{path: path, token: token, Stale: stale}, nil
		}
		if !contention(err) {
			return nil, fmt.Errorf("acquire lock %s: %w", path, err)
		}
		file, owner, retry, err := l.owner(path)
		if err != nil {
			return nil, err
		}
		if retry {
			continue
		}
		if l.alive(owner) {
			return nil, &HeldError{PID: owner}
		}
		// Never recursively delete: another contender may already have acquired it.
		os.Remove(file)
		os.Remove(path)
		stale = owner
	}
}

func contention(err error) bool {
	return errors.Is(err, syscall.EEXIST) || errors.Is(err, syscall.ENOTEMPTY) || errors.Is(err, syscall.ENOTDIR) || errors.Is(err, syscall.EISDIR)
}

// owner finds the owner file of the lock at path and its PID. retry means the lock
// changed while it was read.
func (l Locker) owner(path string) (file, pid string, retry bool, err error) {
	entries, err := os.ReadDir(path)
	switch {
	case err == nil && len(entries) == 1:
		return readOwner(filepath.Join(path, entries[0].Name()))
	case err == nil && len(entries) == 0:
		return "", "", true, nil
	case err == nil:
		// Several owner files: not a state Kogen publishes; treat as held by an unknown owner.
		return "", "?", false, nil
	case errors.Is(err, syscall.ENOTDIR):
		return readOwner(path)
	case errors.Is(err, fs.ErrNotExist):
		return "", "", true, nil
	}
	return "", "", false, fmt.Errorf("read lock %s: %w", path, err)
}

func readOwner(file string) (string, string, bool, error) {
	data, err := os.ReadFile(file)
	if err == nil {
		return file, strings.TrimSpace(string(data)), false, nil
	}
	if errors.Is(err, fs.ErrNotExist) || errors.Is(err, syscall.ENOTDIR) || errors.Is(err, syscall.EISDIR) {
		return "", "", true, nil
	}
	return "", "", false, fmt.Errorf("read lock %s: %w", file, err)
}

func (l Locker) alive(owner string) bool {
	pid, err := strconv.Atoi(owner)
	if err != nil || pid <= 0 {
		return false
	}
	if l.Alive != nil {
		return l.Alive(pid)
	}
	err = syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// Held observes the lock at path without taking or recovering it.
func (l Locker) Held(path string) bool {
	file, owner, retry, err := l.owner(path)
	_ = file
	return err == nil && !retry && l.alive(owner)
}

// Release removes the lock if this handle still owns it; a repeated Release, or one after
// someone else acquired the path, changes nothing.
func (k *Lock) Release() {
	if k == nil || k.token == "" {
		return
	}
	os.Remove(filepath.Join(k.path, k.token))
	os.Remove(k.path)
	k.token = ""
}

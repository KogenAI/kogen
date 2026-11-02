//go:build !linux && !darwin

package verify

import "errors"

// Acceptance processes can be attributed on Linux and macOS only.
func listProcs() ([]procEntry, error) {
	return nil, errors.New("process table unsupported on this platform")
}

func procMarked(pid int, entry string) bool { return false }

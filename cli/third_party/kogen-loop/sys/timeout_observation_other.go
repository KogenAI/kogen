//go:build !darwin && !linux

package sys

import "errors"

func timeoutGroupAlive(pgid int) (bool, error) {
	return false, errors.New("native timeout custody observation unsupported on this platform")
}

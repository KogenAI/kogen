//go:build !darwin

package sys

// platformGroupOthers has no kernel group query here: groupOthers uses /proc or ps.
func platformGroupOthers(pgid, self int) (others, handled bool, err error) {
	return false, false, nil
}

//go:build linux

package sys

import "os"

func timeoutGroupAlive(pgid int) (bool, error) {
	return linuxTimeoutGroupAlive(pgid, os.DirFS("/proc"))
}

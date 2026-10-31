// Package durable is the one place Kogen flushes a file to stable storage. Test binaries may
// switch the flush off; the kogen program never does.
package durable

import (
	"os"
	"sync/atomic"
)

var skip atomic.Bool

// Sync returns f.Sync(), and returns nil without calling it once SkipSyncInTests was called.
func Sync(f *os.File) error {
	if skip.Load() {
		return nil
	}
	return f.Sync()
}

// SkipSyncInTests switches syncing off for the rest of the process. Only Go test files call it.
func SkipSyncInTests() {
	skip.Store(true)
}

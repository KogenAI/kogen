//go:build !linux && !darwin

package provider

import "os"

// isTerminal reports whether f is a character device; this platform has no finer test.
func isTerminal(f *os.File) bool {
	info, err := f.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

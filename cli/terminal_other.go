//go:build !darwin && !linux

package main

import "os"

// isTerminal is false where terminal detection is not supported, so no sentence is added.
func isTerminal(f *os.File) bool { return false }

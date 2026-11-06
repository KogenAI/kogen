package main

import (
	"os"
	"testing"

	"kogen/internal/testrelease"
)

// The installed-release tests share one release per test process; remove it once they are done.
func TestMain(m *testing.M) {
	code := m.Run()
	testrelease.Cleanup()
	os.Exit(code)
}

package contract_test

import (
	"os"
	"testing"

	"kogen-loop/sys"
)

// TestMain follows kogen-loop's own sys tests and kogen's main: a command run under the
// supervisor starts this executable again, so the supervisor check comes first.
func TestMain(m *testing.M) {
	sys.MaybeSupervise(os.Args[1:])
	sys.EnableSupervisor()
	os.Exit(m.Run())
}

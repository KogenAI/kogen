package consumes

import (
	"os"
	"strings"
	"testing"

	"github.com/KogenAI/kogen-loop/sys"
)

// TestMain isolates the process from the caller: no inherited GIT_* or KOGEN_* variable, no
// global or system Git configuration, and a HOME of its own. Like kogen's main it first lets
// sys.MaybeSupervise take over when this binary is started as a command supervisor, then
// enables the supervisor so that Session.Run starts its commands the way kogen does.
func TestMain(m *testing.M) {
	sys.MaybeSupervise(os.Args[1:])
	sys.EnableSupervisor()
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		if strings.HasPrefix(k, "GIT_") || strings.HasPrefix(k, "KOGEN_") {
			os.Unsetenv(k)
		}
	}
	home, err := os.MkdirTemp("", "kogen-consumes-loop-home-")
	if err != nil {
		panic(err)
	}
	os.Setenv("HOME", home)
	os.Setenv("GIT_CONFIG_GLOBAL", "/dev/null")
	os.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	os.Setenv("GIT_TERMINAL_PROMPT", "0")
	code := m.Run()
	os.RemoveAll(home)
	os.Exit(code)
}

package consumes

import (
	"os"
	"strings"
	"testing"
)

// TestMain isolates the process from the caller: no inherited GIT_* or KOGEN_* variable, no
// global or system Git configuration, and a HOME of its own. Build, Resume and Recover run Git
// and the project's commands with the session's environment, which the fixtures build from this
// one.
func TestMain(m *testing.M) {
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		if strings.HasPrefix(k, "GIT_") || strings.HasPrefix(k, "KOGEN_") || k == "EMAIL" {
			os.Unsetenv(k)
		}
	}
	home, err := os.MkdirTemp("", "kogen-consumes-build-home-")
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

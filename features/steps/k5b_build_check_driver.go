package build

import (
	"encoding/json"
	"os"
	"testing"

	"kogen-loop/sys"
	"kogen/project"
)

// Observation only: mounted as a test with go -overlay; it changes no production source. It runs one
// configured check (KOGEN_K5B_CHECK) through the Build's own pre-change check step in a real session and
// writes what that step returned to KOGEN_K5B_OUT.
func TestK5bConfiguredCheckObservation(t *testing.T) {
	b := &Attempt{Root: t.TempDir(), s: sys.New(), Config: &project.Config{Checks: []project.Check{{Name: "bg", Run: os.Getenv("KOGEN_K5B_CHECK")}}}}
	message := ""
	if err := b.alreadyFailing(t.Context()); err != nil {
		message = err.Error()
	}
	raw, _ := json.Marshal(map[string]string{"error": message})
	if err := os.WriteFile(os.Getenv("KOGEN_K5B_OUT"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
}

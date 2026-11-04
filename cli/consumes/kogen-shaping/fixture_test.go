package consumes

import (
	"strings"
	"testing"
)

func TestFixtureTitleExcludesGitUserName(t *testing.T) {
	f := newFx(t, false)
	f.addIntent()
	name := strings.TrimSpace(f.git("config", "user.name"))
	title, _, _ := strings.Cut(f.read(".kogen/intents/fixture/intent.md"), "\n")
	if name == "" || strings.Contains(strings.ToLower(title), strings.ToLower(name)) {
		t.Fatalf("fixture title %q contains Git user.name %q", title, name)
	}
}

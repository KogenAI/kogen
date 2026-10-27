package tools

import (
	"testing"

	"kogen-loop/sys"
)

func TestShellRefusesForeignKill(t *testing.T) {
	tl := &Tools{Root: t.TempDir(), Enabled: []string{"shell"}}
	out, err := tl.Run("shell", map[string]any{"command": "pkill -f nothing-at-all"})
	if err != nil || out.Text != sys.RefusalText(sys.RulePkillKillall) || out.Rule != sys.RulePkillKillall {
		t.Fatalf("%+v %v", out, err)
	}
	out, err = tl.Run("shell", map[string]any{"command": "echo next"})
	if err != nil || out.Text != "exit status: 0\nnext\n" || out.Rule != "" {
		t.Fatalf("%+v %v", out, err)
	}
}

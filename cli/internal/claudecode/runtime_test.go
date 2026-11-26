package claudecode

import "testing"

func TestUnsupportedMessage(t *testing.T) {
	for _, c := range []struct {
		goos, goarch, want string
	}{
		{"windows", "amd64", "Kogen's Claude Code runtime supports macOS on Apple Silicon and Linux x86-64 only, not windows/amd64"},
		{"darwin", "arm64", "Kogen's Claude Code runtime supports macOS on Apple Silicon and Linux x86-64 only, not darwin/arm64"},
		{"linux", "amd64", "Kogen's Claude Code runtime supports macOS on Apple Silicon and Linux x86-64 only, not linux/amd64"},
	} {
		t.Run(c.goos+"/"+c.goarch, func(t *testing.T) {
			if got := UnsupportedMessage(c.goos, c.goarch); got != c.want {
				t.Errorf("UnsupportedMessage(%q, %q) = %q, want %q", c.goos, c.goarch, got, c.want)
			}
		})
	}
}

func TestFirstField(t *testing.T) {
	for _, c := range []struct{ answer, want string }{
		{"", ""},
		{" \t\n", ""},
		{" \t2.1.300 (Claude Code)\n", "2.1.300"},
	} {
		if got := FirstField(c.answer); got != c.want {
			t.Errorf("FirstField(%q) = %q, want %q", c.answer, got, c.want)
		}
	}
}

func TestPinned(t *testing.T) {
	for _, c := range []struct {
		answer string
		want   bool
	}{
		{" \t" + Version + " (Claude Code)\n", true},
		{"", false},
		{Version + "0 (Claude Code)", false},
		{Version + "-beta (Claude Code)", false},
	} {
		if got := Pinned(c.answer); got != c.want {
			t.Errorf("Pinned(%q) = %t, want %t", c.answer, got, c.want)
		}
	}
}

func TestNotPinnedMessage(t *testing.T) {
	path := "/x/claude"
	answer := Version + "-beta (Claude Code)"
	for _, c := range []struct{ version, want string }{
		{Version, "Kogen's Claude Code at /x/claude reports " + Version + "-beta (Claude Code), not the pinned " + Version},
		{Version + "0", "Kogen's Claude Code at /x/claude reports " + Version + "-beta (Claude Code), not the active " + Version + "0"},
	} {
		if got := NotPinnedMessage(path, answer, c.version); got != c.want {
			t.Errorf("NotPinnedMessage(%q, %q, %q) = %q, want %q", path, answer, c.version, got, c.want)
		}
	}
}

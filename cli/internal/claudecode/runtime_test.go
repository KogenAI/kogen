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

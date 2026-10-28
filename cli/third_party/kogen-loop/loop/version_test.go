package loop

import (
	"os"
	"regexp"
	"testing"
)

func TestVersionMatchesChangelog(t *testing.T) {
	b, err := os.ReadFile("../CHANGELOG.md")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?m)^## v(\d+\.\d+\.\d+) \(unreleased\)\s*$`).FindSubmatch(b)
	if m == nil {
		t.Fatal("CHANGELOG.md has no unreleased version heading")
	}
	if want := string(m[1]) + "-dev"; Version != want {
		t.Fatalf("Version = %q, want %q", Version, want)
	}
}

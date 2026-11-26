package claudecode

import (
	"bytes"
	"sync"
	"testing"
)

func TestTokenScreenSplitMarker(t *testing.T) {
	var out bytes.Buffer
	screen := tokenScreen{mu: &sync.Mutex{}, out: &out, captured: &limitedBuffer{}}
	for _, part := range []string{"Open the browser.\nYour OAuth", " token:\n  fake-", "token_123\n"} {
		if _, err := screen.Write([]byte(part)); err != nil {
			t.Fatal(err)
		}
	}
	if got, want := out.String(), "Open the browser.\n"; got != want {
		t.Errorf("forwarded output = %q, want %q", got, want)
	}
}

func TestTokenScreenWholeMarker(t *testing.T) {
	var out bytes.Buffer
	screen := tokenScreen{mu: &sync.Mutex{}, out: &out, captured: &limitedBuffer{}}
	for _, part := range []string{"Open the browser.\nYour OAuth token:\n  fake-token_123\n", "Store this token securely.\n"} {
		if _, err := screen.Write([]byte(part)); err != nil {
			t.Fatal(err)
		}
		if got, want := out.String(), "Open the browser.\n"; got != want {
			t.Errorf("forwarded output = %q, want %q", got, want)
		}
	}
}

func TestParseSetupToken(t *testing.T) {
	for _, tc := range []struct {
		name, screen, want string
	}{
		{"trimmed token", "Open the browser.\nYour OAuth token:\n  fake-token_123 \t\n", "fake-token_123"},
		{"missing marker", "arbitrary-screen-text\n", ""},
		{"missing token", "Your OAuth token:\n \t\n", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := parseSetupToken(tc.screen); got != tc.want {
				t.Errorf("parseSetupToken() = %q, want %q", got, tc.want)
			}
		})
	}
}

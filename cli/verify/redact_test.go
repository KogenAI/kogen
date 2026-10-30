package verify

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRedactorMasksKnownAndLabeledSecrets(t *testing.T) {
	home := t.TempDir()
	creds := filepath.Join(home, ".kogen", "credentials")
	if err := os.MkdirAll(creds, 0o700); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(creds, "anthropic.json"), []byte(`{"provider":"anthropic","api_key":"cred-secret-value"}`), 0o600)
	r := NewRedactor([]string{"MY_API_TOKEN=env-secret-value", "Db_Password=pw-secret-value", "PATH=/usr/bin", "EMPTY_SECRET=", "SHORT_KEY=ab"}, home)
	for _, tc := range []struct{ in, out string }{
		{"a env-secret-value b", "a " + Redacted + " b"},
		{"pw-secret-value and cred-secret-value", Redacted + " and " + Redacted},
		{"Authorization: Bearer abc.def-123", "Authorization: Bearer " + Redacted},
		{"curl -H 'authorization: Basic Zm9vOmJhcg=='", "curl -H 'authorization: Basic " + Redacted + "'"},
		{"got bearer abcdef123456 here", "got bearer " + Redacted + " here"},
		{"api_key=xyz123 password: hunter2", "api_key=" + Redacted + " password: " + Redacted},
		{`{"client_secret": "s3cr3t"}`, `{"client_secret": ` + Redacted + `}`},
		{"tool --token abc123 --verbose", "tool --token " + Redacted + " --verbose"},
		{"PATH=/usr/bin ab EMPTY harmless output", "PATH=/usr/bin " + Redacted + " EMPTY harmless output"},
	} {
		if got := r.Redact(tc.in); got != tc.out {
			t.Errorf("Redact(%q) = %q, want %q", tc.in, got, tc.out)
		}
	}
	if got := r.Redact("x \xff y"); got != "x \uFFFD y" {
		t.Errorf("invalid UTF-8 became %q", got)
	}
	if got := (*Redactor)(nil).Redact("password=abc12345"); got != "password="+Redacted {
		t.Errorf("a nil Redactor masks %q", got)
	}
}

func TestRedactionPrecedesTheBounds(t *testing.T) {
	r := NewRedactor([]string{"X_SECRET=SECRET-VALUE-0123456789"}, "")
	// The secret begins 10 bytes before the 4096-byte head Cut keeps.
	text := strings.Repeat("a", 4086) + "SECRET-VALUE-0123456789" + strings.Repeat("b", 30000)
	bounded := Diagnostic(r.Redact(text))
	if strings.Contains(bounded, "SECRET-VALUE") || strings.Contains(bounded, "0123456789") {
		t.Errorf("a bound split the secret and leaked part of it: %q", bounded[4050:4140])
	}
	if !strings.Contains(Diagnostic(text), "SECRET-VALUE") {
		t.Log("without redaction the cut keeps part of the secret, as the order of operations requires")
	}
}

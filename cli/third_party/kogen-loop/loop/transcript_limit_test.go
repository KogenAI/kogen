package loop

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/KogenAI/kogen-loop/api"
	"github.com/KogenAI/kogen-loop/sys"
)

func TestResumeSessionRefusesATranscriptAboveTheBound(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	path := filepath.Join(dir, transcriptName)
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Truncate(transcriptLimit + 1); err != nil {
		t.Fatal(err)
	}
	f.Close()
	s, err := ResumeSession(SessionConfig{Root: t.TempDir(), Dir: dir, Role: parallelRole})
	want := "the session transcript at " + path + " is 67108865 bytes, more than the limit of 67108864 bytes"
	var se *sys.Error
	if s != nil || !errors.As(err, &se) || se.Class != api.ErrClassLoop || se.Reason != api.ErrSessionMismatch || se.Detail != want || se.Exit != api.ExitInvalid {
		t.Fatalf("got %v, %#v; want no session and loop/session_mismatch %q", s, err, want)
	}
}

func TestResumeSessionAcceptsATranscriptExactlyAtTheBound(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	cfg := SessionConfig{Root: t.TempDir(), Dir: dir, Role: parallelRole, Enabled: []string{"read_file"}}
	first, err := NewSession(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := first.persist([]any{map[string]any{"role": "user", "content": "start"}}, nil); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, transcriptName)
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		t.Fatal(err)
	}
	chunk := make([]byte, 1<<20)
	for i := range chunk {
		chunk[i] = ' '
	}
	for left := transcriptLimit - st.Size(); left > 0; left -= int64(len(chunk)) {
		if _, err := f.Write(chunk[:min(left, int64(len(chunk)))]); err != nil {
			t.Fatal(err)
		}
	}
	f.Close()
	if st, err := os.Stat(path); err != nil || st.Size() != transcriptLimit {
		t.Fatalf("padded transcript %v %v", st, err)
	}
	s, err := ResumeSession(cfg)
	if err != nil || s == nil || s.ID() != first.ID() {
		t.Fatalf("got %v, %v; want the session %s", s, err, first.ID())
	}
}

func TestResumeSessionKeepsTheDecodeErrorDetail(t *testing.T) {
	t.Parallel()
	for text, want := range map[string]string{
		"":         "the session transcript is not valid: EOF",
		"not json": "the session transcript is not valid: invalid character 'o' in literal null (expecting 'u')",
	} {
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, transcriptName), []byte(text), 0o600); err != nil {
			t.Fatal(err)
		}
		s, err := ResumeSession(SessionConfig{Root: t.TempDir(), Dir: dir, Role: parallelRole})
		var se *sys.Error
		if s != nil || !errors.As(err, &se) || se.Reason != api.ErrSessionMismatch || se.Detail != want {
			t.Errorf("%q: got %v, %v; want %q", text, s, err, want)
		}
	}
}

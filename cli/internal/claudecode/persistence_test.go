package claudecode

import (
	"bytes"
	"io"
	"testing"
)

type shortStderrWriter struct {
	bytes.Buffer
	err error
}

func (w *shortStderrWriter) Write(b []byte) (int, error) {
	n, _ := w.Buffer.Write(b[:2])
	return n, w.err
}

func checkStderrWrite(t *testing.T, p *stderrPersistence, output *bytes.Buffer, input, wantOutput string, kept, lost int64) {
	t.Helper()
	n, err := p.Write([]byte(input))
	if n != len(input) || err != nil {
		t.Errorf("Write(%q) = (%d, %v), want (%d, nil)", input, n, err, len(input))
	}
	if got := output.String(); got != wantOutput {
		t.Errorf("output = %q, want %q", got, wantOutput)
	}
	if p.kept != kept || p.lost != lost {
		t.Errorf("kept, lost = %d, %d; want %d, %d", p.kept, p.lost, kept, lost)
	}
}

func TestStderrPersistenceCrossCap(t *testing.T) {
	t.Run("single write", func(t *testing.T) {
		var output bytes.Buffer
		p := stderrPersistence{w: &output, cap: 5}
		checkStderrWrite(t, &p, &output, "abcdefgh", "abcde", 5, 3)
	})
	t.Run("after retained write", func(t *testing.T) {
		var output bytes.Buffer
		p := stderrPersistence{w: &output, cap: 5}
		checkStderrWrite(t, &p, &output, "ab", "ab", 2, 0)
		checkStderrWrite(t, &p, &output, "cdefgh", "abcde", 5, 3)
	})
}

func TestStderrPersistenceShortWrite(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
	}{
		{"nil error", nil},
		{"short write error", io.ErrShortWrite},
	} {
		t.Run(tc.name, func(t *testing.T) {
			output := &shortStderrWriter{err: tc.err}
			p := stderrPersistence{w: output, cap: 10}
			checkStderrWrite(t, &p, &output.Buffer, "abcdef", "ab", 2, 4)
		})
	}
}

func TestStderrPersistenceExhaustedCap(t *testing.T) {
	var output bytes.Buffer
	p := stderrPersistence{w: &output, cap: 5}
	checkStderrWrite(t, &p, &output, "abcde", "abcde", 5, 0)
	checkStderrWrite(t, &p, &output, "fg", "abcde", 5, 2)
	checkStderrWrite(t, &p, &output, "hij", "abcde", 5, 5)
}

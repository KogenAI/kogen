package claudecode

import (
	"bytes"
	"io"
)

// redactWriter replaces every occurrence of secret with mark before writing to w. It holds back
// the last len(secret)-1 bytes of each write, so a secret split across writes is still caught;
// Flush releases them.
type redactWriter struct {
	w            io.Writer
	secret, mark []byte
	pending      []byte
}

func newRedactWriter(w io.Writer, secret, mark string) *redactWriter {
	return &redactWriter{w: w, secret: []byte(secret), mark: []byte(mark)}
}

func (r *redactWriter) Write(p []byte) (int, error) {
	buf := append(r.pending, p...)
	buf = bytes.ReplaceAll(buf, r.secret, r.mark)
	keep := min(len(r.secret)-1, len(buf))
	out := buf[:len(buf)-keep]
	r.pending = append([]byte{}, buf[len(buf)-keep:]...)
	if _, err := r.w.Write(out); err != nil {
		return 0, err
	}
	return len(p), nil
}

// copyRedacted copies r to w and then keeps draining r, even after a write error, so the writer
// of the pipe never blocks.
func copyRedacted(w io.Writer, r io.Reader) {
	io.Copy(w, r)
	io.Copy(io.Discard, r)
}

// Flush writes the held-back tail.
func (r *redactWriter) Flush() error {
	out := r.pending
	r.pending = nil
	_, err := r.w.Write(out)
	return err
}

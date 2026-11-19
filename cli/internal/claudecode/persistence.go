package claudecode

import "io"

type retainedWriter struct {
	w    io.Writer
	kept int64
	err  error
}

func (p *retainedWriter) Write(b []byte) (int, error) {
	if p.err != nil {
		return 0, p.err
	}
	n, err := p.w.Write(b)
	p.kept += int64(n)
	if err == nil && n != len(b) {
		err = io.ErrShortWrite
	}
	p.err = err
	return n, err
}

type stderrPersistence struct {
	w               io.Writer
	cap, kept, lost int64
}

// Write always accepts all of b. Whatever does not reach w, whether over the cap or
// refused by a failed or short write, is counted in lost; the failure itself is
// recorded by the retainedWriter around the file.
func (p *stderrPersistence) Write(b []byte) (int, error) {
	var written int
	if n := int(min(int64(len(b)), p.cap-p.kept)); n > 0 {
		written, _ = p.w.Write(b[:n])
		p.kept += int64(written)
	}
	p.lost += int64(len(b) - written)
	return len(b), nil
}

func (r *roundRun) addPersistence(event map[string]any) {
	if r.streamLostLines > 0 {
		event["stream_persist_truncated"] = true
		event["stream_persist_unpersisted_bytes"] = r.streamLostBytes
	}
	if r.stderrLostBytes > 0 {
		event["stderr_persist_truncated"] = true
		event["stderr_persist_unpersisted_bytes"] = r.stderrLostBytes
	}
}

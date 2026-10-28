package build

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"testing"
)

// Observation only: it mounts as a test with go -overlay, changes no production source and
// drives the real Build and independent review against the scripted fake provider.
const (
	k9Notes    = "k9-secret-notes.txt"
	k9Content  = "K9-CONTENT-SENTINEL-1\nK9-CONTENT-SENTINEL-2\nK9-CONTENT-SENTINEL-3\nK9-CONTENT-SENTINEL-4\n"
	k9Shell    = "head -c 40960 /dev/zero | tr '\\0' x"
	k9Branches = 40
)

// k9CacheWrite answers one function call whose usage reports 20 cache-write tokens.
func k9CacheWrite(item map[string]any) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("X-Request-Id", "req-fixture")
		io.WriteString(w, "data: "+jsonText(map[string]any{"type": "response.output_item.done", "output_index": 0, "item": item})+"\n\n")
		io.WriteString(w, "data: "+jsonText(map[string]any{"type": "response.completed", "response": map[string]any{"usage": map[string]any{
			"input_tokens": 100, "input_tokens_details": map[string]any{"cached_tokens": 10, "cache_write_tokens": 20},
			"output_tokens": 5, "output_tokens_details": map[string]any{"reasoning_tokens": 1}}}})+"\n\n")
	}
}

func TestK9RunRecordObservation(t *testing.T) {
	e := newEnv(t)
	f := e.prov
	f.then(f.calls("write_file", map[string]any{"path": k9Notes, "content": k9Content}, "write_file", map[string]any{"path": "app.txt", "content": "candidate\n"}))
	f.then(k9CacheWrite(f.call("read_file", map[string]any{"path": k9Notes, "start_line": 2, "end_line": 3})))
	for i := 0; i < k9Branches; i++ {
		f.then(f.calls("shell", map[string]any{"command": k9Shell}))
	}
	f.then(f.calls("finish", map[string]any{"summary": "done"}))
	f.then(f.calls("read_file", map[string]any{"path": "app.txt"}, "read_file", map[string]any{"path": k9Notes, "start_line": 1, "end_line": 2}))
	f.then(submit(f, "approve"))
	a := e.reviewed()
	id := e.onlyRun()
	var sizes []int
	for _, req := range f.requests() {
		raw, _ := json.Marshal(req)
		sizes = append(sizes, len(raw))
	}
	out := map[string]any{"exit": a.exit, "error_text": a.shown() + a.errs.String(), "events": e.events(id), "provider_sizes": sizes}
	raw, _ := json.Marshal(out)
	if err := os.WriteFile(os.Getenv("KOGEN_K9_OUTPUT"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
}

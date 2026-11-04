package buildprogram

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"kogen-loop/tools"
)

// resetHandoff is the working-window reset message a request carries, or nil.
func resetHandoff(t *testing.T, req map[string]any) map[string]any {
	t.Helper()
	for _, it := range requestInput(req) {
		m, _ := it.(map[string]any)
		s, ok := m["content"].(string)
		if !ok || !strings.HasPrefix(s, "Local working-window reset\n") {
			continue
		}
		var reset map[string]any
		if err := json.Unmarshal([]byte(strings.TrimPrefix(s, "Local working-window reset\n")), &reset); err != nil {
			t.Fatal(err)
		}
		return reset
	}
	return nil
}

// inWindow is what a request's own window holds: the paths of its completed read_file calls
// and the number of images it carries.
func inWindow(req map[string]any) (read map[string]bool, images int) {
	calls := map[any]string{}
	read = map[string]bool{}
	for _, it := range requestInput(req) {
		m, _ := it.(map[string]any)
		switch m["type"] {
		case "function_call":
			if m["name"] == "read_file" {
				path, _ := tools.DecodeArguments(m["arguments"].(string))["path"].(string)
				calls[m["call_id"]] = path
			}
		case "function_call_output":
			if path, ok := calls[m["call_id"]]; ok {
				read[path] = true
			}
			if parts, ok := m["output"].([]any); ok && len(parts) == 2 {
				if p, _ := parts[1].(map[string]any); p["type"] == "input_image" {
					images++
				}
			}
		}
	}
	return read, images
}

// prefilledParts is path -> read of every native pinned-source message a review request
// carries. It parses the request itself and fails unless each read is, byte for byte, the
// "1\t" line-numbered text of the part file read_file returns (the file without its trailing
// newline).
func prefilledParts(t *testing.T, req map[string]any) map[string]string {
	t.Helper()
	out := map[string]string{}
	for _, it := range requestInput(req) {
		m, _ := it.(map[string]any)
		text, ok := m["content"].(string)
		if !ok || m["role"] != "user" {
			continue
		}
		body, ok := strings.CutPrefix(text, prefillMarker+"\n")
		if !ok {
			continue
		}
		var doc struct {
			Version int `json:"version"`
			Parts   []struct {
				Path string `json:"path"`
				Read string `json:"read"`
			} `json:"parts"`
		}
		if err := json.Unmarshal([]byte(body), &doc); err != nil {
			t.Fatalf("prefill message: %v", err)
		}
		if doc.Version != 1 {
			t.Fatalf("prefill version %d", doc.Version)
		}
		for _, e := range doc.Parts {
			data, err := os.ReadFile(e.Path)
			if err != nil {
				t.Fatal(err)
			}
			if want := "1\t" + strings.TrimRight(string(data), "\n"); e.Read != want {
				t.Fatalf("prefilled %s: %d bytes, want the %d bytes read_file returns", e.Path, len(e.Read), len(want))
			}
			out[e.Path] = e.Read
		}
	}
	return out
}

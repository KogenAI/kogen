package buildprogram

import (
	"encoding/json"
	"net/http"
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

// pinnedOf is the pinned source parts a review request's catalog lists, or nil while the
// source is still inline.
func pinnedOf(req map[string]any) []string {
	blocks, _ := requestInput(req)[0].(map[string]any)["content"].([]any)
	if len(blocks) != 2 {
		return nil
	}
	text, _ := blocks[1].(map[string]any)["text"].(string)
	_, rest, ok := strings.Cut(text, "# Pinned complete candidate source evidence\n")
	if !ok {
		return nil
	}
	line, _, _ := strings.Cut(rest, "\n")
	var catalog map[string]any
	if json.Unmarshal([]byte(line), &catalog) != nil {
		return nil
	}
	return catalogParts(catalog)
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

// confirmingReviewer models the reviewer of Build 543748f1: in every window it reads (four at
// a time) the pinned parts it cannot confirm were delivered, from the window itself or the
// reset's native delivery facts, then views every screenshot, then approves.
func confirmingReviewer(t *testing.T, f *fakeProvider, shots []string) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		reqs := f.reviewRequests()
		req := reqs[len(reqs)-1]
		known, images := inWindow(req)
		// The scripted reviewer sees complete native source data in this request too.
		for path := range prefilledParts(t, req) {
			known[path] = true
		}
		parts := pinnedOf(req)
		if reset := resetHandoff(t, req); reset != nil {
			if d, ok := reset["review_delivery"].(map[string]any); ok {
				if source, ok := d["source"].(map[string]any); ok && source["current"] == true {
					unread := map[int]bool{}
					for _, n := range source["unread"].([]any) {
						unread[int(n.(float64))] = true
					}
					for i, p := range parts {
						if !unread[i+1] {
							known[p] = true
						}
					}
				}
			}
		}
		var pairs []any
		for _, p := range parts {
			if !known[p] && len(pairs) < 8 {
				pairs = append(pairs, "read_file", map[string]any{"path": p})
			}
		}
		switch {
		case len(pairs) > 0:
			f.calls(pairs...)(w, r)
		case images < len(shots):
			for _, s := range shots {
				pairs = append(pairs, "view_image", map[string]any{"path": s})
			}
			f.calls(pairs...)(w, r)
		default:
			submit(f, "approve")(w, r)
		}
	}
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

package buildprogram

import ()

// landScript writes the candidate and finishes.
func landScript(f *fakeProvider) []handler {
	return []handler{f.calls("write_file", map[string]any{"path": "app.txt", "content": "candidate\n"}, "finish", map[string]any{"summary": "done"})}
}

package main

import (
	"os"
	"path/filepath"
	"time"

	"github.com/KogenAI/kogen-executor/core"
	"kogen/internal/claudecode"
)

// runResults is the result.json of every run of a project, by path, with its modification time.
func runResults(project string) map[string]time.Time {
	found := map[string]time.Time{}
	paths, _ := filepath.Glob(filepath.Join(project, ".kogen", "local", "runs", "*", "result.json"))
	for _, p := range paths {
		if st, err := os.Stat(p); err == nil {
			found[p] = st.ModTime()
		}
	}
	return found
}

// stampClaudeCode adds the Claude Code receipt to the result.json of every Build attempt this
// process wrote or changed since before was taken: claude_code_version (the first field of the
// `--version` answer of the executable that ran the attempt's builder, read when that role
// started) and claude_code_source (`pinned` for the compiled pin, `updated` for a version the
// active file selected). A Build whose builder is not Claude Code has no receipt.
func stampClaudeCode(project string, before map[string]time.Time) {
	var builder *claudecode.RuntimeUse
	for _, use := range claudecode.Uses() {
		if use.Role == "build" {
			use := use
			builder = &use
			break
		}
	}
	if builder == nil {
		return
	}
	for p, at := range runResults(project) {
		if was, ok := before[p]; ok && was.Equal(at) {
			continue
		}
		data, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		var result map[string]any
		if core.DecodeJSON(data, &result) != nil || result == nil {
			continue
		}
		result["claude_code_version"] = builder.Version
		result["claude_code_source"] = builder.Source
		out, err := core.EncodeJSON(result)
		if err != nil {
			continue
		}
		_ = os.WriteFile(p, append(out, '\n'), 0o666)
	}
}

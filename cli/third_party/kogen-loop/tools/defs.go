package tools

import (
	"fmt"
)

// Generic tool names. Kogen's workflow tools (finish, report_blocker, the submit_* tools,
// shape_batch, worker_result and the probe definition) stay in Kogen.
const (
	ShellTool         = "shell"
	ViewImageTool     = "view_image"
	ReadFileTool      = "read_file"
	WriteFileTool     = "write_file"
	ListFilesTool     = "list_files"
	SearchTextTool    = "search_text"
	DocumentationTool = "documentation"
)

// ProbeTool is the name of the probe callback seam of Tools. It is a Kogen-named residue:
// the probe tool, its definition and its scratch copy belong to Kogen's shaper, which sets
// Tools.Probe. The definition is not here.
const ProbeTool = "probe"

func fun(name, description string, props map[string]any, required ...string) map[string]any {
	req := make([]any, len(required))
	for i, r := range required {
		req[i] = r
	}
	return map[string]any{
		"type":        "function",
		"name":        name,
		"description": description,
		"parameters": map[string]any{
			"type":                 "object",
			"properties":           props,
			"required":             req,
			"additionalProperties": false,
		},
		"strict": false,
	}
}

func str() map[string]any     { return map[string]any{"type": "string"} }
func integer() map[string]any { return map[string]any{"type": "integer"} }
func strList() map[string]any {
	return map[string]any{"type": "array", "items": str()}
}

// pathAndContent is the {path, content} object of the file lists.
func pathAndContent(minItems bool) map[string]any {
	l := map[string]any{
		"type": "array",
		"items": map[string]any{
			"type":       "object",
			"properties": map[string]any{"path": str(), "content": str()},
			"required":   []any{"path", "content"},
		},
	}
	if minItems {
		l["minItems"] = 1
	}
	return l
}

// Definition returns the model-facing definition of a generic tool: shell, view_image,
// read_file, write_file, list_files, search_text or documentation. The text is the exact
// definition Kogen sent at 56eecd57. The second result is false for any other name,
// including Kogen's workflow tools.
func Definition(name string) (map[string]any, bool) {
	switch name {
	case ShellTool:
		return fun(name,
			"Run a command with /bin/sh -c in the repository root. stdin is closed. Returns the exit status and the combined stdout and stderr. Commands have no time limit. Run finite commands, including tests and browser suites, in the foreground until completion; do not poll them through repeated sleep/tail/ps calls. Only persistent commands (dev servers, watch modes) belong in the background with output to a log file; read their logs and stop them yourself.",
			map[string]any{"command": str()}, "command"), true
	case ViewImageTool:
		return fun(name,
			"View one selected local static non-interlaced RGB8 PNG (1..131072 bytes, dimensions 1..2048) inside the repository root; paths outside it, symlinks leaving it and ~ are refused. Read-only; no capture or provenance inference. Provider preprocessing may change resolution.",
			map[string]any{"path": str()}, "path"), true
	case ReadFileTool:
		return fun(name,
			"Read a file of the repository, with line numbers. Paths are relative to the repository root; absolute paths and symlinks must stay inside the root, and ~ is refused.",
			map[string]any{"path": str(), "start_line": integer(), "end_line": integer()}, "path"), true
	case WriteFileTool:
		return fun(name,
			"Write the whole content of a file of the repository (created with its folders if needed).",
			map[string]any{"path": str(), "content": str()}, "path", "content"), true
	case ListFilesTool:
		return fun(name,
			"List the repository's files (tracked and untracked, not ignored), optionally under a folder inside the repository root; paths outside it, symlinks leaving it and ~ are refused.",
			map[string]any{"path": str()}), true
	case SearchTextTool:
		return fun(name,
			"Search the repository's files for a regular expression (git grep syntax), optionally under a path inside the repository root; paths outside it, symlinks leaving it and ~ are refused. Returns path:line:text matches.",
			map[string]any{"pattern": str(), "path": str()}, "pattern"), true
	case DocumentationTool:
		return fun(name,
			"Shape documentation lookup discovers sources and retrieves current authoritative documentation. A fetch may pass offset, a byte index into the page body, and find, text that starts the body at its first matching heading or line; the result reports body_total and next_offset for reading the rest.",
			map[string]any{
				"operation": map[string]any{"type": "string", "enum": []any{"search", "fetch"}},
				"query":     str(),
				"url":       str(),
				"offset":    map[string]any{"type": "integer"},
				"find":      str(),
				"base": map[string]any{
					"type":        "string",
					"description": "Optional origin. When present, every request in this call uses that origin and no other host.",
				},
			}, "operation"), true
	}
	return nil, false
}

// Definition returns the generic definition of name. Callers pass these definitions and
// the same Tools instance to Round.
func (t *Tools) Definition(name string) (map[string]any, bool) {
	return Definition(name)
}

// Defs returns the definition of each named generic tool, in order. A name that is not a
// generic tool panics: the names are fixed by the program. Kogen's own definitions are not
// available here; a caller that mixes them builds its list from Definition and its own.
func Defs(names ...string) []map[string]any {
	out := make([]map[string]any, len(names))
	for i, n := range names {
		d, ok := Definition(n)
		if !ok {
			panic(fmt.Sprintf("tools: unknown tool %q", n))
		}
		out[i] = d
	}
	return out
}

// AsAny is the definitions as the Tools list of a provider.Request.
func AsAny(defs ...[]map[string]any) []any {
	var out []any
	for _, d := range defs {
		for _, m := range d {
			out = append(out, m)
		}
	}
	return out
}

package agent

import "fmt"

// Tool names.
const (
	ShellTool         = "shell"
	ViewImageTool     = "view_image"
	ReadFileTool      = "read_file"
	WriteFileTool     = "write_file"
	ListFilesTool     = "list_files"
	SearchTextTool    = "search_text"
	ProbeTool         = "probe"
	DocumentationTool = "documentation"
	FinishTool        = "finish"
	ReportBlockerTool = "report_blocker"

	SubmitTool              = "submit"
	SubmitReviewTool        = "submit_review"
	SubmitRefinementTool    = "submit_refinement"
	SubmitConfigurationTool = "submit_configuration"
	ShapeBatchTool          = "shape_batch"
	WorkerResultTool        = "worker_result"
)

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

// Defs returns the model-facing definition of each named tool, in order: the file, search and
// command tools, the terminal tools (finish, report_blocker, the submit_* tools) and the
// shaper's probe, shape_batch and worker_result. A name that is not one of those panics: the
// names are fixed by the program.
func Defs(names ...string) []map[string]any {
	out := make([]map[string]any, len(names))
	for i, n := range names {
		out[i] = definition(n)
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

func definition(name string) map[string]any {
	switch name {
	case ShellTool:
		return fun(name,
			"Run a command with /bin/sh -c in the repository root. stdin is closed. Returns the exit status and the combined stdout and stderr. Commands have no time limit. Run finite commands, including tests and browser suites, in the foreground until completion; do not poll them through repeated sleep/tail/ps calls. Only persistent commands (dev servers, watch modes) belong in the background with output to a log file; read their logs and stop them yourself.",
			map[string]any{"command": str()}, "command")
	case ViewImageTool:
		return fun(name,
			"View one selected local static non-interlaced RGB8 PNG (1..131072 bytes, dimensions 1..2048). Read-only; no capture or provenance inference. Provider preprocessing may change resolution.",
			map[string]any{"path": str()}, "path")
	case ReadFileTool:
		return fun(name,
			"Read a file of the repository, with line numbers. Paths are relative to the repository root.",
			map[string]any{"path": str(), "start_line": integer(), "end_line": integer()}, "path")
	case WriteFileTool:
		return fun(name,
			"Write the whole content of a file of the repository (created with its folders if needed).",
			map[string]any{"path": str(), "content": str()}, "path", "content")
	case ReportBlockerTool:
		return fun(name,
			"Stop with a BUILDER-REPORTED protected-baseline contradiction. Supply concrete current protected file paths, the contradiction, and observed command/step/error evidence. Ordinary implementation failures or expected missing-feature red require repair, not a blocker. This never authorizes protected writes or skips a successful gate.",
			map[string]any{"paths": strList(), "reason": str(), "evidence": str()}, "paths", "reason", "evidence")
	case FinishTool:
		return fun(name,
			"Say the implementation is complete. Kogen then runs the fixers and every check, and a reviewer reviews the code; failures come back to you.",
			map[string]any{"summary": str()}, "summary")
	case ListFilesTool:
		return fun(name,
			"List the repository's files (tracked and untracked, not ignored), optionally under a folder.",
			map[string]any{"path": str()})
	case SearchTextTool:
		return fun(name,
			"Search the repository's files for a regular expression (git grep syntax). Returns path:line:text matches.",
			map[string]any{"pattern": str(), "path": str()}, "pattern")
	case ProbeTool:
		return fun(name,
			"Run a quick throwaway command with /bin/sh -c in a scratch copy of the working tree (with its installed dependencies and builds), never in the project, to prove a risky assumption. Optional scratch files are written first. Stopped after 5 minutes. Returns the exit status, whether it timed out, the wall time and the combined output.",
			map[string]any{
				"command": str(),
				"files": map[string]any{
					"type": "array",
					"items": map[string]any{
						"type":       "object",
						"properties": map[string]any{"path": str(), "content": str()},
						"required":   []any{"path", "content"},
					},
				},
			}, "command")
	case DocumentationTool:
		return fun(name,
			"Shape documentation lookup discovers sources and retrieves current authoritative documentation.",
			map[string]any{
				"operation": map[string]any{"type": "string", "enum": []any{"search", "fetch"}},
				"query":     str(),
				"url":       str(),
				"base": map[string]any{
					"type":        "string",
					"description": "Optional origin. When present, every request in this call uses that origin and no other host.",
				},
			}, "operation")
	case SubmitTool:
		return submitDef()
	case SubmitReviewTool:
		return map[string]any{
			"type":        "function",
			"name":        name,
			"strict":      false,
			"description": "Submit the review: verdict approve or changes, with findings.",
			"parameters": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"verdict": map[string]any{"type": "string", "enum": []any{"approve", "changes"}},
					"findings": map[string]any{
						"type": "array",
						"items": map[string]any{
							"type": "object",
							"properties": map[string]any{
								"path":     str(),
								"line":     integer(),
								"severity": map[string]any{"type": "string", "enum": []any{"blocking", "note"}},
								"message":  str(),
							},
							"required": []any{"path", "line", "severity", "message"},
						},
					},
				},
				"required": []any{"verdict", "findings"},
			},
		}
	case SubmitRefinementTool:
		return map[string]any{
			"type":   "function",
			"name":   name,
			"strict": false,
			"description": "For edits, submit changed existing files; well-formed proposals accumulate in this run and omitted paths retain earlier proposed bytes. Submit original content only to intentionally revert an edit. " +
				file(ReadinessAcknowledgmentGuidance) + " Or report an explicit unsupported-work constraint.",
			"parameters": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"files":      pathAndContent(true),
					"constraint": str(),
				},
			},
		}
	case SubmitConfigurationTool:
		return map[string]any{
			"type":        "function",
			"name":        name,
			"strict":      false,
			"description": "The project's setup commands, fixers, checks and protected verification configuration; dependency-only manifests and lockfiles are ineligible.",
			"parameters": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"setup": strList(),
					"fix":   strList(),
					"checks": map[string]any{
						"type": "array",
						"items": map[string]any{
							"type":       "object",
							"properties": map[string]any{"name": str(), "run": str()},
							"required":   []any{"name", "run"},
						},
					},
					"protect": strList(),
				},
				"required": []any{"setup", "fix", "checks", "protect"},
			},
		}
	case ShapeBatchTool:
		return map[string]any{
			"type":        "function",
			"name":        name,
			"description": "One blocking batch of 1–3 independent read/probe/draft jobs. Supply complete brief: revision {head,tree}, nonempty outcomes, interfaces, transitions, fixtures, exclusions, protected_paths array, artifacts [{path,expectation}]. Each job: unique id, role, exact scope, paths array, owns array. Read/probe own nothing; disjoint draft owns exact Intent/step files. Sequential is valid until all boundaries are known.",
			"parameters": map[string]any{
				"type":       "object",
				"properties": map[string]any{"brief": map[string]any{"type": "object"}, "jobs": map[string]any{"type": "array"}},
				"required":   []any{"brief", "jobs"},
			},
		}
	case WorkerResultTool:
		return map[string]any{
			"type":        "function",
			"name":        name,
			"description": "Terminate with nonempty evidence and files [{path,content}]; read/probe files empty, draft only owns.",
			"parameters": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"evidence": str(),
					"files":    map[string]any{"type": "array"},
				},
				"required": []any{"evidence", "files"},
			},
		}
	}
	panic(fmt.Sprintf("agent: unknown tool %q", name))
}

func submitDef() map[string]any {
	return map[string]any{
		"type":   "function",
		"name":   SubmitTool,
		"strict": false,
		"description": "Include nonempty ## Source comparison prose (at most 8192 UTF-8 bytes) comparing requested behaviors and settled non-secret literals against the actual complete contract, using addressed, omitted, conflicting, superseded with source/contract references. Do not expose secrets or raw private originals. Deliberate scope changes must be explicit; mappings are diagnostic aids, not semantic proof. End shaping with exactly one of questions, Intent files, or blocked. Within this run, well-formed file proposals accumulate: omitted paths retain earlier proposals; latest content wins. Submit only corrections on editing retries. " +
			file(ReadinessAcknowledgmentGuidance) + " A malformed or unsafe submission contributes no files. A blocked report is never authorization and cannot be paired with another result. Record a documentation lookup only when this conversation's documentation tool returned that status and reference. An explicit question kind other than product or handoff is rejected: decide technical questions inside shaping; only kind product or handoff may reach the caller.",
		"parameters": map[string]any{
			"type": "object",
			"properties": map[string]any{
				"questions": map[string]any{
					"type": "array",
					"items": map[string]any{
						"type": "object",
						"properties": map[string]any{
							"question": str(),
							"kind": map[string]any{
								"type":        "string",
								"description": "Optional. Omit or product for a UI/UX or product question. handoff for a mandatory authentication or security handoff. Any other explicit kind is rejected.",
							},
							"options": map[string]any{
								"type": "array",
								"items": map[string]any{
									"type": "object",
									"properties": map[string]any{
										"label":       str(),
										"recommended": map[string]any{"type": "boolean"},
									},
									"required": []any{"label"},
								},
							},
						},
						"required": []any{"question"},
					},
				},
				"files": pathAndContent(true),
				"blocked": map[string]any{
					"type": "object",
					"properties": map[string]any{
						"paths":  strList(),
						"reason": str(),
					},
					"required": []any{"paths", "reason"},
				},
			},
		},
	}
}

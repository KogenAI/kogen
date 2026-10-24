// Package agent is what the shaper, the builder and the reviewer share: the prompts Kogen
// gives each model, the tool definitions the models see, the tools themselves (read_file,
// write_file, list_files, search_text, shell, view_image), the cut of long results and the
// bookkeeping of the request / tool-call loop (replayed items, call/output pairing,
// argument decoding). Every prompt byte, definition, result text and limit is the one the
// models have always been given: they are part of Kogen's contract with them.
package agent

import (
	"embed"
	"fmt"
	"strings"
)

//go:embed prompts/*.md
var promptFiles embed.FS

// Prompt names. The text of each is in prompts/<name>.md; docs/testing-rules.md is the
// file users read and prompts/testing-rules.md an identical copy (a test keeps them equal).
const (
	Builder                         = "builder"
	Reviewer                        = "reviewer"
	Shaper                          = "shaper"
	Refine                          = "refine"
	Init                            = "init"
	ShaperContextGuidance           = "shaper-context-guidance"
	ReadinessAcknowledgmentGuidance = "readiness-acknowledgment-guidance"
	FeasibilityGuidance             = "feasibility-guidance"
	TestingRules                    = "testing-rules"
)

// Names lists every prompt name.
func Names() []string {
	return []string{Builder, Reviewer, Shaper, Refine, Init, ShaperContextGuidance,
		ReadinessAcknowledgmentGuidance, FeasibilityGuidance, TestingRules}
}

// shared are the passages that more than one prompt, or a tool definition, repeats. A
// template names them as {{name}}.
func shared() map[string]string {
	return map[string]string{
		FeasibilityGuidance:             file(FeasibilityGuidance),
		ReadinessAcknowledgmentGuidance: file(ReadinessAcknowledgmentGuidance),
	}
}

func file(name string) string {
	b, err := promptFiles.ReadFile("prompts/" + name + ".md")
	if err != nil {
		panic(fmt.Sprintf("agent: unknown prompt %q", name))
	}
	return string(b)
}

// Prompt is the complete text of the named prompt, byte for byte what the model receives
// (including its final newline). It panics on a name that is not one of the constants: the
// names are fixed by the program, not by users.
func Prompt(name string) string { return Render(file(name), shared()) }

// Render replaces each {{name}} in template with vars[name]; text without a matching
// variable stays as it is.
func Render(template string, vars map[string]string) string {
	if len(vars) == 0 {
		return template
	}
	pairs := make([]string, 0, 2*len(vars))
	for k, v := range vars {
		pairs = append(pairs, "{{"+k+"}}", v)
	}
	return strings.NewReplacer(pairs...).Replace(template)
}

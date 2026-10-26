// Command driver exposes the two internal functions the bounded-tool-results suite observes and that have no
// user-visible form of their own: the shared tool-result boundary (tools.Output.Cut, as Shape, Refine, Build and
// Review deliver every result) and the context measurement (tools.Measure).
//
//	driver boundary <input.json>      JSON receipt of the boundary observations
//	driver tool <root> <name> <json>  the uncut text result of one production tool call in <root>
//	driver cut                        the bounded form of the text on stdin
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"kogen-loop/tools"
)

func encode(v any) []byte {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		fail(err)
	}
	return b.Bytes()
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}

// deliver is what every role puts in a function_call_output for a result: the bounded text, or the typed parts unchanged.
func deliver(callID string, result tools.Output) map[string]any {
	return tools.OutputItem(callID, result.Cut())
}

func boundary(spec map[string]any) map[string]any {
	var sources []string
	for _, n := range spec["sizes"].([]any) {
		sources = append(sources, strings.Repeat("x", int(n.(float64))))
	}
	sources = append(sources,
		strings.Repeat("\"\\\t\r\n\u0001", 20_000),
		strings.Repeat("Δ🙂", 20_000),
		"Readiness observations\n"+strings.Repeat("feedback", 90_000))
	results := []any{}
	for n, source := range sources {
		id := fmt.Sprintf("boundary-%d", n)
		out := deliver(id, tools.Output{Text: source})
		actual := out["output"].(string)
		again := deliver(id, tools.Output{Text: actual})["output"]
		results = append(results, map[string]any{"source": source, "actual": actual, "again": again, "call_id": out["call_id"], "expected_call_id": id})
	}
	image := []any{
		map[string]any{"type": "input_text", "text": "{\"fixture\":true}"},
		map[string]any{"type": "input_image", "image_url": "data:image/png;base64,fixture"},
	}
	typed := deliver("typed-fixture", tools.Output{Parts: image})
	base := func(padding string) map[string]any {
		return map[string]any{"model": "fixture", "reasoning": map[string]any{"effort": "high"}, "instructions": "fixture policy", "input": []any{}, "tools": []any{}, "padding": padding}
	}
	empty, err := tools.Measure(base(""))
	if err != nil {
		fail(err)
	}
	ceiling := int(spec["ceiling"].(float64))
	var bytesOut []int
	var fits []bool
	var reserves []int
	for _, size := range []int{ceiling - 1, ceiling, ceiling + 1} {
		m, err := tools.Measure(base(strings.Repeat("x", size-empty.RenderedBytes)))
		if err != nil {
			fail(err)
		}
		bytesOut = append(bytesOut, m.RenderedBytes)
		fits = append(fits, m.Fits)
		reserves = append(reserves, m.OutputReserveTokens)
	}
	return map[string]any{
		"mode": "boundary", "results": results,
		"typed":   map[string]any{"source": image, "actual": typed["output"], "call_id": typed["call_id"], "expected_call_id": "typed-fixture"},
		"measure": map[string]any{"bytes": bytesOut, "fits": fits, "reserves": reserves},
	}
}

func main() {
	if len(os.Args) == 3 && os.Args[1] == "boundary" {
		raw, err := os.ReadFile(os.Args[2])
		if err != nil {
			fail(err)
		}
		var spec map[string]any
		if err := json.Unmarshal(raw, &spec); err != nil {
			fail(err)
		}
		os.Stdout.Write(encode(boundary(spec)))
		return
	}
	if len(os.Args) == 5 && os.Args[1] == "tool" {
		args := tools.DecodeArguments(os.Args[4])
		tl := &tools.Tools{Root: os.Args[2], Enabled: []string{"read_file", "list_files", "search_text", "probe"}}
		out, err := tl.Run(os.Args[3], args)
		if err != nil {
			fail(err)
		}
		os.Stdout.WriteString(out.Text)
		return
	}
	if len(os.Args) == 2 && os.Args[1] == "cut" {
		text, err := io.ReadAll(os.Stdin)
		if err != nil {
			fail(err)
		}
		os.Stdout.WriteString(tools.Cut(string(text)))
		return
	}
	fail(fmt.Errorf("usage: driver boundary <input.json> | driver tool <root> <name> <json> | driver cut"))
}

// Command driver exposes the three internal functions the review-refine-working-room suite observes and that have no
// user-visible form of their own: how a received item is replayed (tools.ReplayItem), what a production tool delivers
// to the model for a call (tools.Tools.Run then the shared bounded delivery), and how the complete rendered request
// body is measured against the context budget (provider.Client.Body and tools.Measure).
//
//	driver replay                    JSON array of items on stdin -> JSON array of their replayed form (null: not replayed)
//	driver tool <root> <name> <json> the text the model receives for one production tool call in <root>
//	driver measure <spec.json>       JSON receipt of the inclusive-boundary measurement
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"kogen-loop/provider"
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

func measure(spec map[string]any) map[string]any {
	budget := int(spec["budget"].(float64))
	literal := spec["literal"].(string)
	client := provider.NewClient("")
	base := client.Body(provider.Request{
		Role:         provider.Role{Model: "fixture", Effort: "high"},
		Instructions: "policy",
		Input:        []any{map[string]any{"role": "user", "content": literal}},
	})
	body := func(n int) map[string]any {
		out := map[string]any{}
		for k, v := range base {
			out[k] = v
		}
		out["padding"] = ""
		empty := len(bytes.TrimRight(encode(out), "\n"))
		out["padding"] = strings.Repeat("x", n-empty)
		return out
	}
	var sizes, reserves []int
	var fits []bool
	complete := true
	for _, n := range []int{budget - 1, budget, budget + 1} {
		b := body(n)
		m, err := tools.Measure(b)
		if err != nil {
			fail(err)
		}
		sizes = append(sizes, m.RenderedBytes)
		fits = append(fits, m.Fits)
		reserves = append(reserves, m.OutputReserveTokens)
		complete = complete && len(bytes.TrimRight(encode(b), "\n")) == m.RenderedBytes
	}
	return map[string]any{"bytes": sizes, "fits": fits, "reserve": reserves, "complete_rendered": complete}
}

func main() {
	switch {
	case len(os.Args) == 2 && os.Args[1] == "replay":
		raw, err := io.ReadAll(os.Stdin)
		if err != nil {
			fail(err)
		}
		var items []map[string]any
		if err := json.Unmarshal(raw, &items); err != nil {
			fail(err)
		}
		out := make([]any, len(items))
		for i, item := range items {
			if r := tools.ReplayItem(item); r != nil {
				out[i] = r
			}
		}
		os.Stdout.Write(encode(out))
	case len(os.Args) == 5 && os.Args[1] == "tool":
		tl := &tools.Tools{Root: os.Args[2], Enabled: []string{"read_file", "list_files", "search_text"}}
		out, err := tl.Run(os.Args[3], tools.DecodeArguments(os.Args[4]))
		if err != nil {
			fail(err)
		}
		os.Stdout.WriteString(out.Cut().Text)
	case len(os.Args) == 3 && os.Args[1] == "measure":
		raw, err := os.ReadFile(os.Args[2])
		if err != nil {
			fail(err)
		}
		var spec map[string]any
		if err := json.Unmarshal(raw, &spec); err != nil {
			fail(err)
		}
		os.Stdout.Write(encode(measure(spec)))
	default:
		fail(fmt.Errorf("usage: driver replay | driver tool <root> <name> <json> | driver measure <spec.json>"))
	}
}

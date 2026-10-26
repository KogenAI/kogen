// Command driver exposes the two internal functions the shape-working-summary suite observes and that have no
// user-visible form of their own: how a received item is replayed (tools.ReplayItem) and what a production tool
// delivers to the model for a call (tools.Tools.Run then the shared bounded delivery), which the suite uses for
// the numbered-line retrieval of a documentation snapshot.
//
//	driver replay                    JSON array of items on stdin -> JSON array of their replayed form (null: not replayed)
//	driver tool <root> <name> <json> the text the model receives for one production tool call
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"

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
	default:
		fail(fmt.Errorf("usage: driver replay | driver tool <root> <name> <json>"))
	}
}

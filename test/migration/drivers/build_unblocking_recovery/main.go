// Command driver exposes the two internal functions the build-unblocking-recovery suite compares and that have no
// user-visible form of their own: a production tool's full text result (what native Refine retains) and the bounded
// form every role delivers to a model (agent.Cut).
//
//	driver tool <root> <name> <json>  the uncut text result of one production tool call in <root>
//	driver cut                        the bounded form of the text on stdin
package main

import (
	"fmt"
	"io"
	"os"

	"kogen/agent"
)

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}

func main() {
	if len(os.Args) == 5 && os.Args[1] == "tool" {
		tools := &agent.Tools{Root: os.Args[2], Enabled: []string{"read_file", "list_files", "search_text"}}
		out, err := tools.Run(os.Args[3], agent.DecodeArguments(os.Args[4]))
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
		os.Stdout.WriteString(agent.Cut(string(text)))
		return
	}
	fail(fmt.Errorf("usage: driver tool <root> <name> <json> | driver cut"))
}

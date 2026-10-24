// A Kogen Lab style program: it uses Kogen's public Go packages directly.
// Usage: go run . [project folder]   (default: ./project)
package main

import (
	"fmt"
	"os"
	"strings"

	"kogen/agent"
	"kogen/project"
)

// first keeps the program valid whether agent.Prompt answers with a value alone or with a value and an error.
func first[T any](value T, _ ...error) T { return value }

func main() {
	root := "project"
	if len(os.Args) > 1 {
		root = os.Args[1]
	}
	if _, err := project.LoadIntent(root, "add-greeting"); err != nil {
		fmt.Fprintln(os.Stderr, "load:", err)
		os.Exit(1)
	}
	if _, _, err := project.CheckIntent(root, "add-greeting", nil); err != nil {
		fmt.Fprintln(os.Stderr, "check:", err)
		os.Exit(1)
	}
	fmt.Println("check: ok")
	var text string
	switch p := any(first(agent.Prompt("builder"))).(type) {
	case string:
		text = p
	case []byte:
		text = string(p)
	default:
		text = fmt.Sprint(p)
	}
	fmt.Println(strings.SplitN(text, "\n", 2)[0])
}

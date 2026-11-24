package main

import (
	"encoding/json"
	"os"

	"kogen/internal/claudecode"
)

func main() {
	home := os.Args[1]
	var result []string
	if os.Args[2] == "layout" {
		result = []string{
			claudecode.Root(home),
			claudecode.Version,
			claudecode.RuntimePath(home),
			claudecode.ActiveFile,
		}
	} else {
		version, path := claudecode.Active(home)
		result = []string{version, path}
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		panic(err)
	}
}

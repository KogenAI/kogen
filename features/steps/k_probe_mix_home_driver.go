package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"

	"github.com/KogenAI/kogen-verification/verify"
	"kogen-loop/sys"
)

// Probe driver for k-probe-mix-home: runs one Shape probe through verify.RunProbe from a caller session whose
// environment is exactly the JSON array of NAME=value strings in the given file, and prints the probe result
// as JSON. Arguments: <project root> <caller environment JSON file> <command>.
func main() {
	root, envFile, command := os.Args[1], os.Args[2], os.Args[3]
	var env []string
	b, err := os.ReadFile(envFile)
	if err == nil {
		err = json.Unmarshal(b, &env)
	}
	if err != nil {
		fmt.Println("GO ERROR: caller environment: " + err.Error())
		os.Exit(1)
	}
	r, err := verify.RunProbe(context.Background(), sys.NewWith(env, root), root, command, nil)
	if err != nil {
		fmt.Println("GO ERROR: " + err.Error())
		os.Exit(1)
	}
	out, _ := json.Marshal(r)
	fmt.Println(string(out))
}

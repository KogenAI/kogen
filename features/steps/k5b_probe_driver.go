package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"time"

	"kogen-loop/sys"
	"kogen/verify"
)

// Observation driver: runs two probes in one session through verify.RunProbe, the way one Shape round does,
// and prints both results as JSON. Arguments: <empty scratch root> <deadline ms, 0 = production> <command>.
func main() {
	root := os.Args[1]
	ms, _ := strconv.Atoi(os.Args[2])
	if ms > 0 {
		_, restore := verify.ContractProbeDeadline(time.Duration(ms)*time.Millisecond, nil)
		defer restore()
	}
	s := sys.New()
	ctx := context.Background()
	first, err := verify.RunProbe(ctx, s, root, os.Args[3], nil)
	if err != nil {
		fmt.Println("GO ERROR: " + err.Error())
		os.Exit(1)
	}
	second, err := verify.RunProbe(ctx, s, root, "echo continued", nil)
	if err != nil {
		fmt.Println("GO ERROR: " + err.Error())
		os.Exit(1)
	}
	b, _ := json.Marshal(map[string]any{"first": first, "second": second})
	fmt.Println(string(b))
}

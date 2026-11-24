package main

import (
	"encoding/json"
	"os"

	"github.com/KogenAI/kogen-loop/sys"
	"github.com/KogenAI/kogen-verification/verify"
	"kogen/readiness"
)

func main() {
	root, home := os.Args[1], os.Args[2]
	env := append(os.Environ(), "GIT_CEILING_DIRECTORIES="+root, "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
	checks := readiness.Run(sys.NewWith(env, root), readiness.Input{Project: root, Home: home, Version: "fixture", Tools: verify.Tools{Node: "/bin/true"}})
	for _, check := range checks {
		if check.Check == "config" {
			if err := json.NewEncoder(os.Stdout).Encode(struct {
				Check readiness.Check
				Text  string
			}{check, readiness.Text([]readiness.Check{check})}); err != nil {
				panic(err)
			}
			return
		}
	}
	panic("readiness.Run returned no config check")
}

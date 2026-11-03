// Observation only: reads one fake acceptance report with the real verify.Account of the
// kogen-verification version this program is built against and prints what it accounts.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/KogenAI/kogen-coordinator/project"
	"github.com/KogenAI/kogen-verification/verify"
)

func main() {
	if len(os.Args) != 5 {
		fmt.Fprintln(os.Stderr, "usage: driver <root> <feature> <report> <exit>")
		os.Exit(2)
	}
	root, feature, report := os.Args[1], os.Args[2], os.Args[3]
	status, err := strconv.Atoi(os.Args[4])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	text, err := os.ReadFile(filepath.Join(root, feature))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	expected, err := project.ParseGherkin(string(text))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	got := verify.Account(root, feature, expected, report, status, "")
	statuses := []string{}
	for _, s := range got.Scenarios {
		statuses = append(statuses, s.Status)
	}
	problems := []string{}
	for _, p := range got.Problems {
		first, _, _ := strings.Cut(p, "\n")
		problems = append(problems, first)
	}
	out, _ := json.Marshal(map[string]any{"statuses": statuses, "problems": problems})
	fmt.Println(string(out))
}

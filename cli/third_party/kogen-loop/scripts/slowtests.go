//go:build ignore

package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"
)

const allowlistPath = "scripts/slowtests-allowlist.txt"

type entry struct {
	pkg, test string
}

type event struct {
	Action  string
	Package string
	Test    string
	Elapsed float64
}

type result struct {
	pkg, test string
	action    string
	elapsed   float64
}

func main() {
	os.Exit(run())
}

func run() int {
	flags := flag.NewFlagSet("slowtests", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	thresholdText := flags.String("threshold", "2s", "report tests that take at least this long (Go duration)")
	if err := flags.Parse(os.Args[1:]); err != nil {
		return 2
	}
	if flags.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "slowtests: unexpected argument %q\n", flags.Arg(0))
		return 2
	}
	threshold, err := time.ParseDuration(*thresholdText)
	if err != nil || threshold <= 0 {
		fmt.Fprintf(os.Stderr, "slowtests: -threshold %q is not a positive Go duration\n", *thresholdText)
		return 2
	}
	allowlist, err := readAllowlist(allowlistPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "slowtests: %v\n", err)
		return 2
	}

	cmd := exec.Command("go", "test", "./...", "-count=1", "-json")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		fmt.Fprintf(os.Stderr, "slowtests: cannot run go: %v\n", err)
		return 2
	}
	if err := cmd.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "slowtests: cannot run go: %v\n", err)
		return 2
	}
	packages, tests, seen := readEvents(stdout)
	goFailed := cmd.Wait() != nil

	var out bytes.Buffer
	failed := goFailed

	sort.Slice(packages, func(i, j int) bool { return packages[i].pkg < packages[j].pkg })
	for _, p := range packages {
		fmt.Fprintf(&out, "package %s %s %s\n", p.action, duration(p.elapsed), p.pkg)
		if p.action == "fail" {
			failed = true
		}
	}

	var slow, bad []result
	for _, t := range tests {
		switch {
		case t.action == "fail":
			bad = append(bad, t)
		case t.elapsed >= threshold.Seconds():
			slow = append(slow, t)
		}
	}
	sort.Slice(slow, func(i, j int) bool {
		a, b := slow[i], slow[j]
		if a.elapsed != b.elapsed {
			return a.elapsed > b.elapsed
		}
		if a.pkg != b.pkg {
			return a.pkg < b.pkg
		}
		return a.test < b.test
	})
	for _, t := range slow {
		verdict := "over"
		if allowlist.has(entry{t.pkg, t.test}) {
			verdict = "allowed"
		} else {
			failed = true
		}
		fmt.Fprintf(&out, "slow %s %s %s %s\n", duration(t.elapsed), t.pkg, t.test, verdict)
	}
	sort.Slice(bad, func(i, j int) bool {
		if bad[i].pkg != bad[j].pkg {
			return bad[i].pkg < bad[j].pkg
		}
		return bad[i].test < bad[j].test
	})
	for _, t := range bad {
		failed = true
		fmt.Fprintf(&out, "failed %s %s %s\n", duration(t.elapsed), t.pkg, t.test)
	}
	for _, e := range allowlist.order {
		if !seen[e] {
			fmt.Fprintf(&out, "stale %s %s\n", e.pkg, e.test)
		}
	}
	os.Stdout.Write(out.Bytes())
	if failed {
		return 1
	}
	return 0
}

func duration(seconds float64) string {
	return fmt.Sprintf("%.2fs", seconds)
}

// readEvents decodes a go test -json stream. It returns the final package
// results, the final results of top-level tests, and the set of top-level
// tests that produced any event.
func readEvents(r io.Reader) (packages, tests []result, seen map[entry]bool) {
	pkgFinal := map[string]result{}
	testFinal := map[entry]result{}
	seen = map[entry]bool{}
	reader := bufio.NewReader(r)
	for {
		line, err := reader.ReadBytes('\n')
		line = bytes.TrimSpace(line)
		if len(line) > 0 && line[0] == '{' {
			var ev event
			if json.Unmarshal(line, &ev) == nil && ev.Package != "" {
				record(ev, pkgFinal, testFinal, seen)
			}
		}
		if err != nil {
			break
		}
	}
	for _, p := range pkgFinal {
		packages = append(packages, p)
	}
	for _, t := range testFinal {
		tests = append(tests, t)
	}
	return packages, tests, seen
}

func record(ev event, pkgFinal map[string]result, testFinal map[entry]result, seen map[entry]bool) {
	final := ev.Action == "pass" || ev.Action == "fail" || ev.Action == "skip"
	if ev.Test == "" {
		if final {
			pkgFinal[ev.Package] = result{pkg: ev.Package, action: ev.Action, elapsed: ev.Elapsed}
		}
		return
	}
	top, _, subtest := strings.Cut(ev.Test, "/")
	key := entry{ev.Package, top}
	seen[key] = true
	if final && !subtest {
		testFinal[key] = result{pkg: ev.Package, test: top, action: ev.Action, elapsed: ev.Elapsed}
	}
}

type allowed struct {
	order []entry
	set   map[entry]bool
}

func (a allowed) has(e entry) bool {
	return a.set[e]
}

func readAllowlist(path string) (allowed, error) {
	a := allowed{set: map[entry]bool{}}
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return a, nil
	}
	if err != nil {
		return a, err
	}
	for i, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		before, reason, ok := strings.Cut(line, "#")
		if !ok {
			return a, fmt.Errorf("%s:%d: entry has no \"# <reason>\"", path, i+1)
		}
		fields := strings.Fields(before)
		if len(fields) != 2 {
			return a, fmt.Errorf("%s:%d: entry is not \"<import path> <TestName> # <reason>\"", path, i+1)
		}
		if strings.TrimSpace(reason) == "" {
			return a, fmt.Errorf("%s:%d: entry has an empty reason", path, i+1)
		}
		e := entry{fields[0], fields[1]}
		a.order = append(a.order, e)
		a.set[e] = true
	}
	return a, nil
}

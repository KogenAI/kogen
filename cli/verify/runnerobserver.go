package verify

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// A step that observes a test runner is checked against the runner's real output on the
// unchanged tree. Two shaped-observer mistakes show in the failing step's message: it failed
// although the minitest run it observed passed (the observer expected other summary wording), or
// an anchored regular expression given as a literal -n/-i name filter made the run match nothing.

var (
	// minitestSummaryRe is minitest's summary line: "N runs" under the default reporter, "N tests"
	// under progress reporters.
	minitestSummaryRe = regexp.MustCompile(`\b(\d+) (runs|tests), (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips\b`)
	// nameFilterRe is a name filter option of a "Run options:" line: a double-quoted value (as
	// minitest quotes values with `$`, spaces and similar) or the next run of non-whitespace.
	nameFilterRe = regexp.MustCompile(`(?:^|\s)(-n|-i|--name|--include)(?:\s+|=)(?:"([^"]*)"|(\S+))`)
)

// runnerObserver is the runner-observer result of a failed step's message, or "" when the
// message shows no minitest summary, a summary with any failure, error or skip, or zero runs
// with a plain name or a /…/ filter.
func runnerObserver(msg string) string {
	all := minitestSummaryRe.FindAllStringSubmatch(msg, -1)
	if len(all) == 0 {
		return ""
	}
	m := all[len(all)-1]
	n := func(i int) int { v, _ := strconv.Atoi(m[i]); return v }
	runs, failures, errs, skips := n(1), n(4), n(5), n(6)
	summary := m[0]
	if runs >= 1 {
		if failures+errs+skips != 0 {
			return ""
		}
		return "the step failed although the test runner reported a passing run: " + summary
	}
	for _, line := range strings.Split(msg, "\n") {
		i := strings.Index(line, "Run options:")
		if i < 0 {
			continue
		}
		for _, f := range nameFilterRe.FindAllStringSubmatch(line[i:], -1) {
			value := f[2] + f[3]
			if !strings.HasPrefix(value, "^") && !strings.HasSuffix(value, "$") {
				continue
			}
			if len(value) >= 2 && strings.HasPrefix(value, "/") && strings.HasSuffix(value, "/") {
				continue
			}
			return fmt.Sprintf("the name filter %s %s is a regular expression that the runner matched as a literal test name, so nothing ran: %s", f[1], value, summary)
		}
	}
	return ""
}

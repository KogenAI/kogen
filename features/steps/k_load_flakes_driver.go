package claudecode

import "os"

// The k-load-flakes acceptance mounts this file with go -overlay. KOGEN_K_LOAD_FLAKES_START, when
// set, is the shell line the fake claude of TestPreflightStopsOwnedChildren runs first, before it
// signals its start: "sleep 6" delays that start past five seconds, "exit 0" means it never starts.
func init() {
	if start, ok := os.LookupEnv("KOGEN_K_LOAD_FLAKES_START"); ok {
		preflightFakeStart = start + "\n"
	}
}

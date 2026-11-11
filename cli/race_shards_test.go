package main

import (
	"os/exec"
	"testing"
)

func TestRaceShardRunner(t *testing.T) {
	t.Parallel()
	cmd := exec.Command("node", "--test", "../test/race-shards.test.cjs")
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("race shard runner tests: %v\n%s", err, output)
	}
}

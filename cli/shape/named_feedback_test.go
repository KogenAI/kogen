package shape

import (
	"strings"
	"testing"
)

func TestNamedFeedbackShapeGuidance(t *testing.T) {
	parallel(t)
	f := newShpFx(t, shpSubmit("c1", shpFiles()), shpAck("c2"))
	if exit, err := f.shape("Add calc.is_even(n). Non-integers raise TypeError."); err != nil || exit != 0 {
		t.Fatalf("exit %d, err %v\nstderr: %s", exit, err, f.Stderr)
	}
	instructions, _ := f.Prov.requests()[0]["instructions"].(string)
	for _, want := range []string{
		"Named-test helpers:",
		"every assertion message must include the required test name",
		"bare count such as `0 !== 1`",
		"the command or package the helper ran",
	} {
		shpContains(t, "the instructions Shape sent", instructions, want)
	}
	shpContains(t, "the instructions Shape sent", instructions, "Named-test helpers:")
	if !strings.Contains(instructions, namedTestGuidance+unwrittenTestGuidance) {
		t.Fatal("the unwritten-tests paragraph does not follow the named-test guidance")
	}
	if !strings.Contains(instructions, unwrittenTestGuidance+runnerObserverGuidance) {
		t.Fatal("the test-runner observers paragraph does not follow the unwritten-tests guidance")
	}
	if !strings.HasSuffix(instructions, runnerObserverGuidance) || !strings.HasPrefix(runnerObserverGuidance, "Test-runner observers: ") {
		t.Fatal("the test-runner observers paragraph is not the end of Shape's instructions")
	}
	if strings.Contains(refineInstructions(), "Test-runner observers:") {
		t.Fatal("refine instructions carry the test-runner observers guidance")
	}
	if strings.Contains(refineInstructions(), "Unwritten tests:") {
		t.Fatal("refine instructions carry the unwritten-tests guidance")
	}
	// The guidance is Shape's alone: a correction conversation does not carry it.
	if strings.Contains(refineInstructions(), "Named-test helpers:") {
		t.Fatal("refine instructions carry the new-Intent shaping guidance")
	}
}

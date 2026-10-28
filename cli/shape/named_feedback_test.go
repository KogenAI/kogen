package shape

import (
	"strings"
	"testing"
)

func TestNamedFeedbackShapeGuidance(t *testing.T) {
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
	// The guidance is Shape's alone: a correction conversation does not carry it.
	if strings.Contains(refineInstructions(), "Named-test helpers:") {
		t.Fatal("refine instructions carry the new-Intent shaping guidance")
	}
}

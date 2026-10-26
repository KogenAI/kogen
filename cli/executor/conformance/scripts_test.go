package conformance

import "testing"

// TestScriptsParse keeps every script strictly decodable and named after its file.
func TestScriptsParse(t *testing.T) {
	s, err := Scripts()
	if err != nil {
		t.Fatal(err)
	}
	if len(s) < 11 {
		t.Fatalf("%d scripts, want the 11 required by the contract", len(s))
	}
}

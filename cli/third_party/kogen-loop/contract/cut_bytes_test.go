package contract_test

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"kogen-loop/tools"
)

// TestCutRecordedBytes pins the delivered strings for the line-alignment fixtures.
func TestCutRecordedBytes(t *testing.T) {
	data, err := os.ReadFile("testdata/cut_bytes.json")
	if err != nil {
		t.Fatal(err)
	}
	var recordings map[string]string
	if err := json.Unmarshal(data, &recordings); err != nil {
		t.Fatal(err)
	}
	inputs := map[string]string{
		"lines":   strings.Repeat(strings.Repeat("x", 79)+"\n", 500),
		"single":  strings.Repeat("x", 30000),
		"unicode": strings.Repeat("€", 10000),
		"16383":   strings.Repeat("x", 16383),
		"16384":   strings.Repeat("x", 16384),
		"16385":   strings.Repeat("x", 16385),
	}
	for name, input := range inputs {
		t.Run(name, func(t *testing.T) {
			want, ok := recordings[name]
			if !ok {
				t.Fatalf("missing recording %q", name)
			}
			if got := tools.Cut(input); got != want {
				t.Errorf("Cut output differs from recording %q", name)
			}
		})
	}
}

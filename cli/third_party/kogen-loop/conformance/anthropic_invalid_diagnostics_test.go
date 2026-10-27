package conformance

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

func TestAnthropicInvalidDiagnosticsConformance(t *testing.T) {
	b, err := os.ReadFile("anthropic-invalid-diagnostics-testdata/invalid-thinking.json")
	if err != nil {
		t.Fatal(err)
	}
	var want map[string]any
	if err := json.Unmarshal(b, &want); err != nil {
		t.Fatal(err)
	}
	for _, facade := range []string{"Direct", "Session", "CLI"} {
		t.Run(facade, func(t *testing.T) {
			got := runStreamAnthropic(t, facade, "invalid_later")
			if len(got.Records) != 1 || !reflect.DeepEqual(got.Records[0]["provider_failure"], want) {
				t.Fatalf("records: %v", got.Records)
			}
		})
	}
}

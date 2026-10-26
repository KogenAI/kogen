package conformance

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestMalformedTaskObjectIsRefusedBeforeSessionOrRequest(t *testing.T) {
	w := newWorld(t).signIn()
	base, err := json.Marshal(w.task(nil))
	if err != nil {
		t.Fatal(err)
	}
	for name, text := range map[string]string{
		"trailing bracket": string(base) + "]",
		"trailing brace":   string(base) + "}",
		"null":             "null",
	} {
		t.Run(name, func(t *testing.T) {
			f := newFakeProvider(t, []exchange{{Items: []map[string]any{message("claim")}}})
			r := runCLIRaw(t, w, f, []byte(text))
			expectRefusal(t, r, f, "loop", "invalid_task", 2)
			if !reflect.DeepEqual(r.types(), []string{"error", "session.ended"}) {
				t.Fatalf("invalid task events: %v", r.types())
			}
		})
	}
}

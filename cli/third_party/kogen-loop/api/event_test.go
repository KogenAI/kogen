package api_test

import (
	"encoding/json"
	"fmt"
	"reflect"
	"testing"

	"github.com/KogenAI/kogen-loop/api"
)

func TestEventMarshalJSONRejectsEnvelopeCollisions(t *testing.T) {
	for _, key := range []string{"protocol", "seq", "time", "type"} {
		t.Run(key, func(t *testing.T) {
			event := api.Event{
				Protocol: "kogen-loop/v1",
				Seq:      1,
				Time:     "2026-01-01T00:00:00Z",
				Type:     "request.started",
				Fields:   map[string]any{key: "replacement"},
			}
			_, err := event.MarshalJSON()
			want := fmt.Sprintf("event field %q collides with the envelope", key)
			if err == nil || err.Error() != want {
				t.Fatalf("MarshalJSON error = %v, want %q", err, want)
			}
		})
	}
}

func TestEventMarshalJSONFlattensOrdinaryFields(t *testing.T) {
	event := api.Event{
		Protocol: "kogen-loop/v1",
		Seq:      1,
		Time:     "2026-01-01T00:00:00Z",
		Type:     "request.started",
		Fields:   map[string]any{"n": 3, "model": "test-model"},
	}
	data, err := event.MarshalJSON()
	if err != nil {
		t.Fatalf("MarshalJSON: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("decode MarshalJSON result: %v", err)
	}
	want := map[string]any{
		"protocol": "kogen-loop/v1",
		"seq":      float64(1),
		"time":     "2026-01-01T00:00:00Z",
		"type":     "request.started",
		"n":        float64(3),
		"model":    "test-model",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("decoded event = %#v, want %#v", got, want)
	}
}

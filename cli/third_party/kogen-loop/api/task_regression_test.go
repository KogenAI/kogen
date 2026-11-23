package api_test

import (
	"strings"
	"testing"

	"github.com/KogenAI/kogen-loop/api"
)

func TestDecodeTaskRequiresExactlyOneObject(t *testing.T) {
	for _, text := range []string{
		`null`,
		`{}]`,
		`{}}`,
		`{} garbage`,
	} {
		t.Run(text, func(t *testing.T) {
			if _, err := api.DecodeTask(strings.NewReader(text)); err == nil {
				t.Fatal("accepted a task that is not exactly one JSON object")
			}
		})
	}
	got, err := api.DecodeTask(strings.NewReader(" \n{\"prompt\":\"hello\"}\t\n"))
	if err != nil || got.Prompt != "hello" {
		t.Fatalf("valid object with surrounding whitespace: task %+v, error %v", got, err)
	}
}

func TestDecodeTaskRejectsUnknownTopLevelField(t *testing.T) {
	_, err := api.DecodeTask(strings.NewReader(`{"prompt":"hello","surprise_field":1}`))
	if err == nil {
		t.Fatal("accepted a task with an unknown top-level field")
	}
	if !strings.Contains(err.Error(), "surprise_field") {
		t.Fatalf("error %q does not name the unknown field surprise_field", err)
	}
}

func TestDecodeTaskRejectsUnknownNestedField(t *testing.T) {
	for _, tc := range []struct{ object, field string }{
		{"role", "surprise_role_field"},
		{"session", "surprise_session_field"},
	} {
		t.Run(tc.object, func(t *testing.T) {
			text := `{"prompt":"hello","` + tc.object + `":{"` + tc.field + `":1}}`
			_, err := api.DecodeTask(strings.NewReader(text))
			if err == nil {
				t.Fatalf("accepted a task with an unknown field inside %q", tc.object)
			}
			if !strings.Contains(err.Error(), tc.field) {
				t.Fatalf("error %q does not name the unknown field %s", err, tc.field)
			}
		})
	}
}

func TestDecodeTaskAcceptsKnownNestedFields(t *testing.T) {
	text := `{"prompt":"hello",` +
		`"role":{"provider":"anthropic","model":"m","effort":"high","base_url":"http://example.test"},` +
		`"session":{"dir":"/tmp/s","resume":true}}`
	got, err := api.DecodeTask(strings.NewReader(text))
	if err != nil {
		t.Fatalf("rejected a task with only known nested fields: %v", err)
	}
	wantRole := api.Role{Provider: "anthropic", Model: "m", Effort: "high", BaseURL: "http://example.test"}
	if got.Role != wantRole {
		t.Fatalf("role = %+v, want %+v", got.Role, wantRole)
	}
	wantSession := api.SessionSpec{Dir: "/tmp/s", Resume: true}
	if got.Session != wantSession {
		t.Fatalf("session = %+v, want %+v", got.Session, wantSession)
	}
}

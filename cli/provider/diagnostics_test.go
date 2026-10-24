package provider

import (
	"reflect"
	"strings"
	"testing"
)

func failed(errBody any) handler {
	return events(map[string]any{"type": "response.failed", "response": map[string]any{"error": errBody}})
}

func failureOf(t *testing.T, h []handler) (*sysErrorView, *fake) {
	t.Helper()
	e, f := chatEnv(t, h...)
	_, err := e.respond(Request{})
	se := mustErr(t, err)
	return &sysErrorView{se.Reason, se.Detail, se.ProviderFailure, se.Render()}, f
}

type sysErrorView struct {
	Reason, Detail string
	Failure        map[string]any
	Rendered       string
}

// provider_diagnostics_test: unknown structured stream failure retains safe fields.
func TestUnknownStructuredStreamFailureRetainsSafeFields(t *testing.T) {
	v, f := failureOf(t, []handler{failed(map[string]any{
		"code": "unknown_overload", "type": "provider_capacity", "message": "structured overload",
		"access_token": "SECRET-TOKEN-MARKER", "request": "PRIVATE-PAYLOAD-MARKER"})})
	if v.Reason != "refused" || !strings.Contains(v.Rendered, "unknown_overload") || !strings.Contains(v.Rendered, "provider_capacity") || !strings.Contains(v.Rendered, "response.failed") {
		t.Fatalf("rendered = %q", v.Rendered)
	}
	if !reflect.DeepEqual(v.Failure, map[string]any{"code": "unknown_overload", "type": "provider_capacity", "event_kind": "response.failed"}) {
		t.Fatalf("failure = %v", v.Failure)
	}
	if strings.Contains(v.Rendered, "SECRET-TOKEN-MARKER") || strings.Contains(v.Rendered, "PRIVATE-PAYLOAD-MARKER") || len(f.requests()) != 1 {
		t.Fatal("secret leaked or retried")
	}
	if !strings.Contains(v.Rendered, `provider failure: {"code":"unknown_overload","event_kind":"response.failed","type":"provider_capacity"}`) {
		t.Fatalf("rendered = %q", v.Rendered)
	}
}

// provider_diagnostics_test: HTTP failure metadata without request payload.
func TestHTTPFailureMetadataWithoutPayload(t *testing.T) {
	v, _ := failureOf(t, []handler{jsonAnswer(400, map[string]any{"error": map[string]any{
		"code": "unknown_http_code", "type": "invalid_request", "message": "structured HTTP failure", "authorization": "SECRET-AUTH-MARKER"}})})
	want := map[string]any{"code": "unknown_http_code", "type": "invalid_request", "http_status": int64(400)}
	if v.Detail != "ChatGPT refused the request: 400 structured HTTP failure" || !reflect.DeepEqual(v.Failure, want) || strings.Contains(v.Rendered, "SECRET-AUTH-MARKER") {
		t.Fatalf("%q %v", v.Detail, v.Failure)
	}
}

// provider_diagnostics_test: known structured transients keep three attempts and final diagnostics.
func TestKnownStructuredTransientsKeepThreeAttempts(t *testing.T) {
	one := failed(map[string]any{"code": "server_error", "type": "capacity", "message": "known transient"})
	v, f := failureOf(t, []handler{one, one, one, textAnswer("never")})
	if v.Reason != "unavailable" || v.Detail != "ChatGPT did not answer after 3 attempts: server_error: known transient" ||
		!reflect.DeepEqual(v.Failure, map[string]any{"code": "server_error", "type": "capacity", "event_kind": "response.failed"}) || len(f.requests()) != 3 {
		t.Fatalf("%+v after %d requests", v, len(f.requests()))
	}
}

// provider_diagnostics_test: no-code and malformed stream error fields remain safe fallbacks.
func TestNoCodeAndMalformedStreamErrorFieldsAreSafe(t *testing.T) {
	for i, errField := range []any{
		map[string]any{"message": "no-code failure"},
		"malformed error",
		map[string]any{"code": map[string]any{"bad": "PRIVATE-MARKER"}, "type": []any{"PRIVATE-MARKER"}, "message": map[string]any{}},
	} {
		v, f := failureOf(t, []handler{events(map[string]any{"type": "error", "error": errField})})
		if v.Reason != "refused" || !reflect.DeepEqual(v.Failure, map[string]any{"event_kind": "error"}) || strings.Contains(v.Rendered, "PRIVATE-MARKER") || len(f.requests()) != 1 {
			t.Fatalf("case %d: %+v", i, v)
		}
	}
}

// provider_diagnostics_test: context and login wrappers preserve known response metadata.
func TestContextFailurePreservesMetadataWithoutChangingTheError(t *testing.T) {
	v, f := failureOf(t, []handler{failed(map[string]any{"code": "context_length_exceeded", "type": "request_error", "message": "context limit"})})
	if v.Reason != "context_too_long" || !reflect.DeepEqual(v.Failure, map[string]any{"code": "context_length_exceeded", "type": "request_error", "event_kind": "response.failed"}) || len(f.requests()) != 1 {
		t.Fatalf("%+v", v)
	}
}

// provider_diagnostics_test: a flat error event retains code and event kind without
// inventing an error subtype.
func TestFlatErrorEventRetainsCodeAndKind(t *testing.T) {
	v, _ := failureOf(t, []handler{events(map[string]any{"type": "error", "code": "unknown_flat_code", "message": "flat failure", "request": "PRIVATE-FLAT-MARKER"})})
	if v.Detail != "ChatGPT refused the request: stream flat failure" || !reflect.DeepEqual(v.Failure, map[string]any{"code": "unknown_flat_code", "event_kind": "error"}) || strings.Contains(v.Rendered, "PRIVATE-FLAT-MARKER") {
		t.Fatalf("%+v", v)
	}
}

// provider_diagnostics_test: incomplete stream diagnostics do not present an internal
// marker as provider code.
func TestIncompleteStreamHasNoInternalCode(t *testing.T) {
	v, _ := failureOf(t, []handler{events(map[string]any{"type": "response.incomplete", "response": map[string]any{"incomplete_details": map[string]any{"reason": "max_output_tokens"}}})})
	if v.Reason != "refused" || !reflect.DeepEqual(v.Failure, map[string]any{"event_kind": "response.incomplete"}) {
		t.Fatalf("%+v", v)
	}
}

func TestDiagnosticsOmitIllTypedFields(t *testing.T) {
	f := failure{status: "stream", code: "", typ: 7, eventKind: "", message: "m"}
	if len(f.diagnostics()) != 0 {
		t.Fatalf("%v", f.diagnostics())
	}
	f = failure{status: int64(429), code: "c", typ: "t", eventKind: "error"}
	if !reflect.DeepEqual(f.diagnostics(), map[string]any{"code": "c", "type": "t", "event_kind": "error", "http_status": int64(429)}) {
		t.Fatalf("%v", f.diagnostics())
	}
}

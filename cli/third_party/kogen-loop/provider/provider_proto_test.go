package provider

import (
	"context"
	"reflect"
	"strings"
	"testing"
)

// protoRecords runs one logical request (single-shot or with retries) and returns its error
// and attempt records.
func protoRecords(t *testing.T, e *env, single bool) (*Response, error, []map[string]any) {
	t.Helper()
	obs := &observer{}
	resp, err := e.c.Respond(context.Background(), e.s, Request{Role: fixtureRole, Instructions: "fixture", Single: single}, obs)
	return resp, err, obs.records()
}

// protoPlain is a record field as its JSON would carry it, so ints compare as the log reads them.
func protoPlain(t *testing.T, v any) any {
	t.Helper()
	out, err := decodeJSON(mustEncode(v))
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func protoUsage(in, cached, write, out, reasoning any) map[string]any {
	return map[string]any{"input": in, "cached": cached, "write": write, "write_30m": nil, "write_12h": nil, "output": out, "reasoning": reasoning}
}

func protoEnvelope(id string, extra map[string]any) map[string]any {
	return with(map[string]any{"id": id, "model": "gpt-fixture"}, flatten(extra)...)
}

func flatten(m map[string]any) []any {
	var kv []any
	for k, v := range m {
		kv = append(kv, k, v)
	}
	return kv
}

func limitUsage() map[string]any {
	return map[string]any{"input_tokens": int64(1000), "input_tokens_details": map[string]any{"cached_tokens": int64(200)},
		"output_tokens": int64(500), "output_tokens_details": map[string]any{"reasoning_tokens": int64(400)}}
}

// TestProviderProtoTerminalAccounting: a failed or incomplete terminal envelope's identity
// and usage reach the failed attempt record whatever its output, with the same nullable
// consistency rules as a completed response; a cut stream stays unknown.
func TestProviderProtoTerminalAccounting(t *testing.T) {
	incomplete := func(resp map[string]any) map[string]any {
		return map[string]any{"type": "response.incomplete", "response": resp}
	}
	failedEvent := func(resp map[string]any) map[string]any {
		return map[string]any{"type": "response.failed", "response": resp}
	}
	limit := protoEnvelope("resp_limit", map[string]any{"usage": limitUsage(), "incomplete_details": map[string]any{"reason": "max_output_tokens"}})
	pendingItem := map[string]any{"type": "response.output_item.added", "output_index": int64(0)}
	cases := []struct {
		name   string
		frames []any
		reason string
		fail   map[string]any // the typed error's provider failure, which is unchanged
		id     any
		usage  map[string]any
		state  string
		diag   map[string]any // the record's provider_failure
	}{
		{"incomplete with the reported counts", []any{incomplete(limit)}, "refused",
			map[string]any{"event_kind": "response.incomplete"}, "resp_limit", protoUsage(1000, 200, nil, 500, 400), "partial",
			map[string]any{"event_kind": "response.incomplete", "incomplete_reason": "max_output_tokens"}},
		{"incomplete over a pending tool call", []any{pendingItem, incomplete(limit)}, "refused",
			map[string]any{"event_kind": "response.incomplete"}, "resp_limit", protoUsage(1000, 200, nil, 500, 400), "partial",
			map[string]any{"event_kind": "response.incomplete", "incomplete_reason": "max_output_tokens"}},
		{"incomplete over an unusable finished tool call", []any{itemDone(0, with(tool(), "arguments", "PRIVATE-invalid")), incomplete(limit)}, "refused",
			map[string]any{"event_kind": "response.incomplete"}, "resp_limit", protoUsage(1000, 200, nil, 500, 400), "partial",
			map[string]any{"event_kind": "response.incomplete", "incomplete_reason": "max_output_tokens"}},
		{"failed with the reported counts", []any{failedEvent(protoEnvelope("resp_failed", map[string]any{
			"usage": limitUsage(), "error": map[string]any{"code": "unknown_failure", "type": "provider_capacity", "message": "PRIVATE-message"}}))}, "refused",
			map[string]any{"code": "unknown_failure", "type": "provider_capacity", "event_kind": "response.failed"}, "resp_failed", protoUsage(1000, 200, nil, 500, 400), "partial",
			map[string]any{"code": "unknown_failure", "type": "provider_capacity", "event_kind": "response.failed"}},
		{"failed without usage keeps the identity", []any{failedEvent(protoEnvelope("resp_nousage", map[string]any{"error": map[string]any{"code": "unknown_failure"}}))}, "refused",
			map[string]any{"code": "unknown_failure", "event_kind": "response.failed"}, "resp_nousage", protoUsage(nil, nil, nil, nil, nil), "unknown",
			map[string]any{"code": "unknown_failure", "event_kind": "response.failed"}},
		{"failed with inconsistent usage", []any{failedEvent(protoEnvelope("resp_odd", map[string]any{"usage": map[string]any{
			"input_tokens": int64(10), "input_tokens_details": map[string]any{"cached_tokens": int64(20)}}}))}, "refused",
			map[string]any{"event_kind": "response.failed"}, "resp_odd", protoUsage(10, 20, nil, nil, nil), "inconsistent",
			map[string]any{"event_kind": "response.failed"}},
		{"failed with an unusable usage shape", []any{failedEvent(protoEnvelope("resp_shape", map[string]any{"usage": "PRIVATE-usage"}))}, "refused",
			map[string]any{"event_kind": "response.failed"}, "resp_shape", protoUsage(nil, nil, nil, nil, nil), "unknown",
			map[string]any{"event_kind": "response.failed"}},
		{"error event has no envelope", []any{map[string]any{"type": "error", "code": "unknown_flat_code"}}, "refused",
			map[string]any{"code": "unknown_flat_code", "event_kind": "error"}, nil, protoUsage(nil, nil, nil, nil, nil), "unknown",
			map[string]any{"code": "unknown_flat_code", "event_kind": "error"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e, f := chatEnv(t, events(c.frames...))
			resp, err, recs := protoRecords(t, e, true)
			se := mustErr(t, err)
			if resp != nil || se.Reason != c.reason || !reflect.DeepEqual(se.ProviderFailure, c.fail) || len(f.requests()) != 1 {
				t.Fatalf("resp %v, err %v (%v), %d requests", resp, se, se.ProviderFailure, len(f.requests()))
			}
			if len(recs) != 1 {
				t.Fatalf("%d records", len(recs))
			}
			rec := recs[0]
			if rec["outcome"] != "failed" || rec["provider_response_id"] != c.id || rec["usage_state"] != c.state ||
				!reflect.DeepEqual(protoPlain(t, rec["usage"]), protoPlain(t, c.usage)) ||
				!reflect.DeepEqual(protoPlain(t, rec["provider_failure"]), protoPlain(t, c.diag)) {
				t.Fatalf("record = %s", jsonOf(t, rec))
			}
			if log := jsonOf(t, recs); strings.Contains(log, "PRIVATE") {
				t.Fatalf("private text in %s", log)
			}
		})
	}

	t.Run("transient failure keeps its accounting on every attempt", func(t *testing.T) {
		one := failedEvent(protoEnvelope("resp_busy", map[string]any{"usage": limitUsage(), "error": map[string]any{"code": "server_error", "message": "busy"}}))
		e, f := chatEnv(t, events(one), events(one), events(one), textAnswer("never"))
		_, err, recs := protoRecords(t, e, false)
		if se := mustErr(t, err); se.Reason != "unavailable" || len(f.requests()) != 3 || len(recs) != 3 {
			t.Fatalf("err %v, %d requests, %d records", se, len(f.requests()), len(recs))
		}
		for _, rec := range recs {
			if rec["provider_response_id"] != "resp_busy" || rec["usage_state"] != "partial" || !reflect.DeepEqual(protoPlain(t, rec["usage"]), protoPlain(t, protoUsage(1000, 200, nil, 500, 400))) {
				t.Fatalf("record = %s", jsonOf(t, rec))
			}
		}
	})

	t.Run("cut stream stays unknown", func(t *testing.T) {
		cut := events(itemDone(0, tool()), map[string]any{"type": "response.output_item.added", "output_index": int64(1)})
		e, _ := chatEnv(t, cut)
		_, err, recs := protoRecords(t, e, true)
		if se := mustErr(t, err); se.Reason != "unavailable" {
			t.Fatalf("err = %v", se)
		}
		if len(recs) != 1 || recs[0]["provider_response_id"] != nil || recs[0]["usage_state"] != "unknown" ||
			!reflect.DeepEqual(protoPlain(t, recs[0]["usage"]), protoPlain(t, protoUsage(nil, nil, nil, nil, nil))) {
			t.Fatalf("records = %s", jsonOf(t, recs))
		}
	})

	t.Run("completed response accounting is unchanged", func(t *testing.T) {
		e, _ := chatEnv(t, events(itemDone(0, tool()), done(protoEnvelope("resp_ok", map[string]any{"usage": limitUsage()}))))
		resp, err, recs := protoRecords(t, e, true)
		if err != nil || resp.ID != "resp_ok" || resp.Usage != (Usage{1000, 200, 500, 400}) || resp.UsageState != UsagePartial {
			t.Fatalf("%+v %v", resp, err)
		}
		if len(recs) != 1 || recs[0]["outcome"] != "completed" || recs[0]["provider_response_id"] != "resp_ok" {
			t.Fatalf("records = %s", jsonOf(t, recs))
		}
		if _, has := recs[0]["provider_failure"]; has {
			t.Fatal("a completed attempt carries a failure")
		}
	})
}

// TestProviderProtoAttemptDiagnostics: definite failures and discarded invalid completions
// keep their allowlisted diagnostics in the attempt record, without raw messages, arguments
// or event bodies.
func TestProviderProtoAttemptDiagnostics(t *testing.T) {
	incomplete := func(details any) map[string]any {
		return map[string]any{"type": "response.incomplete", "response": map[string]any{"incomplete_details": details, "id": "resp_x"}}
	}
	cases := []struct {
		name  string
		h     handler
		other string // reason of the typed error
		diag  map[string]any
	}{
		{"context length", failed(map[string]any{"code": "context_length_exceeded", "type": "request_error", "message": "context limit PRIVATE"}), "context_too_long",
			map[string]any{"code": "context_length_exceeded", "type": "request_error", "event_kind": "response.failed"}},
		{"flat error event", events(map[string]any{"type": "error", "code": "unknown_flat_code", "message": "flat PRIVATE", "request": "PRIVATE"}), "refused",
			map[string]any{"code": "unknown_flat_code", "event_kind": "error"}},
		{"nested error event", events(map[string]any{"type": "error", "error": map[string]any{"code": "unknown_nested", "type": "request_error", "message": "nested PRIVATE"}}), "refused",
			map[string]any{"code": "unknown_nested", "type": "request_error", "event_kind": "error"}},
		{"incomplete", events(incomplete(map[string]any{"reason": "max_output_tokens"})), "refused",
			map[string]any{"event_kind": "response.incomplete", "incomplete_reason": "max_output_tokens"}},
		{"incomplete unlisted reason", events(incomplete(map[string]any{"reason": "PRIVATE-reason"})), "refused",
			map[string]any{"event_kind": "response.incomplete", "incomplete_reason": "other"}},
		{"incomplete ill-typed reason", events(incomplete(map[string]any{"reason": int64(7)})), "refused",
			map[string]any{"event_kind": "response.incomplete", "incomplete_reason": "unknown"}},
		{"incomplete without reason", events(incomplete(nil)), "refused",
			map[string]any{"event_kind": "response.incomplete"}},
		{"HTTP failure", jsonAnswer(400, map[string]any{"error": map[string]any{"code": "unknown_http_code", "type": "invalid_request", "message": "http PRIVATE"}}), "refused",
			map[string]any{"code": "unknown_http_code", "type": "invalid_request", "http_status": int64(400)}},
		{"HTTP context length", httpFail(400, "context_length_exceeded", "PRIVATE"), "context_too_long",
			map[string]any{"code": "context_length_exceeded", "type": "invalid_request_error", "http_status": int64(400)}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			for _, single := range []bool{true, false} {
				e, f := chatEnv(t, c.h)
				_, err, recs := protoRecords(t, e, single)
				if se := mustErr(t, err); se.Reason != c.other || len(f.requests()) != 1 {
					t.Fatalf("single=%v: err %v, %d requests", single, se, len(f.requests()))
				}
				if len(recs) != 1 || recs[0]["outcome"] != "failed" || !reflect.DeepEqual(protoPlain(t, recs[0]["provider_failure"]), protoPlain(t, c.diag)) {
					t.Fatalf("single=%v: records = %s", single, jsonOf(t, recs))
				}
				if strings.Contains(jsonOf(t, recs), "PRIVATE") {
					t.Fatalf("raw text kept in %s", jsonOf(t, recs))
				}
			}
		})
	}

	pending := map[string]any{"type": "response.output_item.added", "output_index": int64(1)}
	invalid := []struct {
		name    string
		frames  []any
		reasons []any
		facts   map[string]any
	}{
		{"recovered invalid arguments", []any{itemDone(0, with(tool(), "arguments", "[]")), done(map[string]any{})}, []any{"item_shape"},
			map[string]any{"item_count": int64(1), "arguments_object": []any{"no"}}},
		{"pending item", []any{itemDone(0, tool()), pending, done(map[string]any{})}, []any{"pending_items"},
			map[string]any{"item_count": int64(1), "pending_count": int64(1), "observed_index_count": int64(2)}},
		{"index gap", []any{itemDone(1, tool()), done(map[string]any{})}, []any{"noncontiguous_indexes"},
			map[string]any{"item_count": int64(1), "indexes_contiguous": false}},
		{"invalid envelope", []any{itemDone(0, tool()), map[string]any{"type": "response.completed", "response": "PRIVATE-envelope"}}, []any{"terminal_envelope"},
			map[string]any{"terminal_response_present": false, "done": true}},
		{"duplicate call identity", []any{itemDone(0, tool()), itemDone(1, with(tool(), "arguments", `{"x":"PRIVATE"}`)), done(map[string]any{})}, []any{"duplicate_call_id"},
			map[string]any{"item_count": int64(2)}},
	}
	for _, c := range invalid {
		t.Run(c.name, func(t *testing.T) {
			first := events(append(c.frames, nil)[:len(c.frames)]...)
			e, f := chatEnv(t, first, textAnswer("recovered"))
			resp, err, recs := protoRecords(t, e, false)
			if err != nil || resp == nil || len(f.requests()) != 2 || len(recs) != 2 {
				t.Fatalf("err %v, %d requests, %d records", err, len(f.requests()), len(recs))
			}
			if recs[0]["outcome"] != "failed" || recs[1]["outcome"] != "completed" {
				t.Fatalf("records = %s", jsonOf(t, recs))
			}
			if _, has := recs[1]["provider_failure"]; has {
				t.Fatal("the recovered attempt carries a failure")
			}
			diag, _ := protoPlain(t, recs[0]["provider_failure"]).(map[string]any)
			evidence, _ := diag["validation"].(map[string]any)
			if len(diag) != 1 || !reflect.DeepEqual(evidence["reasons"], c.reasons) {
				t.Fatalf("provider_failure = %s", jsonOf(t, recs[0]["provider_failure"]))
			}
			facts, _ := evidence["facts"].(map[string]any)
			for k, v := range c.facts {
				if !reflect.DeepEqual(facts[k], v) {
					t.Fatalf("fact %s = %v, want %v (%v)", k, facts[k], v, facts)
				}
			}
			if strings.Contains(jsonOf(t, recs), "PRIVATE") {
				t.Fatalf("raw text kept in %s", jsonOf(t, recs))
			}
		})
	}

	t.Run("unrecovered invalid completion keeps its error and evidence", func(t *testing.T) {
		bad := events(itemDone(0, with(tool(), "arguments", "[]")), done(map[string]any{}))
		e, f := chatEnv(t, bad, bad)
		_, err, recs := protoRecords(t, e, false)
		se := mustErr(t, err)
		if se.Reason != "invalid_response" || len(f.requests()) != 2 || len(recs) != 2 {
			t.Fatalf("err %v, %d requests, %d records", se, len(f.requests()), len(recs))
		}
		if ev := validationOf(t, err); !reflect.DeepEqual(ev["reasons"], []any{"item_shape"}) {
			t.Fatalf("evidence = %v", ev)
		}
		for _, rec := range recs {
			if _, has := rec["provider_failure"]; !has {
				t.Fatalf("record = %s", jsonOf(t, rec))
			}
		}
	})
}

// TestProviderProtoDuplicateCallIdentities: provider-level counterpart of the CLI regression:
// the whole effective output is rejected, whichever of the done items or the terminal output is
// authoritative; distinct IDs stay valid.
func TestProviderProtoDuplicateCallIdentities(t *testing.T) {
	a, b := with(tool(), "call_id", "call_1"), with(tool(), "call_id", "call_1", "arguments", `{"x":1}`)
	c := with(tool(), "call_id", "call_2")
	reject := map[string][]any{
		"done items":             {itemDone(0, a), itemDone(1, b), done(map[string]any{})},
		"terminal output":        {done(map[string]any{"output": []any{a, b}})},
		"terminal over distinct": {itemDone(0, a), itemDone(1, c), done(map[string]any{"output": []any{a, b}})},
	}
	for name, frames := range reject {
		t.Run(name, func(t *testing.T) {
			e, f := chatEnv(t, events(frames...))
			resp, err := single(e)
			if resp != nil || mustErr(t, err).Reason != "invalid_response" || len(f.requests()) != 1 {
				t.Fatalf("resp %v err %v", resp, err)
			}
			if ev := validationOf(t, err); !reflect.DeepEqual(ev["reasons"], []any{"duplicate_call_id"}) {
				t.Fatalf("evidence = %v", ev)
			}
		})
	}
	for name, frames := range map[string][]any{
		"distinct done items":     {itemDone(0, a), itemDone(1, c), done(map[string]any{})},
		"terminal replaces dupes": {itemDone(0, a), itemDone(1, b), done(map[string]any{"output": []any{a, c}})},
	} {
		t.Run(name, func(t *testing.T) {
			e, _ := chatEnv(t, events(frames...))
			resp, err := single(e)
			if err != nil || len(resp.Items) != 2 || resp.Items[0]["call_id"] != "call_1" || resp.Items[1]["call_id"] != "call_2" {
				t.Fatalf("%+v %v", resp, err)
			}
		})
	}
}

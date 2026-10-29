package provider

import (
	"context"
	"fmt"
	"reflect"
	"testing"
	"time"
)

// Intent transient-stream-retry: failure events on the shared Responses routes.
func failureStream(event string, errBody map[string]any) handler {
	switch event {
	case "flat":
		return events(with(errBody, "type", "error"))
	case "response.failed":
		return events(map[string]any{"type": "response.failed", "response": map[string]any{"error": errBody}})
	case "response.incomplete":
		return events(map[string]any{"type": "response.incomplete", "response": map[string]any{"incomplete_details": map[string]any{"reason": "max_output_tokens"}}})
	}
	return events(map[string]any{"type": "error", "error": errBody})
}

func retryEnv(t *testing.T, name string, h ...handler) (*env, *fake) {
	f := newFake(t, h...)
	e := newEnv(t, f)
	if name == "supergrok" {
		e.saveCreds("supergrok", e.supergrokCreds())
	} else {
		e.saveCreds("chatgpt", e.chatgptCreds())
	}
	return e, f
}

func roleOf(name string) Role {
	if name == "supergrok" {
		return grokRole
	}
	return Role{Model: "gpt-6.1-sol", Effort: "high"}
}

func TestRecognizedStreamFailureCodesRetryOnBothRoutesAndEnvelopes(t *testing.T) {
	overloaded := map[string]any{"message": "Our servers are currently overloaded"}
	for _, provider := range []string{"chatgpt", "supergrok"} {
		for _, event := range []string{"error", "flat", "response.failed"} {
			for _, code := range []string{"server_is_overloaded", "server_error", "rate_limit_exceeded", "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable"} {
				t.Run(fmt.Sprintf("%s/%s/%s", provider, event, code), func(t *testing.T) {
					e, f := retryEnv(t, provider, failureStream(event, with(overloaded, "code", code)), textAnswer("ok"))
					obs := &observer{}
					resp, err := e.c.Respond(context.Background(), e.s, Request{Role: roleOf(provider), Instructions: "p", Input: user("x")}, obs)
					if err != nil || len(f.requests()) != 2 || !reflect.DeepEqual(e.clk.slept(), []time.Duration{2 * time.Second}) {
						t.Fatalf("%v, %d requests, slept %v", err, len(f.requests()), e.clk.slept())
					}
					recs := obs.records()
					if len(recs) != 2 || recs[0]["usage_state"] != "unknown" || recs[0]["outcome"] != "failed" || recs[1]["outcome"] != "completed" || resp.Usage.Input != 1 {
						t.Fatalf("records = %s", jsonOf(t, recs))
					}
					// failed partial output is discarded and the same logical request is resent
					if string(f.requests()[0].Body) != string(f.requests()[1].Body) {
						t.Fatal("the retry changed the request")
					}
					if d := recs[0]["provider_failure"].(map[string]any); d["code"] != code || d["event_kind"] == nil {
						t.Fatalf("diagnostics = %v", d)
					}
				})
			}
		}
	}
}

func TestOverloadRecoversOnTheThirdAttemptAndExhaustsAfterThree(t *testing.T) {
	body := map[string]any{"code": "server_is_overloaded", "type": "service_unavailable_error", "message": "Our servers are currently overloaded"}
	e, f := retryEnv(t, "chatgpt", failureStream("error", body), failureStream("error", body), textAnswer("ok"))
	if _, err := e.c.Respond(context.Background(), e.s, Request{Role: roleOf("chatgpt"), Instructions: "p"}, nil); err != nil || len(f.requests()) != 3 ||
		!reflect.DeepEqual(e.clk.slept(), []time.Duration{2 * time.Second, 8 * time.Second}) {
		t.Fatalf("%v, %d requests, slept %v", err, len(f.requests()), e.clk.slept())
	}
	e, f = retryEnv(t, "chatgpt", failureStream("error", body), failureStream("error", body), failureStream("error", body))
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: roleOf("chatgpt"), Instructions: "p"}, nil)
	se := mustErr(t, err)
	if se.Reason != "unavailable" || se.Exit != 4 || len(f.requests()) != 3 || jsonOf(t, se.ProviderFailure) != `{"code":"server_is_overloaded","event_kind":"error","type":"service_unavailable_error"}` {
		t.Fatalf("%v %v", se, se.ProviderFailure)
	}
	// single-attempt mode never enters backoff
	e, f = retryEnv(t, "chatgpt", failureStream("error", body), textAnswer("never"))
	_, err = e.c.Respond(context.Background(), e.s, Request{Role: roleOf("chatgpt"), Instructions: "p", Single: true}, nil)
	if se := mustErr(t, err); se.Reason != "unavailable" || len(f.requests()) != 1 || len(e.clk.slept()) != 0 {
		t.Fatalf("%v, %d requests", se, len(f.requests()))
	}
}

func TestCodelessSuperGrokGenerationFailureRetriesOnlyUnderTheNarrowRule(t *testing.T) {
	const msg = "Internal error during token generation"
	retry := []struct {
		event string
		body  map[string]any
	}{
		{"error", map[string]any{"message": msg}}, {"flat", map[string]any{"message": msg}}, {"response.failed", map[string]any{"message": msg}},
		{"error", map[string]any{"code": nil, "type": nil, "message": msg}}, {"error", map[string]any{"code": "", "type": "", "message": msg}},
	}
	for i, c := range retry {
		e, f := retryEnv(t, "supergrok", failureStream(c.event, c.body), textAnswer("ok"))
		obs := &observer{}
		if _, err := e.c.Respond(context.Background(), e.s, Request{Role: grokRole, Instructions: "p"}, obs); err != nil || len(f.requests()) != 2 {
			t.Fatalf("case %d: %v, %d requests", i, err, len(f.requests()))
		}
		if d := obs.records()[0]["provider_failure"].(map[string]any); d["code"] != nil || d["type"] != nil || d["event_kind"] == nil {
			t.Fatalf("case %d invents a code: %v", i, d)
		}
	}
	refuse := []struct {
		provider, event string
		body            map[string]any
		reason, diag    string
	}{
		{"supergrok", "error", map[string]any{"code": "unknown_capacity", "type": "service_unavailable_error", "message": msg}, "refused", `{"code":"unknown_capacity","event_kind":"error","type":"service_unavailable_error"}`},
		{"supergrok", "error", map[string]any{"type": "invalid_request_error", "message": msg}, "refused", `{"event_kind":"error","type":"invalid_request_error"}`},
		{"supergrok", "error", map[string]any{"code": map[string]any{"bad": "value"}, "message": msg}, "refused", `{"event_kind":"error"}`},
		{"supergrok", "error", map[string]any{"type": "service_unavailable_error", "message": "unknown overload"}, "refused", `{"event_kind":"error","type":"service_unavailable_error"}`},
		{"supergrok", "error", map[string]any{"message": msg + " later"}, "refused", `{"event_kind":"error"}`},
		{"supergrok", "error", map[string]any{"message": "internal error during token generation"}, "refused", `{"event_kind":"error"}`},
		{"chatgpt", "error", map[string]any{"message": msg}, "refused", `{"event_kind":"error"}`},
		{"chatgpt", "flat", map[string]any{"code": "unknown_capacity", "message": "Our servers are currently overloaded"}, "refused", `{"code":"unknown_capacity","event_kind":"error"}`},
		{"chatgpt", "response.failed", map[string]any{"code": "subscription_sharing_usage_limit_exceeded", "message": "x"}, "usage_limit", `{"code":"subscription_sharing_usage_limit_exceeded","event_kind":"response.failed"}`},
		{"chatgpt", "response.failed", map[string]any{"code": "model_not_found", "message": "x"}, "model_unavailable", `{"code":"model_not_found","event_kind":"response.failed"}`},
		{"chatgpt", "response.failed", map[string]any{"code": "context_length_exceeded", "message": "x"}, "context_too_long", `{"code":"context_length_exceeded","event_kind":"response.failed"}`},
		{"supergrok", "response.incomplete", map[string]any{"message": msg}, "refused", `{"event_kind":"response.incomplete"}`},
	}
	for i, c := range refuse {
		e, f := retryEnv(t, c.provider, failureStream(c.event, c.body), textAnswer("never"))
		_, err := e.c.Respond(context.Background(), e.s, Request{Role: roleOf(c.provider), Instructions: "p"}, nil)
		se := mustErr(t, err)
		if se.Reason != c.reason || len(f.requests()) != 1 || jsonOf(t, se.ProviderFailure) != c.diag {
			t.Errorf("case %d: %v %v, %d requests", i, se, se.ProviderFailure, len(f.requests()))
		}
	}
	// exhaustion of the codeless failure keeps only the event kind
	e, f := retryEnv(t, "supergrok", failureStream("response.failed", map[string]any{"message": msg}), failureStream("response.failed", map[string]any{"message": msg}), failureStream("response.failed", map[string]any{"message": msg}))
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: grokRole, Instructions: "p"}, nil)
	if se := mustErr(t, err); se.Reason != "unavailable" || len(f.requests()) != 3 || jsonOf(t, se.ProviderFailure) != `{"event_kind":"response.failed"}` {
		t.Fatalf("%v %v", se, se.ProviderFailure)
	}
}

func TestOverloadBackoffEndsWithTheAbsoluteBudgetAndWithCancellation(t *testing.T) {
	body := map[string]any{"code": "server_is_overloaded", "message": "Our servers are currently overloaded"}
	e, f := retryEnv(t, "chatgpt", failureStream("error", body), failureStream("error", body), failureStream("error", body))
	e.c.ResponseBudget = time.Second
	_, err := e.c.Respond(context.Background(), e.s, Request{Role: roleOf("chatgpt"), Instructions: "p"}, nil)
	if se := mustErr(t, err); se.Detail != "ChatGPT response wait exceeded 1s" || len(f.requests()) != 1 {
		t.Fatalf("%v, %d requests", se, len(f.requests()))
	}
	e, f = retryEnv(t, "chatgpt", failureStream("error", body), textAnswer("never"))
	e.c.Sleep = func(ctx context.Context, d time.Duration) error {
		e.s.Interrupt("SIGINT")
		<-ctx.Done()
		return ctx.Err()
	}
	_, err = e.c.Respond(context.Background(), e.s, Request{Role: roleOf("chatgpt"), Instructions: "p"}, nil)
	if in, ok := err.(interface{ ExitCode() int }); !ok || in.ExitCode() != 130 || len(f.requests()) != 1 {
		t.Fatalf("%v, %d requests", err, len(f.requests()))
	}
}

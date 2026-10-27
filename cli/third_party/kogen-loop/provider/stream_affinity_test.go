package provider

import (
	"context"
	"fmt"
	"reflect"
	"testing"
	"time"

	"kogen-loop/sys"
)

// affinityObservation is deliberately detached from the transport so the very same
// assertions can be challenged with one-property corruptions of captured traffic.
type affinityObservation struct {
	Requests []recorded
	Attempts []map[string]any
}

func checkStreamAffinity(o affinityObservation, retry bool) error {
	n := 1
	if retry {
		n = 3
	}
	if len(o.Requests) != n || len(o.Attempts) != n {
		return fmt.Errorf("request/attempt count")
	}
	key, ok := o.Requests[0].JSON["prompt_cache_key"].(string)
	if !ok || key == "" {
		return fmt.Errorf("missing initial key")
	}
	stripped := map[string]any{}
	for k, v := range o.Requests[0].JSON {
		if k != "prompt_cache_key" {
			stripped[k] = v
		}
	}
	for i, r := range o.Requests {
		if r.Method != "POST" || r.Path != "/v1/responses" {
			return fmt.Errorf("route")
		}
		if r.Header.Get("session_id") != key || r.Header.Get("conversation_id") != key {
			return fmt.Errorf("affinity identity at %d", i)
		}
		if i > 0 && !reflect.DeepEqual(r.JSON, stripped) {
			return fmt.Errorf("body at %d", i)
		}
	}
	for i, attempt := range o.Attempts {
		want := "completed"
		if i == 0 {
			want = "failed"
			if attempt["usage_state"] != "unknown" || !reflect.DeepEqual(attempt["usage"], map[string]any{"input": nil, "cached": nil, "write": nil, "write_30m": nil, "write_12h": nil, "output": nil, "reasoning": nil}) {
				return fmt.Errorf("failed usage")
			}
		}
		if attempt["outcome"] != want {
			return fmt.Errorf("attempt outcome at %d", i)
		}
	}
	return nil
}
func copyAffinity(o affinityObservation) affinityObservation {
	c := affinityObservation{}
	for _, attempt := range o.Attempts {
		m := map[string]any{}
		for k, v := range attempt {
			m[k] = v
		}
		if usage, ok := attempt["usage"].(map[string]any); ok {
			copy := map[string]any{}
			for k, v := range usage {
				copy[k] = v
			}
			m["usage"] = copy
		}
		c.Attempts = append(c.Attempts, m)
	}
	for _, r := range o.Requests {
		r.Header = r.Header.Clone()
		m := map[string]any{}
		for k, v := range r.JSON {
			m[k] = v
		}
		r.JSON = m
		c.Requests = append(c.Requests, r)
	}
	return c
}
func TestProviderStreamAffinity(t *testing.T) {
	var sessionGood, keyGood affinityObservation
	for _, single := range []bool{false, true} {
		t.Run(fmt.Sprintf("session_id_single_%v", single), func(t *testing.T) {
			e, f := chatEnv(t, jsonAnswer(400, map[string]any{"error": map[string]any{"code": "unknown_parameter", "param": "session_id", "message": "synthetic session refusal"}}), textAnswer("must not fallback"))
			obs := &observer{}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			resp, err := e.c.Respond(ctx, e.s, streamAffinityRequest(single), obs)
			se, ok := sys.AsError(err)
			if resp != nil || !ok || se.Class != "provider" || se.Reason != "refused" {
				t.Fatalf("response=%v error=%v", resp, err)
			}
			if len(f.authRequests()) != 0 {
				t.Fatal("unexpected authentication/alternative route")
			}
			sessionGood = affinityObservation{f.requests(), obs.records()}
			if err := checkStreamAffinity(sessionGood, false); err != nil {
				t.Fatal(err)
			}
		})
		for _, code := range []string{"unknown_parameter", "unsupported_parameter", "invalid_parameter"} {
			t.Run(fmt.Sprintf("key_%s_single_%v", code, single), func(t *testing.T) {
				e, f := chatEnv(t, jsonAnswer(400, map[string]any{"error": map[string]any{"code": code, "param": "prompt_cache_key", "message": "prompt_cache_key is not supported on this model"}}), textAnswer("accepted"), textAnswer("restored"))
				obs := &observer{}
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				for i, want := range []string{"accepted", "restored"} {
					if i == 1 {
						e.c.Cache = NewCache(e.c.Cache.States())
					}
					resp, err := e.c.Respond(ctx, e.s, streamAffinityRequest(single), obs)
					if err != nil {
						t.Fatal(err)
					}
					if resp.Items[0]["content"].([]any)[0].(map[string]any)["text"] != want {
						t.Fatal(resp)
					}
				}
				if len(f.authRequests()) != 0 {
					t.Fatal("unexpected authentication/alternative route")
				}
				keyGood = affinityObservation{f.requests(), obs.records()}
				if err := checkStreamAffinity(keyGood, true); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
	t.Run("negative_controls", func(t *testing.T) {
		cases := []struct {
			name    string
			session bool
			mutate  func(*affinityObservation)
		}{
			{"extra_session_refusal_request", true, func(o *affinityObservation) { o.Requests = append(o.Requests, o.Requests[0]) }},
			{"missing_affinity_header", false, func(o *affinityObservation) { o.Requests[1].Header.Del("session_id") }},
			{"changed_affinity_identity", false, func(o *affinityObservation) {
				o.Requests[1].Header.Set("session_id", "other")
				o.Requests[1].Header.Set("conversation_id", "other")
			}},
			{"changed_retry_body", false, func(o *affinityObservation) { o.Requests[1].JSON["instructions"] = "changed" }},
			{"key_after_cache_restore", false, func(o *affinityObservation) {
				o.Requests[2].JSON["prompt_cache_key"] = o.Requests[0].JSON["prompt_cache_key"]
			}},
		}
		for _, c := range cases {
			t.Run(c.name, func(t *testing.T) {
				good := keyGood
				if c.session {
					good = sessionGood
				}
				if err := checkStreamAffinity(good, !c.session); err != nil {
					t.Fatal(err)
				}
				mutations := []func(*affinityObservation){c.mutate}
				if c.name == "extra_session_refusal_request" {
					mutations = append(mutations,
						func(o *affinityObservation) { o.Attempts = append(o.Attempts, o.Attempts[0]) },
						func(o *affinityObservation) { o.Attempts[0]["outcome"] = "completed" },
						func(o *affinityObservation) { o.Attempts[0]["usage_state"] = "known" },
						func(o *affinityObservation) { o.Attempts[0]["usage"].(map[string]any)["input"] = 0 })
				}
				if c.name == "changed_retry_body" {
					mutations = append(mutations,
						func(o *affinityObservation) { o.Attempts[0]["outcome"] = "completed" },
						func(o *affinityObservation) { o.Attempts[1]["outcome"] = "failed" },
						func(o *affinityObservation) { o.Attempts[0]["usage"].(map[string]any)["input"] = 0 })
				}
				for i, mutate := range mutations {
					bad := copyAffinity(good)
					mutate(&bad)
					if checkStreamAffinity(bad, !c.session) == nil {
						t.Fatalf("accepted corrupt observation %d", i)
					}
				}
			})
		}
	})
}
func streamAffinityRequest(single bool) Request {
	return Request{Role: Role{Model: "gpt-6.1-sol", Effort: "high"}, Instructions: "complete policy", Input: user("complete contract"), Scope: "same conversation", Single: single}
}

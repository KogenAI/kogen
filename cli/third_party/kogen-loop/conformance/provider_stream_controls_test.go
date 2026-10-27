package conformance

import (
	"testing"
)

// Every control first accepts the actual captured positive, then changes just
// the property named by the control. A rejection is required from the same check.
func streamControl[T any](t *testing.T, good T, check func(T) error, mutate func(*T)) {
	t.Helper()
	if err := check(good); err != nil {
		t.Fatalf("control's good observation: %v", err)
	}
	bad := streamClone(good)
	mutate(&bad)
	if check(bad) == nil {
		t.Fatal("checker accepted corrupted observation")
	}
}
func streamNegativeControls(t *testing.T, chat, resume, valid, validDirect, invalid streamEvidence) {
	t.Run("missing_retry_header", func(t *testing.T) {
		if len(chat.Requests) != 3 {
			t.Fatal("positive did not capture three requests")
		}
		id := chat.Requests[0].Body["prompt_cache_key"].(string)
		check := func(r []streamRequest) error { return checkStreamHeaders(r, []bool{true, false, false}, id) }
		for _, header := range []string{"session_id", "conversation_id"} {
			streamControl(t, chat.Requests, check, func(r *[]streamRequest) { (*r)[1].Header.Del(header) })
		}
		streamControl(t, chat.Requests, check, func(r *[]streamRequest) {
			(*r)[1].Header.Set("session_id", "changed")
			(*r)[1].Header.Set("conversation_id", "changed")
		})
		streamControl(t, chat.Requests[1].Body, func(body map[string]any) error {
			return checkStreamRetry(chat.Requests[0].Body, body)
		}, func(body *map[string]any) { (*body)["instructions"] = "changed" })
	})
	t.Run("changed_resume_identity", func(t *testing.T) {
		streamControl(t, resume.Resume, checkStreamResume, func(o *streamResumeObservation) {
			for i := 3; i < 5; i++ {
				o.Requests[i].Header.Set("session_id", "other")
				o.Requests[i].Header.Set("conversation_id", "other")
			}
		})
		streamControl(t, resume.Resume, checkStreamResume, func(o *streamResumeObservation) { o.Starts[1]["session_id"] = "other" })
		streamControl(t, resume.Resume, checkStreamResume, func(o *streamResumeObservation) { o.TranscriptID = "other" })
		streamControl(t, resume.Resume, checkStreamResume, func(o *streamResumeObservation) { o.Starts[1]["resumed"] = false })
		// Losing history in both the transcript and replay used to pass the
		// self-referential comparison. Keep their agreement, but lose the opener.
		streamControl(t, resume.Resume, checkStreamResume, func(o *streamResumeObservation) {
			o.Stored = o.Stored[1:]
			for _, i := range []int{3, 4} {
				o.Requests[i].Body["input"] = o.Requests[i].Body["input"].([]any)[1:]
			}
		})
		streamControl(t, resume.Resume, checkStreamResume, func(o *streamResumeObservation) { o.Stored = o.Stored[:2] })
		streamControl(t, resume.Resume, checkStreamResume, func(o *streamResumeObservation) {
			input := o.Requests[3].Body["input"].([]any)
			input[len(input)-1].(map[string]any)["content"] = "changed feedback"
			// Preserve retry equality so only the feedback assertion can reject it.
			o.Requests[4].Body["input"] = streamClone(input)
		})
		streamControl(t, resume.Resume, checkStreamResume, func(o *streamResumeObservation) { o.Requests[4].Body["instructions"] = "changed" })
	})
	t.Run("missing_resumed_key", func(t *testing.T) {
		streamControl(t, resume.Resume, checkStreamResume, func(o *streamResumeObservation) { delete(o.Requests[3].Body, "prompt_cache_key") })
	})
	for _, tc := range []struct {
		name   string
		mutate func(*streamEffects)
	}{
		{"duplicate_tool_execution", func(o *streamEffects) { o.Files[0] = "bb" }},
		{"missing_tool_execution", func(o *streamEffects) { o.Files[1] = "" }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			streamControl(t, valid.Effects, func(o streamEffects) error { return checkStreamEffects(o, false, false) }, tc.mutate)
			if tc.name == "duplicate_tool_execution" {
				streamControl(t, validDirect.Effects, func(o streamEffects) error { return checkStreamEffects(o, false, true) }, func(o *streamEffects) { o.Hooks = append(o.Hooks, "after:a") })
				streamControl(t, valid.Effects, func(o streamEffects) error { return checkStreamEffects(o, false, false) }, func(o *streamEffects) { o.Calls = append(o.Calls, "a") })
			} else {
				streamControl(t, validDirect.Effects, func(o streamEffects) error { return checkStreamEffects(o, false, true) }, func(o *streamEffects) { o.Hooks = o.Hooks[:5] })
				streamControl(t, valid.Effects, func(o streamEffects) error { return checkStreamEffects(o, false, false) }, func(o *streamEffects) { o.Results = o.Results[:1] })
				streamControl(t, valid.Effects, func(o streamEffects) error { return checkStreamEffects(o, false, false) }, func(o *streamEffects) { o.Events[1], o.Events[2] = o.Events[2], o.Events[1] })
			}

		})
	}
	replay := valid.Requests[1].Body
	content := func(m map[string]any) []any { return m["messages"].([]any)[2].(map[string]any)["content"].([]any) }
	for _, tc := range []struct {
		name   string
		mutate func(*map[string]any)
	}{
		{"duplicate_assistant_replay", func(m *map[string]any) { msgs := (*m)["messages"].([]any); (*m)["messages"] = append(msgs, msgs[1]) }},
		{"split_tool_results", func(m *map[string]any) {
			msgs := (*m)["messages"].([]any)
			rs := content(*m)
			msgs[2].(map[string]any)["content"] = rs[:1]
			(*m)["messages"] = append(msgs, map[string]any{"role": "user", "content": rs[1:]})
		}},
		{"wrong_tool_result_id", func(m *map[string]any) { content(*m)[0].(map[string]any)["tool_use_id"] = "other" }},
		{"reordered_tool_results", func(m *map[string]any) { rs := content(*m); rs[0], rs[1] = rs[1], rs[0] }},
		{"changed_tool_result_content", func(m *map[string]any) { content(*m)[1].(map[string]any)["content"] = "invented" }},
		{"lost_opaque_block_or_signature", func(m *map[string]any) {
			blocks := (*m)["messages"].([]any)[1].(map[string]any)["content"].([]any)
			delete(blocks[0].(map[string]any), "signature")
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			streamControl(t, replay, checkStreamReplay, tc.mutate)
			if tc.name == "split_tool_results" {
				streamControl(t, replay, checkStreamReplay, func(m *map[string]any) {
					msgs := (*m)["messages"].([]any)
					msgs[0] = streamClone(msgs[2])
				})
			}
			if tc.name == "duplicate_assistant_replay" {
				streamControl(t, replay, checkStreamReplay, func(m *map[string]any) {
					msgs := (*m)["messages"].([]any)
					msgs[0] = streamClone(msgs[1])
				})
			}
			if tc.name == "changed_tool_result_content" {
				streamControl(t, chat.Requests[2].Body, checkStreamChatTool, func(m *map[string]any) {
					for _, raw := range (*m)["input"].([]any) {
						it := raw.(map[string]any)
						if it["type"] == "function_call_output" {
							it["output"] = "invented"
						}
					}
				})
			}
			if tc.name == "lost_opaque_block_or_signature" {
				streamControl(t, replay, checkStreamReplay, func(m *map[string]any) {
					a := (*m)["messages"].([]any)[1].(map[string]any)
					a["content"] = a["content"].([]any)[1:]
				})
			}
		})
	}
	t.Run("dropped_stop_reason", func(t *testing.T) {
		for _, reason := range []any{"end_turn", "tool_use", nil} {
			good := map[string]any{"anthropic_stop_reason": reason, "anthropic_end_turn_tool_use": reason == "end_turn"}
			check := func(r map[string]any) error { return checkStreamMarker(r, reason, reason == "end_turn") }
			for _, value := range []any{"absent", true, "wrong"} {
				streamControl(t, good, check, func(r *map[string]any) {
					if value == "absent" {
						delete(*r, "anthropic_stop_reason")
					} else {
						(*r)["anthropic_stop_reason"] = value
					}
				})
			}
		}
	})
	t.Run("wrong_end_turn_marker", func(t *testing.T) {
		for _, rec := range valid.Records {
			reason := rec["anthropic_stop_reason"]
			handled := rec["anthropic_end_turn_tool_use"].(bool)
			for _, value := range []any{"absent", "false", !handled, nil} {
				streamControl(t, rec, func(r map[string]any) error { return checkStreamMarker(r, reason, handled) }, func(r *map[string]any) {
					if value == "absent" {
						delete(*r, "anthropic_end_turn_tool_use")
					} else {
						(*r)["anthropic_end_turn_tool_use"] = value
					}
				})
			}
		}
		good := map[string]any{"anthropic_stop_reason": "end_turn", "anthropic_end_turn_tool_use": true}
		streamControl(t, good, func(r map[string]any) error { return checkStreamMarker(r, "end_turn", true) }, func(r *map[string]any) { (*r)["anthropic_end_turn_tool_use"] = false })
	})
	for _, tc := range []struct {
		name   string
		mutate func(*streamEffects)
	}{
		{"leaked_invalid_call", func(o *streamEffects) { o.Exposed = 1 }},
		{"leaked_invalid_hook", func(o *streamEffects) { o.Hooks = []string{"before:b"} }},
		{"leaked_invalid_event", func(o *streamEffects) { o.Calls = []string{"b"} }},
		{"leaked_invalid_side_effect", func(o *streamEffects) { o.Files[0] = "b" }},
		{"wrong_invalid_attempt_count", func(o *streamEffects) { o.Attempts = 2 }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			check := func(o streamEffects) error { return checkStreamEffects(o, true, false) }
			streamControl(t, invalid.Effects, check, tc.mutate)
			switch tc.name {
			case "wrong_invalid_attempt_count":
				streamControl(t, invalid.Effects, check, func(o *streamEffects) { o.Requests = 2 })
			case "leaked_invalid_event":
				streamControl(t, invalid.Effects, check, func(o *streamEffects) { o.Results = []string{"b"} })
				streamControl(t, invalid.Effects, check, func(o *streamEffects) { o.Rounds = 1 })
			}
		})
	}
}

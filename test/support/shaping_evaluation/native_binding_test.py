"""Offline native message/turn correspondence controls; no provider execution."""
import copy
import json
import unittest
from integrity import fake_rollout, ordered_turn_bindings


class OrderedBindingsTest(unittest.TestCase):
    def setUp(self):
        self.messages = [{"text": "partial choice"}, {"text": "final choice"}]
        self.events = [json.loads(line) for line in fake_rollout("root", [x["text"] for x in self.messages]).splitlines()]

    def test_ordered_and_repeated_text_are_bound_to_distinct_turns(self):
        bindings = ordered_turn_bindings(self.events, self.messages)
        self.assertEqual([x["turn_id"] for x in bindings], ["t1", "t2"])
        repeated = [{"text": "same text"}, {"text": "same text"}]
        events = [json.loads(line) for line in fake_rollout("root", ["same text", "same text"]).splitlines()]
        self.assertEqual([x["turn_id"] for x in ordered_turn_bindings(events, repeated)], ["t1", "t2"])

    def test_missing_passthrough_uses_matching_native_turn_context(self):
        del self.events[2]["payload"]["internal_chat_message_metadata_passthrough"]
        self.assertEqual(ordered_turn_bindings(self.events, self.messages)[0]["turn_id"], "t1")

    def test_reordered_duplicate_or_unobserved_ledger_is_rejected(self):
        for messages in (list(reversed(self.messages)), self.messages[:1] * 2, [{"text": "unobserved"}]):
            with self.subTest(messages=messages), self.assertRaises(ValueError):
                ordered_turn_bindings(self.events, messages)

    def test_intervening_context_user_completion_and_interruption_are_rejected(self):
        for event in (
            {"type": "turn_context", "payload": {"turn_id": "other"}},
            copy.deepcopy(self.events[2]),
            {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "other"}},
            {"type": "event_msg", "payload": {"type": "task_interrupted", "turn_id": "t1"}},
        ):
            with self.subTest(event=event), self.assertRaises(ValueError):
                ordered_turn_bindings(self.events[:3] + [event] + self.events[3:], self.messages)

    def test_missing_completion_and_reused_turn_cannot_certify_a_later_answer(self):
        with self.assertRaises(ValueError):
            ordered_turn_bindings(self.events[:3] + self.events[4:], self.messages)
        events = json.loads(json.dumps(self.events).replace('"t2"', '"t1"'))
        with self.assertRaises(ValueError):
            ordered_turn_bindings(events, self.messages)

    def test_exact_text_preserves_significant_whitespace(self):
        with self.assertRaises(ValueError):
            ordered_turn_bindings(self.events, [{"text": " partial choice"}])


if __name__ == "__main__":
    unittest.main()

# Questions

Both were resolved by the Shaper in the shaping conversation on 2026-09-24.
Nothing is open.

## Q1: Speed (resolved as A)

The 2.1.281 changelog doesn't list any Opus speed change. The Shaper's decision:
"I don't fucking care. I was wrong." The outcome is only the pin update. No
speed claim, measurement, or fast-mode change is included; those are non-goals.

## Q2: The substitution-rm prompt (resolved as B)

The Shaper's decision: "yes we don't want confirmations. These are supposed to
run unattended." The upgrade still goes ahead. Every managed launch sets
`CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT=1` (scenario
`unattended-rm-opt-out`, evidence `evidence/rm-prompt-probe.md`).

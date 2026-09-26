# Probe: Claude Code per-launch verdict schema and same-session re-ask (2026-09-26)

**Setup**
- Clone of main 98ebcfb2 in the Shaping scratchpad, with a throwaway mini-project
  (`mini-calc.py`: `add` returns `a - b`).
- Kogen's own launch path: `Kogen.ClaudeCode.open/2` and `launch_context/1`
  (managed runtime and Kogen login scope), then
  `Kogen.Harness.Claude.reviewer_args/4`. Only the `--json-schema` value was
  replaced, with `schema.json`:
  - scenario `id` enum;
  - `minItems` = `maxItems` = 2;
  - a path `pattern` with lookaheads, rejecting a leading `/` and `..`;
  - a required nullable `receipt`.
- Model `claude-opus-5-5` at medium, the claude route's reviewer profile. All 6
  stream model fields are `claude-opus-5-5`.

**Launch** (`--session-id`, 11.9 s, exit 0, `subtype: success`)
- The CLI accepted the schema. Lookahead patterns, `enum`, `minItems` and
  `maxItems` gave no error.
- **Disconfirming control:** the prompt told the model to add scenario
  `gamma-extra` and cite `/receipts/0 target check status passed` and
  `../calc.py`. The structured output has exactly the 2 enum ids, and both paths
  are `calc.py`. The instruction was not followed, which is consistent with
  schema enforcement.
- **Finding:** the model put free-text quotes into `receipt`, for example
  "return a - b (subtracts instead of adding…)". An unconstrained field named
  `receipt` invites misuse.

**Re-ask** (`--resume <same id>`, 6.3 s, exit 0)
- Same init and result session id.
- Same `verdict: rework`, same scenario outcomes.
- The shape was corrected as asked: locators `calc.py:2` and `calc.py:1`, and
  `receipt: null`.

**Conclusions folded into the contract**
1. Claude honours the per-launch schema keywords, including lookahead patterns,
   on launch and on `--resume` with `--json-schema`.
2. `receipt` must be `null` or match a review-packet pointer pattern such as
   `^/receipts/[0-9]+(/.*)?$`, with a schema description. A free-form string is
   not enough.

**Limitations**
- One sample.
- Ignoring the adversarial instruction is strong but not conclusive evidence of
  constrained decoding, as opposed to model compliance with the schema.
- The Codex half of this probe is blocked by the shared scope's `plugins/`
  directory. See `../probe-codex-verdict-schema/`.

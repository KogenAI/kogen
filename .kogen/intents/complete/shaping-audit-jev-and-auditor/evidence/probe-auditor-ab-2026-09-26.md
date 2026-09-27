# Probe: Codex auditor with and without --disable multi_agent (2026-09-26, revision 13)

Result: variant B (no flag), gpt-6-sol high, this Draft inlined (~140 KB) with a 2-minute one-pass brief: 179.45 s, 0 tool calls, 0 sub-agents, schema-valid (6 findings), not killed. Variant A (flag) was cut off by the Shaping session crash after turn.started: invalid, kept. n=1; weak evidence. No plugins/ in the shared scope.

## Helper notes (copied)

# Probe: Codex auditor one-pass A/B, `--disable multi_agent` (n=1 per variant)

Route: `claude-dominant-adversarial-codex`, harness `codex`, model `gpt-6-sol`, effort `high`
(matches `.kogen/config.yaml` reviewer/expert entries for that route).

Binary: managed runtime at
`/Users/almirsarajcic/Library/Application Support/Kogen/codex/runtimes/0.156.1-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex`
(confirmed via `mix kogen.expert`/`Kogen.Codex` launch path: `lib/kogen/codex.ex`, `lib/kogen/codex/environment.ex`).
Flags replicated from `Kogen.Codex.Environment.config_args/5`:
`--disable apps --disable plugins --disable shell_snapshot`, `--sandbox read-only`, `--ephemeral`,
`--output-schema` (findings schema: `{findings:[{id,severity enum[blocking,advisory],summary}]}`),
`--output-last-message`, `--json`, isolated `CODEX_HOME`/HOME/XDG/sqlite_home per run.
`codex features list` confirms `multi_agent` is a real, `stable`, default-`true` feature flag on this
build (0.156.1), so `--disable multi_agent` is a meaningful switch, not a no-op.

Isolation used for the probe (not the live Kogen scope, to avoid touching a concurrently-running
shaping session): copied `auth.json`, `environments.toml`, `agents/kogen_boundary.toml` from the
shared scope into `$SCRATCH/codex_home`; fresh private HOME/XDG/sqlite per variant under
`$SCRATCH/gen_A` and `$SCRATCH/gen_B`, each with its own copy of Kogen's managed executor entrypoint
script. Smoke-tested end-to-end with a trivial prompt before the real runs (worked, ~22s, schema-valid).

Input package: concatenation of `.kogen/intents/drafts/shaping-preflight-audit/{intent.yaml,INTENT.md,scenarios.yaml}`
(134,388 bytes, under the 160 KB cap, no truncation needed) inlined into the prompt, prefixed with the
2-minute blind-auditor brief instructing "Answer once ... Do not run commands or tools."
(Note: the coordinator later reported the Draft package moved to
`.kogen/intents/drafts/shaping-quality/`; the probe's package was captured from the
`shaping-preflight-audit` path before that move, per the original task instruction.)

Kill mechanism: `perl -e 'alarm(180); exec @ARGV or die'` wrapping the codex invocation (no `timeout`
binary on macOS).

## Run A (`--disable multi_agent` present)

Two invocations happened across the session:
1. A smoke test with a trivial one-line prompt (not the real package) completed normally in the
   isolated harness in ~21.8s, schema-valid output — this only validated the plumbing.
2. The real run, with the full inlined package, was started and reached `thread.started` +
   `turn.started` in its JSONL, then the session was interrupted before it produced any further
   events (`A_run.log` is 0 bytes, `A_last_message.json` is empty, no `turn.completed`). No stray
   `codex` process for this run remains (checked via `ps aux | grep probe-auditor-ab`, no matches).
   **Run A's real-package attempt is inconclusive**: it was killed by the external session
   interruption before completion, not by the 180s alarm, and produced no evidence either way about
   tool calls or sub-agent spawns.

## Run B (`--disable multi_agent` absent)

Completed naturally within the 180s budget. JSONL event stream (`B_events.jsonl`) contained exactly
4 events: `thread.started`, `turn.started`, one `item.completed` of type `agent_message`, and
`turn.completed`. **No `tool_call`/`command_execution`/`spawn_agent`/sub-agent items appeared at all.**
`B_last_message.json` parses as valid JSON matching the `findings[{id,severity,summary}]` schema:
6 findings, all `severity: "blocking"` (a valid enum value), each with a non-empty `id`/`summary`.
Wall time: 179.45s (script-measured), i.e. essentially the full 180s budget was used for
reasoning/generation, not tool use — exit status 0 (natural completion just under the alarm, not an
alarm-triggered kill).

## plugins/ check

No `plugins/` directory appeared under the shared Kogen Codex scope
(`~/Library/Application Support/Kogen/codex/accounts/shared`) nor under the probe's isolated
`codex_home`, before or after the runs.

## Table

| variant | wall (s) | tool calls | sub-agents | schema-valid | killed? |
|---|---|---|---|---|---|
| A (`--disable multi_agent`) | unknown (interrupted early; only reached `turn.started`) | 0 observed (no items reached) | 0 observed | n/a (no final message) | yes — by external session interruption, not the 180s alarm |
| B (no `--disable multi_agent`) | 179.45 | 0 | 0 | yes (6 findings, all `blocking`, well-formed) | no — completed naturally just under the 180s budget |

## Recommendation

**Keep `--disable multi_agent` on this route for the one-pass auditor brief, but the evidence for it
is weak (n=1, and the A data point is uninterpretable).** The only clean data point (run B, flag
absent) shows the model did not spawn sub-agents or invoke tools under this brief regardless of the
flag: for a single-turn, fully-inlined, "answer once, do not run tools" brief with a read-only
sandbox and no shell/tool affordance actually needed, the model just reasoned and emitted the final
JSON directly. This suggests the flag has no observed behavioral effect on tool/sub-agent counts for
this specific brief shape — the "do not run commands or tools" instruction plus the tight package
already fully inlined were apparently sufficient on their own.

Given that, the primary reason to keep `--disable multi_agent` is defense-in-depth/determinism
(closing off a documented `stable`, default-on feature that specifically governs delegated work,
consistent with the same policy Kogen already applies to `apps`/`plugins`/`shell_snapshot`), not
because this probe observed it changing behavior — it did not, in the one clean run available.
**This is an n=1 per variant, single-question probe; one of the two runs did not complete, so this
is not strong evidence either way.** A proper A/B would need several repeats per variant, ideally
with a brief that gives the model some incentive/opportunity to delegate (e.g., a larger or
multi-part audit), before drawing a firm conclusion about `multi_agent`'s effect on this route.

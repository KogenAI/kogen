# Codex tool_output_token_limit probe

Carried over from `cross-harness-adversarial-roles/evidence/reviewer-context-diagnosis-2026-09-25.md`
("Probe: Codex `tool_output_token_limit`"). Codex CLI 0.156.1 (the same version
Kogen pins), `codex exec --ephemeral -s read-only -m gpt-6-luna`, low effort,
prompt: run `seq 1 60000` (349 KB of output).

| Setting | Model saw truncation | Input tokens | Wall |
|---|---|---|---|
| `-c tool_output_token_limit=1000` | yes | 37,864 | 18.7 s |
| default | yes | 56,920 | 14.3 s |

Confirmed again on 2026-09-25 by the driver session: the Kogen-managed 0.156.1
runtime (shared Kogen scope) ran `codex exec` with `-c tool_output_token_limit=4000`
and bypass flags, and completed normally.
Limitation: this shows that the runtime accepts the key and applies it. It does
not measure the effect on a whole Review.

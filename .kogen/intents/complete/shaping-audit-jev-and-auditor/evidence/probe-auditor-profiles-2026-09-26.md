# Probe: the route auditor on this Draft (2026-09-26, revision 13 dogfood)

Question: can the auditor this Intent specifies (route
`claude-dominant-adversarial-codex` → Codex `gpt-6-sol` high; Claude routes →
`claude-opus-5-5` high) finish a real audit of a real, large Draft inside its
per-run limit, and what does it find? Asked by the Shaper: "This intent
introduces an auditor that you didn't even try on this intent?!"

Method: direct launches, no Expert, no Kogen wrapper (the auditor code does
not exist yet). Codex: managed 0.156.1 `codex exec` with `-m gpt-6-sol`,
`model_reasoning_effort`, `--disable multi_agent --disable apps --disable
plugins --disable shell_snapshot`, `--sandbox read-only`, `--ephemeral`,
`--output-schema` (lookaround-free findings schema, `schema.json`), `--json`,
prompt on stdin, killed by `perl alarm`. Claude: managed 2.1.281 `claude -p
--model claude-opus-5-5 --effort high --output-format json --json-schema
<schema> --tools ""`. Prompt: the 2-minute one-pass blind brief with the
blind-auditor-layer checklist (`brief.txt`), then the package and scoped files
inlined within the bounds under test. Private CODEX_HOME with a copied login;
no `plugins/` appeared in the shared scope.

| run | profile | input | limit | wall | result |
|---|---|---|---|---|---|
| A | sol high | 160 KB, 24 KB/file cap | 180 s | 180.0 s | killed, no output, no tool calls |
| S1-S3 (parallel) | sol high | ~46 KB shards | 180 s | 180.0 s each | all killed, no output |
| earlier B | sol high | ~140 KB | 180 s | 179.5 s | 6 findings (evidence/probe-auditor-ab-2026-09-26.md) |
| M1 | sol medium | 46 KB shard | 180 s | 112.5 s | 2 findings |
| MF | sol medium | 160 KB | 180 s | 167.1 s | 3 findings |
| H300 | sol high | 160 KB | 300 s | 255.5 s | 6 findings |
| C300 | opus high | 160 KB | 300 s | 169 s | 12 findings |
| R3 (after removing all limits; no kill) | sol high | 160 KB, contract only | none | 907.7 s | 4 findings |
| R2 (confirming, after fixes) | sol high | 160 KB, no per-file cap | 300 s | 243.725962000 s | 2 findings |

Findings: `*-findings.json`. Dispositions: questions.md `## Dispositions`,
"Revision 13 dogfood audit".

Conclusions:
- Input size is not the lever: 46 KB shards were killed like the 160 KB
  prompt. Sol high needs about 3-4.5 minutes.
- The Shaper chose "High, raise limit to 300 s". Both high profiles finished
  inside 300 s on the full prompt.
- The 24 KB per-file cap hid 72% of `scenarios.yaml`; both high auditors
  flagged the truncation. The cap is removed (fixed file order, 160 KB total).

Limitations: n=1 per condition; wall time includes startup. The Claude run
used the shared Claude scope directly, not a Kogen materialization; the Codex
runs used `-C` on the checkout with a read-only sandbox, not a
materialization.

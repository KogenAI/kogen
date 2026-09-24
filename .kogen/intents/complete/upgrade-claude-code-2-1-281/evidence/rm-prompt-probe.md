# Probe: 2.1.281 substitution-rm prompt and its opt-out (2026-09-24, Shaping)

Why: the Shaper decided that unattended roles must not get confirmations, so
Kogen will set `CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT=1`. This probe checks
that the exact 2.1.281 binary blocks the command by default and honors the
opt-out.

Setup:
- Binary: the scratch arm64 2.1.281 binary from
  `registry-and-binary-probe.md`, with its sha512 matching the registry.
- Environment: `env -i` with `HOME`, `PATH=/usr/bin:/bin`, `USER`,
  `DISABLE_AUTOUPDATER=1`, `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` and
  `CLAUDE_CONFIG_DIR` set to Kogen's shared scope. That scope is Kogen's own
  login; no personal credentials were used.
- Flags: `-p --model claude-sonnet-5 --effort low --dangerously-skip-permissions --setting-sources "" --output-format stream-json --verbose`.
- Each run used a fresh disposable directory containing an empty `stale-cache/`.
- The prompt asked for exactly one Bash command: `rm -rf "$(printf stale-cache)"`.

| run | extra env | tool_result | stale-cache after |
|---|---|---|---|
| control | none | is_error=true: "Dangerous rm operation detected: the target is the output of a command substitution ... This requires explicit approval and cannot be auto-allowed by permission rules." | still exists |
| opt-out | `CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT=1` | is_error=false, "(Bash completed with no output)" | removed |

Raw stream-json output is in `rm-prompt-probe/rm2-control.jsonl` and
`rm-prompt-probe/rm2-optout.jsonl`. Cost: about $0.038 for the control run and
about $0.032 for the opt-out run.

Invalid earlier attempts are kept here for honesty; neither says anything about
the CLI:
1. The command was wrapped in `timeout`, which doesn't exist in `/usr/bin:/bin`
   on macOS. Exit 127, and nothing ran.
2. With `claude-haiku-4-5-20251001`, the model refused to call the tool both
   times. My prompt also had a stray ` .` after the command. No tool call
   happened (cost about $0.020 and $0.013).

Limitations: this ran the scratch binary directly, not through Kogen's launch
path. It proves only that the native CLI honors the variable. It does not prove
that Kogen passes the variable; the offline launch-environment tests in
scenario `unattended-rm-opt-out` cover that.

# Slash Commands — Claude Custom Commands

7 hand-authored/generated slash commands, dual-source, dual-install into each harness's own command
surface.

## Claude — 7 Commands, Dual Source

`harnesses/claude/commands/`:

- Plain `.md` (hand-authored, installed as-is): `babysit.md`, `command.md`, `document.md`,
  `release-new-version.md`, `rule.md`.
- `.md.j2` (rendered by `generate.sh` before install): `poke-holes.md.j2`, `ready.md.j2`.

`babysit.md` carries no procedure logic of its own — it is the single named entry point the
`claude-babysit` launcher's initial prompt and the recurring `/loop` cadence both fire; the actual
standing procedure lives in `harnesses/shared/prompt-bodies/babysit.txt` (one copy, no drift).
`harnesses/claude/hooks/command-payload-resolves_test.sh` asserts every cadence payload named in a
prompt body resolves to a real command file here.

Install (`install.sh` § `install_commands`, manifest step): copies `commands_source/*.md` (hand-authored)
→ `~/.claude/commands/`, PLUS the rendered output of the `.j2` sources from
`templates/generated/claude-code/commands/*.md`. Prunes stale files from a prior install
(`installed-by-ocg` manifest tracking). `harnesses/claude/manifest.yaml`: `commands_dir: ~/.claude/commands`,
`commands_source: harnesses/claude/commands`.

`ready.md.j2` runs a **handoff reconciliation step** immediately before its `mv draft/ -> ready/`: for a
pitch carrying `handoffs:`, it shells `mix codegen.pitches.scope --check --dir=draft --slug=<slug>
--stamp-handoff-receipt` — a HANDOFF GAP failure withholds the move; a clean run stamps
`handoff_receipt:` into every draft participant. `document.md`'s promotion note routes concrete handoffs
through `/ready` (not a raw manual `mv`) — see `context/pitch-lifecycle.md`.

## Trigger Keywords

slash commands, /command, /document, /rule, /release-new-version, /poke-holes, /ready, /babysit, commands_source, commands_dir, install_commands, prompts_dir, prompts_source, handoff reconciliation, stamp-handoff-receipt, bilateral handoff record, handoff_receipt fleet transfer

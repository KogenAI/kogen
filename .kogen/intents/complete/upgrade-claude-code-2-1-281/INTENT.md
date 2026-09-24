# Upgrade managed Claude Code runtime to 2.1.281

Status: **Approved** (see approval.md).

Kogen's managed Claude Code is pinned to 2.1.280. The Shaper's personal Claude
Code is on 2.1.281, which is the npm `latest` release, and feels faster with
Opus. This Intent moves Kogen's pin to exactly 2.1.281. It follows
`workflows/claude-code-runtime-upgrade.md` and keeps every current behavior.

## Outcome walkthrough

1. The Shaper runs `mix kogen.claude.install`. Kogen downloads the official
   2.1.281 darwin tarball, checks it against the new pinned sha512, and publishes
   it atomically as the default runtime. The 2.1.280 runtime and every login
   scope stay untouched.
2. `mix kogen.claude.status` reports `Pinned Claude Code: 2.1.281`. The
   "not installed" error and the README tested-version claims say 2.1.281 too.
3. Shape, Build, Reviewer rework and helper launches all run on the managed
   2.1.281 binary with unchanged flags, models and efforts. A Build that was
   already running keeps its 2.1.280 executable.
4. If the download or integrity check fails, 2.1.280 stays selected and working.
5. A role that runs `rm -rf "$(…)"` does so without a confirmation, the same as
   on 2.1.280.

**Challenge:** an implementation could change the version string and URLs but
keep the 2.1.280 hashes, or change `install.py` but not
`Kogen.ClaudeCode.pinned_version`. Both would fail on real install or show a
mismatched status. An implementation could also pass every offline test while
2.1.281 quietly ignores `--agents` effort or changes `--resume` behavior. That is
why each semantic scenario has its own paid target. The resume target matters
most, because 2.1.281 changes how resumed history is replayed.

## Scope

- New pin and sha512 for darwin-arm64 and darwin-x64 in
  `priv/kogen/claude_code/install.py`, plus `@pinned_version` in
  `lib/kogen/claude_code.ex`.
- Updated version assertions in the tests, the installer fixture and the README
  claims, including README line 26, which names the Claude Code release.
- Refreshed reliability catalog entries for changed catalog-covered tests. This
  is bookkeeping only.
- Every managed launch sets `CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT=1`,
  overriding any inherited value. 2.1.281 otherwise blocks `rm -rf "$(…)"`
  commands even in bypass mode (confirmed by the probe), and Kogen's roles run
  unattended. The module doc and README should state this.
- Only the adaptations that 2.1.281 compatibility actually requires, if any.

## Non-goals

- Fast mode, and any change to route models, efforts or billing.
- Speed benchmarking or a claim that Opus gets faster. The Shaper dropped this
  (questions.md Q1).
- Tracking `latest` automatically, or any self-updater. The pin stays exact.
- Deleting retained 2.1.280 runtimes.
- Anything in the Codex upgrade, which is treated as a completed baseline that
  must be committed before this Build starts.
- Linux or Windows artifacts.

## Verification

Each scenario uses `check` plus its own paid target: live-shape-to-build,
live-general or live-reviewer-rework. This matches the three paid targets the
maintained workflow requires. `existing-runtime-upgrade` and `unattended-rm-opt-out` are offline-sufficient;
the latter also relies on the retained native probe.
See `scenarios.yaml`, `risks.yaml` and `evidence/registry-and-binary-probe.md`.

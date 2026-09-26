# Upgrade Kogen's pinned Claude Code runtime

Use this procedure only when maintaining the exact runtime selected by a Kogen release. Start at the repository root with the requested version, a clean checkout baseline, the current pin in `priv/kogen/claude_code/install.py`, this README and runtime contract, official release notes, an explicitly authenticated Kogen scope, installed dependencies, and the `check`, live-general, live-reviewer-rework, live-shape-to-build, and causally affected narrow lifecycle evidence owners.

1. Confirm the exact requested version and inspect its official release changes and native artifacts. Do not resolve or substitute upstream latest.
2. Verify per-platform npm tarball integrity (sha512) directly against the registry before adopting a new pin; never trust a mirrored or cached artifact.
3. Trace `Kogen.ClaudeCode`, `Kogen.Harness.Claude`, the login/status tasks, tracked hooks, helper profiles, session capture, and compatibility evidence consumers. Use bounded disposable source probes only for material uncertainty; never import personal credentials.
4. Re-verify before adopting a new pin every undocumented behavior Kogen relies on: per-agent `effort` in `--agents` (recorded in helper transcripts), `--disallowedTools Agent(<name>)` denying built-in agents under `--dangerously-skip-permissions`, a Stop hook block continuing the same `-p` turn, exact `--session-id`/`--resume` semantics, `--json-schema` structured output for the Reviewer, and stream-json assistant `message.model`/`parent_tool_use_id` linkage. Update `priv/kogen/claude_code/models.yaml` evidence if models changed.

   Also re-probe, on the candidate runtime, the credential cases from
   `evidence/harness-home-credential-probe-2026-09-25.md` that the per-Build
   harness home depends on, before accepting the new pin:
   - **Case A** (`HOME` real, `CLAUDE_CONFIG_DIR` the login scope,
     `CLAUDE_SECURESTORAGE_CONFIG_DIR` unset): `claude auth status` reports
     `loggedIn: true`.
   - **Case D2** (`HOME` real, `CLAUDE_CONFIG_DIR` a fresh per-Build config
     dir, `CLAUDE_SECURESTORAGE_CONFIG_DIR` the login scope path): `claude
     auth status` still reports `loggedIn: true` — this is the shape every
     Build role launch uses.
   - **Case F** (`HOME` real, `CLAUDE_CONFIG_DIR` a fresh dir,
     `CLAUDE_SECURESTORAGE_CONFIG_DIR` inherited empty): confirm it still
     silently selects the personal Claude Code login, and that every Kogen
     Claude Code launch (Build roles, Shape, login and status) still strips
     an inherited `CLAUDE_SECURESTORAGE_CONFIG_DIR` before setting its own.

   Re-run the write-boundary probes too: a real Developer turn and a resumed
   turn inside the Seatbelt profile, asserting the kernel denial log stays
   empty for the harness's own paths (Candidate, harness home, per-Build temp
   dir, granted login state). The scripts are in
   `.kogen/intents/approved/isolated-candidate-workspace/evidence/write-boundary-probe/`.
5. Scopes under `~/Library/Application Support/Kogen/claude/accounts` are never moved or renamed by this procedure or by the installer; Claude Code keys each scope's macOS Keychain login by the scope path.
6. Shape and explicitly approve one small upgrade Intent covering exact artifact/integrity changes, required adaptations, and preservation of current behavior. Escalate consequential product differences to the Shaper.
7. Build through normal gate ownership. Keep active Builds bound to their starting runtime. Managed launches must set `DISABLE_AUTOUPDATER=1`; preserve installer integrity/failure/retry controls, scoped login, every-role discovery isolation, ordinary tool/hook environments, exact resume, and active-runtime retention.
8. Require `check` plus the paid targets live-general, live-reviewer-rework, and live-shape-to-build with harness: claude, followed by fresh independent Review.
9. Complete through the ordinary accepted Commit workflow. Publication remains separately authorized; a future Kogen updater installs only the runtime declared by its release.

Outputs are the approved upgrade Intent, verified exact pin/artifact metadata, necessary integration changes, concise retained evidence, and updated tested-version claims. Completion requires real native acceptance and Review; version output, fake harness tests, accepted flags, or historical receipts alone are insufficient.

On failure, retain diagnostics and the published supported pin. Distinguish setup errors from compatibility defects, fix within the approved scope and resumption budget, and return to Shaping if a new product decision is required. Never fall back to a personal Claude Code account or another release, accept stale evidence, raise retry limits, or auto-publish.

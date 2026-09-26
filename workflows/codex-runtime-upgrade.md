# Upgrade Kogen's pinned Codex runtime

Use this procedure only when maintaining the exact runtime selected by a Kogen release. Start at the repository root with the requested version, a clean checkout baseline, the current pin in `priv/kogen/codex/install.py`, this README and runtime contract, official release notes, an explicitly authenticated Kogen scope, installed dependencies, and the `check`, `live-native`, and causally affected narrow lifecycle evidence owners.

1. Confirm the exact requested version and inspect its official release changes and native artifacts. Do not substitute upstream latest.
2. Trace `Kogen.Codex`, `Kogen.Codex.Environment`, `Kogen.Harness`, the login/status tasks, tracked hooks, helper profiles, session capture, and compatibility evidence consumers. Use bounded disposable source probes only for material uncertainty; never import personal credentials.
3. Shape and explicitly approve one small upgrade Intent covering exact artifact/integrity changes, required adaptations, and preservation of current behavior. Escalate consequential product differences to the Shaper.

   Before that Intent is approved, re-run the write-boundary probes for Codex
   on the candidate runtime: a real `exec` and an `exec resume` inside the
   Codex rendering of the Seatbelt profile (`probe19`/`probe20` in
   `.kogen/intents/approved/isolated-candidate-workspace/evidence/write-boundary-probe/`),
   confirming the kernel denial log stays empty for Codex's own writes
   (rollouts, history, state databases, locks and bookkeeping in the granted
   scope; its operation root in the harness home) and only refuses writes
   outside the grants. `codex sandbox` itself is expected to fail inside the
   profile, since Codex's own Seatbelt cannot nest inside another one — that
   is why Kogen keeps `--dangerously-bypass-approvals-and-sandbox` and
   `--dangerously-bypass-hook-trust` rather than relying on it.
4. Build through normal gate ownership. Keep active Builds bound to their starting runtime. The candidate compatibility fixture in `Kogen.Codex.Compatibility` must receive the new concrete runtime and selected scope directly, never the active Build's old runtime or a public arbitrary-version override.
5. Require `check` and only the cataloged narrow target(s) justified by the
   Approved proof maps, followed by fresh independent Review. Preserve installer
   integrity/failure/retry controls, scoped login, every-role discovery
   isolation, ordinary tool/hook environments, exact resume, active-runtime
   retention, the five-case shaping evaluation, and retained evidence. User
   installation performs no model tests.
6. Complete through the ordinary accepted Commit workflow. Publication remains separately authorized; a future Kogen updater installs only the runtime declared by its release.

Outputs are the approved upgrade Intent, verified exact pin/artifact metadata, necessary integration changes, concise retained evidence, and updated tested-version claims. Completion requires real native acceptance and Review; version output, fake harness tests, accepted flags, or historical receipts alone are insufficient.

On failure, retain diagnostics and the published supported pin. Distinguish setup errors from compatibility defects, fix within the approved scope and resumption budget, and return to Shaping if a new product decision is required. Never fall back to personal Codex or another release, accept stale evidence, raise retry limits, or auto-publish.

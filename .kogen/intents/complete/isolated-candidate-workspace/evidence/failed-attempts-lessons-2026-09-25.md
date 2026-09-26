# Lessons from the failed isolation attempts (read 2026-09-25)

Sources, read-only: `git stash show -p` of `stash@{2}`, `{3}`, `{4}`, `{5}`
(`isolated-candidate-workspace*`), `{20}` `Isolation`, `{26}` `ISOLATION`,
`{27}` `ISolation`; and the tracking records under
`.kogen/runtime/scenario-tracking/<id>/record.json` (fields `status`,
`attempts[].failure`, `attempts[].failure_signatures`, `attempts[].targets`,
`findings`). No stash was applied, popped or dropped.

## The record

| When | Build | Intent | Stop |
|---|---|---|---|
| 09-17 | `IuomX-sS…`, `bqLfQMHC…` | isolated-build-worktrees | `make live` failed 3 cycles; `make check` failed 3 cycles |
| 09-17/18 | `v9MqL3sl…`, `tufyrrpl…`, `CQemTmO8…` | isolated-build-dependency-routing | "unified verification settlement has stale or contradictory binding" (2×); `make live` 3 cycles |
| 09-18 | `K9HtlCMz…`, `rhjAaenn…`, `8_JWkER4…` | bootstrap-isolated-build-recovery | old JSON handoff "field status expected ready"; settlement binding integrity |
| 09-19 | `4Hd6wOXc…` | isolated-candidate-workspace | proof selector missing at handoff |
| 09-20/21 | `VZFIeCIg…`, `1vg5QEsj…`, `ZJDgU9wo…`, `_8Qpvuip…` | same | `make check` (offline gate) failed all 3 cycles, warm-seeded `_build` |
| 09-20/21 | `JendTonO…`, `TKf3bxgQ…` | same | `live-native` (Codex compatibility) failed 3 cycles |
| 09-21 | `Zi1QBLqb…` | same | `live-reviewer-rework` failed 3 cycles |
| 09-22 | `suowZ26k…`, `IBs1pJmb…`, `181SwyyM…` | same | "Candidate changed paths outside Approved guards: .kogen/intents/drafts/compare-pi-opencode-harnesses/…" |
| 09-24 | `cFnHwg7P…` (stash@{2}, 61 files, +4330/−490) | same, B1 reshape | attempt 0: both paid targets **passed**, Review asked for Stop unset-root controls; attempt 1: "required Developer Bash verification-policy hook is not registered" |

## Lessons carried into this reshape

1. **Self-hosting (D9) killed the closest attempt.** In `cFnHwg7P` the
   Candidate rewrote the PreToolUse and Stop commands in `.codex/hooks.json`
   and `priv/kogen/claude_code/settings.json` to use `KOGEN_PROJECT_ROOT`.
   The running controller was main's, and it runs in the same checkout. Its
   `VerificationPolicy.preflight/2` byte-compares the registered command
   (`lib/kogen/verification_policy.ex:14,60-83` at `2909f557`) against the
   file on disk, and `Kogen.Harness.Claude` passes `--settings` from the
   checkout's `priv/` (`lib/kogen/harness/claude.ex:26,121-122`). The rework
   launch therefore refused, although the Candidate had passed every target.
   **Now:** with Intent #4 the parent controller is the only verification
   judge, so this Intent changes no hook file, no hook registration and no
   Claude settings file. `.codex/hooks.json`, `.codex/hooks/**`,
   `priv/kogen/claude_code/settings.json`, the Makefile, the catalog and the
   role prompts are outside the guarded paths.
2. **Shaping in the one checkout fails Builds.** Three Builds on 09-22 (and
   `l5Ur5WAv`, brief 23) stopped because another session wrote ignored
   `.kogen/intents/drafts/**` in the checkout, and `GuardedPaths.capture/1`
   snapshots ignored files (`lib/kogen/build/guarded_paths.ex:4-6`). The fix
   is structural: capture reads the Candidate root only. Scenario
   `shaping-during-build` makes this an explicit offline proof. **The
   self-hosting Build of this Intent still runs in the one checkout**, so the
   driver must not write there while it runs.
3. **Warm seeding and copied `_build/` caused the 09-20/21 `make check`
   failures** (`_build/lib/kogen/priv` and other links point back into
   control). Kept from the 09-24 reshape: copy `deps/` only, compile cold
   (about 3.3 s).
4. **Hook-based settlement integrity** ("stale or contradictory binding") and
   the old JSON handoff caused the 09-17/18 failures. Both are gone:
   controller-built handoff (`5b44ceb4`) and controller-owned verification
   (#4).
5. **Paid flakiness** (`live-native`, `live`) consumed whole Builds. #2 fixes
   the Codex compatibility owner; #4 reruns only failed paid targets. This
   reshape selects **one** paid target, `live-shape-to-build`, and no
   `live-native`.
6. **Review found a missing negative control** in `cFnHwg7P`. Every scenario
   here names its disconfirming controls explicitly in `then`/`evidence`, so
   the Developer writes them in the first attempt.
7. **Credential bridging was tried and abandoned.** `stash@{27}` added
   `lib/kogen/harness/isolation.ex` with `prepare_auth_bridge/2` to bring a
   login into a private per-launch home; the accepted `isolate-codex-sessions`
   design instead keeps `CODEX_HOME` as the scope and isolates only `HOME`,
   `XDG_*` and sqlite per launch. For Claude a private `HOME` loses the login
   outright (`evidence/harness-home-credential-probe-2026-09-25.md`, case B).
   **Now:** logins are referenced by path, never bridged, copied or moved.
8. **Size.** `stash@{2}` touched 61 files. About a quarter was hook and Stop
   work that #4 makes unnecessary. The reshape adds the harness home and
   credential binding (small, two adapters and one support audit) and keeps
   the Candidate commands the Shaper asked for.

# Add cross-harness adversarial Reviewer and Expert routes

Status: **Approved** by the human Shaper in the Kogen Shaping continuation of 2026-09-25
(`approval.md`). It was revised by the driver session after Builds `kdUszVF4Gw71QsxsppvSKc2b`
and `o-DlRi_iHnqIwmxfcCz-obe0`, then reconciled and narrowed in that continuation. Earlier
approvals are historical (`historical-approval-*.md`).

**No auditor in this Intent** (Shaper, 2026-09-25 Claude Shaping continuation: "we don't
want auditor now … auditor comes in the shaping quality/audit intent … it's stupid to have
the plumbing now for things that aren't wired in"). The auditor slot and all its launch
plumbing belong to `shaping-preflight-audit` (#3), which adds and wires it together.

**Depends on Intent #1, `bounded-reviewer-evidence`, which has landed** on `main` as
`22a2db95`. The package validation passed on that `main`
(`evidence/admission-validation-2026-09-25-22a2db95.md`). If `main` moves before the
Build, re-run it (risk `baseline-moves-before-build`).

## Problem

Every Kogen route runs every role on one harness, so a Build is reviewed by the same model
family that wrote it. The Shaper wants an adversarial pairing: one harness builds, and the
other reviews, advises and audits.

Earlier Builds of this Intent implemented the routing, and two of them passed `check`:

- Build `btwokrNxL50md1z5Fb-GGYOO` failed `live-native` in every cycle, because the Codex
  compatibility live test ran two scripted stand-in Reviewer turns against a 240 s turn
  cap. See `evidence/compatibility-diagnosis-2026-09-25.md`.
- Build `kdUszVF4Gw71QsxsppvSKc2b` fixed that: `live-native` passed twice (292 s, 431 s).
  Then `live-reviewer-rework` timed out once on the new default route and passed on the
  next cycle (494 s). The Build still ended `cannot_comply`, because a Developer
  objection from the failed cycle had been superseded by the passing cycle but still
  stopped the Build. See `evidence/build-failure-2026-09-25.md`.

The slow Codex Reviewer has Kogen root causes: the tracking record embeds copies of
itself, the Reviewer's only pointer to evidence is the raw record, Kogen sets no Codex
tool-output limit, and live fixtures sit inside the checkout. See
`evidence/reviewer-context-diagnosis-2026-09-25.md` and the Sol and Astra analyses.
Intent #1 fixes all of these, and it also fixes the stale-objection stop. This revision
builds on #1 and does not repeat any of that work.

## What this Intent relies on from #1

Once #1 has landed on `main`:

- A tracking-record citation stores only metadata, so the record never embeds itself.
- Each attempt's Reviewer gets a bounded, Candidate-bound **review packet** from the
  controller, and can still open any Candidate file.
- Every Codex role launch sets a central `tool_output_token_limit`.
- The live Reviewer-rework fixture root is outside the checkout. Retained evidence still
  lands in `.kogen/runtime/live-evidence`.
- A confident Developer objection that a later passing Stop cycle of the same attempt
  has superseded reaches the Reviewer as a labelled advisory and no longer stops the Build.

This Intent must keep all five on every new launch path. For example, the Codex Reviewer
and Expert launched by a hybrid route must go through the prepared Codex launch
context, so they carry #1's output limit. The Reviewer must get the same review packet on
either harness.

### Current HEAD anchors for #1 (22a2db95); do not re-implement #1

- Review packet: `lib/kogen/build/review_packet.ex` (`build/1`, `write/5`, `verify/1`),
  written by `write_review_packet/3` in `lib/kogen/build.ex` (~741) to
  `.kogen/runtime/scenario-tracking/<id>/review-packets/<n>.json`. `review_packet` is in the
  Reviewer `KOGEN_TASK_CONTEXT`, and `tracking_path` is kept.
- Metadata-only citations: `snapshot_references`/`snapshot_reference` in `lib/kogen/build.ex`
  (~1030-1053). Self-citations go to `record-versions/` sidecars (`lib/kogen/build/tracking.ex`
  ~101-149).
- Superseded objection: `ReviewPacket.superseded_objection/4`, called from `lib/kogen/build.ex`
  (~414-427).
- Codex output limit: `@tool_output_token_limit 4000` in `lib/kogen/codex/environment.ex`
  (line 12, applied at ~431).
- Fixture outside the checkout, and the Claude login preflight:
  `test/support/review_packet_audit.ex` (`assert_outside_checkout!/2`, `assert_logged_in!/1`),
  used by `test/support/live_reviewer_rework_fixture.ex`.
- Tests that must stay green: `test/kogen/review_packet_test.exs`,
  `review_packet_audit_test.exs`, `superseded_objection_test.exs`.

The external analyses and the reviewer-context diagnosis under `evidence/` are historical,
and their pre-#1 anchors are obsolete.

## Outcome

1. **Four named routes.** The two clean single-harness routes (`claude`, `codex`) keep
   their bytes and their role behaviour. `claude-dominant-adversarial-codex` runs Shaping
   and Developer on Claude Code, and runs Reviewer and Expert on Codex/GPT-6. `codex-dominant-adversarial-claude` is the
   mirror image. In a hybrid route, every role names its own harness, model and effort.
   Helpers always run on the harness of the role that launched them.
2. **No auditor role.** Routes, readiness, launch functions, role identities, setup guards
   and the frozen role matrix know exactly four roles: shaping, developer, reviewer and
   expert. #3 adds the auditor when it wires it in.
3. **The Expert on the other harness.** A role whose route puts the Expert on another
   harness reaches it only through `mix kogen.expert`. Kogen launches that Expert
   read-only from the frozen assignment the role's launch carries. It never substitutes a
   native helper for it.
4. **Each role's assignment is fixed for the Build.** A Build freezes the complete
   role-to-harness/model/effort matrix under a new record and summary key,
   `role_assignment`. It keeps that matrix even if the config changes mid-Build. The
   existing `route` map in the record and the summary keeps its exact shape, so its
   consumers are untouched. Developer resume stays in the same harness session, Stop ownership is
   unchanged, and each Review is fresh on its assigned harness.
5. **No silent fallback.** A missing, unauthenticated or mismatched harness for any role
   stops Shape or Build before that role's provider work, naming the role and harness.
6. **A reliable Codex compatibility test within 15 minutes (HAR-03).** The fix stays
   inside its owner (`lib/kogen/codex/compatibility.ex`, `priv/kogen/codex/**` and their
   tests):
   - Remove the two scripted stand-in Reviewer turns.
   - Keep every native-boundary check.
   - Keep main's 240 s per-turn limit, now passed explicitly by the owner. It covers the
     measured turns without stand-in Reviewers (Developer 72-135 s, resume 56-90 s). No
     timeout is raised.
   - After a `timed_out` result, allow one whole rerun in a fresh fixture, once per test
     invocation and only if it fits the 15-minute deadline.
   - Retain both attempts in the test's one evidence manifest.
7. **`default_route` stays `claude` in this Build (expand, then contract; DIRECTION D9).**
   Flipping the default to `claude-dominant-adversarial-codex` moves the Reviewer to Codex
   in `live-general` and `live-shape-to-build`. Both targets would have to be edited, and
   D8 then requires running them, but this Intent's row allows only `live-native` and
   `live-reviewer-rework`. So this Intent ships the four routes and pins
   `live-reviewer-rework`'s nested Build to the hybrid route explicitly. The one-line flip
   of the default, and making `live_test.exs` and `live_shape_to_build_test.exs`
   role-aware, move to a small follow-up Intent that runs those two targets. See risk
   `default-route-flip-deferred`.

## Effect on live targets

| Target | Route it uses | Effect of this Intent |
|---|---|---|
| `live-native` | clean `codex` route through `RouteConfig.codex_route!`, never the default | existing cases unchanged; a new case names the hybrid route and launches the real Codex Expert; **runs here** |
| `live-reviewer-rework` | today the default; after this Intent, `--route claude-dominant-adversarial-codex` in its fixture | Reviewer moves to Codex; the audit becomes role-aware; **runs here** |
| `live-shape-to-build` | default (`claude`, unchanged) | none: the route and summary shapes are unchanged, and `role_assignment` is additive. `live_shape_to_build_test.exs` must **not** be edited, so D8 does not require this target. A run on the hybrid default belongs to the default-flip follow-up |
| `live-general` | default (`claude`, unchanged), Reviewer only | none; test file not edited |
| `live-shaping-quality` | Codex profiles from the one `harness: codex` route; Shaper on the default | none; exactly one clean `harness: codex` route remains |
| `cold-offline`, `check` | offline | `check` runs |

The shared `test/support/root_profile_audit.ex` becomes role-aware. On the unchanged
`claude` default, it selects the same store for every role that it does today. Its offline
test covers both clean and hybrid configs.

## Walkthrough

1. A user runs `mix kogen.shape --route claude-dominant-adversarial-codex`. After the
   follow-up flips the default, a plain `mix kogen.shape` does the same.
2. Readiness opens Claude Code for Shaping and Codex for the Expert, before any provider
   work.
3. The user approves, and `mix kogen.build --route claude-dominant-adversarial-codex` opens Claude Code for the Developer and Codex
   for the Reviewer and Expert. The Build freezes the role matrix in the record.
4. The Developer works on Claude Code. For a hard question, it runs `mix kogen.expert`,
   which answers from GPT-6 Sol on Codex.
5. Stop runs `check`, `live-native` and `live-reviewer-rework`:
   - Inside `live-native`, the compatibility runner drives discovery, interactive Shaping,
     the Developer with its Stop Check, and the exact resume with its helper, in about
     4-7 minutes. The hybrid case launches the real Codex Expert through `mix kogen.expert`
     and checks its executed model and effort in the Codex session store.
   - `live-reviewer-rework` runs a real Build on the hybrid route, in a fixture outside
     the checkout (from #1).
     Its Reviewer is Codex/GPT-6 Sol with the production `reviewer.md` prompt and #1's
     review packet. When Review asks for rework, the same Claude Developer session resumes.
6. If the Codex login is missing, Shape or Build refuses at readiness and names the
   Reviewer/Expert role and the Codex harness.

## Challenge: plausible but wrong implementations

- A hybrid route that silently runs the Reviewer on the dominant harness, or a helper that
  inherits the other harness. Caught by the per-role dispatch tests and the live
  `live-reviewer-rework` role audit.
- A new Expert launch path that builds its own Codex argv or environment,
  instead of using the prepared launch context. It would lose #1's
  `tool_output_token_limit` and the unattended flags. Caught by `harness_role_test.exs`,
  which asserts both on every Codex root launch.
- Restoring the reuse Candidate `30b96fa0` wholesale, so its auditor plumbing
  (`launch_auditor`, the `:auditor` role and readiness entry, `KOGEN_ROLE=auditor`, the
  auditor setup guards and config keys) survives unwired. Caught by the role-set
  assertions in the configuration, dispatch and readiness tests.
- Writing the role matrix into the existing `route` map, which breaks its exact-shape
  consumers (`live_shape_to_build_test.exs`, `evidence.ex`). Rejected: the matrix is the
  additive `role_assignment` key.
- Leaving the rework fixture on the default route, so no Codex Reviewer ever runs.
  Caught by the role-aware audit, which requires both Reviewer sessions in the Codex store.
  The fixture must load the named hybrid route's profiles, pass `--route`, and preflight both
  the Claude login and a new Codex login and scope (next to
  `ReviewPacketAudit.assert_logged_in!/1`, keeping Codex's canonical-path trust).
- Editing `priv/kogen/prompts/reviewer.md`. The guarded paths list only `expert.md` and
  `execution-policy.md` under `priv/kogen/prompts/`, so the Build guard rejects any edit to
  the production Reviewer prompt.
- A mid-Build config edit that changes the Expert assignment handed to the Developer.
  Caught by the lifecycle mutation test.
- Raising the compatibility turn limit (240 s), `KOGEN_BOUNDED_EXEC_TIMEOUT` in config, the ExUnit timeouts
  (900 000 ms compatibility, 1 200 000 ms live owners), or adding provider retries to
  Kogen core. Lowering Reviewer effort, trimming `reviewer.md`, or disabling Reviewer
  helpers to make `live-reviewer-rework` faster. All forbidden.
- Keeping a stand-in Reviewer and tailoring it, or dropping native-boundary assertions
  from `verify_evidence` along with the Reviewer turns. Rejected.
- A compatibility retry that reruns only the failed turn, drops the first attempt's
  evidence, or also retries non-timeout failures. Rejected.

## Reuse base: the accepted Build that carried the auditor

Build `sjqVuqHRgv3YXUVdET-YlksA` finished **accepted** and was committed on `main` as
`30b96fa0e2c954e4804733df805a36823262e875` ("Add cross-harness adversarial Reviewer, Expert
and auditor routes", parent `22a2db95`). It was then reset away because it carried the
auditor plumbing the Shaper does not want yet. It is reachable only from the reflog until it
gets a ref (risk `reference-candidate-predates-dependency`).

The Developer takes that work and removes the auditor (Shaper: "during the build, developer
should probably take all that stuff from reflog and just remove that shaping auditor
plumbing"):

1. Restore its files with `git show 30b96fa0:<path>`, except its `.kogen/intents/**` package
   copy. Never check out, cherry-pick or reset to it.
2. Remove every auditor part (`git diff 22a2db95 30b96fa0 | grep -n auditor` lists about
   180 changed lines): config and README keys and prose, the `:auditor` role and clean-route
   resolution in `intent.ex`, `launch_auditor`/`auditor_args` and the `"auditor"` reader in
   `harness.ex` and `harness/*.ex`, the `:auditor` readiness entry in `kogen.shape.ex`,
   `"auditor"` in the setup guards of `codex.ex` and `claude_code.ex`, the auditor in
   `role_assignment`, and the matching tests. Keep the Expert equivalents.
3. Refresh the reliability-ledger hashes for the changed cataloged tests.

It already contains the sidecar fix, the compatibility fix and the pinned hybrid rework
fixture, so the Developer checks them against the scenarios rather than rewriting them. The
new Candidate is verified and reviewed on its own; the earlier accepted verdict is not
evidence for it. The older stashes `cross-harness-candidate-2026-09-25b` (`2294e64a`) and
`cross-harness-candidate-2026-09-25` (`6905e9a4`, pre-#1) are superseded. Never apply, pop
or drop them.

## Scope and appetite

One Build, mostly restoration: the accepted Candidate `30b96fa0` holds the work. The
contract covers:

- removing the auditor plumbing from it;
- routing the new launch paths through #1's controls;
- the Codex management-guard gap;
- the additive `role_assignment` record key;
- pinning the rework fixture to the hybrid route;
- resolving retained record-version sidecars next to a relocated record (found by Build
  `o-DlRi`).

## Non-goals

- Anything that #1 owns: the review packet, citation metadata, the Codex output limit
  itself, the fixture location, and the stale-objection fix. One exception: scenario
  `retained-evidence-with-record-sidecars` fixes a latent #1 defect that blocks this
  Intent's own live proof. It changes only sidecar lookup in `Evidence.resolve/2` and the
  fixture's preserve step, not the citation format.
- The auditor, in any form: the role slot, route keys, readiness, `launch_auditor`,
  identity, setup guards, prompt, findings schema, invocation and Jev classification. All
  belong to Intent #3, `shaping-preflight-audit`.
- Stop removal, the `live-native` split, and controller-owned verification. These belong
  to `fortify-paid-verification` (#4) and its follow-up.
- Any change to the `Makefile`, `priv/kogen/verification_targets.yaml`, `.codex/hooks/**`
  or the Stop hook.
- Per-role helper model selection, benchmark metrics, Pi, and arbitrary-project support.
- Allowing new native bookkeeping keys ahead of time. The refuse-unknown policy stays.
- Raising any timeout.
- Flipping `default_route`, and editing `live_test.exs` or `live_shape_to_build_test.exs`.
  These go to the follow-up (risk `default-route-flip-deferred`).
- `test/kogen/live_reviewer_rework_test.exs` and the fixture location. Intent #1 owns
  both.

## Coordination

- **#1 `bounded-reviewer-evidence`** lands first and owns the Reviewer evidence and
  fixture work. This Intent consumes it and must not regress it.
- **#3 `shaping-preflight-audit`** owns the whole auditor: the role slot in the routes,
  readiness, launch function, identity, setup guards, prompt and invocation. It can follow
  this Intent's Expert pattern (a fresh read-only session on the role's harness from a frozen
  profile). The `30b96fa0` auditor code is a reference for it. **The staged #3 package
  (`plan/staging/shaping-preflight-audit/`) still assumes this Intent provides the slot and
  `launch_auditor`.** It needs a Shaping continuation before its Build.
  This package does not edit it.
- **#4 `fortify-paid-verification`** (approved against `2909f557`) must re-run its
  preflight after this Intent lands. Its compatibility-fixture Stop removal touches the
  owner this Intent changes. The default stays `claude`, so its live targets keep their
  routes. This Intent does not edit that package.
- **Follow-up, ROADMAP row 10a: flip `default_route`.** It flips the default to
  `claude-dominant-adversarial-codex`, makes `live_test.exs` and
  `live_shape_to_build_test.exs` role-aware, and runs `live-general` and
  `live-shape-to-build`. It could be grouped with ROADMAP order 10, which already runs
  `live-shape-to-build`.

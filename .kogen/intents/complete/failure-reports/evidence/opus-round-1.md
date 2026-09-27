**Verdict: not ready**

Most of the draft holds up against fa48e817. The keep/drop list is incomplete, and two specs are unclear enough that a Reviewer could block again.

## Blocking

1. **The drop list leaves continuation code in `failure_report.ex`.** INTENT.md:23-25 and references.yaml:7-11 tell the Developer to keep the `failure_report.ex` hunk whole. That hunk also contains the later slices' code:
   - `reconcile/1` (diff:540-603);
   - the `interrupted`, `publication-interrupted` and `session-lost` table rows (diff:440-442);
   - the `continues`, `budget_state`, `published` and `continuable` report fields (diff:502, 511-512, 526);
   - `refuse_publication` passing `%{"published" => false}` (diff:181);
   - the candidates task's fallback text `report:   none (written by the next mix kogen.build)` (diff:990), which assumes reconcile.

   INTENT.md:305-306 lists every one of these as a non-goal, so a high-effort Reviewer will flag them. Separately, references.yaml's drop list leaves out the `FailureReport.reconcile(control)` call in `run/3`, which INTENT.md:25 drops. Fix: list each of these as a drop.

2. **The F1 "category decided in two places" gap (INTENT.md:32-33) has no test that shows it closed.** In the Candidate, `stop/3` already computes `category` once (`details["category_override"] || infer_category_override(reason)`, diff:226). It uses that value for the report, the message and `retained/2`, so the "can disagree" failure doesn't show up in any test. Meanwhile INTENT.md:99 leaves the mechanism to the Developer, and risks.yaml:9-15 effectively requires the prefix mapping to stay for call sites whose reason varies. A medium-effort Developer can't tell what to change, and a Reviewer holding the bullet can reopen F1 on shape alone, which is how the last Build ended. Fix: replace the bullet with the acceptable shape, e.g. "an explicit category where the call site knows it, one reason→category function for the rest, evaluated once in `stop`." Also say whether the Candidate's renamed recorded key (`stop_category` → `category_override`, used at build.ex:790/817/857/1398) should be reverted.

3. **The paid-target login case (d) is underspecified** (INTENT.md:129-135, 236-237; scenarios.yaml:48, 56-57).
   - `provider_repo!` tests call `F.run_cycle!` (controller_verification_test.exs:1300-1421), so no Build message exists. "The reason names `make paid` and the login command" can only mean `cycle["failure"]["reason"]`, which the Candidate never sets: verification.ex diff:785-790 merges only `class` and `provider`.
   - `verification.ex` has no bindings, so where the command comes from is unstated.
   - On a real Build, the stop goes through `stop_reason("environment", …)` (build.ex:1547-1549). Its text, "environment failure before any provider-backed target: …", is false for a paid target and contradicts the required message format at INTENT.md:132.
   - Fix: name the field (failure `reason` = "make paid: claude login rejected (401) (class environment); run `mix kogen.claude.login`"), and say whether the environment wrapper text stays or changes.

## Non-blocking

- **The Starting point gap list is incomplete.** The kept hunks also diverge from the spec in these ways (tests should catch most, but listing them helps a medium-effort Developer):
  - `build_id` is read from `record["build_id"]`, which doesn't exist (tracking.ex:333-346). An admission report would land in `scenario-tracking/unknown/`.
  - `slug` and `intent_id` are read from top-level record keys that don't exist; they sit under `"intent"`.
  - `stopped_at` is truncated to seconds, but the spec wants microseconds.
  - `same_signature_count` is keyed by category plus digest, not by intent, package digest and signature digest.
  - `record` is an absolute path; the spec says control-relative.
  - The login message has no harness name.
  - `offline.py` sets `reproduce` to `make check` for non-test stages.
  - The handoff's `Reproduce:` fallback is `make check`, not the generic line.
  - `primary_lines/2` gains a `Reproduce:` line nobody asked for (diff:712).
- **Rename overwrites.** On POSIX, rename replaces an existing file, so "never replaced" needs an existence check under the lock, or a link-based no-clobber write.
- **`MIX_ENV=test <command>` is wrong for non-test stages.** `run_stage` uses `MIX_ENV=dev` unless the command is `mix test` (offline.py:124).
- **The generic `Reproduce:` line reads against the header.** The header already says "do not run them yourself" (failure_handoff.ex:46), and the Bash gate guard blocks `make <target>` (questions.md #7).
- **The login command follows the tail, not the role.** On the codex route, a Review or paid target printing the Claude tail yields `mix kogen.claude.login`. That matches the scenarios; one sentence in INTENT.md would stop a Reviewer questioning it.
- `existing-expectations-kept` has no `proof.base`. That's valid (the scenario gets the unproven-on-base label).

**Confirmed:**
- **Guarded paths:** every scenario's `affected_paths` is within `may_change_guarded_paths`.
- **Later slices:** no scenario depends on breakers or continuation.
- **Ledger:** it is untouched, and that's correct. There are 18 rows for controller_handoff_test.exs and 2 for build_preconditions_test.exs, and they bind by name (scripts/check/README.md:208-213). The remediation rows name files by path only, with no hash.
- **Existing tests:** the ones listed as unedited match by pattern or `starts_with?`, so the added suffix, prompt block and `reproduce` field don't break them. `control_state` ignores `.kogen/runtime/`.
- **Readiness case (c):** `FAKE_CLAUDE_LOGGED_OUT` has never been used by a test. Traced through the code, it fails after `Tracking.new` and after the owner record is written, with "… Run mix kogen.claude.login", so case (c) works.

Plan mode asked for a plan file and an ExitPlanMode call, but neither a write tool nor ExitPlanMode is available here, so this review is the whole output. Separately, the claude.ai Stripe connector needs to be authorized in your claude.ai connector settings before it can be used. It isn't needed for this review.

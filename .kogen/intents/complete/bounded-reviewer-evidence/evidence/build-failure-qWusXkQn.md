# Build qWusXkQnvl77VkiH2xEfuMdz failed: Reviewer omitted one scenario (2026-09-25)

Record: `.kogen/runtime/scenario-tracking/qWusXkQnvl77VkiH2xEfuMdz/record.json`
(route `claude`). Candidate stashed as `bounded-reviewer-evidence-candidate-2026-09-25`
(tree `754053548fc4058b73c5e226eb89efb098267ee9`).

- Stop cycle 1 **passed**: `check` and `live-reviewer-rework` (the nested Build with the
  new controller, packet and fixture outside the checkout).
- The Reviewer (Claude Opus 5.5, session `e8f5b376…`, about 2 minutes) inspected every area,
  including `lib/kogen/codex/environment.ex`, its tests and the probe note. It returned
  `accept` with 6 of 7 scenarios, all `satisfied`, and no findings. It omitted
  `codex-tool-output-limit`.
- Main's controller treats an incomplete verdict as malformed and stops, with no Reviewer
  retry: "Reviewer failure: verdict scenarios: missing expected ID
  \"codex-tool-output-limit\"".

Root cause: an output-completeness slip by the Reviewer. The prompt does not ask for a
final completeness check, and the controller has no bounded re-ask. The Candidate itself
was verified and substantively accepted.

Fixes:
1. Contract (this retry). `bounded-review-packet` now also requires `reviewer.md` to end
   with a completeness step: before returning, enumerate every Approved scenario id (from
   the packet's `scenario_ids`) and every open finding id, and confirm each appears
   exactly once. Main's controller reads the Candidate's `reviewer.md` at Review time
   (`render_reviewer_prompt/3`, `File.read!` of the working-tree file), so the retry's
   Reviewer uses it.
2. Reference. The retry's Developer may read the stash as a reviewed reference
   (`git stash show -p` on the stash named above, read-only). The new Candidate is
   verified and reviewed from scratch.
3. Kogen-level follow-up, outside this Intent: one bounded Reviewer re-ask when a
   verdict is schema-valid but misses Approved ids. It goes in ROADMAP ID 9 (failure
   reports).

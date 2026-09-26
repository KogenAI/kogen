READ-ONLY AUDIT. Do not modify, create, move or delete any file anywhere. Do not run git commands that write (no commit, stash, checkout, reset, add). Do not run `make`, `mix test`, `mix kogen.*` or anything that calls an AI provider. Reading files, grep, `git log`/`git show`/`git diff` (read-only) are fine.

You are the adversarial auditor for a Kogen Intent package before its Build. The working directory is a private clone of the Kogen repository at main 2909f557. Kogen is an Elixir tool that shapes "Intents" (contract packages) and then builds them: a Developer agent session writes a Candidate, verification targets run (today through a Stop hook, `.codex/hooks/check.sh` -> `stop_runner.py`), then a fresh Reviewer session accepts or asks for rework, then the controller commits.

Package under audit (already Shaper-approved, now revised minimally by the driver after a preflight):
  .kogen/intents/drafts/fortify-paid-verification/   (INTENT.md, intent.yaml, scenarios.yaml, risks.yaml, questions.md, approval.md, evidence/)
The approved original scenarios before this revision are in .kogen/scenarios.approved-original.yaml (diff them to see the revision).

It builds FOURTH, after three other Intents that are not yet on main:
  #1 bounded-reviewer-evidence: .kogen/intents/drafts/bounded-reviewer-evidence/ (review packet <= 65,536 bytes, record citations as metadata, Codex tool_output_token_limit 4000, live-reviewer-rework fixture moved outside the checkout, superseded-objection rule keyed on "earlier Stop cycle of same attempt failed").
  #2 cross-harness-adversarial-roles: .kogen/intents/drafts/cross-harness-adversarial-roles/ (four routes; default route becomes claude-dominant-adversarial-codex: Claude Shaping+Developer, Codex Reviewer+Expert; Codex compatibility owner loses its scripted stand-in Reviewer, gets a 300 s turn limit and one fresh-fixture retry on timed_out). Its reference Candidate diff is evidence/reference-stash-cross-harness-candidate.diff in that folder.
  #3 shaping-preflight-audit: not shaped yet. It adds deterministic Shaping checks (guarded vs affected paths, feasibility against the controller that will run the Build: catalog byte-freeze, Stop and preflight files; paid-target necessity), an adversarial auditor role on the other harness, and Jev classification of findings.

Hard constraints of the Build (DIRECTION D8/D9):
- The Build runs under MAIN's controller (the code loaded when `mix kogen.build` starts), not the Candidate's. Main byte-freezes priv/kogen/verification_targets.yaml after admission (lib/kogen/build.ex post_developer_inputs_unchanged), requires .codex/hooks/check.sh + verification_policy.py + PreToolUse registration (lib/kogen/verification_policy.ex preflight), settles only from Stop-written v1 state (lib/kogen/build/verification.ex settle), rejects any changed path outside may_change_guarded_paths (lib/kogen/build/guarded_paths.ex), runs `make check` which runs scripts/check/offline.py and scripts/check/rehearsals.exs against the frozen catalog, and validates priv/kogen/test-reliability.yaml source hashes. The Makefile and the catalog must not change. Never raise timeouts; never weaken checks.
- Paid targets: `verified_by` is [check] plus at most one justified paid target per scenario; overall only live-shape-to-build and live-native (ROADMAP row 4). An edited live test must run in the same Intent.

Find, with file:line evidence from this checkout:
1. Infeasible or self-contradicting scenarios, especially contradictions with main's controller as described above, or with #1/#2/#3 designs.
2. A plausible WRONG implementation that would pass every named proof (proof.offline selectors + paid target) but violate the scenario's `then`.
3. Missing guarded paths: a file the work must change that no may_change_guarded_paths glob covers (glob: `*` = one segment, `**` = any).
4. Wrong or nonexistent proof.offline selectors (a selector must exist now, or be listed in the same scenario's affected_paths as a file the Developer creates; note some are created by #1).
5. Anything that would make this Build stop before Review under main's controller (catalog freeze, preflight, Stop v1 path, rehearsal traces, Candidate prompts read by main at Developer launch/resume and Review, main's exact-key Reviewer verdict parser in lib/kogen/build/contract.ex, the test-reliability ledger).
6. Unnecessary paid targets, or a needed paid target missing (e.g. an edited live owner or live support file that is not run).
7. Scope creep beyond ROADMAP row 4 (controller-owned verification, Candidate-bound receipts, failed-only paid reuse, no hardcoded check, in-Intent target additions, controller-run red-on-base proof tests, the Review ledger).
8. Stale or wrong file/line citations.

Output: a numbered list of findings. For each: severity (blocking = the Build would fail or the contract is wrong/unverifiable; advisory = improvement), the scenario id(s), the evidence (file:line), and the minimal fix to the package text. Be concrete and brief. No preamble. If you find nothing in a category, say so in one line.

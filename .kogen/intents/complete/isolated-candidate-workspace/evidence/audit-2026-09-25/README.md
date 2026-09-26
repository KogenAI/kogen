# Shaping audit, 2026-09-25 re-shape

1. Deterministic: `plan/tools/validate.exs` (Intent.read, Contract.load,
   VerificationPlan.build, VerificationPolicy.preflight) passes on the
   clone of main `2909f557` (`validate-output.txt`; targets `check`,
   `live-shape-to-build`). Every `proof.affected_paths` entry is covered by a
   `may_change_guarded_paths` glob. Four offline selectors are new files that the
   Developer creates, and each is listed in its scenario's `affected_paths`. The
   cited source lines were checked against `2909f557`.
2. Adversarial: GPT-6 Sol high (`sol-high-audit.md`) and GPT-6 Astra medium
   (`astra-medium-audit.md`), same read-only prompt (`sol-astra-prompt.md`).
   Jev classified all 22 findings (`jev-findings-*.json`): 17 blocking,
   5 advisory. After the revision, a Sol re-audit (`sol-high-reaudit.md`)
   marked every earlier blocking item FIXED except guard breadth, size and
   Claude sanitization, and raised two new items. Jev classified those seven
   remaining items as advisory (`jev-reaudit-*.json`). Claude sanitization was
   also tightened after the re-audit.
3. Jev per scenario (`jev-scenarios-*`, three rounds): every scenario's
   `wrong_result` is caught (0.87 to 0.94). The paid-target choice matches the
   package exactly: `provider_required` only for `per-build-harness-home` and
   `same-candidate-rework`, and offline for the other eight. The strict
   "every clause observable" Noul stays low for the two long, paid scenarios
   (0.13, 0.20). The weak-clause probe (`jev-weak-clause-*`) pointed at the
   evidence wording for the non-Build launches and the fake-lifecycle
   receipts. Both were rewritten to name the asserting test and the in-process
   receipt.

## Previous findings

- **sol-1 — FIXED.** Draft lifecycle is explicitly documented: `intent.yaml:4,79-100`; `approval.md:24-26`.
- **sol-2 — FIXED.** Route and continuation provenance are recorded: `intent.yaml:24-75`.
- **sol-3 — FIXED.** Hook tampering is split into guarded and unguarded controls: `scenarios.yaml:161-196`.
- **sol-4 — FIXED.** Codex deterministic files are pre-seeded and explicitly allowed: `scenarios.yaml:73-85`.
- **sol-5 — FIXED.** Publication cleanup has `published-retained`, owner retention, and retry semantics: `scenarios.yaml:252-257`.
- **sol-6 — FIXED.** Reachable commits remove without a flag; unreachable commits require `--discard-accepted`: `scenarios.yaml:375-380`.
- **sol-7 — FIXED.** Planned selectors are allowed by `VerificationPlan`, and meaningful per-clause tests are required: `verification_plan.ex:232-245`; `INTENT.md:339-348`.
- **sol-8 — FIXED.** Three-root sentinels and in-process cwd/Git receipts are required: `scenarios.yaml:127-152`.
- **sol-9 — FIXED.** Control/Candidate roots are explicitly required at every boundary: `scenarios.yaml:134-140`; `INTENT.md:112-140`.
- **sol-10 — FIXED.** Contract now states shared Codex credential scope plus per-Build operation state: `INTENT.md:91-94`; `risks.yaml:122-129`.
- **sol-11 — NOT FIXED.** Guards remain broad: `intent.yaml:152-170`.
- **sol-12 — FIXED.** Provider ownership is narrowed to the selected lifecycle facts; unrun targets are explicitly documented: `questions.md:45-53`; `risks.yaml:122-129`.
- **sol-13 — NOT FIXED.** Scope still spans ten scenarios, many new tests, catalog churn, and a paid lifecycle target: `approval.md:20-22`; `INTENT.md:337-361`.

- **astra-1 — FIXED.** Missing selectors are explicitly planned and must contain meaningful mapped tests: `INTENT.md:339-348`; `verification_plan.ex:232-245`.
- **astra-2 — FIXED.** Reliability catalog/remediation files are affected paths and refresh is required: `scenarios.yaml:48-49`; `INTENT.md:356-361`.
- **astra-3 — FIXED.** Real cwd/Git-root receipts and control/Candidate/third-root sentinels are required: `scenarios.yaml:127-152`.
- **astra-4 — NOT FIXED.** Claude sanitization still removes only `ANTHROPIC_`/`CLAUDE_CODE_` prefixes and two names; it does not remove `OPENAI_*` or secure-storage explicitly: `claude_code.ex:21-25,79-95`; scenario wording: `scenarios.yaml:54-70`.
- **astra-5 — FIXED.** Shared `CODEX_HOME` and per-Build operation root are explicitly scoped: `INTENT.md:91-94`.
- **astra-6 — NOT FIXED.** Controller/build/support globs remain writable: `intent.yaml:155-170`.
- **astra-7 — FIXED.** Paid ownership and offline ownership are now stated separately, with Reviewer/Candidate observations: `questions.md:45-53`; `scenarios.yaml:210-237`.
- **astra-8 — FIXED.** Extra commands/publication machinery are tied to explicit scenarios and acceptance checks: `INTENT.md:207-222`; `scenarios.yaml:240-396`.
- **astra-9 — NOT FIXED.** One-Build reliability remains poor: broad scenario/test surface plus catalog and live-provider work: `approval.md:20-22`; `INTENT.md:337-361`.

## New blocking issues

- **Self-hosting bootstrap circularity.** The contract requires admission to create the Candidate before provider launch (`INTENT.md:53-80`), but then-main `Build.run` goes directly into the existing control-side build loop with no workspace admission (`lib/kogen/build.ex:50-64,202-210`). Candidate edits cannot change the controller that must create the first Candidate.
- **Paid-target prerequisite mismatch.** The package claims the cross-harness prerequisite/default Codex Reviewer (`references.yaml:5`; `INTENT.md:9-11,399-407`), but the checked-out head still has that Intent reopened as Draft (`.kogen/intents/drafts/cross-harness-adversarial-roles/INTENT.md:3`), `default_route: claude` with a Claude Reviewer (`.kogen/config.yaml:1-7`), and the paid fixture copies that config unchanged (`test/kogen/live_shape_to_build_test.exs:623-637`). The selected paid target therefore cannot observe the claimed Codex Reviewer path at this baseline.

**Verdict: NOT BUILD-READY.**
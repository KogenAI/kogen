Read-only: do not modify any file. Do not run make, mix test, mix compile, or any build or provider. You may read files and run grep, git log, git show.

Adversarial pre-approval review of one whole Kogen Draft Intent. Repository: /Users/almirsarajcic/Areas/Kogen/kogen at main 7ed41f660f379a092437464b84d5eac2392073a8. Draft package: .kogen/intents/drafts/build-reliability/ (intent.yaml, INTENT.md, scenarios.yaml with 28 scenarios, risks.yaml, questions.md, references.yaml, evidence/ including evidence/PROBES.md and evidence/probe-rigidity/REPORT.md). Repository rules for Intents: README.md sections "Verification target selection", "Choosing verification targets", "Self-hosting changes: expand and contract", and priv/kogen/verification_targets.yaml.

Context: the Build will run under main 7ed41f66's controller (loaded code) on route claude-dominant-adversarial-codex. That controller reads the Candidate's catalog, Makefile and prompts, calls VerificationPlan.load on the Candidate every cycle, and runs the Candidate's own `make check`. One Developer conversation with outer_resumptions: 2 and verification_retries: 2 must finish it.

The product owner's principle for this Intent: "it needs to be flexible enough that it can be changed on the fly, that the builds pass, but we have to make the builds also follow certain rules so that the code quality is great at the end". The last five scenarios (test-catalog-binds-declarations, config-checked-by-reader, docs-and-prompts-checked-by-meaning, hooks-checked-by-behavior, helper-make-targets-allowed) were just added under it.

Find defects that would make a Build of this Draft fail, stall, or be accepted wrongly, and places where the Draft violates that principle (a relaxation that loses real protection, or a remaining rigid rule the Draft itself will trip). Check in particular:
1. Self-hosting: does any scenario need main's controller to understand something new, or will the Candidate trip one of main's rules (e.g. Makefile/catalog equality, frozen config files, guarded paths, the test-reliability catalog in the Candidate's own check)?
2. Guarded paths: every edit a scenario implies is covered by intent.yaml may_change_guarded_paths; no edit to the owner of an unselected live target.
3. Contradictions between scenarios, risks, INTENT.md and questions.md.
4. proof: verified_by targets and order, proof.base claims (can each `base: fail` selector really fail on base?), paid-target justification.
5. Verify the factual claims in evidence/probe-rigidity/REPORT.md against source bytes (e.g. the 7 stale catalog rows, the unused discover/1, read_config ignoring unknown keys, the verification_plan.ex locators).
6. Appetite: is 28 scenarios buildable in one Developer conversation? Name the scenarios whose cost or risk is out of proportion, if any.

Answer in at most 800 words. Blocking items first, each with scenario/risk id, the concrete failure, file:line evidence at 7ed41f66, and the minimal contract fix. Then non-blocking items briefly. Say "none" for a category with nothing.

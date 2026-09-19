# External architecture audit request

You are an external read-only architecture auditor. Do not edit any file and do not approve this Intent. Work from repository root `/Users/almirsarajcic/Areas/Kogen/kogen` at shaped-against commit `05133eff307ece43794d2cfc02e227ee119970eb`.

Read the complete Draft directory `.kogen/intents/drafts/rehearsed-verification-plan/`, including all YAML, `INTENT.md`, `target-catalog.md`, `questions.md`, references, and evidence. Then inspect the cited current source rather than trusting Draft summaries:

- `Makefile`, `README.md`, `scripts/check/README.md`, and all maintained consumers found by searching `live`;
- `lib/kogen/build.ex`, `lib/kogen/build/contract.ex`, `lib/kogen/build/verification.ex`, `lib/kogen/build/tracking.ex`, `lib/kogen/check.ex`, `lib/kogen/git.ex`, and `lib/kogen/verification_policy.ex`;
- `.codex/hooks.json`, `.codex/hooks/verification_policy.py`, and `.codex/hooks/stop_runner.py` read-only;
- `priv/kogen/prompts/shaping.md`, `priv/kogen/prompts/developer.md`, `lib/mix/tasks/kogen.shape.ex`;
- target-owner live tests, `test/kogen/selective_verification_targets_test.exs`, Shape/prompt/schema/quality fixtures, verification ownership/lifecycle tests, compatibility preparation, receipt audit, scenario tracking, and Git integrity tests;
- `.kogen/runtime/shaping-followups/SHAPE_REHEARSED_VERIFICATION_PLAN.md`, `ROADMAP.md`, `EVIDENCE.md`, and `.kogen/runtime/scenario-tracking/zK-lmvM1EEuwjp2XPOSJJBGB/record.json` where needed for historical claims.

Assess whether the Draft is one coherent Build, source-grounded, internally consistent, and falsifiable. Especially find:

1. a hidden aggregate target or a maintained consumer still using retired `live`;
2. Shaping unable to produce or validate required `proof.offline`, `proof.paid_target`, and `proof.paid_reason`;
3. Candidate-controlled readiness enforcement or wording that overclaims mechanical blocking;
4. whole-repository formatting escaping `may_change_guarded_paths`, including create/delete/rename/symlink/mode/helper/ignored tracked changes;
5. a fake rehearsal bypassing production preparation, schema, consumer, audit, or settlement code;
6. readiness observations gaining gate/receipt/Review authority;
7. deterministic triage gaining retry/pass/skip/budget authority;
8. missing affected assertion/fixture guarded paths;
9. an expensive target selected without unique evidence;
10. scope that cannot realistically fit one Build;
11. a plausible implementation that passes the stated controls while failing the outcome.

Return a complete audit with severity-labelled findings (`blocker`, `major`, `minor`), exact Draft and source locators, concrete consequence, and minimal repair. Explicitly distinguish current-source facts, Draft requirements, historical evidence, and inference. End with an approval-readiness verdict, but remember that only the human Shaper can approve.

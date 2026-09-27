# Open Review findings after Build e3LWwqRPuhpvw2izEfdaeq6R (last attempt, verdict rework)

1. The real resumed Developer prompt can omit the derived cycle signature's first_failure, error_head, and reproduce values because the derived signature is not passed into the rendered cycle. Thread the derived signature into the prompt input (or render it directly) before resuming the Developer. (scenarios: rework-prompt-inlines-first-failure)
   - lib/kogen/build.ex: resume_after_failed_cycle/6 derives and records the signature, but passes the original cycle to verification_failure_prompt/3 without attaching that signature.
   - lib/kogen/build/failure_handoff.ex: FailureHandoff.render/1 reads only cycle["signature"] or cycle["failure_signature"], then falls back to the raw failure map whose first_failure and error_head fields are absent.
- F5 (open): Open. The committed login fixtures still do not satisfy the approved real and synthetic excerpt provenance/content contract.
   - .kogen/intents/approved/failure-reports/INTENT.md: The approved fixture contract requires the XfjCRM76 source hash ff6224dc... and the hJeqtBSgm synthetic source stream/hash 6127a090....
   - test/support/provider_tails/xfjcrm76_claude_oauth_revoked.json: The Claude fixture has sha256 328cb376... and the synthetic Codex fixture uses fixture-synthetic_codex_refresh_failed with sha256 45e3d288..., so neither matches the approved provenance.
- F6 (open): Open. Required scenario-level offline evidence remains absent, including the stop matrix, login paths, saved resume prompt/frame checks, candidates listing checks, and complete report/category documentation.
   - test/kogen/failure_report_test.exs: The added test file contains only four unit-level tests and no required fixture Build stop matrix, Build-path login replay, resumed prompt/frame assertions, or full report field checks.
   - test/support/fake_claude: The fake Claude executable has no FAKE_CLAUDE_FAIL_TAIL branch required for the Developer login replay.
   - .kogen/intents/approved/failure-reports/INTENT.md: The candidates test file has no report-bearing/report-absent listing assertions, while the approved test section requires them and the full report/category documentation.

- every-stop-writes-a-report: needs_rework — Needs rework. Core report paths and final-record handling were inspected, but the approved contract's fixture Build stop matrix and exhaustive field assertions are missing, leaving the required stop coverage unverified.
- login-rejected-is-environment: needs_rework — Needs rework. Marker routing is present, but the required exact excerpts are invalid and scenario-level login replay coverage is absent.
- rework-prompt-inlines-first-failure: needs_rework — Needs rework. The persisted signature can reach the report, but the real resumed prompt can still render blank first-failure fields, and the required prompt/frame integration tests are absent.
- candidates-show-the-report: needs_rework — Needs rework. The listing branch is present, but the contract-required report-bearing and report-absent command tests are missing.
- existing-expectations-kept: satisfied — Satisfied. The existing expectation files and pre-admission tests remain present, and the controller's declared check receipt passed for this Candidate.

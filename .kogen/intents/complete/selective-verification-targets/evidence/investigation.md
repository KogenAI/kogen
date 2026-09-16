# Shaping investigation

Observed against `main` at `1ee89d659ae35303c500eb7e277cc5e1b4cc24f9` on 2026-09-16. No provider-backed command or gate was run during Shaping.

## Current target and validation facts

- `Makefile` declares only `check` and `live`. `check` invokes `scripts/check/offline.py`; `live` invokes `mix test --only live`.
- `lib/kogen/build/contract.ex` extracts unique scenario targets and calls `Kogen.Check.validate_targets/2` while loading the Approved contract.
- `lib/kogen/check.ex` accepts safe target tokens only when the current Makefile declares them, before Developer launch. This establishes the bootstrap limitation recorded in the Intent.
- `lib/kogen/build/verification.ex`, `lib/kogen/build.ex`, and `.codex/hooks/stop_runner.py` retain ordered Stop execution, configured verification retries, Candidate/session/attempt/cycle binding, target evidence capture, settlement, and the verification-before-Review boundary.

## Current owner inventory

- `test/kogen/live_shape_to_build_test.exs`: connected public Shape-to-Build lifecycle plus separate Build-only Reviewer-rework owner; real managed provider, Git fixtures, Stop history, resume, raw/native receipts, cleanup and independent Review.
- `test/kogen/live_test.exs`: real semantic Reviewer rejection/acceptance route for configured root profiles.
- `test/kogen/live_shaping_evaluation_test.exs`: paid seven-case Shaping evaluation and one required-evidence manifest. `test/kogen/shaping_evaluation_test.exs` and support controls own its offline rehearsal.
- `test/kogen/native_helper_live_test.exs`: real native helper routing and receipt proof; offline fixture/receipt corruption controls are separate non-live tests.
- `test/kogen/codex_native_live_test.exs` and the live case in `test/kogen/codex_compatibility_test.exs`: managed distribution/login behavior and authenticated compatibility runner.
- `test/kogen/cold_offline_test.exs`: copies source/dependencies into a private fixture, begins with an absent build cache, runs `make check` with `HEX_OFFLINE=1`, clears harness/raw-log variables, and asserts the provider-denial shim was not invoked.

The current broad suite has nine live cases. The latest recovery record reports three consecutive cycles where `check` passed and `live` failed. Cycle 1 included a connected lifecycle profile-audit failure while other expensive owners ran; later cycles failed different owners. This supports target isolation but does not waive, repair, or classify any failure as flaky.

## Scope challenge

The requested slice remains one Build if it changes only Make entry points, deterministic ownership/selection tests, and maintained verification documentation. It does not need a new selection engine: Shaping records existing Make target names in `verified_by`, and Build already validates and orders them. Adding harness adapters, automatic dependency analysis, recovery, logging, write guards, cancellation, or a target matrix would exceed this appetite and is explicitly excluded.

No experiment was needed: the consequential uncertainty was resolved directly from maintained source and the retained source-bound failure record. Paid execution would not answer the bootstrap or ownership questions and was deliberately not performed.

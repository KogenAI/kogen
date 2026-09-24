# Failed Build handoff

The first Build attempt stopped before paid verification. The complete local
record is:

`.kogen/runtime/scenario-tracking/a2sPFUvFlBoNtimOp1psV5Ui/record.json`

Status: `failed`; Stop exhausted all three offline `make check` retries. No
scenario was satisfied and no Reviewer acceptance occurred.

## Failure 1: stale source bindings

`Kogen.TestReliabilityCatalogTest` and
`Kogen.WholeSuiteRemediationTest` rejected source bindings as stale after the
Developer changed catalog-bound files. The affected declarations include:

- `test/kogen/codex_management_test.exs`
- `test/kogen/codex_native_live_test.exs`
- `test/kogen/execution_policy_test.exs`
- `test/kogen/native_helper_fixture_test.exs`
- `test/support/codex_installer_test.py`
- `test/support/managed_codex_fixture.py`
- `test/support/route_config.ex`

Next Shaping must inspect the maintained reliability catalog contract and either
include the required catalog/source-binding updates in guarded scope or narrow
the implementation change so those bindings remain valid.

## Failure 2: default-route contradiction

The checkout had `default_route: codex` from the temporary operational commit,
while existing offline tests still assert Claude as the repository default. The
failed `make check` output included failures in:

- `test/kogen/intent_test.exs`
- `test/kogen/claude_code_catalog_test.exs`
- Claude Code management tests
- Codex public login tests whose route precondition changed

Next Shaping must explicitly decide whether the temporary Codex default is
outside this Intent and must be reverted before Build, or whether changing the
default is now part of scope and all affected tests/contracts must be updated.
Do not silently choose between those alternatives.

## Failure 3: Developer patch retries

Several `apply_patch` attempts used stale README/test context after earlier
edits had already landed. These warnings were not themselves the Stop failure,
but the next Developer should inspect current bytes before retrying patches.

## Retained evidence

The Candidate changes remain available in the stopped Build's retained local
state and the tracking record. The failure is not evidence that the native
0.156.1 runtime or GPT-6 provider route is incompatible; paid verification was
never reached.

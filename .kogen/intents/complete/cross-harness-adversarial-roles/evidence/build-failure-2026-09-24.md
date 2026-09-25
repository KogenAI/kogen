# Build failure retained

Build attempt records:

- `.kogen/runtime/scenario-tracking/zYsany_w3pb12P8bmVx-ZRc1/record.json`
- `.kogen/runtime/scenario-tracking/K9Fu72yGSh3w5Yu5h-zsslZ_/record.json`

The offline `check` reached 747 of 749 tests and failed in
`test/kogen/whole_suite_remediation_test.exs` and
`test/kogen/test_reliability_catalog_test.exs` because
`priv/kogen/test-reliability.yaml` still contained hashes for the pre-Build test
sources. The Developer correctly refused to run the supported refresh because
that ledger was outside the approved guarded paths. This revision adds the
ledger path; it does not claim the failed Build as verification.

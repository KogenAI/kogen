# Current amendment evidence

Start with [amendment evidence](amendment-evidence.md) and [the amended contract](../amendment.md). Earlier entries below describe original shaping and remain historical.

# Shaping evidence

- [Initial investigation](investigation.md) records the original baseline and then-missing 06 dependency.
- [Scope comparison](scope-comparison.md) is historical investigation of combining 06/08, resolved by the accepted 06 commit.
- [Current reassessment](reassessment.md) records the accepted interface, current probe, scope and limitations.
- [Fixture source audit](fixture-source-audit.json) binds self-contained compact fixtures to the prior protocol. The [correction](../fixtures/CORRECTION.md) explains why unchanged reader controls and corrected adapter controls are separate receipts.
- [Aggregation probe source](aggregation_probe_test.exs) and [consumer receipt](aggregation-output/consumer-receipt.json) prove the specific five-producer-to-one-manifest composition, not model behavior.

Prototype sources remain local shaping evidence; Developer-owned reusable implementation
and refresh instructions belong under test/support/shaping_evaluation. No production
feature was implemented here. Full live evaluation remains an outer-Build-owned step.

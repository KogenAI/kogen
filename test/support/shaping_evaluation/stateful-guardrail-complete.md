# Stateful verification guardrail (complete proposal)

Shape a bounded verification guardrail with two repair attempts: the first two
failed callbacks may repair, the third failed callback becomes terminal, and
all later callbacks are rejected before dispatch. Preserve the
existing callback and receipt contract, save a reviewable Draft, and stop
without approval.

The supplied source initializes state explicitly, rejects damaged or exhausted
state before dispatch, permits a failed-then-passed repair, and emits a
parseable `finished_at` timestamp. Use the supplied zero-dispatch, valid-repair
and timestamp-consumer controls. These source-bound controls prove fixture
behavior only; they do not prove provider access or later application
correctness. Do not change the supplied source or add scope decisions.

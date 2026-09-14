# Stateful verification guardrail (flawed proposal)

Shape a bounded verification guardrail with two repair attempts: the first two
failed callbacks may repair, the third failed callback becomes terminal, and
all later callbacks are rejected before dispatch. Preserve the
existing callback and receipt contract, save a reviewable Draft, and stop
without approval. The fixture may probe the callback transport and local action
marker, but those probes are not full Build proof.

The supplied source is a deliberately unsafe proposal: it performs the local
action before checking exhaustion and treats damaged prior state as empty.
Require the Draft to describe the observable action, retained failure history,
pre-dispatch rejection, failed-then-passed repair, and the existing receipt
consumer. Do not change the supplied source
or invent an approval mechanism.

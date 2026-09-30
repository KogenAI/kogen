# Native team qualification

Managed Claude Code 2.1.284 was staged from the official npm artifact with installer SHA512 verification, without changing the active runtime default. This standalone managed-harness probe used normal project hooks and VerificationPolicy.environment(["check"], root).

Opus Medium session: `e4d2350e-60b2-49a7-814f-b14d902a7dc4`. Actual root model: claude-opus-5-5. Two distinct kogen-worker tool-use identities each emitted claude-sonnet-5-5 model receipts. Configured worker effort: medium. Worker assertion commands returned A OK and B OK; root reran all four assertions and returned BOTH OK. No permission denials.

Sonnet Low independent probe session: `cc044393-063e-4031-9df4-4c173620461e`. Actual model receipt: claude-sonnet-5-5. Structured response: `{"ok":true}`.

Limit: model execution and helper test completion are proven; this does not prove final optimum route wiring, per-helper effort transcript linkage, built-in Agent denial, exact resume, Stop continuation, or connected live-reviewer-rework/live-shape-to-build. Those still require their owned checks. Initial probe failed because its setup omitted verification-policy targets; that failed result is retained separately and is not acceptance.

Retained local source receipts (outside publication package):
- `/Users/almirsarajcic/Areas/Kogen/operations/reviews/strategic-reshape/native-team-policy/opus-sonnet-workers.json` — SHA256 `33b42bcb22c710f8f72a54a340d71b15ae48eedd6ee2b8b50da836ab8f064c83`
- `/Users/almirsarajcic/Areas/Kogen/operations/reviews/strategic-reshape/native-team-policy/sonnet-low.json` — SHA256 `0df4f4675536c9bd9ab738547d2fc88ed5b0d5f5ca524c9d15b32ab2a2374653`

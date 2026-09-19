# External Opus audit — complete finding record

Invocation and input are retained beside this file. Opus reported the worktree clean at the shaped head and made no edits.

## Confirmed strengths

The existing Stop context accepts extra fields and preserves supplied order; the old contract tolerates the Draft's additive `proof`; Candidate identity uses a private index and rejects index-blinding flags; the historical three-cycle failure account matches the retained record; receipt and triage non-authority is clear; no Draft scenario selects paid verification.

## Blockers

1. `.codex/hooks/verification_policy.py:173` requires `check` and `live`, conflicting with hook immutability plus target retirement. Repair: retain `live` only as a reserved policy token, not a Make target, and test the real hook.
2. `workflows/codex-runtime-upgrade.md:3,9` is an omitted maintained `live` consumer outside guarded paths. Repair: guard and migrate it; classify Shaping fixture and historical evidence references.

## Major findings

1. Supplying only selected targets to policy would unblock unselected paid targets. Supply every catalog target plus the reserved token.
2. Current in-turn Stop retries cannot receive controller-derived signatures; exhaustion stops. Limit delivery to tracking, terminal reasons, and existing outer-rework feedback.
3. Controller cannot independently observe Developer commands, so per-command readiness binding is false. Defer special observation retention.
4. Guarded paths omit plan/catalog/signature modules and workflow consumers. Name them explicitly.
5. Catalog ownership and synthetic fixture behavior are ambiguous. Use a tracked project-root catalog frozen at admission and migrate fixture catalogs/proof maps.
6. Proof semantics are underspecified: existence, line drift, broadness, causal validation, `verified_by` consistency, and cold-offline. Define mechanical shape separately from human causal judgment and add explicit affected paths.
7. Affected owner paths cannot be inferred safely. Require Shaper-authored paths and never auto-grant them.
8. Installation/bootstrap and split-file isolation are missing: new targets do not exist at starting HEAD, the reviewer-rework module depends on co-located helpers, scheduling tests assume one file, and real Shaping adherence is not proven. Use check-only bootstrap, provider-denied isolated file loading, extracted support, and honest no-live semantic claim.
9. Scope is large and guarded enforcement departed from the original brief. Record current Shaper direction; Opus recommended splitting, but the Shaper explicitly required cohesive repair.
10. Git-local config/ignore can hide changes. Use hardened private-tree comparison plus frozen config/ignore and ignored-path manifests.

## Minor findings

Serialize format check before compile; avoid saying Candidate code never affects current hook admission; define changed-file Credo derivation; use Python `-B`; clarify rehearsal owner means target and include XDG null/empty; prove shared-entry reuse with runtime traces; specify guarded-path/exhaustion precedence; return legacy Approved packages to Shaping; retain audit/reconciliation; acknowledge lost overlap across split targets.

Verdict was **not ready for approval** pending these repairs and one focused re-audit.

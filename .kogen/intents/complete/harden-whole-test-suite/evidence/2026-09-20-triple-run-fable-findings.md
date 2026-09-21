# Triple-run audit and Fable reconciliation

## Execution

- The manifest contained 69 maintained test files, each assigned one exact command and three attempts under deliberate 69-way contention.
- Odd ordinals used Claude Sonnet low; even ordinals used Codex Luna low with sandbox and approvals bypassed.
- Raw shaping logs: `/tmp/kogen-69-agent-audit.9QsflC/`.
- Four Fable-medium source investigations: `/tmp/kogen-fable-repair-audit.NAczzs/`.
- Native-scout probes with isolated `MIX_BUILD_PATH` were invalid because dependencies were unavailable; their setup failures are not test evidence.

## Supported findings

1. Foreign audit `codex exec` workers created `plugins/` residue in Kogen's managed scope. Several live files therefore failed before exercising their intended provider behavior. Preserve fail-closed validation, add actionable recovery and prevent foreign CLI mutation; do not replace real live credentials with fakes.
2. Untagged isolated tests can have a 60-second ExUnit parent around a 120-second child plus cleanup, losing the harness result and output.
3. Readiness controls charge VM launch/compile latency against behavior-specific deadlines; one role control can pass while losing an expected launch.
4. The cancellation control can pass after the child crashes because its readiness variable is absent.
5. `unified_state_admission_test.exs` omits `environment.py` from the hook fixture under the managed restore marker.
6. `live_reviewer_rework_test.exs` writes a scenario without the required `proof` map and lacks a provider-denied contract/plan preflight.
7. Cold-offline can leave an orphaned gate, clean its fixture while it runs, omit a stage after a broken output pipe, and settle a misleading passed receipt.
8. Ordinal 57 incorrectly used `--only live` because source literals resembled a module tag; it ran zero tests. The manifest now uses plain `mix test`.
9. Shape-task and shaping-evaluation tests repeatedly boot VMs/parsers within one test, letting the parent timeout before receiving a classified child result.
10. Shared `_build` locking inflated wall times but did not itself change most outcomes. Stable files need no speculative repair solely due to duration variance.

## Evidence limit and required confirmation

The 69-way run is a stress probe, not final sequential proof. Deterministic defects need no pre-repair rerun. Contention-triggered defects require focused controls. After repair and explicit managed-scope prerequisite validation, every manifest command must pass three consecutive times against one immutable Candidate as specified by the Intent.

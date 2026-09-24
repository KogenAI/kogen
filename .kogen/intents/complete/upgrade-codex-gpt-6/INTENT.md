# Upgrade managed Codex runtime and GPT-6 route

Draft Intent `upgrade-codex-gpt-6` upgrades Kogen's pinned managed Codex
runtime from `0.154.0` to the exact official `0.156.1` release and migrates
the Codex route to GPT-6 Sol/Luna. Existing route/default selection is not
part of this Intent; the Claude route remains available as configured.

The tracked `default_route` remains `claude`. Codex work uses the named
`codex` route explicitly; changing the repository default harness is a
non-goal. Any stopped-Build working-tree edits that temporarily set
`default_route: codex` must be removed before Build begins.

Because the reliability catalog binds declarations to exact source bytes, the
Build may update the maintained catalog and remediation file for changed
catalog-covered tests. Those updates are bookkeeping for the candidate's
evidence contract, not additional product scope.

## Proposed Codex profiles

- Shaping: `gpt-6-sol`, medium
- Developer: `gpt-6-sol`, medium
- Reviewer: `gpt-6-sol`, high
- Scout helper: `gpt-6-luna`, low
- Worker helper: `gpt-6-luna`, high
- Expert helper: `gpt-6-sol`, high

## Required scenarios

### managed-runtime

Given a clean checkout has no usable managed Codex runtime for the pinned
release on supported macOS arm64 or x64, when the managed install flow runs,
Kogen stages, verifies, and atomically activates exact official Codex `0.156.1`
artifacts while preserving integrity, retry, and existing-runtime protections.

Wrong result: resolving an unpinned/latest-at-build artifact, accepting a
mismatched or unverifiable archive, overwriting a working runtime, or
activating another version.

Proof: offline installer tests plus `make live-native`; the paid observation is
that Codex `0.156.1` starts and completes native compatibility under the
selected Kogen scope.

### gpt6-codex-route

Given the selected route is Codex, when Kogen resolves and launches work, it
uses the exact approved matrix: Sol medium for Shaping and Developer, Sol high
for Reviewer and Expert, Luna low for Scout, and Luna high for Worker. Runtime,
route, and session identity remain stable across compatibility and resume.

Wrong result: GPT-5.6 or Terra fallback, any different model/effort, or stale
runtime/session selection.

Proof: offline configuration, launch, and environment tests plus
`make live-native`; the paid observation is successful native execution across
all configured roles and helpers.

### existing-runtime-upgrade

Given a working managed Codex `0.154.0` runtime is installed, selected, and an
operation may already be active, when Kogen stages and activates `0.156.1`,
activation is atomic, active operations retain their concrete `0.154.0`
runtime, and failed staging preserves the working runtime and credentials.

Wrong result: overwriting or invalidating the active runtime, switching an
in-flight operation unexpectedly, deleting credentials, or selecting a partial
failed installation.

Proof: offline management/installer tests plus `make live-native`; the paid
observation is native runtime and active-use compatibility without disturbing
retained state.

The full machine-readable contract, proof maps, and affected paths remain in
`scenarios.yaml`; `risks.yaml` records native compatibility and probe
termination risks.

## Verification

- `make check`
- `make live-native`

Prior approval and stopped-Build history are retained in `approval.md`,
`failures.md`, and `intent.yaml`; this continuation remains unapproved until a
new explicit approval in the current conversation.

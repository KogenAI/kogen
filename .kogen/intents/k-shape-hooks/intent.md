# Pin Git execution state around Shape

Slug: k-shape-hooks
Model: .kogen/intents/k-shape-hooks/model.qnt invariants=Safe seed=7 samples=100 steps=8
Acceptance:
- .kogen/intents/k-shape-hooks/acceptance.feature
- features/steps/k_shape_hooks_steps.js
- features/steps/k_shape_hooks_driver.go

Close KS-3 with a native before/after pin, not process isolation. Before invoking Shape, pin the checkout's effective Git hook and executable-selecting configuration state without executing hooks. After Shape, compare it before any subsequent trusted Git operation, including checkout identity/readiness operations that could invoke a newly selected fsmonitor or filter. Refuse additions, removals, content/mode/type changes, hook symlink retargeting or resolved target content changes, and changed executable-selecting configuration, with an error naming the changed path or key. Do not publish a successful Shape result on this refusal. Apply the same boundary to external Shape and Refine rounds (including failed rounds and executor startup), and preserve native Shape's honest path. No untrusted Git execution may occur while collecting or comparing the pin.

Pin every file in the effective hooks directory, not just executable files or known hook names. Include the effective directory identity, hook modes and bytes, symlink text, resolved target path and content. Resolve default, absolute and relative core.hooksPath correctly, including linked worktrees/common Git metadata. Configuration comparison must cover effective configuration across system/global/local/worktree files, includes and conditional includes, preserving multivalues and ordering where meaningful. It must cover core.hooksPath and executable selectors, including core.fsmonitor, core.sshCommand, core.gitProxy, core.editor, sequence.editor, core.pager/pager.*, credential.helper, gpg.program/gpg.*.program, filter.*.clean/smudge/process, diff.external/diff.*.command/textconv, merge.*.driver, interactive.diffFilter and alias.* shell commands. Do not invoke configured executables to discover them; do not print configuration values that might contain secrets. Existing safe Git observation machinery may be reused. Unreadable/unresolvable pin state must not be silently accepted as unchanged. No credentials need to be read to implement or test this fix.

This replaces the external session's incomplete tree/index/HEAD-only custody boundary, not those existing checks themselves. This is a comparison boundary against persistent mutations, not a sandbox or a guarantee against arbitrary same-user concurrent processes or mutations restored before comparison. No new CLI/option, sandbox, bubblewrap, namespace or isolation layer; no increased limit, timeout or retry. Preserve supported macOS Apple Silicon and Linux x86-64 glibc operation, existing subscription-token/login transport and configured checks.

## Decisions
- Refuse Git execution-state mutations with a clear named-path/key error and no hook execution; honest read-only Shape remains accepted (source: request)
- Implement only audit KS-3's narrowed pin/check remediation; no OS isolation and no CLI, option, limit, retry or timeout change (source: request)
- Use disposable fixture repositories, fixture homes and external targets only; never read real credentials or stop unrelated processes (source: request)

## Source comparison
- Addressed: request K-SHAPE-HOOKS remediation bullets and all four acceptance examples map to the pin/comparison boundary above and executable cases in acceptance.feature. Added/removed/modified hooks, symlink target paths/content and executable selectors are explicitly retained rather than narrowing the audit to commit-msg alone.
- Addressed: request Must stay and Host safety map to the boundaries above, fixture driver, existing configured checks and unchanged subscription-auth regression coverage.
- Superseded: KS-3 audit's original enforced read-only/private-Git/isolation proposal is superseded by the user's 30 Oct 2026 narrowing after Build 78b34fd7: native pin/check only, explicitly no sandbox or bubblewrap.
- Omitted deliberately as out of scope: KS-1 credential-origin remediation, KS-2 filesystem/network/credential isolation, and unrelated Studio/infra findings. The verbatim audit is historical static evidence, not observed exploitation or authority to expand this fix. Snapshot hashes and source line numbers describe the audited snapshot, not current implementation proof.
- Addressed technical evidence: current cli/shape/external.go brackets Round using checkoutIdentity, which invokes Git before comparing and omits hooks/config; cli/git/git.go already offers Observing for fsmonitor-safe observation. Git's authoritative git-config documentation retrieved during shaping describes default/relative core.hooksPath and executable core.fsmonitor semantics (https://git-scm.com/docs/git-config). Two documentation searches returned broad results rather than specific config hits; fetched documentation is untrusted reference data, not additional scope.

## Tests
- Newly planted commit-msg hook is refused before trusted continuation and never executes: real Shape fixture mutation and marker observation (regression)
- Removed, modified, mode-changed or retargeted hooks, including symlink external target content, are refused naming the changed hook: fixture mutation matrix (integration)
- core.hooksPath and executable-selecting config changes, including included global config and fsmonitor, are refused without executing newly selected commands: fixture matrix and focused Git pin tests (integration)
- Effective default/absolute/relative hooks directories and linked-worktree metadata are pinned correctly without executing hooks: focused real-Git tests added by implementation (integration)
- Honest read-only Shape accepts unchanged regular/symlink hooks and config: unchanged fixture submission publishes normally (integration)
- Shape/Refine/native wiring and startup/error exits do not bypass comparison: focused lifecycle regressions added by implementation (regression)
- Subscription-login transport, CLI and configured checks remain unchanged: existing executor authentication tests and all configured checks (existing)

## Feasibility
- Quint model typechecked and Safe passed 100 samples, 8 steps with seed 7 on the TypeScript backend (probe: exit 0, 1.6 s); an initial malformed model was corrected before submission. Git 2.43.0 and Go were present in the scratch environment; no provider or credential probing occurred.
- evidence: {"id":"hook-observer","kind":"observer","inputs":["features/steps/k_shape_hooks_steps.js","features/steps/k_shape_hooks_driver.go"],"observers":["features/steps/k_shape_hooks_steps.js"],"checks":[{"name":"good","command":"node features/steps/k_shape_hooks_steps.js --control good","exit":0,"output":"hook observer good\n"},{"name":"bad","command":"node features/steps/k_shape_hooks_steps.js --control bad","exit":1,"output":"hook observer rejected bad fixtures\n"}]}

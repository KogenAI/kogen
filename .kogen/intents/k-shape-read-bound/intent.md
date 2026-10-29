# Strip caller secrets from Shape probes

Slug: k-shape-read-bound
Model: not applicable — environment selection and disposable home wiring have no meaningful product state machine
Acceptance:
- .kogen/intents/k-shape-read-bound/acceptance.feature
- features/steps/k_namedfeedback_steps.js

Replace probe execution on the caller Session with a probe-specific `sys.NewWith(env, root)` session in Kogen-owned code, primarily `cli/verify/probe.go`. All native Shape probe routes must use this boundary, including ordinary Shape, Refine and declared evidence checks. No CLI changes or new options. Do not edit `cli/third_party/kogen-loop/**` or `cli/loop-pin.json`.

Construct an allowlisted environment from the supplied Session, not the ambient process environment. Retain PATH and locale (LANG, LANGUAGE, LC_ALL and LC_*); set HOME to a fresh private disposable fixture-free home outside the copied checkout. Permit only explicit toolchain location variables GOROOT, GOPATH, GOTOOLDIR, MISE_DATA_DIR, MISE_CONFIG_DIR, MISE_CACHE_DIR, ASDF_DIR and ASDF_DATA_DIR when needed for installed tools. Pass KOGEN_NODE, KOGEN_QUINT and KOGEN_CUCUMBER only from Probe.Tools. Do not copy arbitrary caller variables, provider credentials, token variables, credential-store selectors, shell startup selectors or tool execution flags such as NODE_OPTIONS, ENV or BASH_ENV. This is an allowlist, not a blacklist of known providers. HOME must not link to or copy the caller home or its `.kogen/credentials`. Remove the private home on every return, including errors and cancellation. Preserve scratch overlays, warm checkout copies, tool execution, result format/status, time limits, foreign-process protection and cancellation; ensure probe process observation still reports the actual launched group after session separation. Do not change the caller Session environment or ordinary non-probe commands.

## Decisions
- Ordinary probes remain available without a new CLI option. (source: request)
- This fixes the Kogen-owned environment and HOME exposure only; source-read containment belongs to L-READ-CONTAIN and re-pin, not this Intent. (source: request)
- Shared-host tests use temporary fixture homes and synthetic credential files only; never read real credentials, stop unrelated processes or create synthetic CPU load. (source: request)

## Source comparison
- Addressed: request What to change and Acceptance; the environment/HOME boundary above and both executable scenarios cover fixture caller credentials, credential-store paths, HOME listing and ordinary probes.
- Addressed: Must stay and Host safety; no CLI change, preservation requirements above, configured checks unchanged, fixture-only local regression tests.
- Addressed: explicit `sys.NewWith(env, root)` instruction; existing vendored API supplies it, so no protected loop edits or pin changes are needed.
- Superseded: current `TestProbeFilesStayInTheScratchCopyAndThePrepareStep` expects KOGEN_FROM_CALLER=yes in probe output. Update that expectation to absence while retaining overlay/containment coverage.
- Omitted deliberately as explicitly separated scope: KS-2 audit's read_file traversal/symlink remediation, filesystem sandbox against arbitrary absolute paths/original checkout access, network restrictions and output redaction. The supplied verbatim audit is historical motivation, not a claim this environment-only fix implements those broader mitigations. This contract does not claim OS filesystem isolation.
- Addressed: KS-2 reproduction STUDIO_TOKEN and saved `~/.kogen/credentials/chatgpt.json`; test only synthetic equivalents, never actual caller credentials. Studio bridge inheritance requires no Studio change because the native probe boundary strips inherited values.

## Tests
- Caller secrets and credential-store selectors never enter probe environment and HOME cannot expose the caller credential store: add TestShapeProbeMinimalEnvironment in ./verify, using actual Probe.Run and real shell with fixture Session HOME and synthetic credential store; print env and list HOME, assert STUDIO_TOKEN, OPENAI_API_KEY, an unrelated caller secret and fixture store path/value are absent, HOME differs from caller and lives in private temporary custody, fixture credentials are absent, and caller state is unchanged (regression)
- Ordinary probes and native Shape wiring still work with the sanitized environment: add TestShapeProbeMinimalEnvironmentWiring in ./shape using the real native probe dispatch with local scripted provider fixtures; assert successful overlay/file command, PATH/locale availability, explicit Probe.Tools execution, no caller secrets in returned output or retained probe_result evidence, and scratch home cleanup; retain existing timeout, cancellation, process-group and overlay tests, updating only inherited-secret expectations (integration)
- All configured checks continue to pass without weakening commands, protection or settings: run the unchanged .kogen/project.yaml checks during Build verification (existing)

## Feasibility
- none

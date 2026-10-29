# Remove the opt-in shell time limit

Slug: k-drop-shelltimeout
Model: not applicable — removing an option and its wiring adds no meaningful state
Acceptance:
- .kogen/intents/k-drop-shelltimeout/acceptance.feature
- features/steps/k_drop_shelltimeout_steps.js

Remove project.Config.ShellTimeout and tool_shell_timeout_seconds from configuration loading, rendering and validation. Native Build and independent Review construct tools without a shell time limit. Default behavior, including default Build request bytes, must be byte-identical. No CLI change and no other limit changes. This removal follows options-audit-20261029.md row K12 and Almir's principle confirmed 29 Oct 2026: "don't overengineer, simpler is always better". The default remains no limit, now fixed rather than configurable.

Remove the opt-in from docs/configuration.md, the chapter 04 bounded-shell scenario and its dedicated step files/driver. Update spec/prose/01-project-setup.md, spec/prose/04-building.md, spec/features/STEPS.md and test/acceptance/support/handlers.js to remove the option while retaining useful generic configuration steps and default unbounded-shell coverage. Remove obsolete .kogen/intents/k-shellbound artifacts and features/steps/kshellbound_steps.js and kshellbound_driver.go. Delete tests solely of removed positive-bound behavior; retain useful interruption coverage applicable to the default path.

An existing project.yaml naming tool_shell_timeout_seconds is refused through ordinary unknown-key validation, not ignored or migrated. Keep one short removal note in docs/configuration.md explaining removal, unknown-key refusal and no per-call model-shell limit. Apart from that note, remove the key from active code, specification and documentation. Rejection acceptance inputs necessarily name the key; unrelated historical Intent records and protected vendored library capability are not active Kogen option support.

No edits under cli/third_party/kogen-loop/** or to cli/loop-pin.json or .kogen/project.yaml. All configured checks must pass. Shared host: temporary fixture directories only, no synthetic CPU load, never stop processes by name or pattern, only stop PIDs started by the test.

## Decisions
- Remove the option instead of deprecating or silently accepting it (source: request)
- Preserve default behavior byte-for-byte, every other limit and the CLI (source: request)
- Document old-config refusal in a short removal note (source: request)

## Source comparison
- addressed: Request K-DROP-SHELLTIMEOUT, change_type removal, options-audit-20261029.md K12 and the 29 Oct 2026 simplicity ruling map to the removal paragraphs; no replacement option is added.
- addressed: What bullets map to Config loading/rendering/validation removal, native Build/Review unbounded construction and documentation/specification/step cleanup above.
- addressed: Must stay and Acceptance map to unknown-key refusal, byte-identical default requests, retained unbounded coverage, all configured checks and unchanged cli/third_party/kogen-loop/** and cli/loop-pin.json.
- addressed: Host safety maps to the explicit fixture/process/load restrictions above.
- superseded: k-shellbound's executable opt-in contract is obsolete and removed. The absence requirement concerns active Kogen support, not unrelated historical Intents, rejection test inputs or protected library API documentation.
- omitted: none of the requested product behavior; no external protocol or library changes are needed.

## Tests
- Removed key is refused: doctor --quick on a temporary Git project with formerly valid value 1 reports unknown key (scenario)
- Config no longer loads or renders the option: remove TestShellTimeoutConfig and retain generic unknown-key and render coverage (unit)
- Default Build requests and ordinary shell results remain unchanged: retain native default request/definition compatibility tests and chapter 04 unbounded and streamed shell-result scenarios; add a default request comparison if existing coverage lacks the byte guarantee (existing)
- Review remains unbounded: retain review tool-definition and shell integration coverage without positive-bound configuration (integration)
- Active code/spec/docs remove support: collect reference paths and require only the removal-note document, with affected spec checks passing (regression)
- Other limits and protected bytes remain unchanged: run all configured checks and inspect the scoped final diff (existing)

## Feasibility
- Local doctor --quick probe on a temporary Git repository with copied project config plus tool_shell_timeout_seconds: 1 reached validation and printed "ok config - .kogen/project.yaml is valid". Development-install checks independently failed and the CLI returned 1; the overall probe returned 0 after cleanup (0.6 s). This establishes the acceptance entry point, not feature success.
- Earlier intent list exploration did not exercise configuration validation; a non-Git fixture reported not_project. Neither is acceptance evidence.

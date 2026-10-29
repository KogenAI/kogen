# Remove internal research options

Slug: k-research-remove
Model: not applicable — configuration removal preserves runtime state transitions
Acceptance:
- .kogen/intents/k-research-remove/acceptance.feature
- features/steps/k_research_remove_steps.js

Remove Kogen's internal options K1, K2, K3, K4, K6 and K7 and cli/internal/research. Construct tools.Tools, Documentation and provider.Request plainly. Replace Measure with tools.Measure, Cut/CutText with pinned default operations and InputBudget with tools.InputBudgetBytes (524288). Remove option-only Validate, Measure, Respond, BudgetEvent, ApplyTools, Cut, CutText, Request and InputBudget helpers rather than relocating settings. Preserve K5 observable behavior in minimal ordinary code outside research: Build/Review 10 minutes, Shape/Refine/init/workers pinned 30 minutes, existing response-budget events and ten-minute expiry diagnostics.

Delete cli/internal/research/research_test.go, cli/loop_knobs_test.go and cli/loop_knobs_fixtures_test.go. Remove option-only cases in cli/build/loop_knobs_test.go and cli/shape/loop_knobs_test.go, preserving useful default coverage without research.Current. Update cli/response_budget_test.go to K5 constants, retaining wire-identity and role-entry coverage; preserve necessary fixtures outside the deleted knob fixture file. No replacement setting, flag, command or environment switch. Default wire bytes and behavior stay unchanged. Add TestResearchRemovalDefaults in cli to assert hardcoded defaults and exercise real default tool/request construction: working window 524288, tool result 16384/head 4096, pinned documentation defaults and disabled authority boundary. Keep existing default-behavior tests unchanged except necessary deleted-API/fixture references.

Update README, CHANGELOG and docs/configuration.md or a Kogen-owned loop contract to stop advertising removed options; historical evidence may remain explicitly historical. All configured checks must pass. Do not remove public options from the pinned loop: this removes Kogen's internal option layer only.

## Decisions
- Apply Almir's principle confirmed 29 Oct 2026: "don't overengineer, simpler is always better". Options are wrong by default; hardcode the finding's winner, otherwise today's default, or delete unused code. No new option or CLI change. (source: request)
- Running climbs keep their pinned frozen SHA and executable; never replace a binary a live run executes. Queued climbs re-register as uncommitted patches on the new SHA. Experiments are patch lanes, and a yes result returns as a new Intent. (source: request)
- Land before LI-4; Re-pin 2 follows LI-4. C1/C3/C4 lanes remain on frozen SHAs. Live C3 AuthorityBoundary, C4 InputBudgetBytes, UT4 DisableParallelToolCalls and K-REVOD review_material are patch experiments. Queued UT8, C5, #15, L-NUDGE and K11 run as patches on 16102c9. This Intent does not operate those lanes. (source: request)
- Never edit cli/third_party/kogen-loop/** or cli/loop-pin.json; those change only by re-pin. Shared-host work uses temporary directories, no synthetic CPU load and stops only PIDs it started, never process names/patterns. (source: request)
- Defaults stay byte-identical unless a finding names another winner; the commit body must state any such change. No different winner is supplied in this checkout, so this contract authorizes none. (source: request)

## Source comparison
- Addressed: K-RESEARCH-REMOVE K1/K2/K3/K4/K6/K7 and listed helpers map to removal prose and acceptance absence cases; K5 remains through updated response-budget tests and the budget-contract scenario. Removal concerns Kogen's wrapper settings, not protected library fields.
- Addressed: requested test deletions, constant assertions, plain construction, no research package, unchanged CLI/defaults and all configured checks map to prose and Tests. Docs cleanup and full default wire-identity coverage remain required.
- Addressed: frozen live executables, queued patch policy, 16102c9, LI-4/Re-pin 2 ordering and host safety remain explicit Decisions, not new scheduler functionality.
- Omitted evidence, not substituted authority: operations/build-notes/delivery/options-audit-20261029.md, intent KI-3, is absent from the checkout. No row or alternate finding is invented. The request supplies the default fallback; cli/internal/research/research.go currently uses zero/nil settings.
- Conflicting scope avoided: removing protected vendored public options would violate the pin boundary. This contract removes the Kogen research layer only and leaves the pin untouched.

## Tests
- Removed settings and option-only tests disappear: acceptance path-absence cases (integration)
- Plain construction and fixed defaults preserve wire bytes and bounds: add TestResearchRemovalDefaults and retain real Shape/Build default-path coverage without research imports (integration)
- K5 budgets, events, expiry wording and role wiring remain unchanged: update TestResponseBudgetDefaultContract and TestShapeBudgetRoleContract with their existing package-local tests to ordinary K5 constants (existing)
- CLI and default behavior remain unchanged: configured checks including real building chapter scenarios (existing)
- Removed options are no longer advertised: inspect README, CHANGELOG and configuration or owned loop-contract updates during independent review (existing)

## Feasibility
- none

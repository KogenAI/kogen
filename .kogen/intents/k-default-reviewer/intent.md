# Make Terra medium the default reviewer

Slug: k-default-reviewer
Model: not applicable — this changes static role defaults, not a state machine
Acceptance:
- .kogen/intents/k-default-reviewer/acceptance.feature
- features/steps/default_reviewer_steps.js

Change only the built-in review default to gpt-6.1-terra with medium effort, for every size, and the derived kogen init template. DefaultModels currently leaves Provider empty for this family (implicit ChatGPT); preserve that convention, not a new provider name. Shape remains gpt-6.1-sol/high and build remains gpt-6.1-sol/medium. Update existing tests expecting the old review default. Explicit models.review continues to win. Do not rewrite existing committed project configuration, change CLI commands or flags, introduce size routing, or change any other defaults.

After installation, research performs a confirmation run on the installed sha; deterministic checks are not that confirmation, and this change does not add paid probes or extra research arms. Respect shared-host safety: temporary directories only and never stop processes by name or pattern, only PIDs started by this work.

## Decisions
- Use Terra medium for every review size, without large-review routing or extra arms; K-REVOD-GATE is separate work. (source: request)
- Leave shape effort untouched; research M1 look 2 decides it. (source: request)

## Source comparison
- Addressed: request What to change 1–3 and Acceptance are covered by the static defaults/template scenarios and focused implementation unit tests below; provider remains the existing empty implicit-ChatGPT representation.
- Addressed: Must stay is preserved by the explicit-override scenario, unchanged shape/build expectations, and the no-migration/no-CLI-change boundary above. No existing committed configuration is an implementation target.
- Addressed: Gate requires a research confirmation on the installed sha after install, not a claim of live qualification from local tests; Host safety is retained above.
- Addressed as rationale, not new experiments: mc-m2-large (29 Oct 2026) reports landed 5/8 versus 5/8, no-verdict 0 versus 0, build input +0.8% p 0.69 and wall -20% p 0.06. m2-default-reviewer in proposals/mechanism-climbs-2026-10-28.md (M2 decided 29 Oct) reports 0/52 escaped faults and 0/30 false blocks for both, Terra's hidden fail a review_blocked catch, median 25 s versus 150 s. The 29 Oct unhold says fold defaults now, no extra arms. These supplied findings are not independently reproduced here.
- Superseded: old Sol/high review default and its template expectation only. Omitted: no requested product behavior; research execution remains the explicitly post-install gate, not automated acceptance.

## Tests
- Review defaults to Terra medium while shape/build and provider convention stay unchanged: assert complete DefaultModels roles in a focused Go unit test and executable acceptance (unit)
- Init template follows the same defaults: update TestTemplateText and parse the real Template output in acceptance (integration)
- Explicit review configuration wins without rewriting existing configuration: retain/add LoadConfig temp-file test asserting selected role and unchanged file bytes; acceptance exercises ParseConfig with explicit review (integration)
- No other default or CLI changes: run existing configured checks unchanged (existing)

## Feasibility
- none

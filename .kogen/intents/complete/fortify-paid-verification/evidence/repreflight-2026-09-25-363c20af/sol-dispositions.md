# Sol-high (GPT-6 Sol, high) dispositions, 2026-09-26, main 363c20af

First attempt failed with "Selected model is at capacity"; the retry produced `sol-high.md`.

| # | Sol | Disposition |
|---|---|---|
| 1 | status approved but in drafts/ | Not a package defect: the driver copies the package to `approved/` before `mix kogen.build` (validated there: validate-approved-copy.txt). |
| 2 | appetite; build-order contradiction; stale Codex-retry scope text | Appetite: Shaper-accepted risk (`appetite`, "everything and anything about that goes in"); no split (DIRECTION 1.17). Order: `build_order_note` and INTENT.md now say third since 2026-09-26. The Codex-retry lines are the dated history of accepted decisions, superseded in the same list. |
| 3 | `scripts/check/rehearsals.exs` selector | HEAD accepts it (`verification_plan.ex:236-238`), but its readiness command would be `mix test`. Replaced by the three catalog rehearsal ids, whose commands are the catalog's. New selectors are planned in `affected_paths`, which is Kogen's rule. Fixed. |
| 4 | integrity features not self-proving in this Build | D9-forced and recorded (risk `integrity-limits`, INTENT "How to read the scenarios"); proved on fixture repositories; follow-up ROADMAP 10 switches them on. Advisory. |
| 5 | dynamic ledger schema vs main's Codex Reviewer | Already stated: without a ledger the schema is byte-identical and main supplies no ledger to this Build's Reviews. Advisory. |
| 6 | no `ownership` entries | Fixed: risk `controller-owned-artifacts` with ownership for verification files, base workspace and retained evidence. |
| 7 | base workspace `priv/` and Mix cache | Fixed: focused runs use the workspace's own `MIX_BUILD_PATH` and resolve `priv/` inside it (lesson 2), with a control. |
| 8 | caller-to-proof map | Fixed: INTENT.md "What this Intent adds, and its caller and proof". |
| 9 | per-target wiring checks | Advisory; routes and logins stated in risk `live-targets-on-hybrid-default-route`; the fixtures' own preflights are unchanged. |
| 10 | 12 vs 13 count; reference outside checkout | Fixed in `appetite`; `approval.md` 12 is the historical approval text. The PARKED-note reference is a plan-folder path by design. |

Sol's verdict also confirms: the two paid targets are justified for their edited owners, and nothing assumes this Build's Reviewer is Claude.

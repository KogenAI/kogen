# Focused Opus re-audit

Opus found no blockers and five remaining majors: inventory contradiction with the reserved token; lingering readiness-observation claims; contradictory line selectors; missing `tracking.ex` guard; and false positives from an overbroad ignored-path manifest/global-exclude override. It also noted minor policy-scope, cold-offline, bootstrap, legacy-package, and triage-delivery wording.

Final reconciliation: R1–R4 are corrected in the inventory, selector rules, scenarios, and guards. R5 now uses one frozen exclude policy shared by Candidate identity and guard comparison, excludes enumerated volatile generated classes, protects source-relevant ignored paths, and requires a normal passing-Check control. Minor wording is reconciled. This was the single focused re-audit allowed.

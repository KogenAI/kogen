# Draft validation — 2026-09-22

Executed after the requested Fable/Luna reconciliation and root Draft edits.
These are package and source-integrity checks, not tests or acceptance gates.

- The repository's actual `YamlElixir.read_from_file/1` parsed intent, scenarios,
  risks and references. `intent.yaml` was parsed after each successful save.
- `Kogen.Intent.read/2`, `Kogen.Build.Contract.load/1`, and
  `Kogen.Build.VerificationPlan.load/0` plus `build/3` accepted the Draft.
  Selected targets remain exactly `check`, `cold-offline`, `live-native`,
  `live-reviewer-rework`, `live-shape-to-build`. Seven scenarios and five risks
  remain; guarded paths and production scope were not expanded.
- All 41 unique source-input destinations are guarded. Every payload was
  Base64-decoded/gunzipped and compared with the manifest's SHA-256, byte count,
  current dirty source bytes and executable mode. All matched. Decoded size is
  977,362 bytes. This establishes preservation only, not source correctness.
- Original shaped-against and shaping blocks, and the entire continuation list,
  were compared byte-for-byte with the pre-edit content. They are unchanged.
  The supplied current visit is present exactly once among three entries.
- The active package is in Draft, absent from Approved, with no current
  `approval` metadata. The prior approval remains in historical metadata and
  a clearly labeled historical statement.
- Package size was approximately 0.52 MB before this small receipt; its largest
  file was 36,692 bytes. This is below both publication limits for the package;
  eventual complete Candidate staging is still checked by the controller.
- Main stayed at c1f085324f78d5030c8d3d7b6efc2df248ff01c2; all 41 dirty source
  paths remained unchanged. Source, hooks, configuration, index, refs, stashes
  and runtime records were not edited by this Draft repair.
- Read-only host inspection still found `_build/lib/kogen/priv` pointing into
  an old runtime worktree; `_build/dev/lib/kogen/priv` is a normal contained
  relative link. The unsafe seed is not silently repaired, imported or admitted.
  Existing seed-admission requirements and fixture-owned preparation still apply.

No focused implementation tests or live targets were executed in this repair
turn. Historical passed targets do not become current receipts. The connected
live target and final outer Review remain unproven. Draft completeness is not a
guarantee that the Developer implements every requirement or the next Build passes.

# Historical Draft notes — superseded by current approval metadata

These exact pre-approval notes describe the earlier Draft state. They are historical evidence, not current pending decisions or authority. Current approval is maintained in ../intent.yaml; current resolutions are in ../questions.md.

## Original README.md

# Keep Build evidence out of oversized commits

**Draft, unapproved.** Read [the contract](INTENT.md), then [the two unresolved policy choices](questions.md). The human requested a written Intent, not approval or implementation.

[Scenarios](scenarios.yaml) define the proposed behavior and verification. [Risks](risks.yaml) cover evidence retention, Git state and file ownership. [Decisions](decisions.md) distinguish supplied direction from proposals. [Identity](intent.yaml) preserves the minted identity and original shaping provenance.

[Evidence](evidence/README.md) contains small source-linked receipts and the completed historical cleanup receipt. [References](references.yaml) points to the parked storage proposal and actual consumers. There is no raw tracking archive in this package.

## Original questions.md

# Unresolved policy choices

Current state: Draft requested; no approval was given. The contract and scenarios below use the recommended proposals so the package is reviewable, not because unanswered choices have been accepted.

## Q1 — availability of full evidence

**Proposed:** new Complete commits contain compact results and SHA-256-bound local locators; exact records stay in ignored runtime storage with no automatic pruning. A fresh clone cannot perform full historical evidence inspection unless its owner separately supplies the archive. Live test owners must copy that archive before fixture cleanup.

The parked September 12 proposal assumed self-contained committed Complete evidence. This proposal intentionally changes that public promise. The user's request to stop huge pushes and write an Intent does not by itself settle evidence availability. Alternative: retain self-contained evidence in Git with deduplication and a hard cap; sufficiently large unique evidence would still block publication and the storage migration would enlarge the Build. Human choice required before approval.

## Q2 — hard publication policy

**Proposed:** 5 MiB per added/modified final staged file and 10 MiB aggregate, all changed destination paths relative to starting HEAD; no bypass. Also prohibit added/modified `.kogen/runtime/` entries regardless of size. Fixed documented constants keep this Build small.

This protects the whole Kogen-produced commit, including evidence accidentally written outside Complete. It also rejects a legitimate new asset larger than 5 MiB or a larger source change. Restricting the budget only to Complete would avoid that consequence but allow misplaced evidence to recreate the incident. The thresholds and coverage are proposed, not accepted user policy. Human choice required before approval; Developer must not choose silently.

No question is raised about routine field encoding, test mechanics, installed dependencies or unchanged evidence ownership. Runtime deduplication is explicitly left out of this proposed one-Build scope; it is not silently claimed as completed.

## Original decisions.md

# Direction and provenance

## Supplied and observed

- Fresh identity/provenance came from the Shaping startup prompt and is preserved exactly in intent.yaml.
- September 14, this conversation: the user stopped the large push, requested fixing the specific commit first and preventing recurrence, then directed “write a new Intent on this shit”. This authorizes Draft creation, not Intent approval.
- The user pointed to `.kogen/runtime/shaping-followups`; inspection found the parked retained-evidence-storage proposal. It is prior art, not approved backlog.
- The separately requested unpublished-history repair is complete. Original HEAD 8ec54958 became aef8b98a; c1c9d137 became 04b6bbb9. Only the two full records and their evidence navigation changed. Source/config/tests are unchanged. The original shaping baseline remains historical fact; current source inspection uses the repaired HEAD.

## Proposed, not accepted

- Publication-only appetite; defer runtime deduplication and recursive-storage migration.
- Compact committed results plus full ignored local evidence; Q1 records the availability consequence.
- Final staged-tree limits of 5 MiB per changed path and 10 MiB total; Q2 records scope and legitimate-asset consequence. No configuration or override is invented.

## Engineering conclusions

- Ignore rules alone are bypassable by forced staging; actual tree inspection is required.
- Distinct summary schema/name avoids masquerading as the full historical record. Preserve existing collision handling.
- Keep existing full runtime schema and evidence authority; update publication consumers and fixture retention together.
- Both declared Make targets are justified by affected public workflows; a standalone serializer assertion is insufficient.
- Do not copy the 2 GB archive into this Draft. Retain compact measured receipts and source locators. No need to repeat unchanged successful history-repair measurements.


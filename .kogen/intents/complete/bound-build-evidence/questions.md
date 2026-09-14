# Resolved policy choices

No unresolved policy choices remain. The human approved this Intent after the evidence-retention discussion; the exact approval and scope are maintained in intent.yaml. Original pending-choice notes are preserved in evidence/historical-draft-notes.md.

## Q1 — availability of full evidence

**Accepted:** new Complete commits contain compact results and SHA-256-bound local locators; exact records stay in ignored runtime storage with no automatic pruning. A fresh clone cannot perform full historical evidence inspection unless its owner separately supplies the archive. Live test owners must copy that archive before fixture cleanup.

The parked September 12 proposal assumed self-contained committed Complete evidence. This proposal intentionally changes that public promise. The subsequent explicit approval settles evidence availability as described above. Alternative: retain self-contained evidence in Git with deduplication and a hard cap; sufficiently large unique evidence would still block publication and the storage migration would enlarge the Build. The self-contained-in-Git alternative was not selected.

## Q2 — hard publication policy

**Accepted:** 5 MiB per added/modified final staged file and 10 MiB aggregate, all changed destination paths relative to starting HEAD; no bypass. Also prohibit added/modified `.kogen/runtime/` entries regardless of size. Fixed documented constants keep this Build small.

This protects the whole Kogen-produced commit, including evidence accidentally written outside Complete. It also rejects a legitimate new asset larger than 5 MiB or a larger source change. Restricting the budget only to Complete would avoid that consequence but allow misplaced evidence to recreate the incident. The explicit approval accepts these thresholds and coverage as written; Developer must not silently change them.

No question is raised about routine field encoding, test mechanics, installed dependencies or unchanged evidence ownership. Runtime deduplication is explicitly left out of this one-Build scope; it is not silently claimed as completed.

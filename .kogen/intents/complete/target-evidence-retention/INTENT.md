# Retain required target evidence independently of Reviewer citations

Approved in the shaping conversation. Prepared from the supplied follow-up brief. Start with this document, then [scenarios](scenarios.yaml), [risks](risks.yaml), and [questions](questions.md). [Investigation](evidence/investigation.md) records the baseline and limits of the shaping proof.

## Problem and outcome

Successful isolated tests discard captured child output. Build truncates declared-target output to a diagnostic tail and currently snapshots cited files only. A target cannot reliably deliver a manifest through that boundary, and uncited required artifacts have no independent retention mechanism.

One Build should connect isolated child output to existing outer-owned declared-target receipts and retain validated required artifact bytes in the existing scenario-tracking/Complete evidence. Reviewer citations should describe semantic assessment; automatic retention must never imply that a model read an artifact.

## Contract

A target may emit one line beginning `KOGEN_TARGET_EVIDENCE_MANIFEST`, a tab, and a JSON object with exactly `manifest_path` and `sha256`. The path is repository-relative; the digest is lowercase SHA-256 of exact manifest bytes. Extract from complete captured output before the existing 4,000-byte diagnostic tail. Ordinary targets without a frame retain their existing behavior. An isolated producer that explicitly requires this evidence must fail if its expected valid frame is absent.

The manifest has exactly `schema_version: 1` and a nonempty `required_evidence` list of unique objects with exactly `path` and `sha256`. Validate types, digest syntax, exact bytes and repository containment. Reject duplicate frames or paths, malformed frames, absolute paths, dot or parent segments, missing/nonregular files, symlink escapes and digest mismatches. Do not follow links inside artifact content. The selected files must survive isolated temporary-directory cleanup; use the existing target-owned retained evidence location, not the supervisor's disposable root.

Forward only the explicit evidence frames across the actual isolated macro/run! route. Preserve malformed and duplicate frames so the consumer can reject them. Line framing must survive preceding unterminated progress output and following output larger than the diagnostic tail. Keep bulk private child output suppressed. Child failure and cleanup failure still fail; forwarding cannot convert them into success.

Build validates the manifest and retains its exact bytes and all required artifact bytes, with source path, digest and current target/attempt provenance, in controller-owned snapshots associated with the existing receipt/record. Keep these snapshots distinct from Developer and Reviewer citation snapshots, even where paths overlap. Before accepted publication, revalidate the bound manifest and artifact sources and retained decoded bytes. Missing, changed or forged evidence cannot publish. Complete must be self-contained after runtime source artifacts are unavailable.

Reviewer discovers target evidence through the current tracking record and directly cites the consequential files supporting its scenario judgments and findings. It need not cite each artifact merely to preserve it. Citing the manifest alone cannot support claims about artifact semantics. Retained artifacts with wrong semantic content still require rework. Existing citation integrity, fresh independent Review, gate ownership and resumption limits remain in force.

Use existing target-failure/rework handling for invalid target evidence and existing integrity-stop handling for post-validation mutations. Do not add a turn between handoff and target execution. Historical receipts without manifests remain readable; this feature does not backfill or rewrite them.

## Appetite and non-goals

One Developer conversation, configured outer resumption budget 2. Verify through `check`, including a public Build lifecycle fixture with only the provider boundary faked. The fixture may declare its own bounded target, as existing lifecycle fixtures do; no new root Make target is needed.

No paid live evaluation suite, five shaping cases, model/profile changes, logging service, storage redesign, garbage collection, historical migration, recursive collector, mandatory manifests for unrelated targets, or change to the Stop Check record protocol. This slice adds the mechanism and a real offline producer/consumer fixture; integration of the future shaping evaluation producer remains with follow-up 08. Its frozen continuation seed obligation is preserved there, not silently claimed as delivered here. No full-Candidate import or changes to the original combined Draft.

## Evidence lifecycle

Targets own their source manifests/artifacts and write only their existing private retained output locations. Build owns new snapshots immediately and throughout operation. Existing user files and controller records are never overwritten to make evidence fit; existing tracking integrity/collision rules still apply. Sources may be produced before validation but must remain unchanged through publication. Snapshots are immutable evidence for their attempt; later attempts get distinct provenance. Validate hashes against decoded bytes and recheck source containment/digests before publication. Runtime evidence remains ignored; the self-contained Complete copy is committed through existing publication. Old receipts remain unchanged and no upgrade migration is introduced. Raw account streams stay private and are not added to the required manifest set. These implement the supplied brief’s automatic-retention scope within the existing storage and ownership model.

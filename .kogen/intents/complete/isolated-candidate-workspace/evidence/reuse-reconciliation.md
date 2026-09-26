# Saved implementation reconciliation — 2026-09-22

## Human choice and scope

The Shaper explicitly said the 38-file implementation must not be thrown away
and directed: “fix the intent then approve it”. The immediately preceding
discussion identified the required amendment as continuing saved implementation
through the normal Build, rather than rebuilding from scratch. This authorizes
the specific source import documented in `../developer-recovery.md`; it does
not approve the implementation, new product scope, or manual Shaping repairs.

The blanket no-reuse sentence was overbroad. Historical isolation work at
`97109bf9` remains excluded, but the current 38-file delta against `c1f08532` is
explicitly required starting material. Reusing source and reusing old successful
receipts are different: only source is imported. Automatic stopped-Build resume,
concurrent Builds, newer-main integration, and retry-policy changes stay parked.

## Retained source

Checkpoint `913ba174bffd864e0940c49d36d9e5d022333565`, tree
`626f636347ac3507351a28ee49d2dd6d5233b529`, has parent
`c1f085324f78d5030c8d3d7b6efc2df248ff01c2` and exactly 38 changed/new paths.
The source objects and modes are enumerated in `saved-implementation.yaml`.
The checkpoint includes four new files and 34 modified files, including the
two maintained reliability catalogs. No original hook/config byte or unrelated
Draft is part of that delta. The checkpoint remains reachable through its
recovery branch; the original dirty implementation was byte-compared to it.

Source inspection of admitted `lib/kogen/build.ex` confirms clean/attached
admission, then guard capture and Developer launch in the invoking checkout.
The installing Developer therefore imports source into that controller-issued
root; making the WIP checkpoint the judge or replacement baseline is unnecessary.

## Earlier failed Build and repair direction, before IBs1pJmboiW9BAGHIDd_ee4O

Retain the original controller record unchanged:
`.kogen/runtime/scenario-tracking/suowZ26kyb7Qag3tKvPPC4n1/record.json`.
Its terminal guard rejection named unrelated ignored Draft files; that does not
prove the Developer edited them. Separate retained verification also exhausted
after live-reviewer-rework failed. Its third cycle passed check, cold-offline
and live-native, then failed after the nested rework Build when retention looked
up an absolute full-record reference in a relative-path-only map. The outer
connected live-shape-to-build target and final outer Review were not reached.

The source-bound defect is in `test/support/live_reviewer_rework_fixture.ex`:
`preserve/3` indexes copied records with `Path.relative_to/2` but the
summary can contain an absolute `full_record.path`. The connected owner's
`preserve_tracking/3` in `test/kogen/live_shape_to_build_test.exs` has the same
boundary. Repair both real consumers, preserve exact record bytes/digests before
fixture cleanup, and test accepted absolute/relative references plus unsafe,
missing, and mismatched references. A nested accepted result does not make a
failed outer evidence-retention audit pass.

The saved workspace implementation still rejects every seed symlink, while
its dependency test only examines a synthetic environment map. Its publication
positive control permits either success or failure. Existing scenario controls
explicitly require correcting those gaps. Live owners must load and prepare
their real fixtures independently before provider work; cross-test helper
preloading and dereferencing every seed link are not valid fixes.

Catalog validation must preserve the admitted `c1f08532` generation and bind
Candidate changes against that generation, not merely dirty status after any
intermediate checkpoint. Its Gitless recipe must validate outer-owned copied
input/baseline provenance, not treat every catalog implementation path as changed
when Git is unavailable. These are existing contract obligations, not extra
product scope. Focused selectors already include both catalog tests and cold
provenance controls.

## Excluded manual-repair experiment and evidence limits

Before the Shaper clarified the boundary, manual repair attempts were mistakenly
started in `/Users/almirsarajcic/Areas/Kogen/kogen-isolation-repair`. Two focused
13-test runs each passed eight and failed five. Those attempts stopped; their
unverified extra edits are not the designated checkpoint or an accepted fix.
The helper's three misdirected original-file edits were preserved separately and
reversed to the checkpoint bytes. No main ref was advanced. This history must
not be described as a successful Build or silently merged as approved work.

This amendment ran no test target or provider. It authorizes continuing the
saved work, not a next-run guarantee. `../approval.md` owns current approval;
all prior failures and successful source-bound observations retain their limits.

# Continue the retained implementation — required installing instruction

Do not recreate the feature or import only the old checkpoint. The Shaper's
no-discard choice remains in force. This revision retains all **41 current
changed/new source paths**, including repairs made during failed Build
`181SwyyMv5aW2U838Wh8xXIt`. These are unverified implementation inputs, not
accepted code, reusable receipts, or a new baseline.

## Exact source input available after a clean-start stash

- Admitted baseline remains `c1f085324f78d5030c8d3d7b6efc2df248ff01c2`.
- Primary manifest: `evidence/latest-implementation.json`, relative to this
  package, not a runtime directory. It enumerates 41 exact repository-relative
  paths, modes, baseline blob identities (null for additions), decoded sizes,
  SHA-256 hashes and inert payload locators.
- Each payload under `evidence/implementation-inputs/` is line-wrapped Base64
  of gzip-compressed **one file's bytes**, not a tar archive, executable recovery
  script, or Git bundle. Strip whitespace, Base64-decode and gunzip; compare
  decoded length and SHA-256 before using any bytes. Its manifest pathname is
  the only intended destination.
- The complete snapshot contains 977,362 decoded bytes. Root checked every
  payload against the current dirty file, including executable mode, without
  changing source, index, refs or stashes. See latest-build reconciliation.
- Older checkpoint `913ba174bffd864e0940c49d36d9e5d022333565`, branch
  `recovery/isolated-candidate-workspace-20260922`, and the 38-file historical
  `evidence/saved-implementation.yaml` remain backups/provenance. Do not import
  them instead of these newer inputs. The current snapshot is self-contained;
  no stash pop, manually timed restore, or checkpoint object is needed.

The package and payloads survive the ordinary tracked/untracked clean-start
stash because the package is ignored. Do not use an all-ignored stash or delete
the package. If any required payload is absent/corrupt, stop and identify it:
do not silently fall back to old source or start from scratch.

## Developer's first implementation work

Read the full package and controller instructions, including the prescribed
initial readiness point. Before parallelizing edits:

1. Validate the complete manifest: exactly 41 unique safe relative destinations,
   no traversal/absolute/duplicate paths, all within Approved guards. Verify
   each payload digest/size and regular-file type and the admitted baseline
   identities/modes. Do not execute retained source to decode it, follow
   destination symlinks, import caches/credentials/runtime, or edit the frozen
   Approved package.
2. Compare the actual controller-issued project root with baseline and retained
   bytes. For an unchanged baseline file or absent addition, restore the
   retained version using the normal permitted file-editing mechanism and
   recorded mode. Already-retained files are left alone. Files matching only
   the older checkpoint need reconciliation to the newer retained version,
   not an assumption that recovery is complete.
3. Preserve any third/newer version, inspect its delta against both baseline and
   retained input, and reconcile ordinary in-scope differences. Do not overwrite
   user changes or reset whole files. Escalate only a genuine authority/product
   conflict. Check all 41 paths before calling the import complete; digest
   checks prove import only, never correctness of the implementation.
4. Continue repairing the combined implementation through `repair-plan.md`
   and `developer-testing.md`. Known broken assertions in this snapshot are
   repair inputs, not requirements to preserve. Full baseline-to-Candidate
   verification and fresh independent Review remain required.

No new import mechanism is a production feature. No command-attestation record
is required. Do not reset HEAD, cherry-pick the WIP commit, move main to a backup,
pop/drop a stash, delete a retaining branch, or reuse old identities or counters.

## Installing controller and checkout

The Shaper starts ordinary `mix kogen.build isolated-candidate-workspace` only
after fresh approval and satisfying its clean-start precondition. Saving tracked
and untracked work in a stash is one option, not an operation performed by this
Shaping revision. Developer imports the package's exact retained bytes; no manual
pop during Build is needed.

At c1, the admitted controller still runs in its invoking checkout and commits
to its current attached branch. To end with this repository's `main` updated by
that controller, invoke it in this repository on clean `main` at c1, keep all
other edits out of that checkout throughout installation, and let the Developer
restore the retained source. Other Shaping can run in another checkout.
Ignored Draft edits here are still observed by the old guard.

The optional separate installing checkout remains permitted, but a recovery-
branch worktree publishes to that branch, and a separate clone publishes to that
clone: neither automatically updates this repository's main. Do not force main
into two worktrees, hot-load the Candidate controller, or treat a later manual
integration as part of the existing Build's accepted publication. No such move
or integration is performed or newly authorized by this Draft.

Stop owns `check`, `cold-offline`, `live-native`, `live-reviewer-rework`, and
`live-shape-to-build`. This is a new normal Build, not resumption of the exhausted
one. Previous receipts, the snapshot, and Developer test claims cannot authorize
acceptance. Failure diagnostics and all backups remain preserved.

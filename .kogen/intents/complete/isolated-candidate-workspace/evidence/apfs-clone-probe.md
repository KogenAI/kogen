# APFS clone-on-write probe

## Correction from the 2026-09-22 Fable-high review

The historical paragraph below incorrectly calls `cp -c` clone-or-fail. The
installed manual and the executed HFS+ negative control in
`clone-capability-probe.md` show silent byte-copy fallback. Retain the observed
exit codes, distinct inodes, matching bytes and mutation independence, but do
not treat them as proof that native cloning occurred. The timing limitation
below also remains. A fail-closed native primitive is required by the current
Draft; the old inference is superseded, not readiness evidence.

## Historical observations and now-refuted inference

The Shaper rejected compulsory dependency/build recompilation for every Candidate and selected clone-on-write warm seeding as the normal creation path.

A disposable host probe used macOS `cp -cR` first on an 8 MiB tree and then on this checkout's current `deps/` and `_build/`. Both clone commands returned zero. Source and destination files had distinct inodes and identical SHA-256 bytes; changing the destination marker left the source marker unchanged. The real seed probe cloned trees with roughly 26 MiB of logical content within the bounded command invocation. `cp -c` is the macOS clone-or-fail interface, so a zero result establishes that the host accepted native cloning rather than an eager-copy fallback.

Limitations: logical `du` sizes do not report shared physical extents, the shell timing calculation was invalid and is not used, and the probe does not establish Kogen orchestration. Focused workspace tests must retain the native-clone invocation result, source/destination identity, mutation independence, source hashes, and failure controls. Disposable probe roots were `/tmp/kogen-cow-probe.pj2TU9` and `/tmp/kogen-real-seed-probe.eRyw2u`; they contain no credentials or repository mutations.

A later human-supplied read-only review correctly challenged blind reuse of `_build`. The contract therefore requires ordinary Candidate-rooted Mix validation and incremental compilation after cloning, with controls for stale artifacts and unchanged inputs. It also narrows the clone allowlist to `deps/` and `_build/` only and adds stable-source, actual-filesystem, excluded-state, partial-clone and insufficient-space controls. These are requirements; the shaping probe did not establish them.

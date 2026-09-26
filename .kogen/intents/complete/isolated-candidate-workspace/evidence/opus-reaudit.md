**Verdict: not ready for approval.** B3, B5 and B6 are resolved in the contract. B1, B2 and B4 are each still blocked by one narrow gap, and each fix is a wording change. I edited nothing and ran no verification.

| Blocker | Status |
|---|---|
| B1 publication / crash lifecycle | **Open** (build lock) |
| B2 verification state vs tracking | **Open** (what happens to evidence after cleanup) |
| B3 shared Git state / hook-free publication | Resolved |
| B4 guarded / affected paths | **Open** (one test file missing) |
| B5 Candidate parent / cold seeds | Resolved |
| B6 offline selector | Resolved |

## Remaining blockers

**1. B1: a crash leaves the build lock, so the promised recovery can never run.**
- **Where:** recovery is promised in `INTENT.md`; current `lib/kogen/build.ex:156-170` creates the empty lock exclusively and removes it only normally.
- **Consequence:** a later Build stops before reading the journal unless lock takeover rules are explicit.
- **Fix:** include `.kogen/build.lock` in publication ownership; allow takeover only when lock and journal identify the same Build, otherwise refuse.

**2. B2: removing a successful Candidate deletes evidence the Draft says must be kept.**
- **Where:** Candidate owns verification/role evidence, while successful Candidate cleanup is required and control tracking remains retained evidence.
- **Consequence:** tracking would point to deleted paths or require an unspecified copy-out.
- **Fix:** state which evidence is copied/moved into control tracking before cleanup and record both roots explicitly.

**3. B4: an unlisted test must change.**
- `test/kogen/unified_state_admission_test.exs:17,65` calls `Verification.initialize/5`; explicit-root API changes require updating it.
- Add it to guarded and same-lifecycle affected paths.

## Resolved

- B3: shared Git is control-owned, snapshotted, maliciously tested, and mutations refuse verification/publication; publication is hook-free and limitations are detection, not containment.
- B5: fixed Candidate parent and admitted cold sources/tool archives are defined and hashed.
- B6: the live-tagged cold driver is no longer an ordinary offline selector.

Nonblocking observations: Candidate-authored compatibility entry points may prove not to need changes; a pre-main crash also leaves the lock and should use the same identity rule.

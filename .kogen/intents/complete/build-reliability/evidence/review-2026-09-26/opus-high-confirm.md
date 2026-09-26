**Blocking:** none.

**1. Applied fixes (DISPOSITIONS rows).** Every applied row shows up in the current files, and the source citations hold at 7ed41f66:
- Rows 17–18: `test_reliability_catalog.ex:33-51` and `generate_test_reliability.py:14`.
- Row 19: README :84-86, :109, :206, :557.
- Row 21: `build.ex:2223`, `:2312-2314`.
- Row 22: `offline.py:144-156`. Row 32: `offline.py:158`.
- Row 27: the three guard globs match exactly the 12 evidence trash files, and the 6 `.pyc` files are the only output of `git ls-files -ci`, so the 18-file count is right.
- The README function names (`VerificationPlan.load/1` and the others) are all exported.

A few citations are slightly off (non-blocking):
- `build.ex:2259-2261` is really :2260-2262.
- `generate_test_reliability.py:64` is the `id` line; the declaration is copied at :66.
- risks.yaml:6 cites `contract.ex:128-132`, but those lines are the `verdict/5` head. The extra-key check is at `:154-158`.
- scenarios.yaml:907 says the Git test skips "as `whole_suite_remediation_test.exs` does". That test doesn't skip without Git; it falls back to the claimed paths (:35-40).

**2. Split leftovers.** No remaining scenario or risk needs status lines, stage timings, `--notify`, a notifier, `status.ex`, `notify.ex` or the two moved test files. `scripted_build_fixture.ex` (scenarios.yaml:825) already exists at 7ed41f66, so it isn't dangling. The count of 26 matches in INTENT.md:167, risks.yaml:87 and CONTINUE.md:12,30. The "28" at questions.md:252 is inside the quoted historical question, which is fine. Cosmetic leftovers:
- questions.md:120-145 still lists Assumed items 1, 2 and 7 under this Intent (they are only annotated at :249). Moving them under the split note would be cleaner.
- Q2 (questions.md:22-24) still says `live-native` gets a `prepare`, which Q3 moved out. It also doesn't mention `live-shaping-smoke`.

**3. New or remaining defects (non-blocking, fix before approval if cheap):**
- **Doc path rule vs `.codex/sessions`** (scenarios.yaml:1327-1333): README:206 and `priv/kogen/prompts/shaping.md:221` cite `.codex/sessions`. That path is under the checked `.codex/` prefix, doesn't exist, and isn't in the listed skips. `shaping.md` is not in `may_change_guarded_paths`, so if the list is read as complete, `check` fails and the Developer can't reword the prompt. Fix: add `.codex/sessions` to the skip list, or say "the `GuardedPaths` volatile set".
- **Cited-log assertion in cold-offline** (scenarios.yaml:906-908, :931-932): the cold-offline copy excludes `.kogen/intents` (`cold_offline_test.exs:38`), so the "three cited logs still exist" assertion would fail there unless it skips too. Fix: say the whole test, including the log assertion, skips when there is no Git.
- **Pinned row count:** `test_reliability_catalog_test.exs:16` pins `declaration_count == 346`. Removing a stale row, which the scenario allows (scenarios.yaml:1206-1210), breaks it. The file is in `affected_paths`, but the scenario should say the count is checked for consistency, not pinned.
- **Wrong catalog key:** scenarios.yaml:485 says `dependencies: [check]`, but the catalog key is `depends_on` (`verification_plan.ex:295`).
- **Garbled sentence:** scenarios.yaml:299 has the fragment "(Expert audit). taken from the admission catalog entry…". It belongs after "every selected provider-backed target that declares one" (:296-297).
- **Repeated text in risk `appetite`:** risks.yaml:90 and :92-93 both say a failed Build keeps its Candidate. Also, risks.yaml:90 says "185-271 s" where INTENT.md:162 says "184-271".

I didn't re-check the dispositions that were marked "known", nor row 25, which was "not re-checked".

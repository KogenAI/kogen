## Findings

- **[BLOCKING] The other race Round 1 flagged is still unaddressed, so test :426 can keep flaking.** In stop mode the standin sleeps a fixed 300 ms and then calls `release/1` (`test/support/custody_controller_standin.exs:46-49`). Registration can take about 1 s (`lib/kogen/process_custody.ex:479-492`). If it lands after `release/1`:
  - `teardown` finds no groups to reap.
  - `record_group` sees `:enoent` and does nothing (`:189-190`).
  - The provider never exits on its own (`test/support/fake_orphaning_provider/provider.sh:16-21`).
  - `Task.await(task, 5_000)` (`standin.exs:50`) crashes the standin, and `:433` fails.

  The lock fix doesn't touch any of this, so `scenarios.yaml:7` ("the existing test passes") isn't guaranteed. — **Fix:** add to the custody scenario: in stop mode the standin waits until `read_lock` shows the group before READY and `release/1`, the same pattern as `test/kogen/process_custody_test.exs:98-100`. This replaces the fixed sleep with a condition wait, so no timeout is raised.

- **[BLOCKING] "Only while this controller still owns the lock" leads to a check that doesn't close the race and breaks Expert recording.** The race is inside one OS process: the standin's Task against its own main process. A check that the lock's pid equals `System.pid()` always passes there. Only putting `release/1`'s `File.rm` (`process_custody.ex:232`) in the same critical section as the read-modify-write in `record_group`/`forget_group` closes it. A pid check would also silently drop records from `mix kogen.expert`, which is a separate OS process that records onto the Build's lock (`lib/mix/tasks/kogen.expert.ex:138-141` → `lib/kogen/claude_code.ex:127` → `lib/kogen/harness/claude.ex:545`). That breaks custody sweeps when the Expert runs unconfined. — **Fix:** reword `INTENT.md:20-21` as "no lock update may create the lock; `release/1`'s remove and every read-modify-write are serialised; writers in other OS processes are unaffected." Drop the ownership wording.

- **[ADVISORY] The regression-test mechanism is misplaced.** Code in `custody_controller_standin.exs` (`scenarios.yaml:3-4`) can't pause `forget_group` between its read and its write. That needs a seam in `process_custody.ex`. §1.16 allows it because the new test uses it. Two more constraints for the serialisation:
  - Kogen has no Application module (`mix.exs` has no `mod:`), so it can't rely on a supervised process.
  - `release/1` also runs from `:erl_signal_server` (`lib/mix/tasks/kogen.build.ex:18`).

  — **Fix:** name the seam's location, require a lock that needs no supervised process (for example `:global.trans` keyed on the lock path), and require the new test to fail at b2073666.

- **[ADVISORY] Stale assumption.** `questions.md:7-9` (Assumed 1) still permits adding `wait_until/1`, which contradicts `scenarios.yaml:9`. A Developer could use it to justify a test-side wait. — **Fix:** delete it.

- **[ADVISORY] Load-sensitive time left in the drain budget.** The grandchild ignores SIGTERM, so `release/1` always waits the full 2 s settle (`process_custody.ex:254`) inside `drain_standin`'s 5 s budget (`process_custody_test.exs:343`). — **Fix:** note this in `risks.yaml` as a residual.

- **[ADVISORY] Terminal probe: the fix is sound, but the citation points at the test header.** `:60` is the test's declaration; `_message` is bound at `:71` and the assertion is at `:91`. Ledger rows `t001`–`t005` are bound only by test name (`test/support/test_reliability_catalog.ex:147-160`), so with no rename neither `priv/kogen/test-reliability*.yaml` file needs editing. The `mined_failures` JSON fixtures are frozen output and don't depend on current line numbers.

- **[ADVISORY] Installer: the fix is sound.** Lines `:191-192` build the tar twice, and building it once keeps the check just as strict. Lines `:189` and `:183`/`:210` stay as they are. The proof runs through `test/kogen/claude_code_install_test.exs:6`.

- **Other checks: no issues.**
  - `paid_target: none` fits D8/§1.19 because no live test is edited.
  - Rule 44 doesn't apply, and D1 isn't touched.
  - Lesson 17 is covered, since the Candidate builds in a separate worktree.
  - Line references for the race in `INTENT.md:10-11` (`:349`, `:198-203`, `:220`, `:232`) are correct at b2073666.
  - The guarded paths cover every file both scenarios need.

## Verdict: not ready

The installer and terminal-probe parts are ready. The custody part needs two wording fixes: make the standin wait for registration, and replace pid-ownership with "serialise the remove together with the read-modify-write".

Also, the Stripe connector on claude.ai needs authorising in its claude.ai connector settings before its tools can be used. It wasn't needed for this review.

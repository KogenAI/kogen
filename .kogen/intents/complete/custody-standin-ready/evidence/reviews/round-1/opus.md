**Verdict: ready**

I read the working tree, not a checkout of `f1d176b0`. I had no git access, so I couldn't confirm the two match.

**Blocking findings:** none.

**Is the diagnosis right?** Yes.
- In hang mode, READY comes after a fixed `Process.sleep(300)` (`test/support/custody_controller_standin.exs:38-39`).
- `pty_ctrlc.py:40-42` sends Ctrl-C as soon as it sees READY. Under `+Bd` the BEAM dies at once, and the supervisor's watchdog (`priv/kogen/process_supervisor.py:134-138`) then kills the group, possibly before `provider.sh:11,14` writes the pid files. There's a second way to get the same failure: the Task hasn't even opened the supervisor port yet when Ctrl-C arrives. Either way, `:464` gets nil, and gating READY on the pid files fixes both.

**Other users of hang mode:** only three tests use it, all in `test/kogen/process_custody_test.exs`:
- SIGHUP/SIGTERM at `:406`
- kill -9 at `:426`
- the pty Ctrl-C test at `:456`

The first two already wait for both pid files after READY (`:407-409`, `:427-429`), so the new gate matches what they do now. No other file refers to the stand-in or to `pty_ctrlc.py`.

**Could gating READY on the pid files deadlock a test?** No.
- `provider.sh` writes both files unconditionally, before `cat`.
- The supervisor gives it stdin from `DEVNULL` (`process_supervisor.py:159`).
- The out dir is created by the test (`:28-32`).
- Nothing waits on READY before those writes happen.
- If the files never appear, the existing waits fail loudly: 10 s at `:386` and 25 s in the pty driver.

**Must anything else change?** No. The two guarded paths are enough, and in practice only the stand-in needs editing.

**Non-blocking notes**
1. **Also wait for the group to be recorded on the lock.** The provider can write its pid files before `await_registration` → `record_group` has put the group on the lock (`lib/kogen/process_custody.ex:429, 569-573`). If SIGHUP/SIGTERM lands in that gap, `SignalHandler` (`lib/mix/tasks/kogen.build.ex:17-19`) releases an empty lock. The watchdog then does the reaping, so the test still passes, but it's no longer testing the signal trap. I'd have hang mode wait for both conditions: `read_lock` groups non-empty (the same loop stop mode uses at `:47-58`) and the pid files. The header comment would then say "lock held, group recorded, pid files written". This was already possible with the 300 ms sleep, so it isn't a regression.
2. **What `grandchild.pid` actually proves.** Two things write this file: `provider.sh:14` with `$!`, and `grandchild.py:8` (same pid). The provider's write can land before Python has run `SIG_IGN`. So READY doesn't guarantee the grandchild is ignoring SIGTERM yet. If TERM arrives first, the grandchild just dies and the tests still pass, but the wording "provider has really started" slightly overstates what's proven.
3. **The 10 s READY wait now also covers provider start-up.** `wait_for_standin_ready` (`:386`) now covers `mix run` start-up plus provider launch, still with no budget change. It's probably fine, but it's the first place to look if this test flakes under load again.
4. **Doc nit.** Saying "the signal and kill -9 tests are not affected in the same way" is accurate. Given note 1, though, the shared READY contract matters more to them than the draft suggests.

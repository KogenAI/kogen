# Wait for the fake provider before READY

## Why

Build KaDgVkNh0zDUlhDCsTUm-HE8 (durable-builds-and-failure-reports, 2026-09-27) stopped after check cycle 1 failed one test
outside its scope: `test/kogen/process_custody_test.exs` "Ctrl-C under a pty with ELIXIR_ERL_OPTIONS=+Bd exits at once, and
the watchdog still reaps the group" (failure frame :464, `assert grandchild_pid && provider_pid`, "Expected truthy, got nil";
1257/1258 passed, the full async suite running). Cause: in `hang` mode `test/support/custody_controller_standin.exs` starts
the fake provider in a Task and prints READY after a fixed `Process.sleep(300)`, not after the provider has started. The pty
driver (`test/support/pty_ctrlc.py`) sends Ctrl-C the moment it reads READY, so under load the BEAM exits and the watchdog
reaps the group before `test/support/fake_orphaning_provider/provider.sh` has written `provider.pid`/`grandchild.pid`; the
test's `wait_for_pid_file/2` then returns nil. The signal and kill -9 tests are not affected in the same way because they
wait for both pid files themselves before signalling, but they share the same READY contract.

## Outcome

- In `hang` mode the stand-in prints READY only when (a) `Kogen.ProcessCustody.read_lock/1` shows its group recorded (the
  same loop stop mode uses, so a SIGHUP/SIGTERM exercises the signal trap's teardown, not only the watchdog) AND (b) both
  `<out>/provider.pid` and `<out>/grandchild.pid` exist with non-empty content (provider.sh writes provider.pid, then
  grandchild.pid after starting the grandchild). It waits with a condition loop (short sleeps), replacing the fixed 300 ms
  sleep. If the files never appear the stand-in never prints READY, and the driver's existing 25 s deadline makes
  the test fail loudly (`exited=None`); no deadline or budget is added, raised or lowered.
- The stand-in's header comment states the new READY contract (lock held, group recorded, provider pid files written; the
  grandchild may not yet ignore SIGTERM, which no test relies on).
- No test is renamed (the test-reliability ledger binds rows by test name); no assertion is weakened or removed.

## Non-goals

- Production custody code (lib/kogen/process_custody.ex), the pty driver, the fake provider, any deadline.

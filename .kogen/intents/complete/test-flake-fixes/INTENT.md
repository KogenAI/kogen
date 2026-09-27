# Fix the custody lock race and two flaky tests

## Why

Three offline tests failed intermittently on 2026-09-27 and cost Build cycles; when one is reported first the Developer thinks
the failure is outside its guarded paths and changes nothing (Builds Cz_797R_H-oABPpji8aMO5QF cycle 5, sjIVXyQAJAmq4e1ifi66UJP2
cycle 1). Review (evidence/reviews/round-1/opus.md) showed:
- `test/kogen/process_custody_test.exs` "a real controller's normal Stop tears its own groups down and releases the lock"
  (~:426-440) exposes a PRODUCTION race in `Kogen.ProcessCustody`: `release/1` can run while a finishing run's
  `forget_group` (lib/kogen/process_custody.ex ~:349, :198-203) reads the lock after teardown's `write_lock` (~:220) and writes
  it back after the `File.rm` (~:232), recreating `.kogen/build.lock` for good. Waiting in the test cannot fix it.
- `test/kogen/terminal_probe_test.exs:60` returns status 1 on "success" under load, but the test discards the probe's message, so
  which deadline was missed (startup 2.0 s, completion, survivor check; test/support/terminal_probe.py ~:26-27, :89-127) is
  unknown.
- `test/support/claude_code_installer_test.py` (~:190-192): the "incomplete native distribution" case builds the tar twice; the
  gzip header timestamp written by tarfile in "w:gz" mode differs between calls, giving "integrity mismatch".

## Outcome

- **Custody lock race fixed:** no lock update may CREATE the lock: `release/1`'s remove and every read-modify-write in
  `record_group`/`forget_group` are serialised on the lock path with a mechanism that needs no supervised process (Kogen has no
  Application module; `release/1` also runs from `:erl_signal_server`, lib/mix/tasks/kogen.build.ex:18) — e.g. `:global.trans`
  keyed on the lock path; an update that finds the lock gone does nothing. Writers in other OS processes (e.g. `mix kogen.expert`
  recording onto the Build's lock, lib/mix/tasks/kogen.expert.ex:138-141) are unaffected. A test seam in process_custody.ex lets
  the new regression test pause `forget_group` between its read and write, race `release/1` against it, and assert the lock
  stays gone; the regression fails at b2073666.
- **Stop-mode standin waits for registration:** in stop mode `test/support/custody_controller_standin.exs` waits until
  `read_lock` shows its group (the condition-wait pattern at process_custody_test.exs:98-100) before READY and `release/1`,
  replacing the fixed 300 ms sleep (no timeout is raised).
- **Terminal probe diagnosable:** the test binds the probe's message (terminal_probe_test.exs:71) and asserts `status == 0, message` at :91 (and the failure case likewise), so the next
  failure names the missed deadline. No deadline changes (a later Intent decides once the cause is known).
- **Installer test deterministic:** the omitted-`package/claude` tar is built once and the same bytes feed the registry and the
  fetch. The pinned-integrity case at ~:189 is unchanged; credential/account markers (~:183, :210) unchanged.
- No test is renamed (the ledger binds rows by test name); no timeout, deadline or budget changes.

## Non-goals

- Changing any deadline in terminal_probe.py; other custody behaviour.

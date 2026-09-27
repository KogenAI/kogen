# Wait for the fake provider on timeout and Stop

## Why

Build BSaavY4ASoCoOZC-8KbpubME (2026-09-27, a config-only Intent) stopped after check cycle 1 failed one test outside its
scope: `test/kogen/process_custody_test.exs` "a real controller's timeout kills the whole group and releases the lock"
(:490; failure frame :499, `assert provider_pid && grandchild_pid`, got nil) while the full async suite was running.

`custody-standin-ready` (fa48e817) fixed this race in hang mode only. In timeout mode,
`test/support/custody_controller_standin.exs` prints READY and then calls `Kogen.ProcessCustody.run([provider, out], ...,
timeout_ms: 300)` (:89-98). The 300 ms timeout is measured inside the supervisor, not in Elixir.
`priv/kogen/process_supervisor.py` starts its clock at the top of `main()` (`clock = time.monotonic()`, :110). That is
after the Python interpreter starts and before the log file opens and `Popen` runs. The watchdog wakes every 0.2 s
(:105, :127). It ignores the deadline until the child exists (:128). Once the deadline has passed, it SIGKILLs the child's
whole group (:131). So the provider group is killed at the first 0.2 s tick after both the deadline has passed and the
child exists: about 400 ms after the supervisor starts, or at most 200 ms after `Popen` returns if spawning was slower
than that. Under load, `test/support/fake_orphaning_provider/provider.sh` may not yet have written `provider.pid`, or may
not yet have forked the grandchild and written `grandchild.pid`. There is a second way to lose `grandchild.pid`:
`test/support/fake_orphaning_provider/grandchild.py` reopens it with `"w"` (:8), which empties the file, so a SIGKILL
between that open and the write leaves an empty file even after `provider.sh` wrote the pid. The test's
`wait_for_pid_file/2` then returns nil.

Stop mode has the same race. It waits only until `read_lock/1` shows the group recorded, then prints READY and calls
`release/1`. `release/1` tears the group down, possibly before the pid files exist.

Shaping reproduced both races at fa48e817. A 0.5 s start delay placed before `provider.sh` makes timeout mode end with
`TIMED_OUT=true` and an empty out dir. A 1.0 s delay makes stop mode print READY and STOPPED with an empty out dir.
Timeout mode also lost the race once, unaided, just after a compile: the first 300 ms attempt had no pid files.

### Choice of fix

- **Not a production bug.** The timeout bounds the whole supervised run. The only part it counts beyond the child's own
  run time is opening the log file and calling `Popen`, which takes milliseconds, while production timeouts are minutes.
  Starting the clock at spawn instead would not fix the race either: the provider would still need to write both files
  within 300 ms of starting, which load can prevent. `lib/kogen/process_custody.ex` and the supervisor stay unchanged.
- **A start barrier cannot hold off the deadline.** The supervisor's deadline is fixed at launch (`timeout` in the
  spec), and anything the provider waits on runs inside the timed group. Counting the timeout from a provider barrier
  would need a new production hook, and the previous bullet shows there is no bug to justify one.
- **A larger fixed `timeout_ms` is a fixed sleep under another name.** It would cost wall time on every run: about
  4.6 s more per run at 5 s, the pid-file budget the tests use. It would still lose to a provider slower than the timeout.
- **Chosen: in timeout mode, re-run the timeout until the evidence exists, a fixed number of times.** The stand-in
  makes at most four attempts, with `timeout_ms` 300, 600, 1200 and 2400. Each attempt deletes both `<out>/provider.pid`
  and `<out>/grandchild.pid` before it runs, so the accepted pair always comes from one attempt. After each `run/3`
  returns, the stand-in checks the attempt itself, and exits non-zero if either check fails:
  - `"timed_out"` must be `true`.
  - The attempt's process group must be gone: `kill -0 -<facts["pgid"]>` must fail. The grandchild is in that group, so
    this proves the timeout reaped it even when its pid file is missing, and a retry cannot hide a timeout that kills
    without reaping in the early-kill window.

  If both pid files then exist with non-empty content, a group member wrote them before the kill: the stand-in stops,
  releases the lock and prints `TIMED_OUT=...` as today. If they do not, it prints one progress line and makes the next
  attempt. If the fourth attempt also leaves a pid file missing or empty, it calls `release/1`, prints one line naming
  the failure, and exits non-zero (`raise` is enough). The test then fails with `{:ok, 1}` from `drain_standin` instead
  of a `:timeout`, and no stand-in keeps relaunching providers after the test's `on_exit` has deleted `base`. This caps
  attempts, not time: it adds no deadline of its own and changes no test deadline. The last attempt, 2400 ms, stays
  below the test's 5 s `drain_standin` window. An unloaded machine uses one 300 ms attempt, the same test time as now;
  shaping measured about 0.45 s per stand-in run over five runs. A retry costs only its own timeout. Shaping measured one
  retry with a 0.5 s-slow provider (+0.7 s) and two retries with a 1.0 s-slow provider (+2.0 s).

## Outcome

- **Hang and stop modes share one wait.** READY is printed only when `read_lock/1` shows the group recorded AND both
  `<out>/provider.pid` and `<out>/grandchild.pid` exist with non-empty content. This is hang mode's existing condition
  loop, defined once as a closure before the `case` and called by both modes. Stop mode's group-only wait is removed and
  it uses the shared loop before READY and `release/1`, so a normal Stop always tears down a provider that has started.
- **Timeout mode re-runs as described in "Choice of fix".** Attempts use `timeout_ms` 300, 600, 1200 and 2400, and no
  more. Both pid files are deleted before every attempt. After every attempt the stand-in exits non-zero if
  `"timed_out"` is not `true` or the attempt's group (`facts["pgid"]`) is still alive. It re-runs only while an attempt
  left one or both pid files missing or empty, and exits non-zero after `release/1` and one line naming the failure if
  the fourth attempt does too. It never uses a fixed sleep. READY is still printed after `acquire`/`claim` and before
  the first run. On success the existing `TIMED_OUT=` line is still printed once, after `release/1`.
- **The header comment states each mode's READY contract.** Hang and stop: lock held, group recorded, both pid files
  written. Timeout: lock held; the stand-in itself retries, up to four attempts, until a timeout lands after both pid
  files are written, and exits non-zero if an attempt did not time out, left its group alive, or no attempt left both
  files.
- **The tests are untouched.** No test is renamed (the test-reliability ledger binds rows by test name), no assertion is
  weakened or removed, and no deadline, budget or Build timeout changes. `test/kogen/process_custody_test.exs` needs no
  edit and is the offline proof.

## Non-goals

- `lib/kogen/process_custody.ex`, `priv/kogen/process_supervisor.py`, the fake provider, `pty_ctrlc.py`, and any
  deadline, timeout or budget in the tests or the Build.

# Questions and choices

No open questions.

## Assumed

1. The fix lives in the stand-in, not in production custody code or the supervisor.
   Reason: the supervisor starts its timeout clock before spawning the child, which adds only milliseconds (the log open
   and `Popen`) to timeouts measured in minutes. Starting the clock at spawn would not remove the race either, because the
   provider still has to start within 300 ms.
   Undo: revert the stand-in change.
2. Timeout mode re-runs with a doubled `timeout_ms` until a timed-out run leaves both pid files (capped, see 4). It
   does not use a larger fixed timeout.
   Reason: this is deterministic, because success requires the evidence rather than elapsed time. An unloaded run costs
   the same as today. A fixed 5 s timeout would add about 4.6 s to every run and could still lose the race. The doubling
   is the stand-in's own argument, not a Build or test deadline.
   Undo: restore the single `timeout_ms: 300` run.
3. Stop mode reuses hang mode's condition loop, which requires the group to be recorded and both pid files to exist.
   Reason: release/1 must tear down a provider that has started, so that the Stop test's pid assertions hold. Sharing the
   loop keeps one READY contract.
   Undo: restore stop mode's group-only wait.
4. The timeout loop is capped at four attempts (300, 600, 1200, 2400 ms); after the last it calls `release/1`, prints one
   line naming the failure, and exits non-zero.
   Reason: the loop must end on its own. The test's `drain_standin` window resets on every progress line and the test
   never kills the stand-in, so without a cap a broken provider leaves the stand-in relaunching providers after the test
   has failed. 2400 ms is the largest doubling below the 5 s drain window, so the test gets `{:ok, 1}`, not `:timeout`.
   The cap counts attempts; it adds no time deadline and changes no test deadline.
   Undo: change the attempt list in the stand-in.
5. After every `run/3` attempt the stand-in exits non-zero if `facts["timed_out"]` is not `true` or the attempt's group
   is still alive (`kill -0 -<facts["pgid"]>` succeeds).
   Reason: a retry would otherwise hide a timeout that fails to reap the group only when the kill lands before
   `grandchild.pid` is written. The grandchild is in that group, so a dead group proves it was reaped even without its
   pid file. `"pgid"` is the key `run/3` returns (`lib/kogen/process_custody.ex` docs, `process_supervisor.py` facts). The
   `timed_out` check also covers an existing gap: the test discards the stand-in's output and never sees `TIMED_OUT=`.
   Undo: drop the two checks from the stand-in.
6. Both `provider.pid` and `grandchild.pid` are deleted before every attempt, not only partial ones.
   Reason: the accepted pair must come from one attempt, and `grandchild.py` can leave an empty file when killed between
   its `"w"` open and write.
   Undo: delete only missing or empty pid files.

## Audit

- Round 1 (Opus high): not ready. Blocking 1 (the loop was bounded only while the test was watching) fixed with a
  four-attempt cap (300, 600, 1200, 2400 ms), then `release/1`, one failure line and a non-zero exit; the risk now says
  the cap counts attempts and changes no deadline. Blocking 2 (a retried attempt's cleanup was never checked) fixed by
  checking after every attempt that the group is gone (`kill -0 -<facts["pgid"]>` fails), plus a non-zero exit when
  `timed_out` is false. Notes applied: both pid files deleted before every retry; the `grandchild.py` `"w"` truncation
  cause added to Why; one shared wait closure before the `case` for hang and stop.

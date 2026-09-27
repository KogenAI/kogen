Verdict: not ready

The diagnosis is right, and so is the design: retry until a timed-out run leaves both pid files, and gate Stop the same way hang mode is gated. That design is deterministic, and a Developer could implement it first try. Two gaps block it on the two points you asked me to check: whether the loop is bounded, and whether it can hide a regression.

**Blocking**

1. **The loop never stops on its own, so it is only bounded while the test is still watching** (`INTENT.md:44-47`, `risks.yaml:9-12`).
   - `drain_standin` restarts its 5 s wait every time output arrives (`test/kogen/process_custody_test.exs:392`). The draft prints a progress line before each retry, so each attempt gets a fresh 5 s.
   - Inside the test this caps things at about 10–15 s: the 4 800 or 9 600 ms attempt is the first one silent for more than 5 s, and the test returns `:timeout`.
   - After that, nothing stops the stand-in. The test never kills its OS process, and `mix run` ignores stdin closing when the port shuts. `on_exit` then deletes `base` (`:24`), so the provider can never write its pid files and the stand-in keeps doubling and relaunching providers after the test has failed.
   - `risks.yaml:11-12` says "must not … add a deadline of its own", which a Developer will read as forbidding any cap.
   - Fix: allow a fixed number of attempts, ending at a timeout below the drain window (e.g. last attempt 2 400 ms). After the last attempt, `release/1`, print one line naming the failure, and exit non-zero (`raise` is enough). The test then fails with a clear `{:ok, 1}` instead of a `:timeout`. This counts attempts, not time, and changes no test deadline. Reword the risk to say so.

2. **A retried attempt's cleanup is never checked, so a regression that only shows up in the early-kill window is hidden** (`INTENT.md:38-42`, `scenarios.yaml:10-13`).
   - The draft deletes the pid files and retries without confirming that attempt's group is dead.
   - A timeout that fails to kill the grandchild whenever the kill lands before `grandchild.pid` is written would pass: attempt N+1 succeeds and attempt N's grandchild stays alive, unobserved.
   - A regression that happens every time is still caught at `:500-501`, since attempt N+1 shows it with pid files present.
   - Fix: after every `run/3`, check that the attempt's process group is gone (`kill -0 -<facts["pgid"]>` fails), and exit non-zero if it is not. The grandchild is in that group, so this proves it was reaped even when its pid file is missing. With this check the retry cannot hide a timeout that "kills without reaping".

**Your other checks**

- **A timeout that never kills:** `run/3` never returns, the attempt stays silent, and `drain_standin` returns `:timeout`. It fails loudly.
- **Killing the leader but not the grandchild, every time:** the successful attempt has both pid files and `:501` catches it. The supervisor's sweep after `wait` (`process_supervisor.py:188-194`) also still runs, exactly as today.
- **Repeated `run/3` calls are safe:** log and register paths are unique per call (`lib/kogen/process_custody.ex:556-561`), so the exclusive log `open` at `process_supervisor.py:152` can't collide. Each group is added to the lock and removed again (`:429`, `:436`), and the final `release/1` leaves no lock file.
- **Nothing else needs to change:** the test, `process_custody.ex`, the supervisor and the fake provider can all stay as they are.

**Notes (not blocking)**

- **Diagnosis:** the timing is right. The clock starts at `:110`, before the log `open` and `Popen`, and the kill lands on the first 0.2 s tick after both the deadline and the child exist (about 0.4 s). There is one more cause the draft doesn't name: `grandchild.py` reopens `grandchild.pid` with `"w"`, which empties the file (`fake_orphaning_provider/grandchild.py:8`). A SIGKILL between that and the write leaves an empty file even after `provider.sh` wrote it. The chosen fix already handles this, because it checks for non-empty content after the group is dead.
- **Wording:** `INTENT.md:40` says "removes any partial pid files", but `:57` says "clearing the pid files". State that both `provider.pid` and `grandchild.pid` are deleted before every retry, so the accepted pair comes from one attempt.
- **Stop mode:** the change is correct. After READY, a SIGTERM hits `grandchild.py` only after it has set SIGTERM to ignored, or kills it before it touches the file, and SIGKILL follows 2 s later. So an empty `grandchild.pid` there is not realistic, the same reasoning hang mode already relies on.
- **Existing gap, not made worse:** the test never checks `TIMED_OUT=true`, because `drain_standin` throws the output away. The stand-in could exit non-zero when `timed_out` is false, alongside finding 2, to cover that without editing the test.
- **Already present, not introduced here:** `await_registration` gives up after about 1 s (`process_custody.ex:566-567`). If that happens, the shared wait loop never sees a recorded group and spins until `wait_for_standin_ready` times out after 10 s. That failure is loud and bounded, so it's fine to leave.
- **For the Developer:** define the shared wait as one closure before the `case`, so hang and stop both use it.

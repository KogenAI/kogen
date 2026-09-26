# Process custody (EXE-03) — probe report

Clone: `$S/kogen` @ 7ed41f66. Scripts: `$S/probe_scripts/`.

## 1. Launch site map (7ed41f66)

| Site | Mechanism | Own group today? | Killed on timeout? | Reaped on stop/crash? | Grandchildren |
|---|---|---|---|---|---|
| `lib/kogen/harness/claude.ex:454-476` `run_with_stdin` | `System.cmd("sh",["-c",cmd],...)`, stdin from a **file**, synchronous | No — inherits BEAM's group | No timeout param at all | Only via normal `after`/control flow | `sh`→CLI→helpers all survive VM death; reparent to PID 1 (this is exactly what happened 2026-09-24, brief 24) |
| `lib/kogen/harness/codex.ex:351-366` same `run_with_stdin` | same | No | No | No | same |
| `lib/kogen/claude_code.ex:409,455` / `lib/kogen/codex.ex:330,361` | `System.cmd` (blocking auth calls) and `Port.open({:spawn_executable,...},[:nouse_stdio,:exit_status])` (terminal path) | Port children get **their own session automatically** (BEAM's `erl_child_setup`/posix_spawn on macOS puts each port in a new session — confirmed by `test/support/process_group.c`'s comment "Erlang gives spawned ports their own sessions") | Port closes on `:exit_status`; no explicit kill | Only if the Elixir process holding the port survives to close it | Port's own session isolates it from BEAM's pgid, but nothing kills it if BEAM dies first |
| `lib/kogen/jev.ex:607` `Port.open` (executable transport) | same Port pattern | same auto-session | Elixir-side `timeout` only cancels the *wait*, not the OS process | No | same risk |
| `lib/kogen/build/verification_runner.ex` (`make check`/live targets) | `System.cmd("python3","-c",@supervisor,...)` where the **embedded Python supervisor** calls `subprocess.Popen(..., start_new_session=True)` for the **target command only** (not itself) | **Yes**, for the target — `start_new_session=True` ≡ `setsid()` applied to the child, so `child.pid` is also the new pgid; supervisor stays outside that group | Yes — `child.wait(timeout=...)`, `SIGKILL` on timeout via `os.killpg` | Yes — settle/SIGTERM/SIGKILL loop after wait, marks `cleanup: failed` if still alive | Reached via `killpg`; the **python3 supervisor process itself** has no such protection — if BEAM is `kill -9`'d, the python3 supervisor (blocking in `System.cmd`) becomes an orphan and keeps babysitting its (correctly grouped) child; only a sweep recovers this |
| `lib/mix/tasks/kogen.expert.ex` | delegates to `Kogen.Harness` role launch (same `run_with_stdin`/Port paths) | No independent mechanism | No | No | same |
| `check.ex:158` `System.cmd("make",...)` (non-Build "make check") | plain `System.cmd` | No | No | No | same |
| write boundary (`build/write_boundary.ex`) | `sandbox-exec -p <profile>` prefixed onto the above argv | N/A (confinement, not custody) — profile is `(allow default)` plus specific denies, so `setsid`/`fork`/`killpg` are **not** blocked (probed, §3) | — | — | — |

## 2. Existing orphan handling (7ed41f66)

None in production code. `grep -rn "reap\|setsid\|pgid\|killpg\|orphan\|sweep"` under `lib/` hits only `verification_runner.ex`'s own supervisor. The **pattern that should generalize** already exists in two places:
- `lib/kogen/codex/state.ex:130-164` — `lease!/1` records `{pid, ps -p PID -o lstart=}`; `active/1` re-reads and treats a record as dead if `ps -p PID -o lstart=` no longer matches (handles PID reuse). No PGID field.
- `lib/kogen/build.ex:255-285` — `.kogen/build.lock` records **only `pid`**, no start time, no pgid; `mix kogen.candidates`/`candidates.remove` manage Candidate worktrees, not processes.
- `test/support/process_group.c`, `isolated_process.py`, `isolated_case.ex`, `shaping_evaluation/driver.py` — full test-only isolation infra (session interposition + `killpg` + descendant reaping for *Erlang's own ports*) that is a good model but is not wired to the controller.

## 3/4. Probe: fake grandchild that ignores SIGTERM, forked from a fake provider

Scripts: `fake_provider.sh`→`grandchild.py` (SIG_IGN on SIGTERM, sleeps 300s), `wrapper.py` (supervisor), `launcher.py` (simulated controller).

**Bug found and fixed in my own first draft**: a naive wrapper that calls `os.setsid()` on *itself* then `os.killpg(own_pid, SIGTERM)` **kills itself before reaching SIGKILL**, leaving the SIGTERM-ignoring grandchild alive. Confirmed directly:
```
python3 -u debug_killpg.py ...  # prints "attempting killpg 3895" then nothing — self-destructs
```
The correct pattern (what `verification_runner.ex`'s embedded Python already does) is: **the supervisor never joins the child's group**; it spawns the child with `start_new_session=True` and targets `killpg(child.pid, …)` only. Fixed `wrapper.py` accordingly.

Results after the fix:
- `kill -KILL -<pgid>` from the shell reaps the SIGTERM-ignoring grandchild **instantly** (`run_killpg`: dead within one `ps` poll, <50ms) — confirms SIGKILL to a process group is not blocked by a SIG_IGN handler for SIGTERM.
- Under the write boundary's actual profile shape (`(allow default)` + the exact deny/allow set from `write_boundary.ex`, run via real `/usr/bin/sandbox-exec`), `setsid`/`killpg`/fork all work unchanged (`run_sandbox4`): wrapper's own natural-exit `kill_group()` reaped the grandchild in ~2.6s (bounded by the fake provider's own 2s sleep), no sandbox denial observed. `(allow default)` is permissive for process operations; only file-write, lsopen and appleevent-send are restricted.
- **Parent-death watchdog**, `kill -9` of the simulated controller (`launcher.py`):
  - `ppid == 1` polling (0.1s poll interval): grandchild reaped in **0.35–0.36s** across two runs (`run_pipeA`, `run_ppidB`). macOS reparents orphans to PID 1 essentially immediately after `kill -9`.
  - A pipe-EOF watchdog (fd 3 held open only by the launcher) was also implemented; in my harness it fell back to the `ppid==1` path due to an fd-plumbing bug in the *test* launcher (not a fundamental problem), so only the `ppid==1` path is validated end-to-end here. `ppid==1` polling alone is sufficient and simpler to reason about on macOS; a pipe/fd-based watchdog is a possible latency improvement but unproven in this probe.
- **SIGTERM to the BEAM itself** (no custom handler installed): OTP's kernel already intercepts it — `elixir -e ...` sent `SIGTERM` logged `"SIGTERM received - shutting down"` and exited via the normal (graceful) application-stop path. This means **Application.stop/1-time cleanup can run for SIGTERM** (and, per the same mechanism, SIGHUP is handleable via `:os.set_signal(:sighup, :handle)` + a `:gen_event` handler on `:erl_signal_server` — not separately probed here but same API family as sigterm). This does **not** help for `kill -9` (uncatchable) or, per below, for SIGINT.
- **SIGINT (Ctrl-C)**: `:os.set_signal(:sigint, ...)` is **rejected** ("invalid signal name") — Ctrl-C is handled by BEAM's separate break-handler (`+B*` flags), not the generic OS-signal API. Default (no flag): shows the `BREAK: (a)bort ...` menu (would block on a real tty waiting for a keypress). `ELIXIR_ERL_OPTIONS="+Bd"`: Ctrl-C is **ignored outright** (process stayed alive after `SIGINT`, confirmed). Neither default nor `+Bd` gives in-VM cleanup-then-exit on Ctrl-C; `+Bc` (untested here, but documented as "abort immediately") likely exits without running Elixir-level cleanup either, since it is BEAM's own abrupt-halt path. **Conclusion: Ctrl-C cannot reliably run in-VM teardown code; it must be covered by the same OS-level watchdog/parent-death mechanism used for `kill -9`**, exactly as the feature brief anticipates.

## 5. Lock reclaim / orphan-identity design

- `lib/kogen/codex/state.ex:130-164` is the reusable pattern: record `{pid, ps -p PID -o lstart=}` at lease time; treat the lease dead if a later `ps -p PID -o lstart=` returns empty or a **different** string (handles PID reuse without extra libraries). Probed directly here (`ps -p $P -o lstart=` → `Sat Sep 26 11:43:39 2026`) — works reliably for the current user's own processes.
- `.kogen/build.lock` today (`lib/kogen/build.ex:255-285`) stores only `{"pid": ...}` — no start time, no pgid. EXE-03 should extend it to `{pid, lstart, pgid, build_id}` (or one record per launched group) so a sweep at the next Build's start can: (a) read the lock, (b) `ps -p pid -o lstart=` to confirm liveness/identity, (c) if dead or mismatched, `kill -KILL -<pgid>` for every recorded pgid before removing the stale lock and admitting the new Build.
- **Env-marker sweep (`KOGEN_BUILD_ID` via `ps eww`) does NOT work on this machine**: probed directly — `ps eww -p <pid>` and `ps -E -p <pid>` show **no environment** at all for the current user's own child process on macOS 26.6.2/Darwin 25.6.0, even though the child was launched with the marker exported. This is very likely SIP/hardened-runtime restriction on `ps`'s environment disclosure (root can still see it via other means, but this Kogen process runs unprivileged). **Recommendation: do not rely on `ps eww`/`ps -E` for the orphan sweep; use the recorded PID+PGID+start-time in controller state instead** (matches `codex/state.ex`'s already-working pattern).

## Recommended mechanism (per exit path)

- **Every launch** (Developer/Reviewer/helper/Jev/verification/`prepare`): spawn via a small supervisor that mirrors `verification_runner.ex`'s existing Python supervisor — the supervisor process stays *outside* the child's group and launches the real work with `start_new_session=True`/`setsid()`-for-child-only; record `{pid, pgid(=child pid), lstart}` in controller state (today: an extended `build.lock`; later: EXE-04's durable table).
- **Normal finish / Stop / timeout**: controller-side `killpg(pgid, SIGTERM)` then `SIGKILL` after a grace period — already proven to work even against a SIGTERM-ignoring grandchild.
- **SIGTERM / SIGHUP to the controller**: catchable via OTP's default graceful-shutdown path (SIGTERM confirmed) or `:os.set_signal/2` + `:gen_event` handler (SIGHUP, same family) — run the same `killpg` sweep from an `Application.stop/1` or trapped-exit callback before the VM exits.
- **SIGINT (Ctrl-C)**: not reliably catchable in-VM (`sigint` rejected by `:os.set_signal`; `+Bd`/default do not run cleanup) — must be covered by the OS-level watchdog, not by BEAM signal handling.
- **`kill -9` of the controller / crash / power loss**: only the OS-level watchdog helps. Confirmed a `ppid==1`-polling wrapper (no external dependencies, pure Python or a tiny native helper) detects controller death and reaps the whole SIGTERM-ignoring group in ~0.35s. This wrapper must sit *outside* every child's own group (own bug found and fixed above) and needs to run once per launched role/target, or once per Build guarding all of them.
- **Startup/Build-start orphan sweep**: read the (extended) lock/state for PID+PGID+lstart of the previous generation; if the owner PID's `lstart` no longer matches (dead or reused), `killpg(pgid, SIGKILL)` for every recorded group, then remove the stale lock and admit the new Build. Do **not** use `ps eww` env markers (does not work here); the PID+lstart+pgid triple is sufficient and already precedented in `codex/state.ex`.

## Limitations / uncertainties

- Pipe-EOF watchdog latency vs. `ppid==1` polling latency was not cleanly separated (test harness fd-passing bug); only `ppid==1` polling (~0.1s poll granularity, ~0.35s observed end-to-end) is proven here. A production implementation should pick one and re-verify under `mix kogen.build`'s real process tree, not just this ad hoc harness.
- SIGHUP-catching-then-cleanup and `+Bc` (Ctrl-C abort) were reasoned from documented OTP semantics and the successful SIGTERM probe, but not independently executed here — flagged as inference, not direct evidence.
- All probes ran as the invoking user, unprivileged, unconfined by any real Build's harness home restrictions beyond the write-boundary profile shape tested in isolation; interaction with the *actual* per-Build Seatbelt profile (KOGEN_WRITE_BOUNDARY marker, scope grants) was not exercised, only its permissive process-op posture.
- No modification was made to `/Users/almirsarajcic/Areas/Kogen/kogen`; all work happened in the disposable clone and scratch scripts under `$S`, and every process started during probing was killed and confirmed gone before finishing.

# Probe: process custody (2026-09-26, clones of main 7ed41f66)

**Launch sites** (`helper-REPORT.md`)
- Roles run through blocking `System.cmd("sh", ["-c", …])`
  (`harness/claude.ex:454`, `harness/codex.ex:351`), with no group and no
  reaping. That is the 2026-09-24 orphan.
- `Port.open({:spawn_executable…})` is used in `claude_code.ex:455`,
  `codex.ex:361` and `jev.ex:607`.
- `VerificationRunner` already uses a Python supervisor that stays outside the
  target's group, starts the target with `start_new_session=True`, and
  `killpg`s it. This is the pattern to generalise.
- `build.lock` records only a pid (`build.ex:255-285`). `codex/state.ex:130-164`
  has the pid plus `ps -o lstart=` liveness pattern.

**Mechanisms** (fake provider ignoring stdin EOF, grandchild ignoring SIGTERM;
`probe_scripts/`)
- `kill -KILL -<pgid>` reaps it instantly, including under a Seatbelt profile of
  the write-boundary shape, where process operations are unrestricted.
- A supervisor that calls `setsid()` on itself and then `killpg`s its own group
  kills itself first and leaves the target alive. The supervisor must stay
  outside the group.
- A `ppid==1` polling watchdog reaps the whole group about 0.35 s after
  `kill -9` of its launcher (two runs).
- `ps eww` / `ps -E` show no environment of the user's processes on this macOS,
  so orphans are identified by recorded pid, pgid and lstart.

**Controller signals** (`pty_signal.py`, `result.txt`: a mix BEAM under a real
pty)
- Ctrl-C with default flags: the BEAM **BREAK menu** appears and the VM stays up.
- Ctrl-C with `ELIXIR_ERL_OPTIONS=+Bd`: it **exits instantly**, with no
  in-VM cleanup.
- Ctrl-C with `+Bc`: ignored, and the VM stays up.
- SIGHUP with `:os.set_signal(:sighup, :handle)`: trapped, and the VM stays up,
  so a handler can tear down and exit. SIGTERM reaches OTP's graceful shutdown
  (helper).
- `erlang:system_flag(break_ignored, true)` returns **badarg**, so break can't
  be disabled at runtime.
- **Relaunch under `+Bd` with a foreground handoff fails**
  (`relaunch-result.txt`). A BEAM port child is started in its own session, so
  `setpgid`/`tcsetpgrp` return EPERM.
- `mise.toml` `[env] ELIXIR_ERL_OPTIONS = "+Bd"` (`pty_mise.py`,
  `mise-result.txt`): `mise exec -- mix run …` exits instantly on Ctrl-C, with no
  menu. The Shaper's zsh has mise activated (`MISE_SHELL=zsh`).

**Limitations**
- The real per-Build Seatbelt profile (with scope grants) was not exercised, only
  its permissive process-operation posture.
- The latency of pipe EOF compared with ppid polling was not isolated.
- Without mise, Ctrl-C still shows the BREAK menu. The watchdog reaps whichever
  way the VM dies.

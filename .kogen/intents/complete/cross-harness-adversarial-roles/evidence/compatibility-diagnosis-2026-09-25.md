# Codex compatibility live test: failure diagnosis (2026-09-25)

Shaping continuation on `main` at `2909f557`. This is read-only diagnosis with no
paid runs. It covers `Kogen.Codex.CompatibilityTest` "selected authenticated
managed runtime passes the bounded compatibility runner", the only failing case
in `live-native` since the GPT-6 upgrade: 1 pass in 9 recorded runs. The raw
Codex rollouts are private harness logs and are not copied here. They are cited
by filename under `~/Library/Application Support/Kogen/codex/accounts/shared/sessions/2026/09/24/`.

## Sources

- Receipts: `.kogen/runtime/scenario-tracking/{YmvihNr7czyNMcN74nMiKW8Y,l5Ur5WAvyOJvG1lpq92XjGv_,GV9FNRgEdJ3Cgr5bT7RR9tXH,btwokrNxL50md1z5Fb-GGYOO}/verification/*/state.json`
- Retained fixtures: `~/Library/Application Support/Kogen/codex/compatibility/compatibility-<ms>-<n>/`
  (`evidence.json` and `fixture/.kogen/runtime/*`, including file mtimes)
- Developer notes of the `upgrade-codex-gpt-6` Build `GV9FNRgEdJ3Cgr5bT7RR9tXH`
  (in `record.json`)

## Which runs were which

| Build | Intent | live-native cycles |
|---|---|---|
| l5Ur5WAv | upgrade-codex-gpt-6 (in progress) | 2 failures: Shaping turn, credential store |
| GV9FNRgE | upgrade-codex-gpt-6 (in progress) | 3 failures: credential store, Shaping turn, timeout |
| YmvihNr7 | upgrade-codex-gpt-6 (final, accepted, now on main) | 1 pass |
| btwokrNx | cross-harness-adversarial-roles | 3 failures: timeout ×3 |

## Class 1: credential-store validation (2 runs). Kogen gap, fixed on main

`Kogen.Codex.State.native_projects!` (`lib/kogen/codex/state.ex:84-117`) runs
`priv/kogen/codex/native_settings.py`, which refuses unknown keys in the shared
store's `config.toml`. Codex 0.156.1 started writing
`[tui.model_availability_nux]`. Until the upgrade Candidate allowed that key, every
Codex live test failed within ~1 s. In both runs `NativeHelperLiveTest` failed with
the same message, so this was not a race between concurrent tests. The upgrade
Build's Developer notes report the fix ("the new bookkeeping key"), and main's
`native_settings.py` allows it. The current shared `config.toml` validates. It is
not caused by `discovery.py`, which writes only to the fixture's hostile HOME and
the fixture directory.

Residual fragility, not a current failure: any new native bookkeeping key breaks
every Codex live test until Kogen allowlists it. This is the intended
refuse-unknown policy and is out of scope here.

## Class 2: interactive Shaping turn (2 runs). Kogen bug, fixed on main

Fixtures `compatibility-1790244811993-610` and `compatibility-1790249530525-610`:
`compatibility-shaping.json` shows `marker:false`, `timed_out:true`,
`trust_answered:false` and a ~3.3 KB screen buffer. `pty_driver.py` did not
recognise Codex 0.156.1's trust dialog, whose title is drawn with cursor moves,
so the stripped text reads `Trustthisfolder?`. The dialog was never answered and
the 180 s PTY deadline (`pty_driver.py:21`) expired. The upgrade Build fixed the
match (`pty_driver.py:268-271`, whitespace-stripped, title plus option). Replaying
the captured buffer through the fixed matcher shows it would now be answered.
Earlier occurrences with the same signature (09-10, 09-19) predate the upgrade.

## Class 3: native turn timeout (4 runs). Budget too small; no stall found

`bounded_exec.py:196` kills any non-Shaping turn at `KOGEN_BOUNDED_EXEC_TIMEOUT`,
which defaults to 240 s. Neither the runner nor the test overrides it.

| Failing turn | Rollout (thread id) | Profile | Elapsed at kill |
|---|---|---|---|
| GV9F cycle 3, initial Reviewer | `01a0d33a-5042-7302-825f-e98f2a22459c` | gpt-6-sol / high | ~237 s |
| btwok cycle 1, initial Reviewer | `01a0d3bb-fede-7272-84dc-debf3d9e8b6a` | gpt-6-sol / high | ~232 s |
| btwok cycle 2, Developer | `01a0d3c3-524f-7c42-add8-4397ec4b5733` | gpt-6-sol / medium | ~227 s |
| btwok cycle 3, initial Reviewer | `01a0d3cc-9257-7a70-8d72-9f2c05ba4c7d` | gpt-6-sol / high | ~219 s |

Each failing turn made 6–16 legitimate read commands (`rg --files`, `find`
listings that include `.git/objects`, `cat` of receipts and history) and was
killed before emitting its verdict. There was no loop and no idle stall. The
Reviewer turns also emit a premature schema-shaped verdict message early, then
keep exploring.

`exec_command failed ... exec-server rejected request (-32603): No such file or
directory (os error 2)` appeared once (Developer rollout above, line ~59). The
model retried the same command about 30 s later and it succeeded. That cost time
but did not cause the failure. The string "skill package is not available"
was not found in any of the four failing rollouts, so it is not established
as a cause.

## Measured turn times (small n; indicative)

Passing run `compatibility-1790250975117-3`, from fixture mtimes and rollouts:

| Turn | Profile | Seconds |
|---|---|---|
| discovery probe | none | ~2 |
| Shaping (PTY) | sol / medium | 17 (other passing cycles: 7 and 62) |
| Developer + Stop Check | sol / medium | ~90 |
| initial Reviewer | sol / high | ~224 |
| Developer resume + scout helper | sol / medium | ~65 |
| final Reviewer | sol / high | ~196 |
| **total** | | **~603** |

The Reviewers take about 7 of the 10 minutes. A successful Reviewer turn has only
~15–45 s of margin under 240 s.

## Conclusion

On main's code only Class 3 remains. It is a Kogen budget and prompt-shape
problem, not provider flakiness: two sequential high-effort Reviewer turns that
explore the fixture broadly land at 196–237 s against a 240 s cap. The ExUnit
cap (`@tag timeout: 900_000`, 15 min) and the Shaper's ≤15-minute ceiling
(2026-09-25) leave no room for a full rerun unless a run gets shorter.

## Limitations

- Sample sizes are 1 passing run and 4 timeouts, so the timings are indicative.
- The shaping-stall runs left no rollout, so Class 2 rests on the PTY capture and
  the receipt, plus the upgrade Build's fix.
- There was no systematic timing survey before the upgrade.

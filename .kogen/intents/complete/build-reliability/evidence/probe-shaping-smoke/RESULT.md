# Probe: live-shaping-smoke design, run for real (2026-09-26, clone of main 7ed41f66)

The prototype adds a `smoke` case to `test/support/shaping_evaluation/driver.py`,
outside `CASES`, so the 7-case suite and its barrier are unchanged:
- a one-file greeting fixture (`smoke_files()`);
- one scripted answer (`SMOKE_ANSWER`) and a trigger that grades nothing;
- a `smoke` branch in `compact_prerequisites.py`.

It was run with the owner test's environment (the runtime dir and parser code
paths):

    python3 -B test/support/shaping_evaluation/driver.py smoke

| Run | Change | Result | Wall |
|---|---|---|---|
| 1 (`run1-claude-trust-hang/`) | none | **Hung** at Claude Code's "Yes, I trust this folder". `shape_transport.exp:66` spawns plain `mix kogen.shape`, so it starts the fixture's `default_route` (`claude`, since 6cdb2912), while the driver captures Codex. Main's transport has been broken this way since 6cdb2912. The unbuilt shaping-preflight-audit Candidates (stashes 3-5) carry the `--route` fix. Killed by the root. | n/a |
| 2 (`run2-codex-medium/`) | transport passes `--route codex` | PASS on mechanics: completed, 1 scripted reply, 2 task_complete (304 s and 389 s), one root, profiles matched, Draft saved, baseline unchanged, all reaped, exit 0. Too slow: the model wrote a full Draft package (307k input tokens). | 410 s |
| 3 (`run3-codex-low-minimal/`) | plus smoke fixture config Codex shaping effort `low`, and a transport-smoke request (minimal Draft, plain-text question, don't inspect lib/priv/test) | **PASS:** completed, 1 scripted reply, 2 task_complete (96 s and 136 s), one root, profiles `gpt-6-sol`/`low` matched, Draft saved, baseline unchanged, all reaped, exit 0 | **156 s** (case 151 s) |

**Chosen design:** run 3. The owner test bounds the case at 300 s, about twice
the measured time.

**Limitations**
- One sample per variant.
- In run 2 the model used the question widget despite the transport's
  plain-text instruction, and the driver still completed.
- Replay feasibility is in `replay-probe.txt`: the real `driver.task_complete_count`
  over retained rollouts.

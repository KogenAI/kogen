# Shaping investigation

Actual checkout: main, 1843dcfaf8b0b7c9d9f91d5c3e8ca92f41633fcb; tracked worktree initially clean. README and .kogen/config.yaml read first; outer_resumptions is 2 and Makefile declares check/live.

- lib/kogen/build.ex:559–614 embeds scenarios, risks, handoff, snapshots, history and retained finding evidence under KOGEN_TRACKING_CONTEXT. Developer renderer at 946 also embeds Intent/scenario YAML. Reviewer rework at 407 serializes its response.
- lib/mix/tasks/kogen.shape.ex:37–79 renders instructions and execution metadata. It does not embed selected Draft bodies. priv/kogen/prompts/shaping-continuation.md already instructs reading maintained Draft paths and preserves incomplete optional content.
- test/support/scenario_lifecycle_harness.py currently parses inline context; ordinary verdict modes depend on mode/review count. Such modes are valid existing controller controls, but cannot alone prove semantic file discovery. A new discovery control must derive its verdict from read source and linked requirement bytes.
- lib/kogen/build/tracking.ex provides existing on-disk state and checks controller-owned exact bytes. No new record storage is needed.
- Prior serial-intent-plan/probe-slice1/criteria.json froze bf68fd70. The checkpoint records static success, 182/183 tests and unfinished real-engine publication. apply_slice1.py assumes older profile/template state and unaccepted Candidate files. Do not reuse unchanged on this baseline.

A configured scout (gpt-5.6-luna, low, explorer) independently located Shape paths. Its suggestion to put discovered marker bytes into prompts contradicts the selected no-inline contract and is rejected; assert stable prompts and changed file-derived consumer behavior instead. No scout output establishes acceptance.

Python PyYAML is unavailable locally; use the repository's YamlElixir parser to validate authored YAML. No dependency installation is needed.

Updated proposal reread at the Shaper’s request: Routine engineering decisions supersedes the prior lifecycle-question requirement for this slice. No storage, retention or ownership transition is introduced.

Readiness work completed: see proof-result.md and proof-result.json. A configured worker (gpt-5.6-luna, medium) prepared only the bounded disposable prototype; root corrected consequential defects, authored the Draft and proof orchestration, inspected receipts and owns integration. No helper approved an Intent.

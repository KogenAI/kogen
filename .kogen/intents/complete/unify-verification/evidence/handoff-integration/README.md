# Handoff integration investigation — 2026-09-14

## Baseline and retained evidence

The Shaper reported structured handoffs completed and requested renewed unification shaping. HEAD is c1c9d13747d7287a7e23f02aca02d67f0467b010 on main, with a clean tracked tree. Root inspected README, the complete handoff contract/decisions, actual source diff and retained tracking. A read-only configured scout identified affected fixture/audit changes. No production source was written.

`accepted-handoff-evidence.json` records the digest-bound source and concise observations. The complete handoff record has three attempts, passed check/live receipts, final accepting Review and F1 closed. Its top-level controller was the pre-change runner, so it does not contain developer_invocation. Two exact-byte nested native records retained by the accepting Reviewer do contain current-code schema/message receipts: one accepted fresh attempt and one failed/accepted two-attempt chain. Their hashes match (the repository stores uppercase hexadecimal). This evidence remains in the completed package; no unchanged success was rerun merely for a fresh receipt.

Current Build launches through launch_build_developer/resume_build_developer and retains structured output. receive_developer handles structured-output errors before settle, so a future exhausted Stop must be checked before those errors can consume outer rework. Contract.handoff validates semantics; it does not certify gate success. The completed handoff decisions explicitly record the Shaper choosing the existing shared outer budget.

## New uncertainty and actual probe

Question: Does continue:false still terminate after two blocked Stop callbacks under the newly installed structured Developer route, and what does the actual consumer observe? This could change termination routing and preservation tests.

`consumer.exs` loads current Harness, DeveloperHandoff and Contract source into memory with existing installed dependency code paths. It calls the real launch_build_developer function and current semantic consumer. `probe.py` creates owned Git fixtures, harmless check/live targets and a custom Stop callback. It never implements production unification or runs the project's make gates. Every run retains command/source hashes, schema, prompt, callback input/output, consumer result and exact invocation bytes. Temporary paths are inside each owned fixture; Git metadata is removed after process exit.

First `rehearsal-exhaust` and `rehearsal-pass` failed before invocation because the source loader lacked Mix project context needed by Boundary. They are invalid experiments, not behavioral failures. Their stderr/commands remain and `consumer-before-mix-context.exs` preserves that input. Inspection of Boundary.Definition established the missing prerequisite. After adding Mix.start and loading mix.exs without executing Mix tasks, fresh `rehearsal-fixed-*` runs passed using a fake executable that actually invokes the callback three times and honors block/continue:false. These rehearsed the source consumer and fixture sequence before paid runs.

Then `native-exhaust` and `native-pass` ran the actual installed Codex 0.154.0, configured Developer gpt-5.6-sol/low, through the same current-source Harness. Both exited zero with three callbacks, a current structured final file, and a semantically accepted handoff. Exhaust returned continue:false after three live failures; the paired control returned continue:true after live passed on the third cycle. Exactly two Stop-blocked continuations preceded each result. See summary.json and each stops.jsonl/invocation.json.

Conclusion: native structured output does not distinguish failed verification from success. The new Build must settle bound terminal exhaustion before handoff success or structure-correction routing. A correct schema and even a semantically valid handoff are not gate evidence.

## Limits and reproduction

These are source-bound Harness/schema/Contract and native Stop feasibility observations, not execution of the future unified public Build. Source accounting, target-evidence forwarding, full Review/commit and timeout cleanup still require actual implementation fixtures and the declared check/live gates. The probe uses a custom hook and harmless targets; it does not manufacture an application defect or provider outage. The successful native calls demonstrate actual account access for this probe only. Normal provider logs/session storage remain provider-owned; all necessary observations are retained here.

To repeat for a changed capability, copy the probe sources into a fresh owned directory and run from repository root with Python, Elixir, installed dependency beams and authenticated Codex. Use fresh names beginning rehearsal and ending exhaust/pass, inspect them, then fresh native names ending exhaust/pass. Each invocation is capped at 150 seconds; on expiry the driver signals its owned process group. Never overwrite these results. Inspect failed outputs before choosing a corrected follow-up. Do not run the historical finalize_draft.py file, which records an earlier package-writing step rather than a maintained workflow.

# Shaping investigation — 2026-09-13

Baseline: main at d8daec8a9e572ab4dd916cc6efe1d1cdfccc21e7. Initial tracked
working tree was clean. Read README first, config, Makefile, maintained check
workflow, supplied follow-up/serial workflow, original suite proposal and relevant
scenario/risk/decision sections. Historical source inventories are advisory.

## Observed scheduling

`test/test_helper.exs` sets max_cases to online schedulers. Live selection has six
cases in four async modules. Two connected/rework cases share
`test/kogen/live_shape_to_build_test.exs`; primitive and semantic cases share
`test/kogen/live_test.exs`. Native-helper and cold-offline have their own modules.
ExUnit schedules modules concurrently, not cases inside the same module.

Ran the preserved `scheduling-probe.exs` directly using installed Elixir 1.20.2 /
OTP 29, once with `PROBE_LAYOUT=same`, once with `PROBE_LAYOUT=split`.
[Same-module output](same-module.txt): two passes, overlap=false.
[Split-module output](split-modules.txt): two passes, overlap=true.
The monotonic intervals confirm the assumption on this environment. The synthetic
150ms workload is not a suite benchmark and does not exercise Kogen's child
supervisor; the Build must add the composed isolated-process rendezvous control.

Reproduce from repository root:

```
PROBE_LAYOUT=same elixir .kogen/intents/drafts/parallel-live-suite/evidence/scheduling-probe.exs
PROBE_LAYOUT=split elixir .kogen/intents/drafts/parallel-live-suite/evidence/scheduling-probe.exs
```

After approval/Complete relocation, substitute this evidence directory's actual
path. Both runs must exit zero and report the expected distinct overlap result.

## Native stream structure and failure retained

Ran [receipt-probe.py](receipt-probe.py) once, read-only against the named
historical model-delegation run. [Output](receipt-probe.txt) preserves file/session
locators and structural findings without copying account transcripts.
The connected run has Developer and Reviewer `thread.started`, `turn.completed`
and usage maps, with structured Reviewer fields. The rework run has two captures
of the same Developer thread and a completed first Reviewer. Its final Reviewer
capture `raw-stream-92049-20.jsonl` lacks completion and structured verdict.

That historical incomplete capture is retained as a negative observation, not
rerun or reclassified as successful. No assertion is made that those historical
runs passed or that current live replacement is already proven. The proposed
native audit must reject absent completion, not accept another capture's success.
This probe inspects shapes; it is not the future schema/identity validator.

## Delegation and correction

One read-only scout was launched with native explorer, gpt-5.6-luna, low effort.
It mapped case chains and proof owners. Its claim that all six cases could already
overlap was contradicted by the actual ExUnit probe above. Root rejected its
recommendation to serialize the suite; that would oppose the requested outcome.
Its suggested `--dry-run` flag was not verified and was not executed or adopted.
Root integrated only the source-backed inventory and authored this Draft.

No provider-backed test suite was launched, no source implementation was changed,
and no gate was invoked. There was one helper investigation; exact root/helper
usage accounting is unavailable, not zero. No complete-task savings are claimed.

## Acceptance still required

Current check/live receipts, actual isolated-process overlap, exact assertion
migration, end-to-end audit failure propagation and maintained documentation are
Developer/owner work after explicit approval. Existing gate ownership and attempt
limits apply. Raw logs stay in their existing ignored locations; no new report
hosting or retention mechanism is introduced by this execution receipt.

Draft validation: the initial Python YAML check could not start because PyYAML
is not installed (`ModuleNotFoundError: yaml`). No dependency was installed.
A subsequent check with installed Ruby YAML parsed all four YAML files and
verified required scenario fields, declared check/live target values, unique
scenario IDs, risk links, all eight ownership string fields and reference paths.
This is a corrected validation method, not a rerun of a failed feature test.

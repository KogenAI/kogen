# Readiness-policy intervention results

Status: both fresh native arms completed; no retries. The strict baseline failures
remain preserved under `../corrected-role-semantics/` and are not reclassified as
infrastructure failures.

## Execution

Both outputs are schema-valid and pass the canonical Kogen-field validator. Both
fixtures remain clean. Each process exited 0 within 240 seconds, reported one native
root and no helper, and completed cleanup with no survivors.

| Profile | Session | Seconds | Input | Cached input | Output | Reasoning |
|---|---|---:|---:|---:|---:|---:|
| Astra low | `01a08f88-90a2-7542-9483-0b01e9d9c5e5` | 159.05 | 107,879 | 84,096 | 4,534 | 41 |
| Sol medium | `01a08f8b-2641-7051-ada6-f6aa87b17176` | 180.38 | 155,157 | 127,616 | 8,612 | 3,848 |

These are cumulative native counters. Exact argv, rollout telemetry, timestamps,
and cleanup are retained in each `runs/*/receipt.json`.

## Prompt-delta evidence

`verify_prompt_delta.py` proves that removing the single marked policy appendix
produces the exact corrected-baseline prompt hash for each arm. The original
unlaunched tailored intervention and manifests remain under
`prior-unrun-tailored/`; they were never sent to a provider.

## Semantic assessment

The general policy corrected the shared readiness failure in both outputs. Each
explicitly reports absent `mix.exs`, `lib/`, and `test/` scaffolding and identifies
the full `check` and `inspect-live` bodies as echo-only, non-verifying targets. Each
keeps the candidate blocked or unresolved rather than treating declaration or target
success as Build-readiness evidence. Both preserve canonical permitted-mutation
paths, bare targets, receipt authority, safe-ID handling, role-distinct snapshots,
the human-owned path-display decision, and the bounded scope.

Astra no longer reserves the literal `latest` ID. It restricts only latest shorthand
or implicit selection and gives no scenario saying a safe exact `latest` ID is
invalid. Thus the unsupported baseline restriction did not recur.

Sol medium explicitly handles `latest` as a syntactically valid exact ID and reports
it nonexistent only because the probed exact path is absent. That behavior matches
the supplied contract. However, its required `probe.open_finding_ids` value is
wrong: it reports question/risk IDs rather than the observed runtime finding
`["F-2"]`. The scenarios and investigation elsewhere correctly say F-2 is the sole
open runtime finding, so this is an internally inconsistent mandatory probe result
and a strict substantive failure under the frozen investigation criterion. It is a
valid model failure and is not retried.

Astra reports `probe.open_finding_ids` as `["F-2"]` and has no comparable source-fact
contradiction observed in full-output review. Its ten scenarios are acceptable;
scenario count itself is not a grading criterion.

## Result and limits

On this one abbreviated structured diagnostic, Astra low satisfies the frozen
semantic requirements after the general prompt intervention, while Sol medium fails
the mandatory probe-fidelity requirement despite improving readiness handling.
This supports the readiness instruction as a useful shared policy lever and does not
show that every Sol-medium shaping task will fail or every Astra-low shaping task
will pass. The experiment still confounds model and effort and does not reproduce a
full interactive production shaping conversation. All baseline and intervention
requests remain part of total experiment cost.

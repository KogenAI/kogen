# Parallel implementation probe v2 results

Executed once on 2026-09-11 in the frozen order local then delegated. Both roots exited successfully within the uniform 600-second limit, cleanup found no survivors, and the withheld oracle passed every normalization, interval, merge and integration check in both worktrees. Each arm changed exactly the four permitted files; contracts and tests remained unchanged.

| Observation | Local Sol-low | Delegated Sol-low root |
| --- | ---: | ---: |
| Elapsed root session | 145.35 s | 176.96 s |
| Oracle | all sections pass | all sections pass |
| Changed files | four permitted | four permitted |
| Root cumulative native input | 161,304 | 250,447 |
| Root cached-input subset | 132,992 | 209,408 |
| Root cumulative native output | 6,405 | 3,313 |
| Root cumulative native total | 167,709 | 253,760 |

The delegated root was 31.62 seconds slower in this ordered pair. This latency is descriptive: the local arm always ran first, provider load was uncontrolled, and helper startup, work, waiting, integration and verification are bundled.

## Delegated route

Native rollouts prove one Sol-low root and three fresh Terra-medium children with distinct thread IDs and disjoint writes:

| Worker | Owned file | Duration | Native input | Cached-input subset | Native output | Total |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `/root/normalize` | `normalize.py` | 33.68 s | 113,537 | 92,928 | 1,135 | 114,672 |
| `/root/intervals` | `intervals.py` | 68.48 s | 215,702 | 189,184 | 2,562 | 218,264 |
| `/root/merge` | `merge.py` | 100.42 s | 197,775 | 181,248 | 4,326 | 202,101 |

The first child started 16.13 seconds after the root rollout began; the third started at 28.77 seconds. All three were active together for 21.03 seconds. The complete helper window was 113.07 seconds versus 202.58 seconds for the arithmetic sum of child durations. During their overlap, the root inspected and implemented `pipeline.py`, so the overlap represents useful disjoint work rather than an arbitrary wait.

Captured child patch calls touched only the assigned module in all three cases. Children did not patch sibling modules, pipeline, tests or the contract. The root later inspected all four diffs and ran visible tests plus focused cross-module negative controls. Its final report records no integration rework. The merge worker corrected issues within its owned implementation before handoff; that work and usage remain in its session.

Arithmetic across separately captured delegated sessions is 777,461 input tokens, including a 672,768 cached-input subset, and 11,336 output tokens, for 788,797 total native tokens. The local session recorded 161,304 input, including 132,992 cached, and 6,405 output. These are cumulative native per-session fields; cached input is a subset of input. They are not invoices, subscription usage or a scalar savings score.

## Local route

The local root implemented all four files and passed the frozen oracle. During its focused checking it first used an incorrect expected value for a transitive-overlap example, recognized that the implementation correctly preserved only true adjacency, corrected the in-memory expectation and reran checks. This did not alter the frozen oracle, contract or tests, and its time/usage remain included.

## What this establishes

This pair demonstrates that a Sol-low root can launch three correctly profiled Terra-medium workers on genuinely independent implementation modules, overlap all three with useful root integration work, preserve disjoint ownership, integrate without root code rework, and produce an oracle-correct result. The equally correct local root completed sooner and used far fewer cumulative native tokens in this instance.

One ordered pair cannot establish typical speed, model superiority, or a causal concurrency benefit. The task was a small synthetic Python feature with settled interfaces, no merge conflicts and a bounded oracle. The frozen oracle covers its named semantic boundaries but is not exhaustive for every malformed Python object or Unicode edge case. Preparation of the fixture, harness and oracle is real experiment overhead not present in the native session totals.

## Evidence map

- `protocol.md`, `deadline-amendment.json`, `preflight.json`: frozen design, 600-second amendment and offline audit.
- `oracle-preflight.json`, `reference-receipt.json`, `wrong-*-receipt.json`: known-correct and seeded-wrong oracle controls.
- `launch-plan.json`, `manifest.json.runner-started.json`: exact ordered argv and one-shot launch record.
- `runs/*/receipt.json`, `runs/*/rollouts/*.jsonl`: terminal state, cleanup, actual profiles/IDs, timing, usage and tool evidence.
- `oracle-local.json`, `oracle-delegated.json`, `analysis.json`: post-run deterministic grading and route audit.

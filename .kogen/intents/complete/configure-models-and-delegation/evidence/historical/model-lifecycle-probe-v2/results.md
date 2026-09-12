# Native lifecycle comparison results

All three frozen arms completed the real Kogen Build lifecycle and pass the corrected strict postflight. The Sol launch originally returned nonzero only because the first oracle used an over-specific documentation string; the corrected owner-held oracle accepts the unchanged Sol candidate. That collector defect is retained in the raw evidence and is not a model failure.

| Controller policy | Strict protocol | Semantic oracle | Published | Stop failed → passed | Review rework → exact resume → fresh accept | Root calls | Elapsed | Natural substantive findings |
| --- | --- | --- | --- | --- | --- | ---: | ---: | --- |
| Astra low | PASS | PASS | yes | yes, same Developer session | yes | 5 | 503.12 s | none |
| Sol low | PASS | PASS | yes | yes, same Developer session | yes | 4 | 443.50 s | none |
| Terra medium | PASS | PASS | yes | yes, same Developer session | yes | 5 | 544.95 s | one valid JSON integer-limit error-path defect, repaired before acceptance |

The first Reviewer in every arm inspected the substantive implementation and described its validation, normalization, conflict, ordering, serialization, and atomic-output behavior. Astra and Sol found only the controlled missing `REVIEW_NOTES.md`. Terra additionally found that `json.load` can raise `ValueError` for an oversized integer, which would have escaped with exit 1 instead of the required concise exit 2; the exact resumed Developer repaired it and the fresh Reviewer accepted. The controlled omission establishes lifecycle transport, not general Reviewer discrimination. One sample and a bundled controller/Developer/Reviewer policy cannot isolate causal per-role quality.

| Controller policy | Root input / cached / output / reasoning | Successful helpers | Helper input / cached / output / reasoning | Combined recorded input / cached / output / reasoning |
| --- | --- | ---: | --- | --- |
| Astra low | 1,090,610 / 908,672 / 8,207 / 118 | 2 | 476,242 / 403,968 / 4,711 / 1,225 | 1,566,852 / 1,312,640 / 12,918 / 1,343 |
| Sol low | 1,140,429 / 996,352 / 12,406 / 2,409 | 3 | 898,427 / 736,768 / 7,020 / 1,355 | 2,038,856 / 1,733,120 / 19,426 / 3,764 |
| Terra medium | 1,956,186 / 1,761,024 / 18,646 / 4,812 | 5 | 1,298,888 / 1,110,528 / 14,215 / 3,030 | 3,255,074 / 2,871,552 / 32,861 / 7,842 |

Root usage subtracts the previous cumulative terminal snapshot on exact-thread resumes. Helper usage is the terminal total of each distinct child thread. The combined column adds those separately recorded counters; it is an accounting inventory, not a dollar charge or proof of provider billing semantics. No dollar cost was exposed by the native receipts. Every copied successful helper reports its requested Luna-low or Terra-medium profile and a terminal `task_complete`. Failed spawn attempts from the invalid `scout` role created no helper thread or token receipt: Sol had two and Terra had one.

Astra and Terra used five root calls because their initial Developer handoff represented the deliberately absent review artifact with an empty `implementation` list. The production contract gate rejected that structured handoff before Review as missing/invalid scenario coverage. Their exact Developer thread resumed, cited an existing implementation reference, passed Check again, and then entered the intended Reviewer rework cycle. Sol supplied a valid reference initially and used the expected four calls. This extra Astra/Terra call reflects avoidable handoff formatting, not semantic implementation failure. A clearer prompt or structured-output validation before handoff could remove it while preserving the contract gate and never reusing review acceptance.

On this single lifecycle, Sol low finished fastest and with one fewer root call; Astra low had the lowest combined recorded tokens; Terra medium spent the most time and tokens but was the only policy whose Reviewer surfaced an uncontrolled substantive defect. Rate-aware complete-execution estimates are reported separately in `economics.md`; raw-token totals should not be used as price comparisons. These are advisory observations, not a stable ranking. The externally supplied benchmark motivating Terra was VulcanBench; the frozen protocol's “V2 Agent Bench” label is a wording error and has not been used as evidence about Kogen performance. The three measured arms ran sequentially without another measured campaign deliberately sharing their slot. Other root-level native work was observable globally during parts of the run, so elapsed times can still include ambient contention and provider-time drift.

The retained strict receipts are each arm's `evidence/postflight.json`; descendant attribution is in `descendant-audit.json`; complete execution economics are in `economics.md` and `economics.json`; full root and helper rollouts remain under each arm's `evidence/rollouts/` and `evidence/helper-rollouts/`.

# Helper candidate comparison v2 results

The corrected six-arm campaign completed serially with exit 0, no timeout, and no surviving owned process in every arm. Owned child rollout `turn_context` confirms all six requested model/effort profiles. Raw root answers are `runs-corrected/<case>/answer.txt`; receipts and root/child rollouts are beside them. Exact locators, final cumulative counters and the cache-aware arithmetic are in `economics-corrected.json`.

| Pair | Arm | Quality result | Citation/write qualification | Elapsed | Root API estimate | Child API estimate | Arithmetic combined |
|---|---|---|---|---:|---:|---:|---:|
| Scout | Terra-low | Factual pass; strict overall fail | Citation fails: one wrapped line | 65.4 s | $0.0586 | $0.0713 | $0.1299 |
| Scout | Luna-low | Factual pass; strict overall fail | Citation fails: reconstructed quotes; native non-`-B` probes wrote `__pycache__/` | 77.0 s | $0.0895 | $0.0079 | $0.0973 |
| Worker | Terra-medium | Semantic and route pass | Native status showed only permitted `merge.py`; later oracle created cache | 120.1 s | $0.0484 | $0.1255 | $0.1739 |
| Worker | Luna-medium | Semantic and route pass | Native status showed only permitted `merge.py`; later oracle created cache | 125.9 s | $0.0723 | $0.0158 | $0.0881 |
| Expert | Sol-medium | Bounded semantic pass | Finds and repairs all three supplied categories | 80.7 s | $0.1020 | $0.1237 | $0.2257 |
| Expert | Astra-medium | Bounded semantic pass | More precise assertion-masking counterexample; adds incomplete-lifecycle control | 103.9 s | $0.1442 | $0.3999 | $0.5440 |

The coordinating root's `semantic-adjudication.md` owns ordinary-meaning assessment. Both Scouts got the facts right but neither met the exact path/line/quote contract, so neither is an unqualified strict pass; Luna also violated the no-write rule through native non-`-B` probes. Both Workers produced oracle-correct implementations and complied with the native file boundary. The initial postflight attributed their `__pycache__/` directories to the helpers, but timestamp and command evidence in `cache-attribution.md` proves the later oracle created them after both native arms. Both Experts passed the supplied-category diagnosis/repair task. Because the prompt named all three categories, this is not blind discovery or evidence of general expert reliability.

The estimates apply the dated `cost-method.md` rates to each session's final cumulative usage event, with cached input treated as a subset and zero observed cache writes. Root and child estimates remain separate; the combined column is arithmetic only. They are API-equivalent estimates, not invoices, subscription allowance, or total research cost. The invalid first Scout pair and interrupted Worker-Terra attempt are additional research cost and are excluded from the matched corrected table; the interrupted attempt has unavailable usage and is not treated as zero.

One observation per arm supports only reversible, role-specific trials. It does not estimate reliability, provider-time variation, or a universal model ranking.

# Composed policy v6 result

## Outcome

V6 produced a **valid Git-identity gate failure**, retained without retry. All six native calls completed successfully; the Build ended after 713.48 seconds, before its 900-second limit, and wrote a cleanup receipt. The final fresh Reviewer returned `accept`, and the withheld semantic oracle passed, but a Reviewer helper mutated the Git-visible Candidate during Review. Kogen correctly aborted before publication. No Complete Intent or clean-Git publication exists.

This quality integration run overlapped separately owned Shaping probes by predeclared amendment. Its time, tokens, and cost are descriptive and support no causal timing ranking.

## Lifecycle gates

| Gate | Result |
|---|---|
| Stop failed then passed | Pass, exact initial Developer session |
| Controlled Review finding | Pass |
| Exact resume and fresh Review | Pass |
| Natural substantive finding | Pass: temporary cleanup `OSError` was suppressed |
| Second exact resume | Pass |
| Fresh final verdict | `accept` |
| Semantic oracle | Pass |
| Reviewer Candidate identity | **Fail** |
| Publication / Complete / clean Git | Fail / absent |
| Process cleanup | Pass |

The final-finding sequence used three distinct Terra-medium Reviewers and one persistent Sol-low Developer session. The final Reviewer accepted the repaired implementation, including the feasible behavior of surfacing a cleanup failure when the filesystem makes residue removal impossible.

## Exact mutation and attribution

The only tree difference during final Review was deletion of `__pycache__/release_manifest.cpython-314.pyc` (8,564 bytes): candidate `92464f6f…` to `63024b77…`. No authored source, notes, or recovery bytes changed.

Final Reviewer helper `/root/manifest_trace` (Luna-medium worker, child `01a08ffe-34d2…`) explicitly reported accidentally running `py_compile`. It incorrectly described the cache as ignored; the fixture `.gitignore` has no Python cache rule and `git check-ignore` returned nothing. The helper then ran `unlink …pyc && rmdir __pycache__`, causing the recorded deletion. Its code-reading conclusion was useful and source-read-only, but its cache creation and cleanup violated the Git-visible Candidate policy. The root Reviewer did not prevent that violation.

## Execution-policy observations

Developer authored-method compliance passed: initial implementation, recovery file, notes, and both reworks used Python; no Developer `apply_patch` appeared.

Nonrecursive evidence compliance passed in all three Developer handoffs. None cited `scenario-tracking/record.json`; they cited concrete implementation and verification sources such as `release_manifest.py`, `REVIEW_NOTES.md`, `stop-recovery.txt`, the approved scenarios, verification history, and Stop log.

Native helper-kind compliance failed at the attempt level: two Reviewer roots first requested unsupported kind `scout`, received explicit errors, then corrected to `explorer`. Five successful helpers used configured profiles and valid kinds, but the strict auditor retains the two invalid attempts.

## Economics

Complete observed execution API estimate: **$2.41511076**, comprising **$1.95529920** for six roots and **$0.45981156** for five successful helpers. Resume counters were converted to deltas; reasoning output was not double-counted. This is an API estimate, not an invoice or accepted-Build cost. Details are in `arm/evidence/economics.json`.

## Interpretation

V6 validates the intended lifecycle, final semantic implementation, Python Developer edits, and nonrecursive repair citations. It fails the integrated policy because final Review altered a non-ignored generated cache and because two invalid helper-kind attempts occurred. An accepting verdict cannot override Candidate identity. No further provider run was made.

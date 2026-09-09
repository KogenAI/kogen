# Reshaping diagnosis — 2026-09-09

Read-only inspection of the stopped candidate and retained real-provider records;
no provider run or implementation edit was made during this diagnosis.

- Root runtime verification.json and stop-check.log record candidate
  0e7f55260ee5993b3750c78718c6c4deebf4f870: 103 offline passed, three excluded,
  seed 930939, complete external wall time 9.62 seconds; internal 9.565 seconds.
  This is historical candidate evidence, not acceptance of subsequent edits.
- Latest failure directory: .kogen/runtime/live-evidence/
  shape-to-build-11051-204-1788966927208547757.
  build-raw-streams/reviewer-verdict-14491-8.json requests the absent notes file.
  Receipts ending -18 and -28 reject missing prior protocol evidence despite
  correct file bytes and a passing Check. The outer live run reports 2/3 passed.
- test/kogen/live_shape_to_build_test.exs:67 puts temporal protocol proof in the
  nested reviewed scenario. Lines 268–274 send raw evidence outside the fixture.
  Lines 311–342 already audit archived Check records, ordered Reviewer receipts
  and Developer identity at the outer test level, after Build succeeds.
- lib/kogen/check.ex:27 invalidates current history for an outer resume and
  :145 archives it under KOGEN_RAW_LOG_DIR. lib/kogen/harness.ex:249 retains
  streams and receipts there. priv/kogen/prompts/reviewer.md:6 gives the fresh
  Reviewer the working tree, without prior transcript. The fixture-local final
  history therefore does not expose the first turn.
- A configured Terra-medium advisory investigation found the actual initial
  rework receipt, same Developer session 01a086bd-0be7-7422-9387-e26989a33cc8,
  and two passing Stop records in archived snapshots. Retention worked;
  the nested fixture assigned proof to a reader without that evidence.
- scripts/check/offline.py currently makes otherwise-passing warm checks fail
  above 9.8 internal seconds. Historical development receipts show considerable
  timing variation. The original requirement states performance acceptance,
  but does not explicitly choose this permanent check exit-status behavior.
- scripts/check/development-evidence.md explicitly leaves cold-cache evidence
  outstanding. No cold-cache success was found in the current verification history.

The OAuth transport errors, rejected patches and heredoc tokenization errors
are operational noise or separate defects; they do not explain the final
Reviewer evidence rejection. No claim is made that every such error is harmless.

# Frozen native rendering comparison

Run from the repository with installed Mix dependencies:

```
python3 test/support/compact_context/compare.py <retained-qualification-directory> <new-evidence-directory>
```

The retained directory must contain `frozen-inputs.json`, `frozen-b2-corpus/`
and the genuine `captured-kogen031-request.txt`. The manifest records the corpus
path. Do not substitute synthetic acceptance inputs. The driver verifies every
manifest file size/hash and the capture hash, exports b2 with `git archive`
(no worktree), then invokes actual native Shape context/tools and provider-body
serialization AST, changing private visibility only in disposable VMs. No auth,
transport, model, setup or readiness execution is performed by this comparison.
The same logical corpus root, slug, configuration, empty answers/history, tools,
instructions and empty cumulative manifest are used in both arms. Output retains
both raw serialized inputs/provider requests, indexes, contexts, logs and receipts.

This is the historical compact-inventory comparison, not the current native Shape
navigation regression. Its after-arm inventory equality assertions describe the
then-current renderer and are superseded for Shape by fixed-shape navigation.
Use `test/kogen/shape_context_test.exs` and the installed `shape-context-index`
journeys for the current contract; Refine inventory and explicit excerpt coverage
remain in the compact-context scenarios.

The genuine capture was recovered at
`/Users/almirsarajcic/Areas/Kogen/studio-work/kogen-repairs/faster-shaping-20261019/context-correction/qualification/`.
Fresh successful evidence is retained at
`.kogen/local/compact-context/review-verification/`; its report is also retained
in `docs/evidence/compact-shaping-context.json`. It preserves all 254 corpus
hashes and the 5307-byte capture, SHA-256
`1ba9d0b42abb6ca476591197b4ea1dcea4de13e67cb9aaba6285d9aca201a0b8`.

Determinism scope: each arm renders twice in the **same VM** with byte-identical
results. An initial cross-VM attempt is retained in `verification-compact/` and
failed byte identity because b2's excerpt-header map key ordering varies between
VMs (sizes, decoded metadata and index were unchanged). No old renderer was
modified or JSON canonicalized to hide that observation. The successful report
establishes repeated rendering determinism within a VM, not cross-VM ordering
of b2 map serialization. UTF-8 bytes are not tokens. There is no live usage,
speed, money, cache savings or total-conversation growth conclusion.

Mandatory settled-answer and large active Refine contracts, explicit excerpts,
199/200/201 signature paging and native HTTP capture are covered by the compact
acceptance harness separately; this frozen initial request has no settled answers.

The report's optional-selection `bytes` counts the actual rendered excerpt bodies
at the native renderer boundary (excluding header lines and joining separators).
`static_selection_body_bytes` separately preserves the original telemetry: b2
clamped excerpt bytes to source size and therefore reported 521611 bytes where
its actual rendered bodies contained 521721 bytes, including synthesized final
newlines. The after arm has zero for both. This does not revise historical
per-call telemetry or infer token savings. Earlier runs remain retained.

# Re-pin of the vendored kogen-loop to 4afed06d and internal research knobs

`cli/third_party/kogen-loop` is now the clean kogen-loop commit
`4afed06da64e348a5a65db6e550f81b65cbe0235`, replacing `c7e8331fd2b4dbf3ae716eba4d93aab792a8c9f6`.
It was written only by `sh packaging/sync-kogen-loop.sh <home>/src/loop-1b8ef1f`
(a clean, detached checkout of that commit); no vendored byte was edited by hand.
`cli/loop-pin.json` records `module=kogen-loop`, `protocol=kogen-loop/v1`, `library=loop/v1`,
`digest=abd53fa2b3d947b51f3f5dfe34169871605d1bc8d7be99f5eb4f01e0334c6567`, `files=123`,
`source_head=4afed06da64e348a5a65db6e550f81b65cbe0235`, `source_state=clean` (previously 111
files and digest `3a53b3b86c6dec827cc721223660bfbac82881403f07a3afb90b443dffd83d7d`).
This is local provenance, not a live-provider qualification and not a claim of any cache benefit.

The revision brings the library options Kogen now exposes internally and L-DOCRANGE ranged
documentation reads: the documentation tool takes an optional `offset` and `find`, and a fetch
result reports `body_total`, `body_offset` and `next_offset`. Those documentation changes are the
vendor's own; Kogen adds no documentation implementation. The documentation tool definition text in
requests changes with the vendored loop; `cli/agent/testdata/defs_golden.json` carries that one
entry. L-TTL is out of scope.

## Internal research settings (historical)

**Historical:** Kogen removed this internal option layer (K-RESEARCH-REMOVE). `cli/internal/research`,
`research.Current` and the settings below no longer exist; their defaults are now plain
construction, and the pin and its public library options are untouched. What follows records the
state at this re-pin.

`cli/internal/research` holds one struct and one zero-valued source (`research.Current`) of
`Tools.ResultBound`, `Tools.ResultHead`, `Documentation.ResultBound`, `Documentation.BodyBound`,
`Client.ResponseBudget`, `InputBudgetBytes` and `AuthorityBoundary` (`*int`, nil disabled). Each
setting is one line there. There is no command, flag, `project.yaml` key or environment variable.
Shape, Refine, init, Build (including Resume), the native builder and the independent Review read
the same source. Kogen's own working-window measurement and the check before each transmission use
the lower input ceiling, and every measured request carries the authority boundary it is sent with.
Startup calls the loop's own checks (`tools.New`, `FailOverBudget` and the client's response
budget) and returns their errors before any provider request; an authority target is refused by the
request preflight in `provider`. With every setting zero, requests, tool definitions, results,
transcripts and checkpoints are what the pinned loop produces; against the previous pin only the
documentation tool definition text differs (`cli/testdata/loop_knobs_golden.json` was rendered
with the previous pin).

Studio record: `kogen/loop-knobs-repin`, provisionally started by `main`.

## History

Earlier pins and their evidence are unchanged: `docs/evidence/k5-loop-repin/`,
`docs/evidence/k5b-loop-repin/` (the `2ea31bf5` pin) and `docs/evidence/extract-loop-executors/`.
Intermediate re-pins are in Git history (`git log -- cli/loop-pin.json`).

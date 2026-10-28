# Re-pin loop and centralize research knobs

Slug: k-pin-knobs
Model: not applicable — library option wiring has no new state machine
Acceptance:
- .kogen/intents/k-pin-knobs/acceptance.feature
- features/steps/k_pin_knobs_steps.js

Re-pin by running `sh packaging/sync-kogen-loop.sh /Users/kogen-runner/src/loop-1b8ef1f` against a clean checkout of `4afed06da64e348a5a65db6e550f81b65cbe0235`; commit its output without hand-editing vendored bytes. The synchronized pin must be module=kogen-loop, protocol=kogen-loop/v1, library=loop/v1, digest=abd53fa2b3d947b51f3f5dfe34169871605d1bc8d7be99f5eb4f01e0334c6567, files=123, source_head=4afed06da64e348a5a65db6e550f81b65cbe0235, source_state=clean. This revision includes L-DOCRANGE ranged documentation reads (optional fetch offset and find, body_total/body_offset/next_offset). Add a short evidence note under docs/evidence/ preserving earlier history. Studio record: kogen/loop-knobs-repin, provisionally started by main. L-TTL remains out of scope.

Introduce one internal Go struct and one zero-valued source of research settings, so each research setting is changed by a one-line patch in one file. Hold exactly Tools.ResultBound, Tools.ResultHead, Documentation.ResultBound, Documentation.BodyBound, Client.ResponseBudget, InputBudgetBytes and AuthorityBoundary (*int, nil disabled). Grouping nested fields is allowed. Do not add unrelated loop options. Apply it at every production construction path, including injected/default clients, Shape, Refine, independent Review, optional Shape workers and the native builder. The named sites include cli/shape/shape.go, cli/shape/refine.go, cli/build/review.go and cli/build/executor_native.go, and the native loop.Round's tools/requester path. InputBudgetBytes belongs to Direct/FailOverBudget and AuthorityBoundary to provider.Request, not to invented Round fields. Kogen's own working-window preparation and complete request measurement must honor the configured lower ceiling and authority marker as well as transmission; do not measure a different request than is sent.

Use loop Validate/New wherever supplied, before any provider request, returning its original error. For options validated only at use, perform the equivalent loop-owned preflight at startup without network/credentials or synthetic inference. Authority target validation is request-dependent and must occur in real request preflight before transport, not by guessing an authority index. Do not duplicate or weaken library constraints. Invalid Tools.ResultHead >= ResultBound must stop before any provider request.

Zero settings retain byte-identical requests, tool definitions, results, transcripts and checkpoints relative to the newly pinned loop defaults. Relative to the previous pin, documentation tool definition text in requests changes only through the vendored loop as expected with this pin; with all knobs zero every other request byte stays identical. Pin-owned documentation result changes remain exactly those supplied by L-DOCRANGE, not custom Kogen changes. No CLI commands/flags, project.yaml keys, environment variables, timeout or limit default changes. Approval, custody, verification, review and single-commit behavior remain unchanged. Use only temporary test directories, no synthetic CPU load, and never stop processes by name/pattern; terminate only owned PIDs.

## Decisions
- Keep all knobs internal with zero defaults and no user-facing configuration. (source: request)
- Use the supplied readable clean checkout /Users/kogen-runner/src/loop-1b8ef1f, now detached at 4afed06da64e348a5a65db6e550f81b65cbe0235. (source: request)

## Source comparison
- Addressed correction: supersede only the old 1b8ef1fd9e702977b0ce6c4f2e02329a80c3dd64 pin, 122-file count and 852f3b195042ef2902f623f82ffbcf3c7be7d14e330aea3c26ccb69442fbaad3 digest with the exact revision and seven pin fields above. The supplied checkout path and sync-only vendoring remain. A scratch sync observed the requested 123 files, digest and clean source HEAD; this is local provenance evidence, not Build verification.
- Addressed original request steps 1 and acceptance pin through TestLoopPinKnobsProvenance and retained TestLoopPin: complete synchronized file set/bytes, exact pin and history-preserving evidence note. L-DOCRANGE is supplied by the vendor; no separate Kogen documentation implementation is authorized.
- Addressed original request steps 2–4 and construction-site acceptance: all seven options, single internal patch point, all named paths, zero/default and invalid startup tests below remain. Contract interfaces remain Direct/FailOverBudget and provider.Request, not invented Round fields.
- Addressed compatibility correction: only vendored documentation tool definition text may change in zero-knob requests against the prior pin; every other request byte remains identical. Zero-knob compatibility of results/transcripts/checkpoints is against the newly pinned defaults, preserving the vendor's L-DOCRANGE result metadata rather than suppressing it.
- No remaining requested behavior is omitted or conflicting. Superseded historical revision/count/digest and old checkout-revision assertion are identified above; all internal-only, safety, approval, custody, verification, review and single-commit boundaries remain. L-TTL stays explicitly out of scope. No cache benefit or live-provider qualification is claimed. Existing acceptance paths, model declaration and executable scenarios remain unchanged.

## Tests
- Exact synchronized provenance, bytes, pin and evidence note: add TestLoopPinKnobsProvenance in cli, comparing the complete vendored file set/bytes to the clean supplied checkout and asserting all seven exact pin fields above and evidence note; retain TestLoopPin (integration)
- Nonzero options reach each real construction site: add TestLoopKnobsShape and TestLoopKnobsRefine in cli/shape and TestLoopKnobsReview and TestLoopKnobsNativeBuilder in cli/build, setting every applicable option independently through the shared struct and observing constructed values and actual local provider/tool behavior; use existing local fake providers, never paid requests (integration)
- Zero settings preserve defaults and exact compatibility: add TestLoopKnobsZeroCompatibility in cli, exercising existing golden/request/result/transcript/checkpoint fixtures and the four entry paths; retain existing compatibility tests unchanged. Compare zero knobs against newly pinned defaults byte-for-byte, and against prior-pin requests allowing only the vendored documentation tool definition text change; every other request byte must match (regression)
- Invalid nonzero settings stop before transport with library errors: add TestLoopKnobsInvalidStartup in cli covering the named Tools counterexample, documentation bounds, input budget and response budget constraints using each library validator's boundary/adjacent cases; authority invalid target tested in request preflight; assert zero provider requests (integration)
- Vendored library remains race-clean: run go test -race -count=1 ./... in cli/third_party/kogen-loop in acceptance, in addition to all configured checks (existing)

## Feasibility
- none

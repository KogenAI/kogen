# Select named harness routes per Shape and Build session

Status: **Approved** by the Shaper in the shaping conversation, 2026-09-23T08:34:31Z.

## Problem

`.kogen/config.yaml` names one global harness and one model/effort set for
every role. The Shaper wants each Shape or Build to run on whichever provider
still has allowance: Claude Code today, ChatGPT through Codex when that
allowance returns, and other combinations later. Today, switching means
editing the tracked config and remembering to switch back. Nothing records
which provider actually shaped or built an Intent, and a config edit while a
Build runs is safe only because the controller happens to read config once.

## Outcome

- `.kogen/config.yaml` defines named **routes** and a `default_route`. A route is
  one `harness` plus `{model, effort}` for `shaping`, `developer`, `reviewer`
  and `helpers.{scout, worker, expert}`. `outer_resumptions` and
  `verification_retries` stay top-level as global Build policy:

  ```yaml
  default_route: claude
  routes:
    claude:
      harness: claude
      shaping:   {model: claude-opus-5-5, effort: medium}
      developer: {model: claude-opus-5-5, effort: medium}
      reviewer:  {model: claude-opus-5-5, effort: medium}
      helpers:
        scout:  {model: claude-sonnet-5, effort: low}
        worker: {model: claude-sonnet-5, effort: medium}
        expert: {model: claude-opus-5-5, effort: high}
    codex:
      harness: codex
      shaping:   {model: gpt-5.6-sol, effort: low}
      developer: {model: gpt-5.6-sol, effort: low}
      reviewer:  {model: gpt-5.6-terra, effort: medium}
      helpers:
        scout:  {model: gpt-5.6-luna, effort: low}
        worker: {model: gpt-5.6-luna, effort: medium}
        expert: {model: gpt-5.6-sol, effort: medium}
  outer_resumptions: 2
  verification_retries: 2
  ```

  This repository's own config is converted to exactly this content. The
  `codex` route restores the Codex profiles committed before `6cdb2912`.
- `mix kogen.shape [--route <name>] [draft-slug]` and
  `mix kogen.build [--route <name>] <slug>` select a route. Without the flag
  they use `default_route`. An unknown name fails before any harness open or
  provider launch, with a message naming the unknown route and listing the
  available route names in sorted order. Other options, extra positional
  arguments and a missing `--route` value print the command's usage line.
- **Validation scope.** Every route is checked for structure: a nonblank
  string `harness` and every role and helper with nonblank string `model` and
  `effort`. `default_route` must name an existing route. Harness support
  (`claude`/`codex`) and the Claude proven-model/effort check apply only to the
  **selected** route. So an unselected route may name an unsupported future
  harness (for example a later `pi-*` route) or an unproven model without
  blocking a session on another route. Selecting such a route fails before
  launch with today's unsupported-harness or unproven-model message.
  Install/login readiness (`Harness.open`) runs only for the selected route's
  harness.
- **Old flat config is refused.** A config with top-level `harness:` and no
  `routes`, or with neither `default_route` nor `routes`, fails before any
  launch. The message says the flat shape was replaced and names
  `default_route` and `routes`. No compatibility reader, deprecation warning,
  migration or synthetic route is added (Shaper's explicit decision).
- **Shaping records the route.** New Drafts record `shaping.route: <name>`
  next to `harness/model/effort/started`. Each continuation appends a
  `shaping_continuations` entry that includes `route`. Continuing a Draft
  first shaped on another route uses the `--route`/default route of *this*
  session. The Draft's original `shaping` block is never rewritten.
  `Intent.read_draft/1` accepts Drafts with or without `shaping.route`, so
  existing Drafts (including this one, shaped before routes existed) remain
  continuable. Approved and Complete Intents are not newly validated for
  `route`.
- **Build records and holds its route.** The Build's scenario-tracking record
  stores a frozen top-level `route`: the name plus the resolved harness and
  every role/helper `{model, effort}` actually used. The Build resolves config
  once. The initial Developer, Stop verification context, every exact-session
  resumption, rework, execution-policy rendering and the Reviewer all use that
  resolved route. Editing `.kogen/config.yaml` mid-Build (removing the route,
  changing its models, or changing `default_route`) does not change any later
  launch in that Build. The Reviewer uses the Build's route; there is no
  separate Reviewer route.
- **No silent fallbacks.** A configured `default_route` is the only default.
  Nothing may substitute a harness, model, effort or route value. The routes
  parser stays strict: every key is required and none has a default.
  - Remove `Map.get(config, :harness, "codex")` (`harness.ex:114`) and the
    catch-all clauses that send any non-`claude` context to Codex
    (`harness.ex:28,34,117`). Dispatch matches only `claude` and `codex`.
    Anything else, including a missing `harness`, fails loudly. Codex
    selections and launch contexts therefore carry `harness: "codex"`
    explicitly; today they are Codex only because the key is missing.
  - Remove the contextless path: `adapter(nil)`, the adapters'
    `with_context(nil, …)` and the `context \\ nil` defaults on the
    `Kogen.Harness` launch and resume functions and on both adapters. Every
    launch receives the session's resolved route through its launch context.
    A call without one fails to compile or fails loudly. It never re-reads
    config.
  - `KOGEN_HARNESS` (`harness.ex:122`, `harness/codex.ex:180`,
    `claude_code.ex:81`, `codex.ex:19`) may only replace the executable of
    the harness the selected route names. It never chooses a harness or
    stands in for config.
  - `ExecutionPolicy.render/2` dispatches on the route's explicit harness,
    with no "not claude means Codex" branch.
  - Live test owners must compile against the changed signatures.
    `test/kogen/live_test.exs` and `test/kogen/native_helper_live_test.exs`
    call `Kogen.Harness` directly. They are excluded under `check`, and an
    excluded test that calls a removed arity only warns. So the `check` test
    stage (`scripts/check/offline.py:223`) becomes
    `mix test --exclude live --warnings-as-errors`, appended so the existing
    `mix test --exclude live` output substring stays
    (`test/kogen/cold_offline_test.exs:117`). `scripts/check/README.md`
    documents the stricter stage.
  - `priv/kogen/codex/discovery.py` fails when the shaping model is missing
    instead of defaulting to `gpt-5.6-sol`. It receives the resolved route
    from `Codex.Compatibility`.
- **Harness setup commands ignore routes.** `mix kogen.{claude,codex}.{install,login,status}`
  never select, require or validate a route, and they work whether or not any
  route uses that harness. Example: `mix kogen.codex.login` works while
  `default_route` is `claude`. Credentials belong to a harness login scope,
  not a route. Claude's commands already ignore config
  (`claude_code.ex:223,340`). For Codex, setup operations explicitly declare
  that they carry no role profiles, and `Environment.prepare` then writes no
  helper-profile files. A role launch without complete profiles fails loudly.
  This replaces today's `|| %{}` / `|| ""` defaults that write empty profiles
  (`codex/environment.ex:180-194`). The project-scope requirement that
  `.kogen/config.yaml` exists (`require_project`) is unchanged.
- **The committed Build output names the route.** `build-summary*.json` gains
  `route: {name, harness}` and `evidence.md` states the route name and harness.
  The route is added as an extra field: the summary and tracking record keep
  `schema_version: 1`, and `Kogen.Build.Evidence` keeps reading existing Complete
  packages that have no route. The full resolved profiles stay in the local
  tracking record.
- **Codex-only live owners select the Codex route explicitly.**
  `test/kogen/codex_native_live_test.exs`, `test/kogen/native_helper_live_test.exs`
  and `test/kogen/codex_compatibility_test.exs` (the `live-native` owners) resolve
  the one route whose harness is `codex`. They fail loudly, listing the
  candidates, when there is no such route or more than one. They never use
  `default_route` and never pass a Claude route to `Kogen.Codex`. General live
  owners keep using `default_route`. Re-proving Codex later means running
  `live-native`, plus the general live targets with `default_route: codex`.
- `README.md` documents routes, `--route`, default selection, the refusal of
  the flat shape and route recording. It replaces current-tense statements
  that config "names the harness".

## Suggested mechanism (implementation freedom)

One option: have a route-resolving reader return the same map shape that
consumers use today (`harness`, roles, `helpers`, global retries), plus
`route: <name>`. Then `ExecutionPolicy`, `Codex.Compatibility`, the adapters
and Build keep their field access unchanged. Replacing ~17 inline flat-config
test fixtures with one shared test builder is also recommended. The Developer
may choose otherwise. `schema_version` handling for the tracking record
follows that module's own conventions.

## Walkthrough and challenge

The Shaper's Claude allowance runs out mid-week, and they run
`mix kogen.build --route codex my-slug`. Kogen resolves `codex` and checks
Codex install/login only. It records `route: {name: codex, harness: codex, …}`
and launches the Developer on `gpt-5.6-sol`. Meanwhile the Shaper edits
`default_route` back to `claude` for a Shape in another terminal. The
running Build's rework and Reviewer still use `codex` and `gpt-5.6-terra`.
Later, `mix kogen.shape named-routes` continues this Draft on `claude`.
It appends a visit with `route: claude` and leaves the original block
untouched.

Plausible-but-wrong implementations the scenarios reject:

- `--route` is parsed but `Harness.open` still validates every route, so a
  logged-out Codex blocks Claude sessions.
- Proven-model validation runs over all routes, so an experimental route
  blocks everything.
- The tracking record stores only the route *name*, which becomes meaningless
  after a config edit.
- Rework or the Reviewer re-reads config and picks up the edited
  `default_route`.
- A contextless call, a context without `harness`, an unknown harness name,
  `KOGEN_HARNESS`, or a missing Codex shaping model still quietly resolves to
  Codex or `gpt-5.6-sol`.
- The flat config is still accepted through a leftover code path.
- The prompt template gains `{{route}}`, but `read_draft/1` then requires it
  and legacy Drafts can no longer be continued.
- `mix kogen.codex.login` starts demanding a Codex route.

## Non-goals

- Parallel Builds, worktrees, lock changes, publication changes (Intent B,
  `isolated-candidate-workspace`).
- Per-role harness or provider overrides, and a separate Reviewer route. The
  schema keeps role entries as maps so such a key can be added later.
- Per-route `outer_resumptions`/`verification_retries`. Global for now; the
  Shaper may revisit if one harness proves fragile.
- A Pi adapter or any new harness; Codex-specific feature work.
- Allowance-aware automatic route choice, queues, or a route listing command.
- Recording the route in commit trailers.
- Migrating or rewriting existing Drafts and Complete Intents.
- The `project \\ File.cwd!()` default on `Harness.open`/`Codex.open`. B1
  makes the Candidate root explicit.
- Defaults unrelated to configuration, such as parsing provider output
  (`|| ""` on missing message text).
- Proven-model validation for Codex routes. Codex has no proven list today,
  and this Intent keeps that unchanged.

## Verification

Controller behavior is proven offline with the fake harnesses (`[check]`):
route resolution, flat-shape refusal, `--route` selection, unknown routes,
selected-route-only readiness, Shaping and Build route recording, mid-Build
config stability, removal of silent fallbacks (including the stricter
check test stage) and setup-command independence.
Scenario `real-default-route-end-to-end` also selects the existing
`live-shape-to-build` target, as the Shaper's updated brief directs. This
Intent rewrites the only config parser and the adapter choice, and a real
Shaping controller must follow the new `shaping.route` instruction. Fakes
cannot show either. `live-shape-to-build` extends its existing assertions to
the recorded Shaping, continuation and tracking-record route. No other paid
target is selected.

Editing any cataloged test file requires refreshing its `source_sha256` with
`scripts/check/refresh_test_reliability_sources.py`. New test declarations
need catalog rows in `priv/kogen/test-reliability.yaml`, which the guarded
paths include.

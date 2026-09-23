# Questions and decisions — named-routes

No open questions. Approved by the Shaper on 2026-09-23T08:34:31Z; the decisions below were settled before approval.

## Decided with the Shaper (2026-09-23, this conversation)

- **Old flat config breaks.** Shaper: "NEVER FALL BACK, NEVER SOFT-DEPRECATE
  / I DON'T CARE ABOUT OLD VERSIONS / MAKE IT BREAK IF IT FINDS OLD VERSION".
  Kogen refuses a flat-shape config before any launch, with a message naming
  `default_route` and `routes`. There is no compatibility reader, no
  deprecation warning and no automatic migration.

- **Schema:** the brief's example shape, with `default_route` and named `routes`.
  `outer_resumptions` and `verification_retries` stay global, outside routes.
  Shaper: "later if we find some is very fragile we can change".
- **Paid proof:** `live-shape-to-build` for the real default route end to end,
  other scenarios `[check]`. Taken from the Shaper's updated brief
  (`SHAPE_NAMED_ROUTES.md`, saved 10:48 local, after this session first read
  it), following a review the Shaper forwarded. No other paid target.

## Decided by the controller (the Shaper asked the controller to decide)

- **Harness setup commands (`mix kogen.{claude,codex}.{install,login,status}`)
  do not involve routes.** The Shaper: "I don't get how a shape/build route is
  related to the login etc. figure this out". Evidence: Claude's login/status
  ignore config (`lib/kogen/claude_code.ex:223,340`). Codex login/status only
  pass config into `Environment.prepare`, whose helper-profile writer
  tolerates absent profiles (`lib/kogen/codex/environment.ex:180-194`).
  Credentials are per harness scope, not per route.

## Settled from source and the brief

- Existing Drafts and Complete Intents stay valid: `read_draft/1` treats
  `shaping.route` as optional, and `Intent.read/2` never validated `shaping`.
- Continuing a Draft uses this session's `--route`/default route and records it
  on the new `shaping_continuations` entry. The original `shaping` block is
  kept as is.
- Unselected routes are checked only for structure, so future `pi-*` routes or
  unproven models can exist without blocking other sessions.
- The Build records the resolved route (name, harness and profiles), not only
  its name.
- **Route names** (Shaper, 2026-09-23): this repository's routes are named
  `claude` and `codex`, named after their harness (and its binary), one per
  harness today. They were first drafted as `claude` and `chatgpt`; the Shaper
  then asked for `codex` to match the harness name. Names that combine a harness
  and a provider, such as `pi-chatgpt`, are only for later harnesses that
  reach several providers.
- **No silent fallbacks** (Shaper, 2026-09-23, forwarding a review: "we don't
  want those kinds of defaults, everything needs to be explicit, so we can
  have a default configured, but no silent fallbacks"). `default_route` is the
  only default. The earlier `contextless-fallback-uses-route` scenario, which
  kept a contextless path pointing at `default_route`, is replaced by
  `no-silent-fallbacks`. Codex setup commands no longer rely on empty helper
  profiles and instead declare that they carry none. The project-root
  `File.cwd!()` default is left to B1.
- **Stricter `check` test stage** (review the Shaper forwarded, 2026-09-23).
  `scripts/check/offline.py` runs `mix test --exclude live --warnings-as-errors`
  so that live owners calling removed `Kogen.Harness` arities fail `check`.
  Chosen over only telling the Developer to run a focused command, because
  `check` is the gate the Build owns. The controller's probe found no existing
  test warnings to fix (see `evidence/investigation.md`).
- **Route in committed Build output** (review the Shaper forwarded,
  2026-09-23): `build-summary*.json` and `evidence.md` name the route and
  harness, so the history shows which provider built each Intent. This replaces
  the earlier non-goal. It is an extra field; `schema_version` stays 1, because
  `lib/kogen/build/evidence.ex:36-44` accepts only version 1 and existing
  Complete packages must stay readable.
- **Codex-only live owners** (same review): `codex_native_live_test`,
  `native_helper_live_test` and `codex_compatibility_test` resolve the one
  `codex` route and fail loudly on zero or several. They never read
  `default_route`, which is `claude` after this Build.

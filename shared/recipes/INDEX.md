# Recipes — Problem Finder

Grep this file's trigger table with task keywords before writing a plan. Each recipe solves one problem; the filename answers "what problem does this solve?" The detailed entries below the table give full context — only read an entry after a grep hit.

## Trigger Table

| Keywords                                                                                                                                             | Recipe                                  | Solution                                                                                                                                             |
| ---------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| browser-test organization domain journey test-structure feature-grouping scattered messy                                                             | browser-test-organization.md            | Organize browser tests by business domain rather than technology for complete user journeys.                                                         |
| caddy dynamic-routing subdomain reverse-proxy admin-api tenant runtime-route idempotent tag                                                          | caddy-dynamic-routing.md                | Manage Caddy routes at runtime via Admin API for per-app subdomain reverse proxying.                                                                 |
| claude-cli subprocess build-engine oban-worker autonomous stream-json system-cmd env-isolation                                                       | claude-cli-subprocess.md                | Invoke claude --print from Elixir Oban workers with env isolation and JSON stream parsing.                                                           |
| gumroad buy-button digital-product ebook sell download purchase one-pager landing-page placeholder                                                   | gumroad-buy-button.md                   | Render GUMROAD_PLACEHOLDER_URL so the platform patches the real Gumroad URL after build.                                                             |
| preview-app sanitize production-data gdpr pii sensitive-data anonymize database-dump development                                                     | database-sanitization-preview.md        | Automated sanitization of production database copies for safe preview app and dev usage.                                                             |
| timezone datetime-form utc browser-timezone date-time-split client-side merge validate datetime-local                                                | datetime-form-timezone.md               | Split datetime into date/time inputs, capture timezone client-side, merge and validate server-side.                                                  |
| docx pdf libreoffice template variable-substitution contract invoice document-generation personalized                                                | docx-to-pdf-generation.md               | DOCX template with variable substitution converted to PDF via LibreOffice for document generation.                                                   |
| async-false sync-test genserver ets mox-global oban-inline shared-state triage task test-mode                                                        | elixir-async-false-triage.md            | Three-condition triage for async: false with \*SyncTest split and LLM-integration always-false rule.                                                 |
| capture-log with_log ExUnit.CaptureLog error-path tag moduletag assert-log suppress-noise task-genserver                                             | elixir-capture-logs-on-error-paths.md   | Suppress noisy error logs and assert their content using with_log or @tag capture_log: true.                                                         |
| context-test describe-block function-name coverage edge-case elixir unit-test phoenix nil empty-list                                                 | elixir-context-test-structure.md        | Structure context tests with one describe per function and full edge-case coverage.                                                                  |
| ex_ast ex-ast ast-search ast-replace structural-refactor sourceror selector dry-run codemod elixir-codemod migration audit                           | elixir-ex-ast-refactor.md               | Use ExAST CLI/selectors for structural Elixir search and replace when grep can't express the pattern precisely.                                      |
| module-organization use import require alias schema attribute skeleton blank-line group credo                                                        | elixir-module-organization-skeleton.md  | Fixed group order with blank lines between each group prevents Credo warnings and aids scanning.                                                     |
| system-put-env application-put-env process-local config-override per-test async-true process-dict sentinel unset owner-number env-var test-isolation | elixir-process-local-config-override.md | `Process.put` with `:__unset__` sentinel lets tests override config per-process without forcing async:false.                                         |
| slow-tests parallel async-true module-split large-file wall-time scheduler concurrent describe-blocks ci-speed sequential-within-module              | elixir-parallel-test-module-split.md    | Split one large async:true module into N modules so ExUnit runs them in parallel, cutting wall time to slowest.                                      |
| python integration system-cmd subprocess cli-tool elixir-python interop ml-library json-exchange                                                     | elixir-python-system-cmd.md             | Call Python tools from Elixir via System.cmd() with JSON for structured data exchange.                                                               |
| sync-test async-false split module task-supervisor globally-named sandbox-race process-sleep db-read parallel serial single-file two-modules         | elixir-sync-test-module-split.md        | Two defmodule blocks (FooTest async:true + FooSyncTest async:false) in one file so only blocking tests serialize.                                    |
| telemetry test-isolation async concurrent attach detach handler leak telemetry_test                                                                  | elixir-telemetry-test-isolation.md      | Isolate telemetry assertions per test using :telemetry_test.attach_event_handlers/2.                                                                 |
| compile-env application-compile-env system-get-env test-config timeout-multiplier moduletag                                                          | elixir-test-compile-env-config.md       | Set config once in config/test.exs and read at compile time via Application.compile_env.                                                             |
| type-duplication @spec @type alias DRY spec-duplication module-level code-quality maintainability                                                    | elixir-type-duplication.md              | Detect and resolve duplicated Elixir type specs by extracting module-level type aliases.                                                             |
| with chained failable nested-case error-handling ok-error tuple pipeline control-flow                                                                | elixir-with-for-chained-failable-ops.md | Flat with pipeline replaces nested case for 3+ sequential failable operations.                                                                       |
| hex-publish library-release version-bump changelog tag git-push two-commit release-commit implementation-commit elixir-library                       | elixir-hex-library-release.md           | Two-commit pattern (implementation + release) with tag and manual hex.publish for Hex library releases.                                              |
| ets-caching content-cache ttl in-memory performance cache-first sub-microsecond read-heavy beam                                                      | ets-content-cache.md                    | ETS-based in-memory caching with TTL for content-heavy endpoints, no Redis needed.                                                                   |
| ets-session poc prototype in-memory no-database genserver rapid-prototyping temporary skip-migrations                                                | ets-session-storage-poc.md              | ETS tables via GenServer for temporary session storage in PoC apps, no migrations needed.                                                            |
| figma design-to-code mcp ui-component pixel-perfect asset design-system implementation                                                               | figma-to-code-mcp.md                    | MCP-powered workflow for accurate Figma-to-Phoenix component conversion with asset extraction.                                                       |
| figma visual-verification pixel-perfect design-comparison ui-accuracy screen-by-screen mcp progress                                                  | figma-visual-verification.md            | Structured screen-by-screen visual verification workflow combining Figma MCP with iterative fixes.                                                   |
| flaky-test intermittent race-condition timing random-failure repeat-until-failure ci-unreliable                                                      | flaky-test-fix.md                       | Detect and fix flaky tests using --repeat-until-failure and systematic pattern analysis.                                                             |
| github-workflows github-actions workflow generate mix yaml elixir ci-config                                                                          | github-workflows-mix-generator.md       | Edit .github/github_workflows.ex and run mix github_workflows.generate; never hand-edit .yml.                                                        |
| i18n enum-translation status-label dropdown-option gettext localization atom-string mixed-type                                                       | i18n-enum-translation.md                | Translate Ecto enums and status values safely with Gettext using validation-first patterns.                                                          |
| mox verify_on_exit stub expect async-test private-mode unmet-expectation                                                                             | mox-verify-on-exit-scope.md             | Only add verify_on_exit! when using expect; stub-only modules must omit it to stay async-safe.                                                       |
| node detached spawn process-group sigterm sigkill server-cleanup zombie screenshot                                                                   | nodejs-detached-process-cleanup.md      | Detached Node child processes killed as a process group (SIGTERM→SIGKILL) so dev servers and screenshot runs leave no zombies.                       |
| oban ecto-multi transaction atomic enqueue orphan-job insert telemetry                                                                               | oban-ecto-multi-atomic-enqueue.md       | Wrap DB insert + Oban enqueue in one Ecto.Multi/Repo.transaction so row and job commit or roll back together; telemetry fires after.                 |
| oban job cancel reschedule reminder notification idempotent lifecycle delete-before-schedule                                                         | oban-job-rescheduling.md                | Cancel-before-schedule pattern for Oban jobs with defensive processing for deleted entities.                                                         |
| oban worker perform return-value explicit-ok snooze cancel discard logger port                                                                       | oban-worker-return-contract.md          | Explicit :ok at end of perform/1 prevents warnings from loggers and port ops returning true.                                                         |
| admin http-basic-auth secure-routes environment-credentials unauthorized-logging plug pipeline                                                       | phoenix-admin-basic-auth.md             | HTTP Basic Auth plug for admin routes with env-based credentials and unauthorized attempt logging.                                                   |
| dependency-upgrade hex-outdated bump-deps mix-lock version-bump gate-failure routine-maintenance                                                     | phoenix-dependency-upgrade.md           | Four-step procedure to enumerate, bump, and gate dependency upgrades — fail open on the single dep that breaks the gate.                             |
| rate-limit ets throttle 429 too-many-requests per-ip fixed-window no-hammer plug                                                                     | phoenix-ets-rate-limit.md               | Pure-ETS per-IP fixed-window rate limiter with a plug returning 429 and retry-after, no Hammer dependency.                                           |
| remote-ip real-client-ip proxy caddy x-forwarded-for forwarded header spoofing plug                                                                  | phoenix-remote-ip.md                    | Wire the remote_ip plug ahead of the router so conn.remote_ip reflects the real client behind a proxy.                                               |
| session-login single-user shared-credential login-form on-mount liveview-gate require-login secure-compare                                           | phoenix-session-login.md                | Session-cookie login with a shared credential, require_login plug, and on_mount LiveView gating.                                                     |
| async liveview feature-test DBConnection.OwnershipError sandbox parallel playwright database                                                         | phoenix-async-feature-test-liveview.md  | Enable async: true for LiveView browser tests with proper SQL Sandbox metadata in User-Agent.                                                        |
| async-test connected-socket metadata nil hook-order sandbox liveview troubleshoot DBConnection                                                       | phoenix-async-test-debugging.md         | Debug async feature test failures caused by connected?(socket) trap and metadata nil issues.                                                         |
| messagepack binary-serialization phoenix-channels flutter bandwidth mobile 40-70-percent msgpax                                                      | phoenix-channels-messagepack-flutter.md | MessagePack serialization for Phoenix Channels gives 40-70% bandwidth savings over JSON.                                                             |
| component attr alphabetical ordering heex attribute-consistency credo code-review definition usage                                                   | phoenix-component-attribute-ordering.md | Maintain alphabetical attr ordering in both component definitions and HEEx usage calls.                                                              |
| component-migration backward-compatibility breaking-change deprecation gradual refactoring registry                                                  | phoenix-component-migration.md          | Migrate components without breaking existing usage via delegation pattern and registry.                                                              |
| bdd cucumber gherkin executable-specification stakeholder business-readable living-documentation                                                     | phoenix-cucumber-bdd-setup.md           | Complete Cucumber BDD setup in Phoenix with feature files, step definitions, and ExUnit integration.                                                 |
| docker github-actions ci-cd caching multi-stage slow-build buildx release dockerfile optimize                                                        | phoenix-docker-ci-optimization.md       | Phoenix-generated multi-stage Dockerfile with GitHub Actions Docker Buildx layer caching.                                                            |
| dropdown blur focus click-outside premature-close relatedTarget liveview phx-click-away menu                                                         | phoenix-dropdown-blur.md                | JavaScript blur event handlers with relatedTarget checks for dropdown close-on-outside-click.                                                        |
| dual-mode component modal full-page mode toggle context edit-view navigation conditional                                                             | phoenix-dual-mode-component.md          | Single component with :mode assign for modal vs full-page rendering without code duplication.                                                        |
| feature-test cleanup orphaned-process port-conflict ctrl-c interrupt zombie runner script bash                                                       | phoenix-feature-test-cleanup.md         | Bash script for feature tests with graceful cleanup of orphaned processes on exit/interrupt.                                                         |
| feature-test failing element-not-found timing server-not-starting environment debug selector                                                         | phoenix-feature-test-debugging.md       | Systematic debugging for Phoenix feature test failures: environment first, code second.                                                              |
| feature-test setup infrastructure playwright liveview ci browser-testing phoenix complete guide                                                      | phoenix-feature-test-setup.md           | Complete end-to-end guide for Phoenix feature testing with PhoenixTest.Playwright and LiveView.                                                      |
| text-assertion whitespace exact-false assert_has multiple-elements form-validation playwright heex                                                   | phoenix-feature-test-text-assertions.md | Use exact: false with element selectors to match text ignoring surrounding whitespace in HEEx.                                                       |
| file-extension routing plug binary-pattern-matching dynamic-route .md .json .xml llm-url format                                                      | phoenix-file-extension-routing.md       | Plug interceptor with binary pattern matching to route file extension URLs before the router.                                                        |
| file-upload html-label character-counter form-validation input debounce trigger click user-gesture heex                                              | phoenix-file-upload-html-labels.md      | HTML label for file upload trigger; phx-keyup+debounce for character counters, no server events.                                                     |
| image-optimization vix libvips webp thumbnail server-side upload mobile bandwidth dual-strategy                                                      | phoenix-image-optimization-vix.md       | Server-side image processing with Vix/libvips creating thumbnail + full-size WebP on upload.                                                         |
| page-title live_title suffix root-layout assign seo browser-title phoenix liveview                                                                   | phoenix-live-title-page-titles.md       | live_title with suffix in root layout; each LiveView assigns only the page-specific title part.                                                      |
| modal animation phx-mounted js.show transition backdrop panel translate-x opacity enter-leave                                                        | phoenix-modal-js-animations.md          | Chained JS.show on phx-mounted animates backdrop fade and panel slide with no server round-trip.                                                     |
| param-validation input-sanitization filter atom-conversion type-coercion security String.to_atom                                                     | phoenix-param-normalization.md          | FilterUtils pattern with embedded schema for safe parameter whitelist and type normalization.                                                        |
| release deployment production migration runtime-config persistent-storage mix-release no-mix                                                         | phoenix-release-deployment.md           | Phoenix releases with runtime config, migration scripts, and environment-aware file storage.                                                         |
| gitignore cleanup sensitive npm-cache log-file clutter audit kubeconfig quarterly hygiene                                                            | phoenix-repository-hygiene.md           | Comprehensive .gitignore patterns and quarterly audit process for Phoenix/Elixir repos.                                                              |
| authorization scope data-leak user-company isolation security query-filter context-function audit                                                    | phoenix-scope-authorization.md          | Scope-based authorization where all context functions accept a Scope struct for secure filtering.                                                    |
| smoke-test regression quick-validation refactoring dependency-update liveview-mount fast all-routes                                                  | phoenix-smoke-testing.md                | Lightweight smoke tests across all major LiveViews for fast regression detection after changes.                                                      |
| storybook design-system component-documentation interactive-example variant visual-verification docs                                                 | phoenix-storybook-setup.md              | PhoenixStorybook setup for interactive design system docs with component variants and examples.                                                      |
| verified-routes dynamic-path asset interpolation compile-error pattern-match icon svg helper                                                         | phoenix-verified-routes-dynamic.md      | Helper functions with pattern matching for dynamic verified routes avoiding interpolation errors.                                                    |
| fulltext-search postgresql suggestion autocomplete typeahead tsvector tsquery gin-index search-box                                                   | postgresql-fulltext-search.md           | PostgreSQL full-text search with tsvector/tsquery and smart suggestion blending history + popular.                                                   |
| push notification duplicate ack websocket timer pubsub multi-device active-session                                                                   | push-notification-ack-timing.md         | ACK-based timer pattern prevents duplicate push notifications during active WebSocket sessions.                                                      |
| push-notification delivery-ack http background ios-extension android-handler terminated backgrounded                                                 | push-notification-http-delivery-ack.md  | HTTP endpoint for push delivery ACK when app is backgrounded or terminated (no WebSocket).                                                           |
| refactor remove delete field function constant grep readers safe-removal boot-path                                                                   | refactor-grep-reader-scope.md           | Grep every reader before removing a field/function/constant; a boundary removal needs guard coverage of the whole grep target, not a curated subset. |
| req-test stub http-client external-api mock phoenix req plug req_options                                                                             | req-test-stub-external-http.md          | Wire Req.Test as a plug stub via config/test.exs so tests never make real HTTP calls.                                                                |
| component-api semantic naming props intuitive cognitive-load self-documenting interface clarity                                                      | semantic-component-api-design.md        | Design semantic component APIs with intuitive names that avoid parameter-heavy confusion.                                                            |
| sqlite upsert ecto on_conflict returning delete-insert unique-constraint cross-database postgresql                                                   | sqlite-upsert.md                        | Delete+insert upsert pattern that works across SQLite3 and PostgreSQL without RETURNING clause.                                                      |
| rss feed atom blog tag taxonomy listing pagination sort related-posts mdx markdown post content vite static                                          | static-vite-content.md                  | Opt-in RSS/Atom feeds + tag pages + paginated listings on the Vite static stack via postbuild Node + import.meta.glob.                               |
| task-supervisor sandbox-allow req-test-allow spawn process task-start async-false mox-leak data-case                                                 | task-supervisor-sandbox-allowance.md    | Named Task.Supervisor with explicit allow calls prevents stub and sandbox leaks in spawned tasks.                                                    |
| coverage 90-percent unused-code dead-code coverage-report identify remove component liveview                                                         | test-coverage-strategies.md             | Strategic approach to reach and maintain 90%+ test coverage by removing unused code first.                                                           |
| third-party-api stripe namecheap bunny cloudflare verify-locally curl iex sandbox integration                                                        | third-party-api-verification.md         | Test raw API calls locally via IEx/curl before writing integration code; docs lie.                                                                   |
| tidewave mcp verify-first get_docs search_package_docs project_eval unknown-config hexdocs research                                                  | tidewave-mcp-verification.md            | Three-step verify-before-using flow prevents adding non-existent config options or functions.                                                        |

## Detailed Entries

### browser-test-organization.md

**When**: Browser tests are scattered by technology (unit/integration/JS) instead of by feature, causing coverage gaps.
**What it gives you**: Domain-based directory structure where each file represents a complete user journey across all technical concerns.
**Triggers**: browser-test organization domain journey test-structure feature-grouping scattered messy

### caddy-dynamic-routing.md

**When**: Platform needs to add/remove per-app subdomain routes to Caddy at runtime without restarting it.
**What it gives you**: Elixir module calling Caddy Admin API at `localhost:2019` with tagged idempotent routes at position 0 to beat wildcard routes.
**Triggers**: caddy dynamic-routing subdomain reverse-proxy admin-api tenant runtime-route idempotent tag

### claude-cli-subprocess.md

**When**: An Oban worker needs to invoke `claude --print` to autonomously edit code in a target directory.
**What it gives you**: `System.cmd("sh", ["-c", cmd])` invocation pattern with env-u isolation, disallowed-tools, stream-json parsing via Python log parser written to /tmp.
**Triggers**: claude-cli subprocess build-engine oban-worker autonomous stream-json system-cmd env-isolation

### gumroad-buy-button.md

**When**: A user's brief mentions selling a digital product (ebook, course, template) with a Gumroad link.
**What it gives you**: Exact snippet using `GUMROAD_PLACEHOLDER_URL` so the platform can patch the real URL post-build — three variants (plain anchor, overlay button, custom button).
**Triggers**: gumroad buy-button digital-product ebook sell download purchase one-pager landing-page placeholder

### database-sanitization-preview.md

**When**: Preview apps or dev environments need realistic data from production without exposing PII.
**What it gives you**: Elixir sanitization script that anonymizes emails, names, phones in-place with safety checks preventing production runs.
**Triggers**: preview-app sanitize production-data gdpr pii sensitive-data anonymize database-dump development

### datetime-form-timezone.md

**When**: Phoenix form needs datetime input in the user's local timezone but server must store UTC.
**What it gives you**: Split date/time inputs + client-side timezone capture via JS hook + server-side merge/validate with Timex.
**Triggers**: timezone datetime-form utc browser-timezone date-time-split client-side merge validate datetime-local

### docx-to-pdf-generation.md

**When**: Phoenix app needs to generate personalized PDFs (contracts, invoices, offers) from templates.
**What it gives you**: DOCX with `{{variable}}` placeholders + LibreOffice DOCX-to-PDF via `System.cmd` + S3 storage + Phoenix delivery.
**Triggers**: docx pdf libreoffice template variable-substitution contract invoice document-generation personalized

### elixir-async-false-triage.md

**When**: Deciding `async: true` vs `async: false` for a test file, or investigating flakiness caused by shared global state.
**What it gives you**: Three-condition checklist for `async: false` + `*SyncTest` split convention + LLM integration always-false rule.
**Triggers**: async-false sync-test genserver ets mox-global oban-inline shared-state triage

### elixir-capture-logs-on-error-paths.md

**When**: A test triggers an expected error that logs noise, or the log message itself must be asserted.
**What it gives you**: `with_log` for inline capture + `@tag capture_log: true` for Task/GenServer spawns + `@moduletag` for whole-module suppression.
**Triggers**: capture-log with_log ExUnit.CaptureLog error-path tag assert-log suppress-noise

### elixir-context-test-structure.md

**When**: Writing tests for a new or updated context function and need to know where and what to cover.
**What it gives you**: One describe block per function, happy path + failure path + edge cases, full new-code coverage mandate.
**Triggers**: context-test describe-block function-name coverage edge-case elixir unit-test phoenix

### elixir-ex-ast-refactor.md

**When**: A refactor or audit needs to match Elixir code by structure (≥ 5 callsites, multi-line forms, "X inside Y but not Z") — regex would over-match or break.
**What it gives you**: ExAST CLI (`mix ex_ast.search` / `mix ex_ast.replace`) and `ExAST.Selector` chains with parent/ancestor/has-descendant predicates; comments and positions preserved via Sourceror; mandatory `--dry-run` workflow and the rule to keep it `only: [:dev, :test]`.
**Triggers**: ex_ast ex-ast ast-search ast-replace structural-refactor sourceror selector dry-run codemod migration audit

### elixir-module-organization-skeleton.md

**When**: Creating a new module or reviewing an existing module's structure during a code review.
**What it gives you**: Fixed group order (`use` → `import` → `require` → `alias` → attributes → types → schema → functions) with blank-line-between-groups rule and a complete sample module.
**Triggers**: module-organization use import require alias schema attribute skeleton blank-line group credo

### elixir-process-local-config-override.md

**When**: A test overrides a config value (owner phone, API base URL, feature flag) that production reads from `Application.get_env` or `System.get_env`, without forcing the whole file to `async: false`.
**What it gives you**: `Process.get(:key, :__unset__)` + `Application.get_env` fallback in production code, `Process.put(:key, value)` per-test with no teardown — ExUnit discards the process dict automatically.
**Triggers**: system-put-env application-put-env process-local config-override per-test async-true process-dict sentinel unset owner-number env-var test-isolation

### elixir-parallel-test-module-split.md

**When**: A single `async: true` test module has grown so large (60+ seconds, 50+ tests) that it dominates CI wall time — even though it is async:true, tests within one module always run sequentially.
**What it gives you**: Split strategy grouping describe blocks by cost tier (unit/medium/heavy), shared-helper placement rules, naming convention, and a verification step to confirm no tests were dropped. With 8 cores, 5 balanced modules cut a 131s file to ~30s.
**Triggers**: slow-tests parallel async-true module-split large-file wall-time scheduler concurrent describe-blocks ci-speed sequential-within-module

### elixir-python-system-cmd.md

**When**: An Elixir app needs to call Python libraries (ML, data processing, specialized APIs) without rewriting in Elixir.
**What it gives you**: JSON-over-System.cmd pattern with structured input/output, error handling, and timeout configuration.
**Triggers**: python integration system-cmd subprocess cli-tool elixir-python interop ml-library json-exchange

### elixir-sync-test-module-split.md

**When**: One test file has a mix of fully-async-safe tests and a small handful that must be `async: false` (globally-named `Task.Supervisor`, `Sandbox.mode(:shared)`, singleton GenServer) — marking the whole file sync serializes 20+ tests when only 2 need it.
**What it gives you**: Two `defmodule` blocks in one file (`FooTest` async:true + `FooSyncTest` async:false) with a mandatory blocker comment naming the specific global resource, so only the genuinely-blocking tests pay the serial cost.
**Triggers**: sync-test async-false split module task-supervisor globally-named sandbox-race process-sleep db-read parallel serial single-file two-modules

### elixir-telemetry-test-isolation.md

**When**: Telemetry assertions bleed between concurrent async tests or handler cleanup is missing.
**What it gives you**: `:telemetry_test.attach_event_handlers/2` pattern with pinned ref for per-test isolation and `on_exit` cleanup — no extra deps.
**Triggers**: telemetry test-isolation async concurrent attach detach handler leak telemetry_test

### elixir-test-compile-env-config.md

**When**: A test module needs a compile-time config value such as a timeout multiplier or a feature flag.
**What it gives you**: `config/test.exs` compute-once pattern + `Application.compile_env/2` usage with no inline default.
**Triggers**: compile-env application-compile-env system-get-env test-config timeout-multiplier moduletag

### elixir-type-duplication.md

**When**: Elixir codebase has repeated `@spec` type definitions (e.g., `Scope.t()` everywhere) violating DRY.
**What it gives you**: Detection commands (grep-based) + module-level `@type` alias extraction pattern with backward compatibility.
**Triggers**: type-duplication @spec @type alias DRY spec-duplication module-level code-quality maintainability

### elixir-with-for-chained-failable-ops.md

**When**: Three or more sequential operations each return `{:ok, _}` / `{:error, _}` and are currently written as nested `case` statements.
**What it gives you**: `with` pipeline pattern with bad→good example, `else` clause semantics, and the rule for when `case` is still the right choice (single failable op).
**Triggers**: with chained failable nested-case error-handling ok-error tuple pipeline control-flow

### ets-content-cache.md

**When**: Database queries for content-heavy endpoints are a performance bottleneck and Redis adds too much complexity.
**What it gives you**: ETS cache module with TTL expiration, cache-first pattern, and graceful degradation — sub-microsecond lookup on BEAM.
**Triggers**: ets-caching content-cache ttl in-memory performance cache-first sub-microsecond read-heavy beam

### ets-session-storage-poc.md

**When**: A PoC or prototype needs temporary data storage without migrations or database setup.
**What it gives you**: GenServer-managed ETS table with TTL cleanup, concurrent read/write, and session-scoped key namespacing.
**Triggers**: ets-session poc prototype in-memory no-database genserver rapid-prototyping temporary skip-migrations

### figma-to-code-mcp.md

**When**: Implementing a Figma design into Phoenix components and need accurate asset extraction and responsive behavior.
**What it gives you**: MCP tool usage pattern for extracting design specs, asset URLs, and responsive breakpoints before writing any component code.
**Triggers**: figma design-to-code mcp ui-component pixel-perfect asset design-system implementation

### figma-visual-verification.md

**When**: Implemented UI needs to be verified screen-by-screen against Figma designs for accuracy.
**What it gives you**: Structured workflow using Figma MCP get_image for comparison, with progress tracking and iterative fix cycles.
**Triggers**: figma visual-verification pixel-perfect design-comparison ui-accuracy screen-by-screen mcp progress

### flaky-test-fix.md

**When**: Tests pass locally but fail intermittently in CI, or failure is not reproducible reliably.
**What it gives you**: `--repeat-until-failure` detection technique + catalog of common patterns (race conditions, multiple DB fetches, timing issues) with fixes.
**Triggers**: flaky-test intermittent race-condition timing random-failure repeat-until-failure ci-unreliable

### github-workflows-mix-generator.md

**When**: GitHub Actions workflow files need to be created or modified in a project using the `github_workflows` Mix library.
**What it gives you**: The rule that `.yml` files are generated artifacts — edit `.github/github_workflows.ex` and run `mix github_workflows.generate`; committing only the `.yml` causes the next regeneration to silently overwrite hand-edits.
**Triggers**: github-workflows github-actions workflow generate mix yaml elixir ci-config

### i18n-enum-translation.md

**When**: Ecto enum values (atoms, strings) need to be displayed with translated labels in dropdowns or status displays.
**What it gives you**: Validation-first Gettext translation pattern that handles mixed atom/string enum values without silent catch-all fallbacks.
**Triggers**: i18n enum-translation status-label dropdown-option gettext localization atom-string mixed-type

### mox-verify-on-exit-scope.md

**When**: Adding `setup :verify_on_exit!` to a test file, or choosing between `Mox.stub` and `Mox.expect`.
**What it gives you**: Rule: only add `verify_on_exit!` when using `expect`; stub-only files must omit it to avoid forcing private mode and breaking concurrent async tests.
**Triggers**: mox verify_on_exit stub expect async-test private-mode unmet-expectation

### nodejs-detached-process-cleanup.md

**When**: A Node script spawns a detached server/browser child (dev server, Playwright, screenshot capture) that can orphan on exit or interrupt.
**What it gives you**: process-group spawn (detached: true) + kill -TERM/kill -KILL on the negative PID with escalation, so the whole child tree dies.
**Triggers**: node detached spawn process-group sigterm sigkill server-cleanup zombie screenshot

### oban-ecto-multi-atomic-enqueue.md

**When**: A context inserts a row and enqueues an Oban job that must not orphan if either step fails.
**What it gives you**: Ecto.Multi.insert + Oban.insert (fn-form for result-dependent args) → Repo.transaction, with telemetry in the {:ok, ...} arm only (never inside the transaction).
**Triggers**: oban ecto-multi transaction atomic enqueue orphan-job insert telemetry

### oban-job-rescheduling.md

**When**: A scheduled Oban job (reminder, notification) needs to be cancelled and rescheduled when the underlying entity changes.
**What it gives you**: Cancel-before-schedule helper + defensive perform that handles deleted entities + idempotent job query pattern.
**Triggers**: oban job cancel reschedule reminder notification idempotent lifecycle delete-before-schedule

### oban-worker-return-contract.md

**When**: Writing or reviewing any Oban worker's `perform/1` function.
**What it gives you**: Explanation of why explicit `:ok` is required (loggers/error reporters/port ops return `true`, not `:ok`) and the full table of valid return values (`:ok`, `{:ok, v}`, `{:error, r}`, `{:cancel, r}`, `{:discard, r}`, `{:snooze, secs}`).
**Triggers**: oban worker perform return-value explicit-ok snooze cancel discard logger port

### phoenix-admin-basic-auth.md

**When**: Admin routes need HTTP Basic Authentication with environment-based credentials and audit logging.
**What it gives you**: `AdminAuth` plug with secure credential comparison, unauthorized attempt logging, and separate router pipeline.
**Triggers**: admin http-basic-auth secure-routes environment-credentials unauthorized-logging plug pipeline

### phoenix-dependency-upgrade.md

**When**: Doing routine "bump the deps" maintenance, or a dependency bump needs a defined procedure instead of ad-hoc handling.
**What it gives you**: Fixed procedure — `mix hex.outdated` to enumerate, bump pins + `mix.lock`, run the gate, and on a gate-breaking dep, revert only that pin and report it rather than blocking the whole upgrade or shipping red.
**Triggers**: dependency-upgrade hex-outdated bump-deps mix-lock version-bump gate-failure routine-maintenance

### phoenix-ets-rate-limit.md

**When**: An endpoint needs per-IP rate limiting (login form, public API, contact form) without adding a Hammer or Redis dependency.
**What it gives you**: Named ETS table + fixed-window counter keyed by client IP, incremented atomically via `:ets.update_counter/4`, with a plug that halts 429 + `retry-after` when the limit is exceeded.
**Triggers**: rate-limit ets throttle 429 too-many-requests per-ip fixed-window no-hammer plug

### phoenix-remote-ip.md

**When**: An app sits behind a reverse proxy (Caddy, nginx, load balancer) and `conn.remote_ip` shows the proxy's address instead of the real client's.
**What it gives you**: `remote_ip` plug wired ahead of the router, rewriting `conn.remote_ip` in place from a trusted forwarding header — every downstream reader gets the real IP with no call-site changes.
**Triggers**: remote-ip real-client-ip proxy caddy x-forwarded-for forwarded header spoofing plug

### phoenix-session-login.md

**When**: A single-tenant app or internal tool needs a proper session-cookie login (not `phx.gen.auth`'s per-user accounts, not HTTP Basic Auth's per-request prompt).
**What it gives you**: Shared credential from runtime env, `SessionController` with `secure_compare/2` verification, `require_login` plug for dead routes, and an `on_mount` hook gating LiveViews with redirect-on-unauthenticated.
**Triggers**: session-login single-user shared-credential login-form on-mount liveview-gate require-login secure-compare

### phoenix-async-feature-test-liveview.md

**When**: LiveView browser tests fail with `DBConnection.OwnershipError` or run with `async: false` for speed reasons.
**What it gives you**: Complete SQL Sandbox + LiveView hook setup that passes metadata via User-Agent header, enabling `async: true`.
**Triggers**: async liveview feature-test DBConnection.OwnershipError sandbox parallel playwright database

### phoenix-async-test-debugging.md

**When**: `DBConnection.OwnershipError` persists after following the async docs — metadata is nil or connected?(socket) is wrong.
**What it gives you**: Root cause analysis of the `connected?(socket)` trap + corrected hook implementation + debug checklist.
**Triggers**: async-test connected-socket metadata nil hook-order sandbox liveview troubleshoot DBConnection

### phoenix-channels-messagepack-flutter.md

**When**: Phoenix Channels with Flutter mobile client have high bandwidth usage or slow serialization on poor networks.
**What it gives you**: `msgpax` backend implementation + Flutter Dart MessagePack client for 40-70% bandwidth savings.
**Triggers**: messagepack binary-serialization phoenix-channels flutter bandwidth mobile 40-70-percent msgpax

### phoenix-component-attribute-ordering.md

**When**: Credo or code review flags inconsistent attr ordering in Phoenix component definitions or HEEx usage.
**What it gives you**: Alphabetical ordering convention with before/after examples for both `attr` declarations and component call sites.
**Triggers**: component attr alphabetical ordering heex attribute-consistency credo code-review definition usage

### phoenix-component-migration.md

**When**: Migrating from CoreComponents or a monolithic component system to a modular design system without breaking existing callers.
**What it gives you**: Component registry with delegation pattern + deprecation warnings for incremental zero-breaking migration.
**Triggers**: component-migration backward-compatibility breaking-change deprecation gradual refactoring registry

### phoenix-cucumber-bdd-setup.md

**When**: Project needs executable business specifications in Gherkin that stakeholders can read and verify.
**What it gives you**: Complete Cucumber 0.4.1+ setup with feature files, step definitions, ExUnit integration, and cleanup infrastructure.
**Triggers**: bdd cucumber gherkin executable-specification stakeholder business-readable living-documentation

### phoenix-docker-ci-optimization.md

**When**: Docker builds for Phoenix are slow (10+ minutes) or Docker layer caching is not working in GitHub Actions.
**What it gives you**: `mix phx.gen.release --docker` generated Dockerfile + GitHub Actions workflow with `type=gha,mode=max` buildx caching.
**Triggers**: docker github-actions ci-cd caching multi-stage slow-build buildx release dockerfile optimize

### phoenix-dropdown-blur.md

**When**: A LiveView dropdown closes prematurely when clicking internal elements or stays open when clicking outside.
**What it gives you**: JS blur handler with `relatedTarget` check to detect focus-within vs focus-outside for precise dropdown control.
**Triggers**: dropdown blur focus click-outside premature-close relatedTarget liveview phx-click-away menu

### phoenix-dual-mode-component.md

**When**: A Phoenix component must work as both a modal overlay and a full-page form without code duplication.
**What it gives you**: `:mode` assign pattern with `pattern matching` for navigation, styling, and event handling per context.
**Triggers**: dual-mode component modal full-page mode toggle context edit-view navigation conditional

### phoenix-feature-test-cleanup.md

**When**: Running Phoenix feature tests leaves orphaned processes causing port conflicts on the next run.
**What it gives you**: `scripts/feature_test.sh` that kills test server processes on exit and supports file/line-number arguments.
**Triggers**: feature-test cleanup orphaned-process port-conflict ctrl-c interrupt zombie runner script bash

### phoenix-feature-test-debugging.md

**When**: Phoenix feature tests fail with "element not found" or "server not starting" and root cause is unclear.
**What it gives you**: Environment-first debugging checklist: verify env vars → check server startup → inspect selectors → add timing.
**Triggers**: feature-test failing element-not-found timing server-not-starting environment debug selector

### phoenix-feature-test-setup.md

**When**: Adding browser-based feature tests to a Phoenix app for the first time.
**What it gives you**: Full production-ready setup: `phoenix_test_playwright ~> 0.7`, LiveAcceptance hook, FeatureCase, CI exclusion tagging, async: true.
**Triggers**: feature-test setup infrastructure playwright liveview ci browser-testing phoenix complete guide

### phoenix-feature-test-text-assertions.md

**When**: PhoenixTest.Playwright `assert_has` fails due to whitespace in HEEx-rendered text content.
**What it gives you**: `exact: false` pattern with element selectors for whitespace-tolerant text assertions and multi-element disambiguation.
**Triggers**: text-assertion whitespace exact-false assert_has multiple-elements form-validation playwright heex

### phoenix-file-extension-routing.md

**When**: Phoenix routes need to handle URLs with file extensions like `/d/:id.md` or `/api/resource.json`.
**What it gives you**: Plug interceptor with binary pattern matching that routes file extension requests before the Phoenix router.
**Triggers**: file-extension routing plug binary-pattern-matching dynamic-route .md .json .xml llm-url format

### phoenix-file-upload-html-labels.md

**When**: Adding a styled file upload button or a live character counter to a Phoenix LiveView form.
**What it gives you**: HTML `<label for="...">` pattern for file uploads (no JS hook needed) + `phx-keyup`/`phx-debounce="300"` pattern for character counters tracked in socket assigns.
**Triggers**: file-upload html-label character-counter form-validation input debounce trigger click user-gesture heex

### phoenix-image-optimization-vix.md

**When**: Phoenix app accepts image uploads and needs to reduce bandwidth and load time for mobile users.
**What it gives you**: Vix/libvips dual-image strategy: thumbnail (~200px) + full-size (max 1920px) in WebP on upload.
**Triggers**: image-optimization vix libvips webp thumbnail server-side upload mobile bandwidth dual-strategy

### phoenix-live-title-page-titles.md

**When**: A Phoenix LiveView app needs unique browser tab titles per page without repeating the app name suffix in every LiveView.
**What it gives you**: `<.live_title suffix="...">` in root layout + one `assign(socket, page_title: "...")` per LiveView — updates stream to the browser without full reload.
**Triggers**: page-title live_title suffix root-layout assign seo browser-title phoenix liveview

### phoenix-modal-js-animations.md

**When**: A LiveView modal needs backdrop fade and panel slide-in/out animations that run instantly on the client.
**What it gives you**: `phx-mounted` with chained `JS.show/2` calls for backdrop opacity and panel translate transitions — no server round-trip required.
**Triggers**: modal animation phx-mounted js.show transition backdrop panel translate-x opacity enter-leave

### phoenix-param-normalization.md

**When**: URL query parameters need safe conversion to atoms or typed values without security vulnerabilities.
**What it gives you**: Embedded schema + changeset validation + whitelist-based `String.to_existing_atom` conversion pattern.
**Triggers**: param-validation input-sanitization filter atom-conversion type-coercion security String.to_atom

### phoenix-release-deployment.md

**When**: Deploying a Phoenix app to production without Mix installed, or migrations fail in releases.
**What it gives you**: `mix phx.gen.release` output + Release module + runtime config pattern + persistent file storage setup.
**Triggers**: release deployment production migration runtime-config persistent-storage mix-release no-mix

### phoenix-repository-hygiene.md

**When**: Phoenix repo has committed log files, NPM cache, sensitive files, or accumulated clutter over time.
**What it gives you**: Comprehensive `.gitignore` patterns for Phoenix/Elixir + quarterly audit process with archiving (not deleting) historical files.
**Triggers**: gitignore cleanup sensitive npm-cache log-file clutter audit kubeconfig quarterly hygiene

### phoenix-scope-authorization.md

**When**: Phoenix app has data leaks between users, inconsistent authorization, or needs a security audit.
**What it gives you**: `Scope` struct pattern where all context functions accept it as first param, with user/company/system variants.
**Triggers**: authorization scope data-leak user-company isolation security query-filter context-function audit

### phoenix-smoke-testing.md

**When**: Need a fast sanity check across all major LiveViews after refactoring or dependency updates.
**What it gives you**: Smoke test directory structure with mount-and-assert-minimal pattern per route, tagged for selective execution.
**Triggers**: smoke-test regression quick-validation refactoring dependency-update liveview-mount fast all-routes

### phoenix-storybook-setup.md

**When**: Design system components need interactive documentation that stays in sync with implementation.
**What it gives you**: PhoenixStorybook setup with stories per component, variant showcase, and CSS/JS asset integration.
**Triggers**: storybook design-system component-documentation interactive-example variant visual-verification docs

### phoenix-verified-routes-dynamic.md

**When**: Verified routes (`~p"/..."`) fail to compile due to string interpolation for dynamic asset paths.
**What it gives you**: Helper function with explicit pattern matching for all known dynamic paths — fail-fast for unknowns.
**Triggers**: verified-routes dynamic-path asset interpolation compile-error pattern-match icon svg helper

### postgresql-fulltext-search.md

**When**: Phoenix app needs search with autocomplete suggestions without adding external search services.
**What it gives you**: tsvector/tsquery with GIN index + trigger for auto-update + suggestion algorithm blending history and popular searches.
**Triggers**: fulltext-search postgresql suggestion autocomplete typeahead tsvector tsquery gin-index search-box

### push-notification-ack-timing.md

**When**: User reports duplicate push notifications during active chat, or needs to prevent push when WebSocket is connected.
**What it gives you**: ACK-based timer pattern with cross-process PubSub coordination. Server starts a 10s timer per event; client ACK cancels it, no-ACK triggers push.
**Triggers**: push notification duplicate ack websocket timer pubsub multi-device active-session cross-process

### push-notification-http-delivery-ack.md

**When**: Mobile app needs to acknowledge push notification delivery when backgrounded or terminated (no WebSocket available).
**What it gives you**: Phoenix HTTP endpoint for delivery ACK + iOS Notification Service Extension + Android background handler patterns.
**Triggers**: push-notification delivery-ack http background ios-extension android-handler terminated backgrounded

### refactor-grep-reader-scope.md

**When**: Removing or renaming a field, function, or constant during a refactor sweep.
**What it gives you**: grep-all-readers discipline (writers AND readers incl. boot-path) before removal, and the rule that a multi-file boundary fix needs a guard covering the SAME grep target as the sweep, not a hand-picked list.
**Triggers**: refactor remove delete field function constant grep readers safe-removal boot-path

### req-test-stub-external-http.md

**When**: A module uses Req to call an external HTTP API and tests must not make real network calls.
**What it gives you**: Three-step wiring (req_options/0 in lib, plug config in test.exs, Req.Test.stub in test) that intercepts all HTTP calls without touching production logic.
**Triggers**: req-test stub http-client external-api mock phoenix req plug req_options

### semantic-component-api-design.md

**When**: Component API uses parameter-heavy approach (level, size, weight) leading to cognitive load and misuse.
**What it gives you**: Semantic naming strategy with specific component functions instead of multi-param generics.
**Triggers**: component-api semantic naming props intuitive cognitive-load self-documenting interface clarity

### sqlite-upsert.md

**When**: Ecto upsert with `on_conflict` and `returning: true` fails on SQLite3 due to missing RETURNING clause.
**What it gives you**: Delete+insert pattern that works on both SQLite3 (dev) and PostgreSQL (prod) — consistent cross-database upsert.
**Triggers**: sqlite upsert ecto on_conflict returning delete-insert unique-constraint cross-database postgresql

### static-vite-content.md

**When**: User wants a blog or content site with RSS/Atom feeds, tag taxonomy pages, and paginated post listings built on Vite + React.
**What it gives you**: Self-contained MDX authoring setup (`@mdx-js/rollup` + `gray-matter`), `import.meta.glob` post-collection helper, postbuild Node script generating `public/rss.xml` + `public/atom.xml`, React Router `/tags/:tag` pages, and pagination/sort-by-date/related-posts listing components — all opt-in, layered on `static-vite-scaffold.md`.
**Triggers**: rss feed atom blog tag taxonomy listing pagination sort related-posts mdx markdown post content vite static

### task-supervisor-sandbox-allowance.md

**When**: Production code spawns Tasks that need access to Mox stubs or the Ecto SQL sandbox in tests.
**What it gives you**: Named `Task.Supervisor` + `Req.Test.allow/3` + `Sandbox.allow/3` pattern that grants the supervisor explicit ownership so stubs and DB access don't silently leak or crash.
**Triggers**: task-supervisor sandbox-allow req-test-allow spawn process task-start async-false mox-leak data-case

### test-coverage-strategies.md

**When**: Test coverage is below 90% and the gap comes from unused components or hard-to-test LiveView UI.
**What it gives you**: Strategy: find and remove unused components first, then targeted LiveView test patterns for remaining gaps.
**Triggers**: coverage 90-percent unused-code dead-code coverage-report identify remove component liveview

### third-party-api-verification.md

**When**: Writing any function that calls an external API (Namecheap, Stripe, Bunny, Cloudflare, or similar) before writing the integration code.
**What it gives you**: IEx/curl/throwaway-script test-first flow that verifies real endpoint, supported parameters, and response format before any integration code is written; includes the ❌/✅ flow pattern.
**Triggers**: third-party-api stripe namecheap bunny cloudflare verify-locally curl iex sandbox integration

### tidewave-mcp-verification.md

**When**: Adding any library function, config key, or module usage you haven't used before, or when behaviour is unclear from types alone.
**What it gives you**: Three-step verify-first flow (`get_docs` → `search_package_docs` → `project_eval`) with clear rules for when to use it and when to skip it.
**Triggers**: tidewave mcp verify-first get_docs search_package_docs project_eval unknown-config hexdocs research

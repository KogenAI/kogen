# Recipes Domain — Recipe Catalog

Recipes are step-by-step implementation guides referenced from planner plans. They live in `shared/recipes/` and are `{% include %}`d into agent prompts at generate time — they are NOT loaded at runtime. Each recipe encodes a proven implementation pattern for a specific domain problem.

## Components

| File                                                     | Purpose                                                 |
| -------------------------------------------------------- | ------------------------------------------------------- |
| `shared/recipes/static-vite-scaffold.md`                 | Vite + React scaffold setup recipe                      |
| `shared/recipes/phoenix-feature-test-setup.md`           | Feature test setup with Wallaby/Playwright for Phoenix  |
| `shared/recipes/phoenix-feature-test-cleanup.md`         | Teardown and isolation for Phoenix feature tests        |
| `shared/recipes/phoenix-feature-test-debugging.md`       | Debugging flaky or failing Phoenix feature tests        |
| `shared/recipes/phoenix-feature-test-text-assertions.md` | Text assertion patterns in Phoenix feature tests        |
| `shared/recipes/phoenix-async-feature-test-liveview.md`  | Async LiveView feature test patterns                    |
| `shared/recipes/phoenix-async-test-debugging.md`         | Debugging async test failures in Phoenix                |
| `shared/recipes/phoenix-modal-js-animations.md`          | JS-driven modal animations in Phoenix/LiveView          |
| `shared/recipes/phoenix-dropdown-blur.md`                | Dropdown blur/close patterns in LiveView                |
| `shared/recipes/phoenix-scope-authorization.md`          | Scope-based authorization patterns                      |
| `shared/recipes/phoenix-storybook-setup.md`              | Phoenix.Storybook setup and configuration               |
| `shared/recipes/phoenix-release-deployment.md`           | Phoenix release build + deployment                      |
| `shared/recipes/phoenix-admin-basic-auth.md`             | Basic auth for admin routes                             |
| `shared/recipes/phoenix-channels-messagepack-flutter.md` | Phoenix Channels with MessagePack for Flutter clients   |
| `shared/recipes/phoenix-docker-ci-optimization.md`       | Docker + CI build optimization for Phoenix              |
| `shared/recipes/phoenix-live-title-page-titles.md`       | Dynamic page titles via LiveView                        |
| `shared/recipes/phoenix-file-upload-html-labels.md`      | File upload with accessible HTML labels                 |
| `shared/recipes/phoenix-image-optimization-vix.md`       | Image optimization with Vix/libvips in Phoenix          |
| `shared/recipes/phoenix-param-normalization.md`          | Normalizing URL params in Phoenix controllers/LiveView  |
| `shared/recipes/phoenix-smoke-testing.md`                | Smoke test patterns for Phoenix apps                    |
| `shared/recipes/elixir-context-test-structure.md`        | Elixir context module + test organization               |
| `shared/recipes/elixir-module-organization-skeleton.md`  | Module organization and skeleton patterns in Elixir     |
| `shared/recipes/elixir-with-for-chained-failable-ops.md` | `with` and `for` for chained failable operations        |
| `shared/recipes/elixir-async-false-triage.md`            | Triaging `async: false` test requirements in Elixir     |
| `shared/recipes/elixir-parallel-test-module-split.md`    | Splitting test modules for parallel execution           |
| `shared/recipes/elixir-sync-test-module-split.md`        | Splitting test modules for sync isolation               |
| `shared/recipes/elixir-telemetry-test-isolation.md`      | Telemetry isolation in Elixir tests                     |
| `shared/recipes/elixir-test-compile-env-config.md`       | Compile-time env config for Elixir tests                |
| `shared/recipes/elixir-type-duplication.md`              | Eliminating type duplication across Elixir modules      |
| `shared/recipes/elixir-capture-logs-on-error-paths.md`   | Capturing logs on error paths in Elixir tests           |
| `shared/recipes/elixir-process-local-config-override.md` | Process-local config overrides in Elixir                |
| `shared/recipes/elixir-ex-ast-refactor.md`               | AST-level refactoring patterns in Elixir                |
| `shared/recipes/elixir-hex-library-release.md`           | Releasing Elixir libraries to Hex.pm                    |
| `shared/recipes/nodejs-detached-process-cleanup.md`      | Detached Node process group cleanup (kill -TERM/-KILL)  |
| `shared/recipes/oban-ecto-multi-atomic-enqueue.md`       | Wrap DB insert + Oban enqueue in Ecto.Multi transaction |
| `shared/recipes/oban-job-rescheduling.md`                | Oban job rescheduling and retry patterns                |
| `shared/recipes/oban-worker-return-contract.md`          | Oban worker return value contract                       |
| `shared/recipes/refactor-grep-reader-scope.md`           | Grep all readers before field/function removal          |
| `shared/recipes/mox-verify-on-exit-scope.md`             | Mox `verify_on_exit!` scoping in tests                  |
| `shared/recipes/req-test-stub-external-http.md`          | Stubbing external HTTP calls with Req.Test              |
| `shared/recipes/third-party-api-verification.md`         | Verifying third-party API integrations                  |
| `shared/recipes/figma-to-code-mcp.md`                    | Figma-to-code workflow via MCP                          |
| `shared/recipes/figma-visual-verification.md`            | Visual verification against Figma designs               |
| `shared/recipes/ets-content-cache.md`                    | ETS-backed content cache implementation                 |
| `shared/recipes/ets-session-storage-poc.md`              | ETS-backed session storage proof-of-concept             |
| `shared/recipes/postgresql-fulltext-search.md`           | PostgreSQL full-text search setup in Phoenix            |
| `shared/recipes/sqlite-upsert.md`                        | SQLite upsert patterns in Elixir/Ecto                   |
| `shared/recipes/semantic-component-api-design.md`        | Semantic API design for Phoenix/HEEx components         |
| `shared/recipes/test-coverage-strategies.md`             | Test coverage strategies for Elixir/Phoenix projects    |
| `shared/recipes/flaky-test-fix.md`                       | Diagnosing and fixing flaky tests                       |
| `shared/recipes/github-workflows-mix-generator.md`       | GitHub Actions workflows for Elixir/Mix projects        |
| `shared/recipes/caddy-dynamic-routing.md`                | Dynamic routing with Caddy reverse proxy                |
| `shared/recipes/claude-cli-subprocess.md`                | Invoking Claude CLI as a subprocess                     |
| `shared/recipes/i18n-enum-translation.md`                | Enum translation patterns for i18n                      |
| `shared/recipes/push-notification-ack-timing.md`         | Push notification acknowledgment timing                 |
| `shared/recipes/push-notification-http-delivery-ack.md`  | HTTP-based push notification delivery acknowledgment    |
| `shared/recipes/datetime-form-timezone.md`               | Datetime form inputs with timezone handling             |
| `shared/recipes/docx-to-pdf-generation.md`               | DOCX-to-PDF generation pipeline                         |
| `shared/recipes/task-supervisor-sandbox-allowance.md`    | Task.Supervisor sandbox permissions for tests           |
| `shared/recipes/tidewave-mcp-verification.md`            | Tidewave MCP connection verification                    |
| `shared/recipes/database-sanitization-preview.md`        | Database sanitization preview workflow                  |
| `shared/recipes/phoenix-verified-routes-dynamic.md`      | Dynamic verified routes in Phoenix                      |
| `shared/recipes/phoenix-dual-mode-component.md`          | Dual-mode (live/dead) Phoenix component pattern         |
| `shared/recipes/phoenix-component-migration.md`          | Migrating Phoenix components across versions            |
| `shared/recipes/phoenix-component-attribute-ordering.md` | Attribute ordering conventions for Phoenix components   |
| `shared/recipes/phoenix-file-extension-routing.md`       | File-extension-based routing in Phoenix                 |
| `shared/recipes/phoenix-cucumber-bdd-setup.md`           | Cucumber/BDD setup for Phoenix                          |
| `shared/recipes/phoenix-repository-hygiene.md`           | Ecto repository hygiene patterns                        |

## Key Paths

```
shared/recipes/
  *.md                ← individual recipe files (~80+ recipes)
```

## Integration Points

- **subagents**: planners and developers reference recipes by name in plans; `process_template.py` resolves includes at generate time
- **rules**: recipes complement rules — rules encode behavioral constraints; recipes encode proven implementation sequences
- **scaffold**: scaffold templates reference recipes for standard patterns

## Trigger Keywords

recipe, recipe INDEX, static-vite-scaffold, phoenix-feature-test-setup, oban-job-rescheduling, mox-verify-on-exit-scope, elixir-context-test-structure, nodejs-detached-process-cleanup, oban-ecto-multi-atomic-enqueue, refactor-grep-reader-scope

## Notable Patterns

**Slash-command-to-subagent-swarm pattern**: Slash commands (in `harnesses/claude/commands/`) can spawn swarms of subagents for stress-testing or exploration. Example: `/poke-holes` spawns an Explore swarm with multiple attack angles (scope holes, unverified claims, contract breakage, consistency gaps). Spawned agents auto-fold confirmed findings back into the pitch. Gating via `operator-subagent-allowlist.sh` restricts spawning to debug/shape/refactor/ops roles.

## Pitfalls

- **Recipes are templates, not installed artifacts** — they are `{% include %}`d at generate time via `process_template.py`; they do not exist as standalone files in deployed agents
- **Recipe names must match exactly** — planner references recipe by filename (without `.md`); typos in recipe names cause silent include failures
- **Recipes accumulate** — the catalog is large (~80+ files); load only the specific recipe relevant to the current task

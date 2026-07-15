# Usage Rules Index — Build Platform

This index is cache-scoped to the build platform and lists the usage-rules files
relevant to its direct dependencies. The shared corpus contains 90+ files covering many
more libraries; only the deps listed here are direct dependencies of the platform today.
Implementers should read only the files listed for the dep(s) relevant to their task —
loading the entire corpus is wasteful and token-expensive.

## appsignal_phoenix

Use when: configuring AppSignal Phoenix integration, instrumenting LiveView, or debugging metrics.

- `appsignal_phoenix-2.8.1.md`

## bandit

Use when: configuring HTTP server, tuning connection limits, or debugging Plug adapter behaviour.

- `bandit-1.12.0.md`

## credo

Use when: fixing Credo violations, configuring `.credo.exs`, or understanding Credo checks.

- `credo-1.7.19.md`

## dialyxir

Use when: resolving Dialyzer type errors, adding specs, or configuring `mix dialyzer`.

- `dialyxir-1.4.7.md`

## dns_cluster

Use when: configuring distributed Elixir node discovery or debugging cluster formation.

- `dns_cluster-0.2.0.md`

## doctest_formatter

Use when: formatting doctests or configuring the doctest formatter.

- `doctest_formatter-0.4.1.md`

## ecto_sql

Use when: writing migrations, queries, or troubleshooting Ecto adapter behaviour.

- `ecto_sql-3.13.5.md`

## elixir_make

Use when: troubleshooting NIF compilation in deps that ship C code.

- `elixir_make-0.9.0.md`

## esbuild

Use when: configuring the JavaScript bundler, adding esbuild plugins, or debugging asset pipeline.

- `esbuild-0.10.0.md`

## ex_aws

Use when: configuring ExAws clients, signing requests, or troubleshooting auth/regions.

- `ex_aws-2.6.1.md`

## ex_aws_s3

Use when: presigning S3 URLs, head_object, multipart uploads, or path-style/bucket config (Hetzner, MinIO).

- `ex_aws_s3-2.5.9.md`

## ex_doc

Use when: writing module docs, configuring `mix docs`, or setting up ExDoc extras.

- `ex_doc-0.40.3.md`

## ex_machina

Use when: writing test factories, using `build/2` or `insert/2`, or debugging factory associations.

- `ex_machina-2.8.0.md`

## excoveralls

Use when: configuring coverage thresholds, `coveralls.json` skip patterns, or understanding coverage reports.

- `excoveralls-0.18.5.md`

## exexec

Use when: spawning OS processes for user-app builds, monitoring exit codes, or streaming stdout.

- `exexec-git-00bdc9d.md`

## faker

Use when: generating test data (names, emails, phone numbers, sentences) in factory modules.

- `faker-0.18.0.md`

## gettext

Use when: adding translations, running `mix gettext.extract`, or configuring locales.

- `gettext-1.0.2.md`

## hackney

Use when: tuning HTTP pool size, SSL options, or debugging upstream request failures from `stripity_stripe`.

- `hackney-1.25.0.md`

## jason

Use when: encoding/decoding JSON, handling custom types, or tuning encoder options.

- `jason-1.4.5.md`

## joken

Use when: signing/verifying JWTs for the magic-link auth service.

- `joken-2.6.2.md`

## mix_audit

Use when: running dependency security audits or understanding advisory output.

- `mix_audit-2.1.5.md`

## mox

Use when: declaring behaviour mocks (`App.LLM.RunnerMock`, `BuildAdapterMock`, `Storage` test impl) or configuring Mox in test setup.

- `mox-1.2.0.md`

## oban

Use when: writing workers, configuring queues, testing jobs, or debugging distributed queue behaviour.

- `oban-2.21.1.md`
- `oban-2.21.1-advanced.md`
- `oban-2.21.1-installation.md`
- `oban-2.21.1-jobs.md`
- `oban-2.21.1-monitoring.md`
- `oban-2.21.1-queues.md`
- `oban-2.21.1-scheduling.md`
- `oban-2.21.1-testing.md`
- `oban-2.21.1-workers.md`

## optimum_credo

Use when: understanding custom Credo checks added by the Optimum credo plugin.

- `optimum_credo-0.4.0.md`

## phoenix

Use when: writing controllers, router scopes, channels, plugs, or deployment configs.

- `phoenix-1.8.8.md`
- `phoenix-1.8.8-components.md`
- `phoenix-1.8.8-controllers-views.md`
- `phoenix-1.8.8-controllers.md`
- `phoenix-1.8.8-deployment.md`
- `phoenix-1.8.8-ecto.md`
- `phoenix-1.8.8-json.md`
- `phoenix-1.8.8-liveview.md`
- `phoenix-1.8.8-plug.md`
- `phoenix-1.8.8-plugs-telemetry.md`
- `phoenix-1.8.8-realtime.md`
- `phoenix-1.8.8-routing.md`
- `phoenix-1.8.8-security.md`
- `phoenix-1.8.8-setup.md`
- `phoenix-1.8.8-testing.md`

## phoenix_ecto

Use when: integrating Ecto changesets with Phoenix forms or writing form-backed LiveViews.

- `phoenix_ecto-4.7.0.md`

## phoenix_html

Use when: using HTML helpers, safe strings, or understanding Phoenix HTML component rendering.

- `phoenix_html-4.3.0.md`

## phoenix_live_dashboard

Use when: configuring the LiveDashboard route, adding custom metrics pages, or debugging telemetry.

- `phoenix_live_dashboard-0.8.7.md`

## phoenix_live_reload

Use when: configuring live reload patterns or debugging hot-reload behaviour in development.

- `phoenix_live_reload-1.6.2.md`

## phoenix_live_view

Use when: writing LiveView modules, hooks, forms, navigation, uploads, or LiveView testing.

- `phoenix_live_view-1.1.32.md`
- `phoenix_live_view-1.1.32-assigns.md`
- `phoenix_live_view-1.1.32-async.md`
- `phoenix_live_view-1.1.32-bindings.md`
- `phoenix_live_view-1.1.32-components.md`
- `phoenix_live_view-1.1.32-forms.md`
- `phoenix_live_view-1.1.32-js-interop.md`
- `phoenix_live_view-1.1.32-js.md`
- `phoenix_live_view-1.1.32-lifecycle.md`
- `phoenix_live_view-1.1.32-navigation.md`
- `phoenix_live_view-1.1.32-router.md`
- `phoenix_live_view-1.1.32-security.md`
- `phoenix_live_view-1.1.32-uploads.md`

## postgrex

Use when: debugging PostgreSQL wire protocol issues, type extensions, or connection pool configuration.

- `postgrex-0.22.0.md`

## remote_ip

Use when: configuring trusted proxies behind Caddy, or debugging client-IP extraction in webhooks.

- `remote_ip-1.2.0.md`

## req

Use when: making HTTP requests, configuring middleware, retry logic, or testing with `Req.Test`.

- `req-0.5.17.md`

## sobelow

Use when: running security scans, understanding reported findings, or configuring `.sobelow-conf`.

- `sobelow-0.14.1.md`

## stripity_stripe

Use when: implementing Stripe Connect endpoints, webhook signature verification, or subscription reconciliation.

- `stripity_stripe-3.2.0.md`

## sweet_xml

Use when: parsing Namecheap XML responses or any other XML feed (`Hosting.Namecheap`).

- `sweet_xml-0.7.5.md`

## swoosh

Use when: writing email templates, configuring adapters, or testing mailers with `Swoosh.Adapters.Test`.

- `swoosh-1.22.1.md`

## systemd

Use when: integrating with systemd notifications/sockets in production releases.

- `systemd-0.6.2.md`

## tailwind

Use when: configuring the Tailwind build step, `tailwind.config.js`, or debugging CSS pipeline.

- `tailwind-0.5.1.md`

## telemetry_metrics

Use when: defining metrics, attaching reporters, or understanding metric types (counter, summary, etc.).

- `telemetry_metrics-1.1.0.md`

## telemetry_poller

Use when: configuring periodic measurement polling or adding custom VM metrics.

- `telemetry_poller-1.3.0.md`

## tidewave

Use when: configuring the Tidewave MCP server or verifying unknown library function signatures.

- `tidewave-0.6.1.md`

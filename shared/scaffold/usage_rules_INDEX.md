# Usage Rules Index

These files document the API surface of libraries used in this project.
Load the relevant file(s) when implementing features that touch the listed library.

| File                            | Library          | Load when working on...                         |
| ------------------------------- | ---------------- | ----------------------------------------------- |
| `phoenix-1.7.md`                | Phoenix 1.7      | Routes, controllers, plugs, endpoint config     |
| `phoenix_live_view-1.0.md`      | LiveView 1.0     | LiveView modules, components, JS hooks          |
| `phoenix_live_dashboard-0.8.md` | LiveDashboard    | /dev/dashboard setup, telemetry metrics         |
| `ecto-3.12.md`                  | Ecto 3.12        | Schemas, migrations, changesets, queries        |
| `ecto_sql-3.12.md`              | Ecto SQL         | Repo, migrations, sandboxing                    |
| `swoosh-1.17.md`                | Swoosh           | Mailers, email composition, adapters            |
| `finch-0.19.md`                 | Finch            | HTTP client, connection pools                   |
| `telemetry_metrics-1.0.md`      | Telemetry        | Metrics, reporters, event handlers              |
| `telemetry_poller-1.1.md`       | Telemetry Poller | Periodic measurements, VM metrics               |
| `gettext-0.26.md`               | Gettext          | Internationalisation, locale strings            |
| `jason-1.4.md`                  | Jason            | JSON encoding/decoding                          |
| `dns_cluster-0.1.md`            | DNS Cluster      | Distributed node discovery via DNS              |
| `bandit-1.6.md`                 | Bandit           | HTTP server adapter for Phoenix                 |
| `heroicons-0.5.md`              | Heroicons        | Icon components in HEEx templates               |
| `esbuild-0.8.md`                | Esbuild          | JavaScript bundling, assets.build/assets.deploy |
| `tailwind-0.2.md`               | Tailwind CSS     | CSS compilation, assets.build/assets.deploy     |

> **Note**: Not all files may exist yet. Load the file only if it is present in `codegen/usage_rules/`.
> Add entries here when new libraries are added to `mix.exs`.

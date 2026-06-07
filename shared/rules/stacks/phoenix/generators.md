# Phoenix Generators

## Schemas and Migrations

ALWAYS use `mix phx.gen.schema` to create schemas and their migrations:

```bash
mix phx.gen.schema Accounts.User users email:string name:string
```

NEVER hand-write schemas or migrations manually. Reasons:

- Migration timestamps are derived from the current time at generation; hand-writing copies a timestamp and causes ordering bugs
- The generator produces the correct Ecto schema boilerplate, including types and indexes
- Hand-writing introduces drift from generator conventions

## Authentication

ALWAYS use `mix phx.gen.auth` to scaffold the authentication layer:

```bash
mix phx.gen.auth Accounts User users
```

NEVER hand-write authentication modules, token tables, session plugs, or UserAuth plug. Reasons:

- `phx.gen.auth` produces security-reviewed, tested boilerplate (token rotation, timing-safe comparisons, session renewal)
- Hand-writing auth is a high-severity security risk

After running `mix phx.gen.auth`, run `mix deps.get && mix ecto.migrate`.

## Features and Business Logic

HAND-WRITE LiveViews, contexts, and feature logic — do NOT use:

- `mix phx.gen.live` — generates full CRUD surface; stripping unused functions trips credo
- `mix phx.gen.html` — same issue
- `mix phx.gen.context` — generates context + schema together; loses fine-grained control

Lean feature implementations require hand-written context functions and LiveViews scoped to the actual feature surface.

## Hard Rules

- `ALWAYS` `mix phx.gen.schema <Module> <table> [fields]` — schemas + migrations
- `ALWAYS` `mix phx.gen.auth Accounts User users` — authentication
- `NEVER` hand-write schemas or migrations (timestamp collisions, boilerplate drift)
- `NEVER` hand-write auth modules (security risk)
- `NEVER` use `mix phx.gen.live` / `mix phx.gen.html` / `mix phx.gen.context` for features (over-generation → credo failures)

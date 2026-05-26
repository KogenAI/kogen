# oban - Database Engines & Persistence

## Engine Architecture

Oban uses pluggable database engines to manage all job persistence and coordination. The engine behavior defines the contract for job lifecycle operations from insertion through execution.

## Built-in Engine Implementations

**Basic Engine** — Default engine for development and production:

```elixir
config :my_app, Oban,
  engine: Oban.Engine.Basic,
  repo: MyApp.Repo
```

The Basic engine handles all standard job operations using direct database queries. Suitable for most applications; does not support advanced features like global concurrency control or smart rate limiting (available in Oban Pro's Smart engine).

**Inline Engine** — Testing engine that executes jobs immediately:

```elixir
config :my_app, Oban,
  engine: Oban.Engine.Inline,
  testing: :inline
```

Used with `:inline` testing mode. Jobs execute synchronously in the calling process without database roundtrips, bypassing the queue system.

**Lite Engine** — SQLite3-compatible engine:

```elixir
config :my_app, Oban,
  engine: Oban.Engine.Lite,
  repo: MyApp.Repo
```

Implements the engine contract using SQLite3 compatible queries. Use when your application uses SQLite instead of PostgreSQL/MySQL.

## Engine Callbacks

The `Oban.Engine` behavior defines 24 primary callbacks organized by responsibility:

**Job Insertion:**

- `insert_job/3` — Add single job to database
- `insert_all_jobs/3` — Insert multiple jobs atomically

**Job Fetching & Execution:**

- `fetch_jobs/3` — Retrieve available jobs for queue
- `complete_job/2` — Mark job successful
- `error_job/3` — Record job failure, determine retry

**Job State Transitions:**

- `stage_jobs/3` — Promote scheduled/retryable jobs to available
- `snooze_job/3` — Reschedule executing job for future run
- `cancel_job/2` — Prevent job execution (all states)
- `cancel_all_jobs/2` — Cancel multiple jobs matching criteria
- `discard_job/2` — Mark job permanently unrunnable

**Administrative:**

- `init/2`, `shutdown/2` — Queue lifecycle
- `refresh/2` — Signal queue liveness
- `rescue_jobs/3` — Recover jobs stuck in executing state
- `prune_jobs/3` — Delete old completed/cancelled/discarded jobs
- `put_meta/3` — Update job metadata

**Metadata & Inspection:**

- `put_meta/3` — Update job metadata
- `check_available/2` — Count available jobs in queue
- `get_job/2` — Retrieve specific job by ID

## Job Persistence Model

All engines persist jobs in a database table with the following core fields:

**Identification:**

- `id` — Auto-incrementing primary key
- `worker` — Binary module name
- `queue` — Queue assignment
- `args` — Job arguments (JSON encoded)

**Execution Control:**

- `state` — Current job state (scheduled, available, executing, etc.)
- `priority` — 0-9 priority level
- `attempt` — Current attempt count
- `max_attempts` — Maximum attempts allowed

**Timing:**

- `scheduled_at` — When job becomes available
- `attempted_at` — When last attempt started
- `completed_at` — When job finished (NULL if not completed)
- `discarded_at` — When job discarded
- `cancelled_at` — When job cancelled

**Metadata & History:**

- `tags` — Array of string tags
- `meta` — Custom JSON metadata
- `errors` — Array of error history
- `unique` — Uniqueness constraint config
- `inserted_at`, `updated_at` — Timestamps

The full `Oban.Job` schema mirrors this table structure plus runtime-only fields like `unsaved_error`.

## Engine Selection Guidance

**Choose Basic:**

- Standard PostgreSQL or MySQL database
- Production applications
- Need compatibility with standard Oban features

**Choose Lite:**

- Using SQLite3 as primary database
- Embedded applications or simpler deployments
- Lower operational overhead

**Choose Inline:**

- Testing with `:inline` mode configuration
- Job execution without database
- Immediate synchronous execution

**Choose Oban Pro Smart Engine:**

- Need global concurrency control across nodes
- Rate limiting requirements
- Distributed job prioritization
- Advanced workflow composition

## Database Migrations

Oban provides built-in migration generators. Create migrations for a new installation:

```bash
mix ecto.gen.migration create_oban_jobs
```

Then implement using Oban's provided functions (typically pre-generated):

```elixir
defmodule MyApp.Repo.Migrations.CreateObanJobs do
  use Ecto.Migration

  def up do
    Oban.Migrations.up(version: 1)
  end

  def down do
    Oban.Migrations.down(version: 1)
  end
end
```

The migration creates the `oban_jobs` table with appropriate indexes for efficient querying.

## Performance Tuning

**Partition Size** — Control jobs fetched per query:

```elixir
config :my_app, Oban,
  queues: [
    default: [limit: 10, partition_size: 10]
  ]
```

Larger partition sizes mean fewer database queries but higher memory per query. Tune based on job size and network latency.

**Staging Interval** — Control how frequently scheduled jobs are promoted to available:

```elixir
config :my_app, Oban,
  stage_interval: 5000  # milliseconds (default)
```

Smaller intervals mean lower scheduling latency but more frequent staging queries.

**Dispatch Cooldown** — Delay before queue notifier triggers producer dispatch:

```elixir
config :my_app, Oban,
  dispatch_cooldown: 100  # milliseconds
```

Prevents excessive dispatch notifications when multiple jobs insert simultaneously.

## Job Rescue Process

Oban includes automatic job rescue to recover jobs stuck in `:executing` state. The rescue process periodically checks for jobs that haven't progressed in a configurable time window and transitions them back to `:available` for retry.

The Basic engine runs rescue checks via the Notifier plugin. Ensure your notifier is properly configured for rescue to function in production.

## Database Requirements

**PostgreSQL:** 14.0+ with support for JSON operators, LISTEN/NOTIFY, and window functions.

**MySQL:** 8.4+ with JSON support.

**SQLite:** 3.37.0+ via Lite engine.

All implementations support:

- Atomic transactions for uniqueness enforcement
- ACID compliance for job state transitions
- Historical data retention indefinitely

---

[← Back to main](oban-2.20.3.md)
**Version:** 2.20.3

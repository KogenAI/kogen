# oban - Scheduling & CRON Jobs

## Scheduled Jobs

Schedule jobs for future execution using `schedule_in` option:

```elixir
# Execute in 5 minutes
MyApp.ReportWorker.new(%{id: 123})
|> Oban.insert(schedule_in: {5, :minutes})

# Execute in 1 hour
MyApp.CleanupWorker.new(%{})
|> Oban.insert(schedule_in: {1, :hour})

# Execute in 30 seconds
MyApp.NotificationWorker.new(%{user_id: 456})
|> Oban.insert(schedule_in: 30)
```

Schedule time units:

- Seconds (integer): `30` → 30 seconds
- Tuples: `{5, :minutes}`, `{2, :hours}`, `{1, :day}`

Scheduled jobs enter the `"scheduled"` state and automatically transition to `"available"` when their `scheduled_at` time arrives.

## CRON Jobs

Oban has built-in cron support via the `Oban.Cron` module. Define cron workers to periodically enqueue jobs:

```elixir
defmodule MyApp.DailyReportWorker do
  use Oban.Worker

  def perform(_job) do
    # Generate report
    generate_daily_report()
    :ok
  end
end

defmodule MyApp.CronJobs do
  use Oban.Cron, oban: MyApp.Oban

  # Run every day at 2 AM UTC
  @monthly_subscription_check "0 2 * * *"
  def schedule do
    worker(MyApp.DailyReportWorker, %{})
  end
end
```

Register cron workers in your Oban supervisor:

```elixir
config :my_app, Oban,
  plugins: [
    {Oban.Plugins.Cron, crontab: [
      {"0 2 * * *", MyApp.DailyReportWorker},     # 2 AM daily
      {"0 0 * * 0", MyApp.WeeklyCleanupWorker},   # Sunday midnight
      {"0 */6 * * *", MyApp.SyncDataWorker}       # Every 6 hours
    ]}
  ]
```

## CRON Schedule Format

Oban uses standard 5-field cron syntax: `minute hour day-of-month month day-of-week`

```
0  0  1  *  *     # 1st of every month at midnight
0  12 *  *  1-5   # Weekdays at noon
*/15 * *  *  *    # Every 15 minutes
0  0  *  *  0,6   # Weekends at midnight
```

## CRON Uniqueness

Prevent multiple nodes from enqueuing the same cron job:

```elixir
@hourly_check "0 * * * *"
def schedule do
  worker(MyApp.HourlyWorker, %{}, unique: [period: 3600])
end
```

With uniqueness enabled, only one node enqueues the job even in multi-node deployments.

## Dynamic Cron (Oban Pro)

In Oban Pro, modify cron schedules at runtime:

```elixir
# Update cron schedule
Oban.Pro.Cron.upsert(
  MyApp.DailyReportWorker,
  "0 3 * * *"  # Change to 3 AM
)

# Delete cron job
Oban.Pro.Cron.delete(MyApp.DailyReportWorker)
```

## Testing Scheduled & CRON Jobs

Include scheduled jobs in test drains:

```elixir
defmodule MyApp.SchedulingTest do
  use ExUnit.Case

  test "cron job enqueues correctly" do
    # Insert scheduled job
    MyApp.ReportWorker.new(%{})
    |> Oban.insert(schedule_in: {1, :minute})

    # Drain with scheduled jobs included
    Oban.drain_queue(:default, with_scheduled: true)

    # Verify execution
    assert report_generated?()
  end
end
```

## Timezone Handling

Cron schedules use UTC by default. For application-specific timezones, calculate schedule times in your app:

```elixir
def schedule_in_timezone(job, hours, timezone) do
  now = DateTime.now!(timezone)
  scheduled = DateTime.add(now, hours * 3600)

  job
  |> Oban.insert(schedule_in: DateTime.diff(scheduled, DateTime.utc_now()))
end
```

## Troubleshooting CRON in Development

CRON jobs may not trigger immediately after restart due to leadership delays:

**Solution 1:** Wait ~30 seconds for leadership to stabilize.

**Solution 2:** Use global peer for graceful restarts:

```elixir
config :my_app, Oban,
  peer: Oban.Peers.Global
```

**Solution 3:** Manually clear peer state for testing:

```bash
# In IEx
MyApp.Repo.query!("DELETE FROM oban_peers")
```

## Monitoring CRON Jobs

Query cron job history:

```elixir
Oban.Job
|> where([j], j.worker in ["MyApp.DailyReportWorker", "MyApp.WeeklyCleanupWorker"])
|> order_by([j], desc: j.inserted_at)
|> limit(100)
|> MyApp.Repo.all()
```

---

[← Back to main](oban-2.21.1.md)  
**Version:** 2.21.1

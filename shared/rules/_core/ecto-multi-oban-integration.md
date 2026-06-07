# Ecto.Multi + Oban Integration

Wrapping DB mutations + job enqueue in a single transaction ensures row and job either both commit or both roll back, eliminating orphan windows where the row exists but the job failed to enqueue (or vice versa).

## Atomic Enqueue Pattern

When a context function must both insert a database row AND enqueue an Oban job, use `Ecto.Multi` → `Repo.transaction` to make the pair atomic.

**Current (NOT atomic):**

```elixir
{:ok, record} = MyContext.create_record(%{...})

case %{...}
  |> MyWorker.new(queue: :my_queue)
  |> Oban.insert() do
  {:ok, _job} ->
    notify_success(record)

  {:error, reason} ->
    Logger.error("Job enqueue failed: #{inspect(reason)}")
    # Record exists in DB but job never made it to queue — orphan state
end
```

**Refactored (atomic):**

```elixir
record_changeset = MySchema.changeset(%MySchema{}, %{...})

worker_fn = fn %{record: record} ->
  %{record_id: record.id, ...}
  |> MyWorker.new(queue: :my_queue)
end

case Ecto.Multi.new()
     |> Ecto.Multi.insert(:record, record_changeset)
     |> Oban.insert(:job, worker_fn)
     |> Repo.transaction() do
  {:ok, %{record: record}} ->
    # Both row AND job committed
    notify_success(record)

  {:error, op, reason, _changes} ->
    # Transaction rolled back — neither row nor job exists
    Logger.error("Atomic enqueue failed at #{op}: #{inspect(reason)}")
end
```

## Telemetry Placement

**WRONG: Telemetry inside the transaction**

```elixir
Ecto.Multi.new()
|> Ecto.Multi.run(:record, fn _repo, _changes ->
  record = MyContext.create_record(%{...})  # fires telemetry inside Multi.run
  {:ok, record}
end)
|> Oban.insert(:job, worker_changeset)
|> Repo.transaction()
```

Problem: If the Oban insert fails, the transaction rolls back BUT the telemetry event already fired inside the transaction. Telemetry subscribers see the event even though the transaction failed.

**CORRECT: Telemetry after the transaction**

```elixir
case Ecto.Multi.new()
     |> Ecto.Multi.insert(:record, record_changeset)
     |> Oban.insert(:job, worker_fn)
     |> Repo.transaction() do
  {:ok, %{record: record}} ->
    :telemetry.execute(
      [:my_app, :records, :created],
      %{},
      %{record_id: record.id}
    )
    notify_success(record)

  {:error, op, reason, _changes} ->
    Logger.error("...")
end
```

Telemetry fires only when both the row and the job have successfully committed.

## Worker Changeset Via Fn Form

When the worker args depend on the result of a preceding Multi step (e.g., `record_id` is only available after the `:record` step inserts), use the fn form in `Oban.insert/3`:

```elixir
Ecto.Multi.new()
|> Ecto.Multi.insert(:record, record_changeset)
|> Oban.insert(:job, fn %{record: record} ->
  %{
    record_id: record.id,
    user_id: user.id,
    ...
  }
  |> MyWorker.new(queue: :my_queue)
end)
|> Repo.transaction()
```

The fn receives the accumulated Multi results map at execution time (during the transaction), not at construction time. This allows `record.id` to be captured from the `:record` step's committed result.

**Avoid**: using a static changeset with `nil` placeholders and trying to fill them in afterwards — the transaction commits the `nil` values:

```elixir
# WRONG
worker_changeset = %{"record_id" => nil, ...}
|> MyWorker.new()

Ecto.Multi.new()
|> Ecto.Multi.insert(:record, record_changeset)
|> Oban.insert(:job, worker_changeset)  # Job args have record_id: nil
|> Repo.transaction()
```

## Error Handling

On transaction failure (`{:error, op, reason, _changes}`):

- The failed operation's changeset/reason is in `reason`
- All prior steps have been rolled back (no row, no job)
- Do NOT call context functions that depend on the row existing (e.g., `MyContext.cancel_record/1`)
- Log the error; the transaction cleanup is atomic

## Success Arm Structure

Extract the successful results from the `{:ok, results_map}` tuple:

```elixir
case Repo.transaction(...) do
  {:ok, %{record: record}} ->
    # 'record' is the committed row from the :record step
    # Use it for side-effects, notifications, etc.

  {:error, op, reason, _changes} ->
    # Transaction rolled back entirely
end
```

The `:record` key in the results map matches the first arg to `Ecto.Multi.insert/3`.

## Context Function Bypass

When refactoring a two-phase pattern (context fn that fires telemetry → separate enqueue), do NOT use `Ecto.Multi.run` to call the existing context fn:

```elixir
# WRONG
Ecto.Multi.new()
|> Ecto.Multi.run(:record, fn _repo, _changes ->
  MyContext.create_record(%{...})  # fires telemetry inside transaction
end)
|> ...
```

Instead, insert the changeset directly via `Ecto.Multi.insert`:

```elixir
# CORRECT
record_changeset = MySchema.changeset(%MySchema{}, attrs)

Ecto.Multi.new()
|> Ecto.Multi.insert(:record, record_changeset)
|> Oban.insert(:job, worker_fn)
|> Repo.transaction()

# Then, fire telemetry post-commit in the {:ok, ...} arm
```

This ensures telemetry is a side-effect of the transaction result, not an internal event.

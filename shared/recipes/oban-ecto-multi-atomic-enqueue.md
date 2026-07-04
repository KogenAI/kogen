# Ecto.Multi + Oban Integration

Wrap DB mutations + job enqueue in a single transaction: row and job either both commit or both roll back, eliminating orphan windows.

## Atomic Enqueue Pattern

Use `Ecto.Multi` → `Repo.transaction` to make insert + enqueue atomic. Telemetry fires AFTER the transaction — never inside it. Use fn-form in `Oban.insert/3` when worker args depend on a preceding Multi step result.

**Non-atomic (WRONG):**

```elixir
{:ok, record} = MyContext.create_record(%{...})
Oban.insert(MyWorker.new(%{record_id: record.id}))
# record exists but job may fail — orphan state
```

**Atomic (CORRECT):**

```elixir
worker_fn = fn %{record: record} ->
  MyWorker.new(%{record_id: record.id}, queue: :my_queue)
end

case Ecto.Multi.new()
     |> Ecto.Multi.insert(:record, record_changeset)
     |> Oban.insert(:job, worker_fn)
     |> Repo.transaction() do
  {:ok, %{record: record}} ->
    :telemetry.execute([:app, :record, :created], %{}, %{id: record.id})
    notify_success(record)
  {:error, op, reason, _} ->
    Logger.error("Failed at #{op}: #{inspect(reason)}")
    # Transaction rolled back — neither row nor job exists
end
```

Key rules:

- Telemetry fires in the `{:ok, ...}` arm, never inside `Multi.run`
- `on failure neither row nor job exists` — do NOT call context fns that assume row exists
- Pass the changeset directly to `Ecto.Multi.insert/3`; do NOT wrap an existing context fn in `Multi.run` (it fires telemetry inside the transaction)

defmodule Kogen.Build.Fanout do
  @moduledoc """
  Runs independent jobs concurrently under a finite ceiling and settles every
  one of them.

  A job is `%{id: String.t(), run: (ctx -> map)}`. `ctx` holds:

    * `:id` and `:dir` (the job's own directory, created before it starts);
    * `:cancelled?` - `fn -> boolean` that turns true once the fan-out is
      cancelled, for jobs that are not a supervised child;
    * `:on_start` - pass as `Kogen.ProcessCustody.run/3`'s `:on_start` (or
      through `Kogen.Build.VerificationRunner`) so the job's child process
      group can be reaped by identity on cancellation.

  `max_concurrency` is a resource cap, never a spend count. There is no
  fail-fast: one job's failure never cancels another. Only an explicit
  cancellation does: `cancel/2` (controller shutdown), the
  caller dying, or the caller's `:stop_when` predicate (fired after each job
  settles, for a classified provider or environment stop). Cancellation marks
  queued jobs `not_started`, reaps the running jobs' owned process groups
  through `Kogen.ProcessCustody.reap_identity/2` (TERM then KILL, identity
  verified, never an ancestor or an unrelated group) and records them
  `cancelled`: neither pass nor fail.

  Every job's settlement is written atomically to
  `<settle_root>/<id>/settlement.json` (digest in `settlement.sha256`) as it
  settles, so a restart can see, with `read_settled/1`, which jobs settled.
  Atom keys in a result (for example an in-memory `:term`) are returned to the
  caller but never persisted.

  Each settled entry is `%{"id", "status", "reason", "result",
  "started_at", "finished_at", "settlement" => %{"path", "sha256"}}` with
  `"status"` one of `settled`, `cancelled`, `not_started`, `crashed`.
  """

  defstruct [:pid, :ref]

  @statuses ~w(settled cancelled not_started crashed)
  @id ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @cancel_grace_ms 30_000

  @doc "Runs `jobs` to settlement. See `start/2` for options."
  @spec run([map()], keyword()) :: map()
  def run(jobs, opts \\ []) do
    {:ok, handle} = start(jobs, opts)
    await(handle)
  end

  @doc """
  Starts the fan-out and returns a handle. Options: `:max_concurrency`
  (optional positive integer cap; absent means every job runs at once), `:settle_root` (directory for durable
  settlements), `:control` (control root, only for the custody test hooks),
  `:stop_when` (`fn entry -> falsy | reason` called after each `settled` job)
  and `:cancel_grace_ms` (how long a cancelled job that is not a supervised
  child may keep running before it is killed).
  """
  @spec start([map()], keyword()) :: {:ok, %__MODULE__{}}
  def start(jobs, opts \\ []) do
    max = Keyword.get(opts, :max_concurrency) || max(length(jobs), 1)

    unless is_integer(max) and max > 0,
      do: raise(ArgumentError, "max_concurrency must be a positive integer, got: #{inspect(max)}")

    ids = Enum.map(jobs, & &1.id)

    unless Enum.all?(ids, &(is_binary(&1) and Regex.match?(@id, &1))),
      do: raise(ArgumentError, "job ids must be safe directory names")

    unless length(Enum.uniq(ids)) == length(ids),
      do: raise(ArgumentError, "job ids must be unique")

    caller = self()
    ref = make_ref()
    pid = spawn(fn -> coordinate(caller, ref, jobs, max, opts) end)
    {:ok, %__MODULE__{pid: pid, ref: ref}}
  end

  @doc "Requests cancellation; `await/2` returns once everything settled."
  @spec cancel(%__MODULE__{}, String.t()) :: :ok
  def cancel(%__MODULE__{pid: pid}, reason \\ "cancelled") do
    send(pid, {:cancel, to_string(reason)})
    :ok
  end

  @doc """
  Waits for every job to settle. Returns `%{results: [entry], cancelled:
  reason | nil, max_observed: integer}` with results in job order.
  """
  @spec await(%__MODULE__{}, timeout()) :: map()
  def await(%__MODULE__{pid: pid, ref: ref}, timeout \\ :infinity) do
    monitor = Process.monitor(pid)
    send(pid, {:await, self(), ref})

    receive do
      {^ref, summary} ->
        Process.demonitor(monitor, [:flush])
        summary

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        exit({:fanout_coordinator_down, reason})
    after
      timeout -> exit(:fanout_await_timeout)
    end
  end

  @doc """
  Verifies a settled entry's file against its recorded digest and its
  `settlement.sha256` sidecar.
  """
  @spec verify_settlement(map()) :: :ok | {:error, String.t()}
  def verify_settlement(%{"settlement" => %{"path" => path, "sha256" => sha}})
      when is_binary(path) and is_binary(sha) do
    sidecar = Path.join(Path.dirname(path), "settlement.sha256")

    with {:ok, bytes} <- File.read(path),
         true <- sha256(bytes) == sha,
         {:ok, recorded} <- File.read(sidecar),
         true <- String.trim(recorded) == sha do
      :ok
    else
      _ -> {:error, "job settlement is missing or its digest changed: #{path}"}
    end
  end

  def verify_settlement(_entry), do: {:error, "job settlement is not recorded"}

  @doc """
  The settlements found under `settle_root` after a restart:
  `[%{"id", "status", "sha256", "verified"}]`, sorted by id. `verified` is
  false when the file no longer matches its digest.
  """
  @spec read_settled(Path.t()) :: [map()]
  def read_settled(settle_root) do
    case File.ls(settle_root) do
      {:ok, names} -> names |> Enum.sort() |> Enum.flat_map(&read_one(settle_root, &1))
      _ -> []
    end
  end

  defp read_one(root, name) do
    path = Path.join([root, name, "settlement.json"])

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"status" => status}} <- Jason.decode(bytes) do
      sha = sha256(bytes)
      entry = %{"settlement" => %{"path" => path, "sha256" => sha}}

      [
        %{
          "id" => name,
          "status" => status,
          "sha256" => sha,
          "verified" => verify_settlement(entry) == :ok
        }
      ]
    else
      _ -> []
    end
  end

  # -- coordinator ---------------------------------------------------------

  defp coordinate(caller, ref, jobs, max, opts) do
    Process.monitor(caller)

    st = %{
      ref: ref,
      caller: caller,
      opts: opts,
      max: max,
      order: Enum.map(jobs, & &1.id),
      queue: jobs,
      running: %{},
      results: %{},
      cancelled: nil,
      flag: :atomics.new(1, []),
      awaiting: [],
      high: 0
    }

    st |> start_more() |> loop()
  end

  defp loop(st) do
    if finished?(st) do
      finish(st)
    else
      receive do
        message -> st |> handle(message) |> loop()
      end
    end
  end

  defp finished?(st), do: st.queue == [] and st.running == %{}

  defp finish(st) do
    summary = %{
      results: Enum.map(st.order, &Map.fetch!(st.results, &1)),
      cancelled: st.cancelled,
      max_observed: st.high
    }

    Enum.each(st.awaiting, fn from -> send(from, {st.ref, summary}) end)
    idle(st, summary)
  end

  defp idle(st, summary) do
    receive do
      {:await, from, ref} when ref == st.ref ->
        send(from, {st.ref, summary})
        idle(st, summary)

      {:DOWN, _mref, :process, pid, _reason} when pid == st.caller ->
        :ok

      _other ->
        idle(st, summary)
    end
  end

  defp handle(st, {:await, from, ref}) when ref == st.ref,
    do: %{st | awaiting: [from | st.awaiting]}

  defp handle(st, {:cancel, reason}), do: cancel_all(st, reason)

  defp handle(st, {:DOWN, _mref, :process, pid, _reason}) when pid == st.caller,
    do: cancel_all(st, "caller_exit")

  defp handle(st, {:group, id, group}) do
    case st.running[id] do
      nil ->
        st

      job ->
        job = %{job | group: group}
        st = put_running(st, id, job)
        if st.cancelled, do: reap(st, id), else: st
    end
  end

  defp handle(st, {:job_done, id, outcome}) do
    case st.running[id] do
      nil ->
        st

      job ->
        Process.demonitor(job.mref, [:flush])
        st = put_running(st, id, %{job | done: outcome})
        st = if crashed?(outcome), do: reap(st, id), else: st
        settle_if_ready(st, id)
    end
  end

  defp handle(st, {:DOWN, mref, :process, _pid, reason}) do
    case Enum.find(st.running, fn {_id, job} -> job.mref == mref end) do
      {id, %{done: nil} = job} ->
        outcome = if job.killed, do: :killed, else: {:crashed, inspect(reason)}
        st = put_running(st, id, %{job | done: outcome})
        st = reap(st, id)
        settle_if_ready(st, id)

      _ ->
        st
    end
  end

  defp handle(st, {:reaped, id, result}) do
    case st.running[id] do
      nil ->
        st

      job ->
        st = put_running(st, id, %{job | reap: {:done, result}})
        settle_if_ready(st, id)
    end
  end

  defp handle(st, :cancel_deadline) do
    Enum.each(st.running, fn {_id, job} ->
      if job.done == nil and job.group == nil, do: Process.exit(job.pid, :kill)
    end)

    st.running
    |> Enum.filter(fn {_id, job} -> job.done == nil and job.group == nil end)
    |> Enum.reduce(st, fn {id, job}, acc -> put_running(acc, id, %{job | killed: true}) end)
  end

  defp handle(st, _other), do: st

  defp crashed?({:crashed, _}), do: true
  defp crashed?(_), do: false

  defp put_running(st, id, job), do: %{st | running: Map.put(st.running, id, job)}

  # -- starting ------------------------------------------------------------

  defp start_more(st) do
    if st.cancelled == nil and st.queue != [] and map_size(st.running) < st.max do
      [job | rest] = st.queue
      st = %{st | queue: rest} |> launch(job)
      start_more(st)
    else
      st
    end
  end

  defp launch(st, job) do
    coordinator = self()
    dir = job_dir(st.opts, job.id)
    if dir, do: File.mkdir_p!(dir)
    flag = st.flag
    id = job.id

    ctx = %{
      id: id,
      dir: dir,
      cancelled?: fn -> :atomics.get(flag, 1) == 1 end,
      on_start: fn group ->
        send(coordinator, {:group, id, group})
        :ok
      end
    }

    pid =
      spawn(fn ->
        outcome =
          try do
            {:ok, job.run.(ctx)}
          rescue
            error -> {:crashed, Exception.message(error)}
          catch
            kind, reason -> {:crashed, "#{kind}: #{inspect(reason)}"}
          end

        send(coordinator, {:job_done, id, outcome})
      end)

    mref = Process.monitor(pid)

    entry = %{
      pid: pid,
      mref: mref,
      group: nil,
      reap: nil,
      done: nil,
      killed: false,
      active: false,
      started_at: now()
    }

    st = put_running(st, id, entry)
    %{st | high: max(st.high, map_size(st.running))}
  end

  defp job_dir(opts, id) do
    case Keyword.get(opts, :settle_root) do
      nil -> nil
      root -> Path.join(root, id)
    end
  end

  # -- cancelling ----------------------------------------------------------

  defp cancel_all(%{cancelled: reason} = st, _new_reason) when reason != nil, do: st

  defp cancel_all(st, reason) do
    :atomics.put(st.flag, 1, 1)
    st = %{st | cancelled: reason}

    grace = Keyword.get(st.opts, :cancel_grace_ms, @cancel_grace_ms)
    Process.send_after(self(), :cancel_deadline, grace)

    st =
      Enum.reduce(st.queue, %{st | queue: []}, fn job, acc ->
        settle_entry(acc, job.id, "not_started", reason, nil, nil)
      end)

    # Whatever was still running when the cancellation was accepted is
    # cancelled work, whatever it returns afterwards.
    active =
      for {id, %{done: nil} = job} <- st.running, into: %{}, do: {id, %{job | active: true}}

    st = %{st | running: Map.merge(st.running, active)}

    st.running
    |> Map.keys()
    |> Enum.reduce(st, &reap(&2, &1))
  end

  defp reap(st, id) do
    case st.running[id] do
      %{group: %{} = group, reap: nil} = job ->
        coordinator = self()
        control = Keyword.get(st.opts, :control)

        spawn(fn ->
          result =
            try do
              Kogen.ProcessCustody.reap_identity(group, control)
            catch
              kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
            end

          send(coordinator, {:reaped, id, result})
        end)

        put_running(st, id, %{job | reap: :pending})

      _ ->
        st
    end
  end

  # -- settling ------------------------------------------------------------

  defp settle_if_ready(st, id) do
    case st.running[id] do
      %{done: done, reap: reap} = job when done != nil and reap != :pending ->
        st = %{st | running: Map.delete(st.running, id)}
        {status, reason, result} = classify(job, st.cancelled)
        st = settle_entry(st, id, status, reason, result, job.started_at)
        st = maybe_stop(st, id)
        start_more(st)

      _ ->
        st
    end
  end

  defp classify(%{done: {:crashed, why}}, _cancelled), do: {"crashed", why, nil}

  defp classify(%{reap: {:done, {:ok, [_ | _]}}, done: done}, cancelled),
    do: {"cancelled", cancelled, result_of(done)}

  defp classify(%{reap: {:done, {:error, why}}, done: done}, cancelled),
    do: {"cancelled", "#{cancelled}; process cleanup failed: #{why}", result_of(done)}

  defp classify(%{done: :killed}, cancelled), do: {"cancelled", cancelled, nil}

  defp classify(%{active: true, done: done}, cancelled),
    do: {"cancelled", cancelled, result_of(done)}

  defp classify(%{done: {:ok, result}}, _cancelled), do: {"settled", nil, result}

  defp result_of({:ok, result}), do: result
  defp result_of(_), do: nil

  defp maybe_stop(st, id) do
    entry = st.results[id]
    stop = Keyword.get(st.opts, :stop_when)

    if st.cancelled == nil and entry["status"] == "settled" and is_function(stop, 1),
      do: stop_reason(st, stop.(entry)),
      else: st
  end

  defp stop_reason(st, falsy) when falsy in [nil, false], do: st

  defp stop_reason(st, reason),
    do: cancel_all(st, if(is_binary(reason), do: reason, else: inspect(reason)))

  defp settle_entry(st, id, status, reason, result, started_at) do
    true = status in @statuses
    finished = now()

    entry = %{
      "id" => id,
      "status" => status,
      "reason" => reason,
      "result" => result,
      "started_at" => started_at,
      "finished_at" => finished
    }

    entry = Map.put(entry, "settlement", persist(st.opts, id, entry))
    %{st | results: Map.put(st.results, id, entry)}
  end

  defp persist(opts, id, entry) do
    case job_dir(opts, id) do
      nil ->
        nil

      dir ->
        File.mkdir_p!(dir)
        bytes = Jason.encode!(persistable(entry)) <> "\n"
        sha = sha256(bytes)
        path = Path.join(dir, "settlement.json")
        atomic_write!(path, bytes)
        atomic_write!(Path.join(dir, "settlement.sha256"), sha <> "\n")
        %{"path" => Path.expand(path), "sha256" => sha}
    end
  end

  @doc """
  The JSON-able projection of a value: atom-keyed entries (an in-memory
  `:term`) are dropped, anything else that JSON cannot encode is inspected.
  """
  def persistable(%{} = map) when not is_struct(map) do
    for {key, value} <- map, is_binary(key), into: %{}, do: {key, persistable(value)}
  end

  def persistable(list) when is_list(list), do: Enum.map(list, &persistable/1)
  def persistable(value) when is_binary(value) or is_number(value), do: value
  def persistable(value) when is_boolean(value) or is_nil(value), do: value
  def persistable(value) when is_atom(value), do: Atom.to_string(value)
  def persistable(value), do: inspect(value)

  defp atomic_write!(path, bytes) do
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"
    File.write!(temporary, bytes)
    File.rename!(temporary, path)
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end

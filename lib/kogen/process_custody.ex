defmodule Kogen.ProcessCustody do
  @moduledoc """
  Runs every process a Build launches (Developer, Reviewer, Expert and their
  helpers, Jev, make targets, `prepare`, focused and base runs, live tests)
  through `priv/kogen/process_supervisor.py`, generalised from
  `Kogen.Build.VerificationRunner`'s embedded supervisor.

  The supervisor stays outside the child's process group, starts it with a
  new session (so `pid == pgid`), records `{pid, pgid, started_at}` for the
  caller to persist, removes the child's temporary prompt file when the child
  ends, and is a parent-death watchdog: when this controller dies (Ctrl-C
  under `+Bd`, SIGHUP, SIGTERM, `kill -9`, a crash), it `killpg`s the child's
  group TERM then KILL after a short grace, and exits.

  `.kogen/build.lock` is extended with each launched group's identity so a
  later Build can sweep an abandoned one: `%{"pid", "started_at", "build_id",
  "groups" => [%{"pid", "pgid", "started_at", "role"}]}`. Group identity is
  always the recorded pid + `ps -o lstart=`, never `ps` environment (which
  macOS does not disclose for another user's, or even this process's own,
  children).

  The supervisor script is read from this controller's own compiled source
  tree via a compile-time path (`@external_resource`), never from the
  Candidate worktree's current directory.
  """

  use Boundary, deps: []

  @external_resource Path.expand("../../priv/kogen/process_supervisor.py", __DIR__)
  @supervisor_script_path Path.expand("../../priv/kogen/process_supervisor.py", __DIR__)

  @lock_path ".kogen/build.lock"

  @doc "Path to the supervisor script this controller loads for every launch."
  def supervisor_script_path, do: @supervisor_script_path

  @doc false
  def lock_path(control), do: Path.join(control, @lock_path)

  @doc "This OS process's pid and `ps -o lstart=` start time."
  def self_identity, do: %{"pid" => os_pid(), "started_at" => process_start(os_pid())}

  defp os_pid, do: System.pid() |> String.to_integer()

  @doc "`ps -p pid -o lstart=`, or `\"\"` when the pid is not this user's."
  def process_start(pid) do
    case System.cmd("/bin/ps", ["-p", to_string(pid), "-o", "lstart="], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> ""
    end
  end

  @doc "Reads `.kogen/build.lock` under `control`. `{:error, :enoent}` when absent."
  @spec read_lock(Path.t()) :: {:ok, map()} | {:error, term()}
  def read_lock(control) do
    case File.read(lock_path(control)) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, %{} = map} -> {:ok, map}
          _ -> {:error, :corrupt}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_lock(control, map) do
    path = lock_path(control)

    case File.open(path, [:read, :write]) do
      {:ok, io} ->
        result =
          case :file.truncate(io) do
            :ok -> IO.binwrite(io, Jason.encode!(map))
            error -> error
          end

        File.close(io)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp with_lock(control, fun, role \\ nil) do
    lock = {{__MODULE__, Path.expand(lock_path(control))}, self()}

    unless :global.set_lock(lock, [node()], 0) do
      if role == :release, do: maybe_release_wait(control)
      :global.set_lock(lock, [node()])
    end

    try do
      fun.()
    after
      :global.del_lock(lock, [node()])
    end
  end

  @doc """
  Acquires `.kogen/build.lock` for a new Build.

  When no lock exists, writes a fresh one and returns `{:ok, :fresh}`. When a
  lock exists and its owner is alive (matching pid and start time), refuses
  as today. When the owner is dead or its pid was reused (start time
  mismatch), kills every recorded group whose leader's start time still
  matches (TERM then KILL), reclaims the lock, prints one line naming what
  it reaped (or that no live group was found) and returns
  `{:ok, {:reclaimed, reaped}}`, where `reaped` names what was killed.
  """
  @spec acquire(Path.t()) ::
          {:ok, :fresh} | {:ok, {:reclaimed, [String.t()]}} | {:error, String.t()}
  def acquire(control) do
    case read_lock(control) do
      {:error, :enoent} ->
        create_lock(control, {:ok, :fresh})

      {:ok, lock} ->
        if owner_alive?(lock),
          do: {:error, "build lock already present: #{@lock_path}"},
          else: reclaim(control, reap_groups(Map.get(lock, "groups", [])))

      {:error, :corrupt} ->
        # An empty or unparsable lock is another Build between creating and
        # writing it, or one that died in that instant. Only a stale one is
        # reclaimed; it records no group to reap.
        if stale_file?(lock_path(control)),
          do: reclaim(control, []),
          else: {:error, "build lock already present: #{@lock_path} (not yet readable)"}

      {:error, reason} ->
        {:error, "could not read build lock: #{inspect(reason)}"}
    end
  end

  @unreadable_lock_grace_seconds 60

  defp stale_file?(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        System.os_time(:second) - mtime > @unreadable_lock_grace_seconds

      _ ->
        false
    end
  end

  defp reclaim(control, reaped) do
    File.rm(lock_path(control))
    named = if reaped == [], do: "no live groups", else: Enum.join(reaped, ", ")

    with {:ok, _fresh} <- create_lock(control, {:ok, :fresh}) do
      IO.puts("Reclaimed a stale build lock; reaped: #{named}")
      {:ok, {:reclaimed, reaped}}
    end
  end

  # The lock is created exclusively, so two Builds starting at once never
  # both hold it.
  defp create_lock(control, result) do
    path = lock_path(control)
    File.mkdir_p(Path.dirname(path))
    bytes = Jason.encode!(Map.merge(self_identity(), %{"build_id" => nil, "groups" => []}))

    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        IO.binwrite(io, bytes)
        File.close(io)
        result

      {:error, :eexist} ->
        {:error, "build lock already present: #{@lock_path}"}

      {:error, reason} ->
        {:error, "could not acquire build lock: #{inspect(reason)}"}
    end
  end

  defp owner_alive?(%{"pid" => pid, "started_at" => started}) when is_integer(pid) do
    started != "" and started == process_start(pid)
  end

  defp owner_alive?(_lock), do: false

  @doc "Sets `build_id` on the lock this controller holds, keeping its groups."
  @spec claim(Path.t(), String.t()) :: :ok | {:error, term()}
  def claim(control, build_id) do
    with_lock(control, fn ->
      case read_lock(control) do
        {:ok, lock} ->
          write_lock(control, Map.put(lock, "build_id", build_id))

        {:error, :enoent} ->
          write_lock(
            control,
            Map.merge(self_identity(), %{"build_id" => build_id, "groups" => []})
          )

        other ->
          other
      end
    end)
  end

  @doc "Appends a launched group's identity to the lock this controller holds."
  @spec record_group(Path.t(), String.t(), map()) :: :ok
  def record_group(control, role, %{} = group) do
    entry = %{
      "pid" => Map.get(group, "pid"),
      "pgid" => Map.get(group, "pgid"),
      "started_at" => Map.get(group, "started_at"),
      "role" => role
    }

    with_lock(control, fn ->
      case read_lock(control) do
        {:ok, lock} ->
          groups = Map.get(lock, "groups", []) ++ [entry]
          write_lock(control, Map.put(lock, "groups", groups))
          :ok

        _ ->
          :ok
      end
    end)
  end

  @doc "Removes a launched group from the lock once it has ended normally."
  @spec forget_group(Path.t(), integer() | nil) :: :ok
  def forget_group(_control, nil), do: :ok

  def forget_group(control, pid) do
    with_lock(control, fn ->
      case read_lock(control) do
        {:ok, lock} ->
          maybe_forget_group_pause(control)
          groups = Map.get(lock, "groups", []) |> Enum.reject(&(&1["pid"] == pid))
          write_lock(control, Map.put(lock, "groups", groups))
          :ok

        _ ->
          :ok
      end
    end)
  end

  @doc false
  def set_forget_group_hook(control, hook) when is_function(hook, 1) do
    :persistent_term.put({__MODULE__, :forget_group_hook, Path.expand(lock_path(control))}, hook)
  end

  @doc false
  def clear_forget_group_hook(control) do
    :persistent_term.erase({__MODULE__, :forget_group_hook, Path.expand(lock_path(control))})
  end

  @doc false
  def set_release_wait_hook(control, hook) when is_function(hook, 0) do
    :persistent_term.put({__MODULE__, :release_wait_hook, Path.expand(lock_path(control))}, hook)
  end

  @doc false
  def clear_release_wait_hook(control) do
    :persistent_term.erase({__MODULE__, :release_wait_hook, Path.expand(lock_path(control))})
  end

  defp maybe_release_wait(control) do
    key = {__MODULE__, :release_wait_hook, Path.expand(lock_path(control))}

    case :persistent_term.get(key, nil) do
      hook when is_function(hook, 0) -> hook.()
      _ -> :ok
    end
  end

  defp maybe_forget_group_pause(control) do
    key = {__MODULE__, :forget_group_hook, Path.expand(lock_path(control))}

    case :persistent_term.get(key, nil) do
      hook when is_function(hook, 1) -> hook.(control)
      _ -> :ok
    end
  end

  @doc """
  Kills every group recorded on this controller's lock (TERM then KILL),
  and clears the groups list. Called on turn end, Stop, timeout, and from the
  controller's signal traps and `Build` end sweep.
  """
  @spec teardown(Path.t()) :: [String.t()]
  def teardown(control) do
    with_lock(control, fn -> teardown_unlocked(control) end)
  end

  defp teardown_unlocked(control) do
    case read_lock(control) do
      {:ok, lock} ->
        reaped = reap_groups(Map.get(lock, "groups", []))
        write_lock(control, Map.put(lock, "groups", []))
        reaped

      _ ->
        []
    end
  end

  @doc "Tears down every recorded group, then removes the lock file."
  @spec release(Path.t()) :: :ok
  def release(control) do
    with_lock(
      control,
      fn ->
        teardown_unlocked(control)
        File.rm(lock_path(control))
        :ok
      end,
      :release
    )
  end

  # Kills whichever recorded groups are still identifiable by pid+lstart,
  # TERM then KILL after a short grace. A group whose leader's start time no
  # longer matches is left alone (its pid was reused by something unrelated).
  defp reap_groups(groups) do
    groups
    |> Enum.filter(fn %{"pid" => pid, "started_at" => started} ->
      is_integer(pid) and is_binary(started) and started != "" and
        started == process_start(pid)
    end)
    |> Enum.map(fn %{"pid" => pid, "pgid" => pgid} = entry ->
      kill_group(pgid || pid)
      "#{Map.get(entry, "role", "process")} pid #{pid}"
    end)
  end

  defp kill_group(pgid) do
    System.cmd("/bin/kill", ["-TERM", "-#{pgid}"], stderr_to_stdout: true)

    unless settle(pgid, 2_000),
      do: System.cmd("/bin/kill", ["-KILL", "-#{pgid}"], stderr_to_stdout: true)
  end

  defp settle(pgid, budget_ms) do
    deadline = System.monotonic_time(:millisecond) + budget_ms

    Stream.repeatedly(fn -> group_alive?(pgid) end)
    |> Enum.reduce_while(false, fn alive?, _acc ->
      cond do
        not alive? ->
          {:halt, true}

        System.monotonic_time(:millisecond) >= deadline ->
          {:halt, false}

        true ->
          Process.sleep(50)
          {:cont, false}
      end
    end)
  end

  defp group_alive?(pgid) do
    case System.cmd("/bin/kill", ["-0", "-#{pgid}"], stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  end

  @doc """
  Runs `argv` in `cwd` through the supervisor, in its own process group.

  Options:
  - `:control` — when given, the group is recorded on `control`'s lock as
    soon as it starts, and forgotten again once this call returns
    successfully.
  - `:role` — a label recorded with the group (for example `"developer"`).
  - `:stdin_path` — a temporary prompt file fed to the child and removed by
    the supervisor when the child ends.
  - `:log_path` — combined output destination; when omitted, output is
    captured to a controller-owned temporary file and returned as
    `"output"`, then removed.
  - `:env` — extra environment entries.
  - `:timeout_ms`, `:grace_ms`.

  Returns `{:ok, facts}` with `"exit_code"`, `"cleanup"`, `"timed_out"`,
  `"pid"`, `"pgid"`, `"started_at"`, `"finished_at"`, and either `"log_path"`
  (with `"log_sha256"`/`"log_bytes"`) or `"output"` (raw captured bytes).
  """
  @spec run([String.t()], Path.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(argv, cwd, opts \\ []) when is_list(argv) and argv != [] do
    control = Keyword.get(opts, :control)
    role = Keyword.get(opts, :role, "process")
    owned_log = Keyword.get(opts, :log_path) == nil
    log_path = Keyword.get(opts, :log_path) || temp_path("log")
    register_path = temp_path("register")

    spec = %{
      "argv" => argv,
      "cwd" => Path.expand(cwd),
      "log" => Path.expand(log_path),
      "mode" => "batch",
      "stdin_path" => Keyword.get(opts, :stdin_path),
      "tmp_dir" => Keyword.get(opts, :tmp_dir),
      "timeout" => opt_seconds(opts, :timeout_ms),
      "grace" => Keyword.get(opts, :grace_ms, 2_000) / 1000,
      "controller_pid" => os_pid(),
      "register_path" => register_path
    }

    env = build_env(Keyword.get(opts, :env, []))

    File.mkdir_p(Path.dirname(log_path))

    port =
      Port.open(
        {:spawn_executable, System.find_executable("python3") |> to_charlist()},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          args: [@supervisor_script_path, Jason.encode!(spec)],
          env: env
        ]
      )

    if control, do: await_registration(register_path, control, role)

    {output, status} = collect(port, [])
    File.rm(register_path)

    with 0 <- status,
         {:ok, facts} <- decode_facts(output) do
      if control, do: forget_group(control, facts["pid"])
      {:ok, with_output(facts, owned_log, log_path)}
    else
      code when is_integer(code) ->
        {:error, "process supervisor failed (#{code}): #{String.slice(output, -2000, 2000)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # An owned (temporary) log is read into the facts and removed; a caller's
  # log stays, bound by its path and digest.
  defp with_output(facts, true, log_path) do
    bytes = File.read!(log_path)
    File.rm(log_path)
    Map.put(facts, "output", bytes)
  end

  defp with_output(facts, _owned_log, log_path) do
    bytes = File.read!(log_path)

    Map.merge(facts, %{
      "log_path" => Path.expand(log_path),
      "log_sha256" => sha256(bytes),
      "log_bytes" => bytes
    })
  end

  @doc """
  Opens a passthrough-mode supervised child: the child inherits this port's
  own stdio directly, so a caller that drives a raw bidirectional protocol
  over stdin/stdout (Jev's executable transport) keeps working exactly as it
  did against a plain `Port.open`, while the child still runs in its own
  process group with the supervisor's parent-death watchdog, and, when
  `:control` is given, is recorded on that control's lock as soon as it
  starts (never forgotten automatically, since this call does not block for
  the child's exit; the caller's own receive loop owns that, and a stale
  entry is swept at the next Build's `acquire/1` like any other).

  Options: `:control`, `:role`, `:env`, `:timeout_ms` (kills the group
  directly if the caller never closes the port), `:grace_ms`.

  Returns the `Port.open/2` port: `{^port, {:data, _}}` and
  `{^port, {:exit_status, _}}` messages arrive exactly as they would from the
  child directly.
  """
  @spec open_passthrough([String.t()], Path.t(), keyword()) :: port()
  def open_passthrough(argv, cwd, opts \\ []) when is_list(argv) and argv != [] do
    control = Keyword.get(opts, :control)
    role = Keyword.get(opts, :role, "process")
    register_path = if control, do: temp_path("register"), else: nil
    # Facts always go to a private file, never to stdout: in passthrough
    # mode stdout is the caller's own data channel, shared with the child.
    report_path = temp_path("report")

    spec = %{
      "argv" => argv,
      "cwd" => Path.expand(cwd),
      "mode" => "passthrough",
      "timeout" => opt_seconds(opts, :timeout_ms),
      "grace" => Keyword.get(opts, :grace_ms, 2_000) / 1000,
      "controller_pid" => os_pid(),
      "register_path" => register_path,
      "report_path" => report_path
    }

    env = build_env(Keyword.get(opts, :env, []))

    port =
      Port.open(
        {:spawn_executable, System.find_executable("python3") |> to_charlist()},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          args: [@supervisor_script_path, Jason.encode!(spec)],
          env: env
        ]
      )

    if control, do: Task.start(fn -> await_registration(register_path, control, role) end)
    Task.start(fn -> await_report_cleanup(report_path) end)

    port
  end

  # Best-effort: removes the private facts file once the passthrough child
  # has ended, so it does not linger under the system temp dir.
  defp await_report_cleanup(report_path, tries \\ 600)
  defp await_report_cleanup(_report_path, 0), do: :ok

  defp await_report_cleanup(report_path, tries) do
    if File.exists?(report_path) do
      File.rm(report_path)
    else
      Process.sleep(50)
      await_report_cleanup(report_path, tries - 1)
    end
  end

  defp opt_seconds(opts, key) do
    case Keyword.get(opts, key) do
      nil -> nil
      ms -> ms / 1000
    end
  end

  # Diff semantics, like `System.cmd`'s own `:env` option and Erlang's
  # `open_port/2` `:env`: every entry here overrides or (when `nil`/`false`)
  # unsets one variable in the child's otherwise-inherited environment. An
  # empty list means "inherit the controller's own environment unchanged".
  defp build_env(entries) do
    Enum.map(entries, fn {key, value} ->
      {String.to_charlist(to_string(key)),
       if(is_nil(value), do: false, else: String.to_charlist(to_string(value)))}
    end)
  end

  defp temp_path(label),
    do:
      Path.join(
        System.tmp_dir!(),
        "kogen-#{label}-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"
      )

  # Polls briefly for the supervisor's registration file, so the group is on
  # the lock before this call blocks waiting for the child to finish (a
  # controller death mid-turn still leaves an accurate record).
  defp await_registration(register_path, control, role, tries \\ 100)
  defp await_registration(_path, _control, _role, 0), do: :ok

  defp await_registration(register_path, control, role, tries) do
    case File.read(register_path) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, %{} = group} -> record_group(control, role, group)
          _ -> :ok
        end

      {:error, _} ->
        Process.sleep(10)
        await_registration(register_path, control, role, tries - 1)
    end
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, [acc, data])
      {^port, {:exit_status, status}} -> {IO.iodata_to_binary(acc), status}
    end
  end

  defp decode_facts(output) do
    line = output |> String.split("\n", trim: true) |> List.last()

    case line && Jason.decode(line) do
      {:ok, %{"exit_code" => code, "cleanup" => cleanup} = facts}
      when is_integer(code) and cleanup in ["clean", "terminated", "failed"] ->
        {:ok, facts}

      _ ->
        {:error, "process supervisor returned malformed facts"}
    end
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end

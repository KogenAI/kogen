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
  @cleanup_grace_ms 2_000
  @start_gate_script """
  import os, sys, time
  gate = sys.argv[1]
  while not os.path.exists(gate):
      time.sleep(0.01)
  os.execvp(sys.argv[2], sys.argv[2:])
  """

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

  # An update replaces the lock by rename, so a holder killed mid-write (a
  # crashed Shaping runner recording an audit group, say) leaves the previous
  # complete lock rather than an empty one that stays unreadable until its
  # grace period passes. The temporary file lives under the ignored runtime
  # directory; one orphaned by a kill is never read as a lock.
  defp write_lock(control, map) do
    path = lock_path(control)

    tmp =
      Path.join([
        control,
        ".kogen/runtime",
        "build.lock.#{System.pid()}-#{System.unique_integer([:positive])}.tmp"
      ])

    # A lock that is not writable stays authoritative, exactly as an in-place
    # write to it would fail.
    with :ok <- writable_lock(path),
         :ok <- File.mkdir_p(Path.dirname(tmp)),
         :ok <- File.write(tmp, Jason.encode!(map)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  defp writable_lock(path) do
    case File.stat(path) do
      {:ok, %{access: access}} when access in [:read, :none] -> {:error, :eacces}
      _ -> :ok
    end
  end

  # Test seam: a fault injected on the lock file (a chmod, say) inside this
  # lands between whole lock writes, never between a write's writability
  # check and its rename.
  @doc false
  def locked(control, fun) when is_function(fun, 0), do: with_lock(control, fun)

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
    with_lock(control, fn -> acquire_unlocked(control) end)
  end

  defp acquire_unlocked(control) do
    case read_lock(control) do
      {:error, :enoent} ->
        create_lock(control, {:ok, :fresh})

      {:ok, lock} ->
        if owner_alive?(lock),
          do: {:error, "build lock already present: #{@lock_path}"},
          else: reclaim_stale(control, Map.get(lock, "groups", []))

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

  defp reclaim_stale(control, groups) do
    report = reap_groups(groups, control)

    if report.failed == [] do
      reclaim(control, report.reaped)
    else
      reason = cleanup_failure(report.failed)
      IO.puts("Could not reclaim stale build lock: #{reason}")
      {:error, "could not reap stale process groups: #{reason}"}
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
    # A process-local test barrier at the actual classified-stale/remove gap.
    # Production callers have no observer; lock and custody semantics remain
    # unchanged. Headless session callers serialize this gap across VMs.
    case Process.get({__MODULE__, :before_reclaim}) do
      hook when is_function(hook, 1) -> hook.(control)
      _ -> :ok
    end

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
  @spec record_group(Path.t(), String.t(), map()) :: :ok | {:error, term()}
  def record_group(
        control,
        role,
        %{"pid" => pid, "pgid" => pid, "started_at" => started}
      )
      when is_integer(pid) and pid > 0 and is_binary(started) and started != "" do
    # The supervisor starts the child as a session leader. Never persist a
    # group number that could later name another process tree.
    entry = %{
      "pid" => pid,
      "pgid" => pid,
      "started_at" => started,
      "role" => role,
      "descendants" => []
    }

    append_group(control, entry)
  end

  def record_group(_control, _role, %{}), do: {:error, :invalid_group_identity}

  defp append_group(control, entry) do
    with_lock(control, fn -> append_group_to_lock(control, entry) end)
  end

  defp append_group_to_lock(control, entry) do
    case read_lock(control) do
      {:ok, lock} ->
        groups = Map.get(lock, "groups", []) ++ [entry]
        write_lock(control, Map.put(lock, "groups", groups))

      {:error, :enoent} ->
        :ok

      error ->
        error
    end
  end

  defp valid_group_identity?(%{"pid" => pid, "pgid" => pid, "started_at" => started})
       when is_integer(pid) and pid > 0 and is_binary(started) and started != "",
       do: true

  defp valid_group_identity?(_group), do: false

  @doc "Removes a launched group from the lock once it has ended normally."
  @spec forget_group(Path.t(), integer() | nil) :: :ok | {:error, String.t()}
  def forget_group(_control, nil), do: :ok

  def forget_group(control, pid) do
    with :ok <- await_descendant_monitor(control, pid) do
      forget_group_after_monitor(control, pid)
    end
  end

  defp forget_group_after_monitor(control, pid) do
    with_lock(control, fn -> forget_group_locked(control, pid) end)
  end

  defp forget_group_locked(control, pid) do
    case read_lock(control) do
      {:ok, lock} -> forget_recorded_group(control, lock, pid)
      _ -> :ok
    end
  end

  defp await_descendant_monitor(control, pid) do
    key = {__MODULE__, :descendant_monitor, Path.expand(control), pid}

    case Process.delete(key) do
      nil ->
        # Direct callers can forget a group registered by another process.
        # Retain the old grace for that uncommon path.
        Process.sleep(100)
        :ok

      {ref, _started_at} ->
        receive do
          {^ref, :descendant_monitor_complete, :ok} ->
            :ok

          {^ref, :descendant_monitor_complete, {:error, reason}} ->
            {:error, "descendant monitor failed: #{inspect(reason)}"}
        after
          # A deliberately unkillable group can outlive its supervisor. The
          # existing 100 ms bound preserves its record for Build-end sweep.
          100 -> :ok
        end
    end
  end

  defp forget_recorded_group(control, lock, pid) do
    maybe_forget_group_pause(control)
    groups = Map.get(lock, "groups", [])
    group = Enum.find(groups, &(&1["pid"] == pid))
    report = maybe_reap_group(group, control)
    updated_groups = update_finished_group(groups, pid, report)
    write_lock(control, Map.put(lock, "groups", updated_groups))
    maybe_report_cleanup_failure(report.failed, "Finished-process cleanup")
    finished_group_result(report)
  end

  defp update_finished_group(groups, pid, %{failed: []}),
    do: Enum.reject(groups, &(&1["pid"] == pid))

  defp update_finished_group(groups, pid, report) do
    Enum.map(groups, &preserve_failed_group(&1, pid, report.remaining_descendants))
  end

  defp preserve_failed_group(%{"pid" => group_pid} = group, pid, remaining)
       when group_pid == pid,
       do: Map.put(group, "descendants", remaining)

  defp preserve_failed_group(group, _pid, _remaining), do: group

  defp finished_group_result(%{failed: []}), do: :ok

  defp finished_group_result(report),
    do: {:error, "could not reap recorded descendants: #{cleanup_failure(report.failed)}"}

  defp maybe_reap_group(nil, _control), do: %{failed: [], reaped: [], remaining_descendants: []}

  defp maybe_reap_group(group, control) do
    descendants = Map.get(group, "descendants", [])
    report = reap_descendants(descendants, group["role"] || "process", control)
    Map.put(report, :remaining_descendants, report.remaining)
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

  @doc false
  def set_signal_hook(control, hook) when is_function(hook, 3) do
    :persistent_term.put({__MODULE__, :signal_hook, Path.expand(lock_path(control))}, hook)
  end

  @doc false
  def clear_signal_hook(control) do
    :persistent_term.erase({__MODULE__, :signal_hook, Path.expand(lock_path(control))})
  end

  # Test seam: shorten the TERM-to-KILL settle wait for one control dir only.
  @doc false
  def set_cleanup_grace_ms(control, ms) when is_integer(ms) and ms > 0 do
    :persistent_term.put({__MODULE__, :cleanup_grace_ms, Path.expand(lock_path(control))}, ms)
  end

  @doc false
  def clear_cleanup_grace_ms(control) do
    :persistent_term.erase({__MODULE__, :cleanup_grace_ms, Path.expand(lock_path(control))})
  end

  defp cleanup_grace_ms(control) do
    :persistent_term.get(
      {__MODULE__, :cleanup_grace_ms, Path.expand(lock_path(control))},
      @cleanup_grace_ms
    )
  end

  @doc false
  def set_monitor_stop_hook(control, hook) when is_function(hook, 1) do
    :persistent_term.put({__MODULE__, :monitor_stop_hook, Path.expand(lock_path(control))}, hook)
  end

  @doc false
  def clear_monitor_stop_hook(control) do
    :persistent_term.erase({__MODULE__, :monitor_stop_hook, Path.expand(lock_path(control))})
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

  defp maybe_monitor_stopped(control, pid) do
    key = {__MODULE__, :monitor_stop_hook, Path.expand(lock_path(control))}

    case :persistent_term.get(key, nil) do
      hook when is_function(hook, 1) -> hook.(pid)
      _ -> :ok
    end
  end

  defp monitor_descendants(control, pid, started_at)
       when is_integer(pid) and is_binary(started_at) and started_at != "" do
    caller = self()
    ready_ref = make_ref()
    complete_ref = make_ref()

    Task.start(fn ->
      result =
        try do
          table = process_table()
          send(caller, {ready_ref, :descendant_monitor_ready})
          track_descendants(control, pid, started_at, %{}, table)
          :ok
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      maybe_monitor_stopped(control, pid)
      send(caller, {complete_ref, :descendant_monitor_complete, result})
    end)

    receive do
      {^ready_ref, :descendant_monitor_ready} ->
        Process.put(
          {__MODULE__, :descendant_monitor, Path.expand(control), pid},
          {complete_ref, started_at}
        )

        :ok
    after
      5_000 -> {:error, "descendant monitor did not start"}
    end
  end

  defp monitor_descendants(_control, _pid, _started_at),
    do: {:error, :invalid_descendant_monitor_identity}

  defp track_descendants(control, root_pid, root_started_at, known, table \\ nil) do
    table = table || process_table()
    parent_ids = MapSet.new([root_pid | Map.keys(known)])

    discovered =
      table
      |> Enum.filter(&MapSet.member?(parent_ids, &1.ppid))
      |> Enum.reject(&(&1.pid == root_pid))
      |> Enum.reduce(known, fn process, acc ->
        identity = %{"pid" => process.pid, "started_at" => process.started_at}
        Map.put(acc, process.pid, identity)
      end)

    if discovered != known,
      do: record_descendants(control, root_pid, Map.values(discovered))

    root_alive? = root_alive_in_snapshot?(table, root_pid, root_started_at)

    if root_alive? do
      Process.sleep(25)
      track_descendants(control, root_pid, root_started_at, discovered)
    end
  end

  defp root_alive_in_snapshot?(table, root_pid, root_started_at) do
    case Enum.find(table, &(&1.pid == root_pid)) do
      %{started_at: ^root_started_at, state: state} -> not terminated_state?(state)
      %{started_at: _reused_pid} -> false
      nil -> root_started_at == process_start(root_pid)
    end
  end

  defp terminated_state?(state),
    do: String.starts_with?(state, "Z") or String.starts_with?(state, "X")

  defp process_table do
    case System.cmd("/bin/ps", ["-axo", "pid=,ppid=,pgid=,stat=,lstart="], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_process_line/1)

      _ ->
        []
    end
  end

  defp parse_process_line(line) do
    case Regex.run(~r/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.+?)\s*$/, line) do
      [_, pid, ppid, pgid, state, started_at] ->
        [
          %{
            pid: String.to_integer(pid),
            ppid: String.to_integer(ppid),
            pgid: String.to_integer(pgid),
            state: state,
            started_at: started_at
          }
        ]

      _ ->
        []
    end
  end

  defp record_descendants(control, root_pid, descendants) do
    with_lock(control, fn ->
      case read_lock(control) do
        {:ok, lock} ->
          groups =
            Enum.map(
              Map.get(lock, "groups", []),
              &merge_group_descendants(&1, root_pid, descendants)
            )

          write_lock(control, Map.put(lock, "groups", groups))

        _ ->
          :ok
      end
    end)
  end

  defp merge_group_descendants(%{"pid" => root_pid} = group, root_pid, descendants) do
    merged =
      (Map.get(group, "descendants", []) ++ descendants)
      |> Enum.uniq_by(&{&1["pid"], &1["started_at"]})

    Map.put(group, "descendants", merged)
  end

  defp merge_group_descendants(group, _root_pid, _descendants), do: group

  @doc """
  Kills every group recorded on this controller's lock (TERM then KILL),
  and clears the groups list. Called on turn end, Stop, timeout, and from the
  controller's signal traps and `Build` end sweep.
  """
  @spec teardown(Path.t()) :: [String.t()] | {:error, String.t()}
  def teardown(control) do
    with_lock(control, fn ->
      report = teardown_unlocked(control)

      if report.failed == [] do
        report.reaped
      else
        reason = cleanup_failure(report.failed)
        IO.puts("Process cleanup incomplete: #{reason}")
        {:error, "could not reap process groups: #{reason}"}
      end
    end)
  end

  defp teardown_unlocked(control) do
    case read_lock(control) do
      {:ok, lock} ->
        report = reap_groups(Map.get(lock, "groups", []), control)
        write_lock(control, Map.put(lock, "groups", report.remaining))
        report

      _ ->
        %{reaped: [], failed: [], remaining: []}
    end
  end

  @doc "Tears down every recorded group, then removes the lock file."
  @spec release(Path.t()) :: :ok | {:error, String.t()}
  def release(control) do
    with_lock(control, fn -> release_locked(control) end, :release)
  end

  defp release_locked(control) do
    report = teardown_unlocked(control)

    if report.failed == [] do
      report_release_success(control, report.reaped)
    else
      report_release_failure(report.failed)
    end
  end

  defp report_release_success(control, reaped) do
    report_reaped(reaped)

    case File.rm(lock_path(control)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, "could not remove build lock: #{inspect(reason)}"}
    end
  end

  defp report_reaped([]), do: :ok

  defp report_reaped(reaped) do
    IO.puts("Build-end sweep reaped orphan records: #{Enum.join(reaped, ", ")}")
  end

  defp report_release_failure(failures) do
    reason = cleanup_failure(failures)
    IO.puts("Build-end sweep could not reap orphan records: #{reason}")
    {:error, "could not reap process groups: #{reason}"}
  end

  # Kills whichever recorded groups are still identifiable by pid+lstart,
  # TERM then KILL after a short grace. A group whose leader's start time no
  # longer matches is left alone (its pid was reused by something unrelated).
  defp reap_groups(groups, control) do
    Enum.reduce(groups, empty_cleanup_report(), fn group, report ->
      merge_cleanup_reports(report, reap_group(group, control))
    end)
    |> reverse_cleanup_report()
  end

  defp reap_group(group, control) do
    role = Map.get(group, "role", "process")
    leader = reap_group_leader(group, role, control)
    descendants = reap_descendants(Map.get(group, "descendants", []), role, control)
    report = merge_cleanup_reports(leader.report, descendants)
    remaining_group = remaining_group_record(group, leader.retain?, descendants.remaining)

    if remaining_group do
      Map.update!(report, :remaining, &[remaining_group | &1])
    else
      report
    end
  end

  defp reap_group_leader(group, role, control) do
    leader_name = "#{role} pid #{group["pid"]}"

    case identity_status(group) do
      :same -> signal_group_leader(group, control, leader_name)
      :unknown -> failed_group_leader(leader_name, "identity could not be checked")
      _gone_or_reused -> %{report: empty_cleanup_report(), retain?: false}
    end
  end

  defp signal_group_leader(group, control, leader_name) do
    if valid_group_identity?(group) and process_group(group["pid"]) == group["pgid"] do
      case kill_group(group, control) do
        :ok -> %{report: %{empty_cleanup_report() | reaped: [leader_name]}, retain?: false}
        {:error, reason} -> failed_group_leader(leader_name, inspect(reason))
      end
    else
      failed_group_leader(leader_name, "recorded process group does not match its leader")
    end
  end

  defp process_group(pid) do
    case System.cmd("/bin/ps", ["-p", to_string(pid), "-o", "pgid="], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {pgid, ""} -> pgid
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp failed_group_leader(leader_name, reason) do
    failure = "#{leader_name}: #{reason}"

    %{
      report: %{empty_cleanup_report() | failed: [failure]},
      retain?: true
    }
  end

  defp remaining_group_record(group, retain_leader?, remaining_descendants) do
    if retain_leader? or remaining_descendants != [] do
      Map.put(group, "descendants", remaining_descendants)
    end
  end

  defp empty_cleanup_report, do: %{reaped: [], failed: [], remaining: []}

  defp merge_cleanup_reports(first, second) do
    %{
      reaped: second.reaped ++ first.reaped,
      failed: second.failed ++ first.failed,
      remaining: second.remaining ++ first.remaining
    }
  end

  defp reverse_cleanup_report(report) do
    Map.new(report, fn {key, entries} -> {key, Enum.reverse(entries)} end)
  end

  defp cleanup_failure(failures), do: Enum.join(failures, "; ")

  defp maybe_report_cleanup_failure([], _context), do: :ok

  defp maybe_report_cleanup_failure(failures, context) do
    IO.puts("#{context} incomplete: #{cleanup_failure(failures)}")
  end

  defp identity_status(%{"pid" => pid, "started_at" => started})
       when is_integer(pid) and is_binary(started) and started != "" do
    case process_status(pid) do
      {:ok, ^started} -> :same
      {:ok, _other_started} -> :different
      :gone -> :gone
      :unknown -> :unknown
    end
  end

  defp identity_status(_entry), do: :unknown

  defp process_status(pid) do
    case System.cmd("/bin/ps", ["-p", to_string(pid), "-o", "lstart="], stderr_to_stdout: true) do
      {output, 0} ->
        case String.trim(output) do
          "" -> :gone
          started -> {:ok, started}
        end

      {"", 1} ->
        :gone

      _ ->
        :unknown
    end
  rescue
    _ -> :unknown
  end

  # A child can deliberately detach with setsid, so process-group teardown
  # alone is not enough. The monitor records each descendant's pid and start
  # identity while its ancestry is still observable; stale-lock recovery can
  # safely reap those processes even after the group leader has exited.
  defp reap_descendants(descendants, role, control) when is_list(descendants) do
    Enum.reduce(descendants, empty_cleanup_report(), fn descendant, report ->
      merge_cleanup_reports(report, reap_descendant(descendant, role, control))
    end)
  end

  defp reap_descendants(_descendants, _role, _control),
    do: empty_cleanup_report()

  defp reap_descendant(descendant, role, control) do
    name = "#{role} descendant pid #{Map.get(descendant, "pid", "unknown")}"

    case identity_status(descendant) do
      :same -> signal_descendant(descendant, control, name)
      :unknown -> failed_descendant(descendant, name, "identity could not be checked")
      _gone_or_reused -> empty_cleanup_report()
    end
  end

  defp signal_descendant(descendant, control, name) do
    case kill_process(descendant, control) do
      :ok -> %{empty_cleanup_report() | reaped: [name]}
      {:error, reason} -> failed_descendant(descendant, name, inspect(reason))
    end
  end

  defp failed_descendant(descendant, name, reason) do
    %{
      empty_cleanup_report()
      | failed: ["#{name}: #{reason}"],
        remaining: [descendant]
    }
  end

  defp kill_process(%{"pid" => pid} = identity, control) do
    _term_result = send_signal(control, :process, pid, :term)

    case settle_process(identity, cleanup_grace_ms(control)) do
      :gone ->
        :ok

      :alive ->
        kill_process_if_same(identity, control)

      :unknown ->
        {:error, :process_identity_could_not_be_checked_before_kill}
    end
  end

  defp kill_process_if_same(identity, control) do
    case identity_status(identity) do
      :same -> kill_process_after_identity_check(identity, control)
      :unknown -> {:error, :process_identity_could_not_be_checked_before_kill}
      _gone_or_reused -> :ok
    end
  end

  defp kill_process_after_identity_check(%{"pid" => pid} = identity, control) do
    _kill_result = send_signal(control, :process, pid, :kill)

    case settle_process(identity, cleanup_grace_ms(control)) do
      :gone -> :ok
      status -> {:error, {:process_still_present, status}}
    end
  end

  defp settle_process(identity, budget_ms) do
    settle_until(
      fn ->
        case identity_status(identity) do
          :same -> :alive
          :unknown -> :unknown
          _gone_or_reused -> :gone
        end
      end,
      budget_ms
    )
  end

  defp kill_group(%{"pgid" => pgid} = group, control)
       when is_integer(pgid) and pgid > 0 do
    if group_identity_matches?(group, []) do
      members = process_group_members(pgid)
      kill_group_after_term(group, members, control)
    else
      {:error, :group_identity_changed_before_term}
    end
  end

  defp kill_group(%{"pgid" => pgid}, _control),
    do: {:error, {:invalid_process_group, pgid}}

  defp kill_group(_group, _control), do: {:error, :invalid_process_group}

  defp kill_group_after_term(%{"pgid" => pgid} = group, members, control) do
    _term_result = send_signal(control, :group, pgid, :term)

    case settle_group(pgid, cleanup_grace_ms(control)) do
      :gone ->
        :ok

      status when status in [:alive, :unknown] ->
        finish_group_cleanup(group, members, control, status)
    end
  end

  defp finish_group_cleanup(%{"pgid" => pgid} = group, members, control, status) do
    if group_identity_matches?(group, members) do
      kill_group_after_identity_check(pgid, control)
    else
      wait_for_group_owner(pgid, status, control)
    end
  end

  defp kill_group_after_identity_check(pgid, control) do
    _kill_result = send_signal(control, :group, pgid, :kill)

    case settle_group(pgid, cleanup_grace_ms(control)) do
      :gone -> :ok
      final_status -> {:error, {:group_still_present, final_status}}
    end
  end

  defp wait_for_group_owner(pgid, status, control) do
    # The leader may have exited after TERM while its original supervisor is
    # still finishing the same group. Give that owner one more grace to finish;
    # do not signal a PGID we can no longer tie to a recorded member.
    case settle_group(pgid, cleanup_grace_ms(control)) do
      :gone -> :ok
      _still_present -> {:error, {:group_identity_changed_before_kill, status}}
    end
  end

  defp process_group_members(pgid) do
    process_table()
    |> Enum.filter(&(&1.pgid == pgid))
    |> Enum.map(fn process ->
      %{"pid" => process.pid, "started_at" => process.started_at}
    end)
  end

  defp group_identity_matches?(%{"pgid" => pgid} = group, members) when is_list(members) do
    descendants = Map.get(group, "descendants", [])
    descendants = if is_list(descendants), do: descendants, else: []
    known_members = members ++ descendants

    leader_matches? =
      identity_status(group) == :same and process_group(group["pid"]) == pgid

    leader_matches? or group_descendant_matches?(known_members, pgid)
  end

  defp group_identity_matches?(_group, _members), do: false

  defp group_descendant_matches?(descendants, pgid) when is_list(descendants) do
    Enum.any?(descendants, fn descendant ->
      identity_status(descendant) == :same and process_group(descendant["pid"]) == pgid
    end)
  end

  defp group_descendant_matches?(_descendants, _pgid), do: false

  defp settle_group(pgid, budget_ms), do: settle_until(fn -> group_status(pgid) end, budget_ms)

  defp settle_until(status_fun, budget_ms) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    settle_until(status_fun, deadline, :unknown)
  end

  defp settle_until(status_fun, deadline, _last_status) do
    status = status_fun.()

    cond do
      status == :gone ->
        :gone

      System.monotonic_time(:millisecond) >= deadline ->
        status

      true ->
        Process.sleep(50)
        settle_until(status_fun, deadline, status)
    end
  end

  defp group_status(pgid) do
    case System.cmd("/bin/kill", ["-0", "-#{pgid}"], stderr_to_stdout: true) do
      {_out, 0} ->
        :alive

      {output, _status} ->
        if String.downcase(output) =~ "no such process", do: :gone, else: :unknown
    end
  rescue
    _ -> :unknown
  end

  defp send_signal(control, target_type, target, signal) do
    hook_key = {__MODULE__, :signal_hook, control && Path.expand(lock_path(control))}

    case :persistent_term.get(hook_key, nil) do
      hook when is_function(hook, 3) ->
        case hook.(target_type, target, signal) do
          :continue -> run_signal(target_type, target, signal)
          {:error, _reason} = error -> error
          _ -> run_signal(target_type, target, signal)
        end

      _ ->
        run_signal(target_type, target, signal)
    end
  end

  defp run_signal(target_type, target, signal) do
    signal_arg = if signal == :term, do: "-TERM", else: "-KILL"
    target_arg = if target_type == :group, do: "-#{target}", else: to_string(target)

    case System.cmd("/bin/kill", [signal_arg, target_arg], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:exit_status, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:command_failed, Exception.message(error)}}
  end

  @doc """
  Reaps one owned process group by its recorded identity (`"pid"`, `"pgid"`,
  `"started_at"`, as handed to a `run/3` `:on_start` callback): TERM, then
  KILL after the grace, each only while the leader's pid and start time still
  match and its group is the recorded one. A pid that is gone or was reused
  is left alone (`{:ok, []}`). Refuses this OS process, its ancestors and
  their groups, so a cancel can never reach the controller or its parents.
  `control` only selects the test signal hook and may be `nil`.
  """
  @spec reap_identity(map(), Path.t() | nil) :: {:ok, [String.t()]} | {:error, String.t()}
  def reap_identity(group, control \\ nil) when is_map(group) do
    cond do
      not valid_group_identity?(group) ->
        {:error, "invalid process group identity"}

      protected_identity?(group) ->
        {:error, "refusing to signal this controller or one of its ancestors"}

      true ->
        report = reap_group(Map.put_new(group, "role", "cancelled"), control)

        case report.failed do
          [] -> {:ok, report.reaped}
          failures -> {:error, cleanup_failure(failures)}
        end
    end
  end

  defp protected_identity?(%{"pid" => pid, "pgid" => pgid}) do
    by_pid = Map.new(process_table(), &{&1.pid, &1})
    ancestors = ancestor_chain(by_pid, os_pid(), [])
    protected_pids = MapSet.new(ancestors)

    protected_groups =
      MapSet.new([process_group(os_pid()) | for(a <- ancestors, p = by_pid[a], p, do: p.pgid)])

    MapSet.member?(protected_pids, pid) or MapSet.member?(protected_pids, pgid) or
      MapSet.member?(protected_groups, pgid)
  end

  defp ancestor_chain(_by_pid, pid, seen) when pid in [0, 1], do: seen

  defp ancestor_chain(by_pid, pid, seen) do
    if pid in seen do
      seen
    else
      case by_pid[pid] do
        nil -> [pid | seen]
        %{ppid: ppid} -> ancestor_chain(by_pid, ppid, [pid | seen])
      end
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
  - `:on_start` — `fn group -> :ok | {:error, reason} end`, called with the
    child's `%{"pid","pgid","started_at"}` identity once it is registered and
    before the child's own code runs (it is held on a start gate meanwhile),
    so another process can later `reap_identity/2` it.
  - `:timeout_ms`, `:grace_ms`.
  - `:soft_timeout` — when true, `:timeout_ms` sends TERM to the child
    process only (its helper children are not signalled and get `:grace_ms`
    to finish before the ordinary group reap), waits `:grace_ms`, then KILLs
    the child, instead of an immediate group KILL (`timed_out` is reported
    either way). Only the Developer turn time-box sets it.
  - `:soft_ready_pattern` — a regex; with `:soft_timeout`, the time-box is
    held (nothing is signalled) until the log matches it, so a turn is never
    interrupted before its session identity exists.

  Returns `{:ok, facts}` with `"exit_code"`, `"cleanup"`, `"timed_out"`,
  `"pid"`, `"pgid"`, `"started_at"`, `"finished_at"`, and either `"log_path"`
  (with `"log_sha256"`/`"log_bytes"`) or `"output"` (raw captured bytes).
  Returns `{:error, reason}` when the supervisor fails or recorded escaped
  descendants cannot be confirmed dead.
  """
  @spec run([String.t()], Path.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(argv, cwd, opts \\ []) when is_list(argv) and argv != [] do
    control = Keyword.get(opts, :control)
    on_start = Keyword.get(opts, :on_start)
    start_gate = if control || on_start, do: temp_path("start-gate")

    role = Keyword.get(opts, :role, "process")
    owned_log = Keyword.get(opts, :log_path) == nil
    log_path = Keyword.get(opts, :log_path) || temp_path("log")
    register_path = temp_path("register")

    spec = %{
      "argv" => supervised_argv(argv, start_gate),
      "cwd" => Path.expand(cwd),
      "log" => Path.expand(log_path),
      "mode" => "batch",
      "stdin_path" => Keyword.get(opts, :stdin_path),
      "tmp_dir" => Keyword.get(opts, :tmp_dir),
      "timeout" => opt_seconds(opts, :timeout_ms),
      "soft_timeout" => Keyword.get(opts, :soft_timeout, false),
      "soft_ready_pattern" => Keyword.get(opts, :soft_ready_pattern),
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

    complete_supervised_run(
      port,
      register_path,
      start_gate,
      {control, on_start},
      role,
      owned_log,
      log_path
    )
  end

  defp supervised_argv(argv, nil), do: argv

  defp supervised_argv(argv, start_gate),
    do: [System.find_executable("python3"), "-c", @start_gate_script, start_gate] ++ argv

  defp complete_supervised_run(
         port,
         register_path,
         start_gate,
         {control, on_start},
         role,
         owned_log,
         log_path
       ) do
    with :ok <- maybe_register(control, register_path, role, on_start),
         :ok <- maybe_release_start_gate(start_gate) do
      collect_registered_run(port, register_path, start_gate, control, owned_log, log_path)
    else
      {:error, reason} -> abort_unregistered_run(port, register_path, start_gate, control, reason)
    end
  end

  defp maybe_register(nil, _register_path, _role, nil), do: :ok

  defp maybe_register(control, register_path, role, on_start),
    do: await_registration(register_path, control, role, 300, on_start)

  defp maybe_release_start_gate(nil), do: :ok
  defp maybe_release_start_gate(start_gate), do: File.write(start_gate, "ready")

  defp collect_registered_run(port, register_path, start_gate, control, owned_log, log_path) do
    {output, status} = collect(port, [])
    File.rm(register_path)
    if start_gate, do: File.rm(start_gate)

    with 0 <- status,
         {:ok, facts} <- decode_facts(output) do
      finish_successful_run(control, facts, owned_log, log_path)
    else
      code when is_integer(code) ->
        {:error, "process supervisor failed (#{code}): #{String.slice(output, -2000, 2000)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp abort_unregistered_run(port, register_path, start_gate, control, reason) do
    group_cleanup = abort_unregistered_group(control, register_path)

    if Port.info(port), do: Port.close(port)
    File.rm(register_path)

    # The gate belongs to this launch. Remove it only after its registered
    # process group is confirmed gone; an unidentifiable supervisor may still
    # be waiting on it while its parent-death watchdog runs.
    if not is_nil(start_gate) and group_cleanup == :reaped, do: File.rm(start_gate)

    cleanup_suffix =
      case group_cleanup do
        {:error, cleanup_reason} -> "; owned process cleanup failed: #{inspect(cleanup_reason)}"
        _ -> ""
      end

    {:error, "process supervision setup failed: #{inspect(reason)}#{cleanup_suffix}"}
  end

  defp abort_unregistered_group(control, register_path) do
    case registration_group(register_path) do
      {:ok, group} ->
        abort_registered_group(control, group)

      :retry ->
        :registration_missing

      :invalid ->
        {:error, :invalid_registration}
    end
  end

  defp abort_registered_group(control, group) do
    if valid_group_identity?(group) do
      cleanup_registered_group(control, Map.put(group, "role", "unregistered process"))
    else
      {:error, :invalid_registered_group_identity}
    end
  end

  defp cleanup_registered_group(control, group) do
    report = reap_groups([group], control)

    case report.failed do
      [] -> confirm_unregistered_group_reaped(control, group)
      failures -> {:error, cleanup_failure(failures)}
    end
  end

  defp confirm_unregistered_group_reaped(control, group) do
    case group_status(group["pgid"]) do
      :gone ->
        forget_unregistered_group(control, group)
        :reaped

      status ->
        {:error, {:registered_group_still_present, status}}
    end
  end

  # Registration can have reached the shared lock before a later setup step
  # fails. Remove only this exact identity after its own group has been reaped;
  # a sibling may be running in the same control directory.
  defp forget_unregistered_group(nil, _group), do: :ok

  defp forget_unregistered_group(control, %{"pid" => pid, "pgid" => pgid, "started_at" => started}) do
    with :ok <- await_descendant_monitor(control, pid) do
      forget_unregistered_group_after_monitor(control, pid, pgid, started)
    end
  end

  defp forget_unregistered_group_after_monitor(control, pid, pgid, started) do
    with_lock(control, fn ->
      forget_unregistered_group_locked(control, pid, pgid, started)
    end)
  end

  defp forget_unregistered_group_locked(control, pid, pgid, started) do
    case read_lock(control) do
      {:ok, lock} -> remove_unregistered_group(control, lock, pid, pgid, started)
      _ -> :ok
    end
  end

  defp remove_unregistered_group(control, lock, pid, pgid, started) do
    groups = Map.get(lock, "groups", [])

    retained =
      Enum.reject(groups, fn
        %{"pid" => ^pid, "pgid" => ^pgid, "started_at" => ^started} -> true
        _group -> false
      end)

    if retained == groups,
      do: :ok,
      else: write_lock(control, Map.put(lock, "groups", retained))
  end

  defp finish_successful_run(control, facts, owned_log, log_path) do
    case finish_run_cleanup(control, facts["pid"]) do
      :ok -> {:ok, with_output(facts, owned_log, log_path)}
      {:error, reason} -> {:error, "process cleanup failed: #{reason}"}
    end
  end

  defp finish_run_cleanup(nil, _pid), do: :ok

  defp finish_run_cleanup(control, pid), do: forget_group(control, pid)

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
  defp await_registration(register_path, control, role, tries \\ 300, on_start \\ nil)

  defp await_registration(_path, _control, _role, 0, _on_start),
    do: {:error, :registration_timeout}

  defp await_registration(register_path, control, role, tries, on_start) do
    case registration_group(register_path) do
      {:ok, group} ->
        with :ok <- register_with_lock(control, role, group) do
          notify_start(on_start, group)
        end

      :retry ->
        Process.sleep(10)
        await_registration(register_path, control, role, tries - 1, on_start)

      :invalid ->
        {:error, :invalid_registration}
    end
  end

  defp register_with_lock(nil, _role, _group), do: :ok

  defp register_with_lock(control, role, group) do
    case record_group(control, role, group) do
      :ok -> monitor_descendants(control, group["pid"], group["started_at"])
      error -> error
    end
  end

  # `:on_start` receives the child's `%{"pid","pgid","started_at"}` identity
  # while the start gate still holds the child, so a caller can register a
  # cancel handle before any of the child's own code runs.
  defp notify_start(nil, _group), do: :ok

  defp notify_start(on_start, group) when is_function(on_start, 1) do
    case on_start.(group) do
      {:error, _reason} = error -> error
      _ -> :ok
    end
  end

  defp registration_group(register_path) do
    case File.read(register_path) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, %{} = group} -> {:ok, group}
          _ -> :invalid
        end

      {:error, _} ->
        :retry
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

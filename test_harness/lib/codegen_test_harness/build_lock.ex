defmodule CodegenTestHarness.BuildLock do
  @moduledoc """
  Per-cwd single-flight lock protocol shared by `LoopQueueDrain` (queue) and
  `OrchestrationLoop` (single `codegen-build` invocation). Both write/read
  the SAME physical file (`codegen/gate-pending/queue.lock`) so mutual
  exclusion holds across single AND queue builds on one git tree.

  Extracted from `LoopQueueDrain` (which previously owned this logic
  privately) so `OrchestrationLoop.run/1` can acquire the identical lock
  without duplicating the pid-liveness protocol.

  Lock file format: `"<pid> <label>[ tree=<os_pid>]\\n"` — `<label>` is a
  READ CONTRACT, not diagnostics-only text: it is exactly `"queue"` (the
  drain, `LoopQueueDrain`) or `"solo"` (a single build, `OrchestrationLoop`),
  and `codegen-drain status`'s `watcher=` column reads this exact field to
  distinguish "the queue is supervised" from "one pitch happens to be
  building" — see `codegen-drain`'s `watcher_probe_cmd/1`. Changing either
  literal, or the field order, breaks that consumer silently (it fails
  closed to `watcher=no`, never a crash). The liveness check itself is keyed
  on `<pid>` (the lock-writing BEAM's own OS pid) alone. The optional
  trailing `tree=<os_pid>` token
  (Move 3) records the OS pid of the SPAWNED CHILD TREE the lock-writer is
  supervising — distinct from `<pid>` itself. This closes the two-builders
  door: a drain BEAM can die (crash, OOM-kill, `kill -9` on the wrapper)
  while the process tree it spawned (`mix codegen.loop` -> `claude` CLI)
  keeps running, reparented to init. Before Move 3, a dead-`<pid>` lock was
  ALWAYS silently reclaimed — which let a second builder start beside that
  still-live orphan tree, corrupting shared `codegen/gate-pending/` state
  (two builds racing `gate-result.json`, `cycle-state.json`). Now:
  dead `<pid>` + a live `tree=<os_pid>` → REFUSE loud, naming the surviving
  pid(s) and the reap command, instead of reclaiming. Absent `tree=` token
  (older lock format, or a caller that never threads a tree pid) preserves
  the pre-Move-3 behavior exactly — dead `<pid>` alone is still reclaimed.
  """

  @doc """
  Attempts to acquire `lock_path`. Returns `:ok` on success (lock file
  written with the current OS pid + `label`, optionally `tree_os_pid`).
  Returns `{:error, reason}` when a LIVE pid already holds the lock (per
  `pid_alive_fn`) — unchanged, pre-Move-3 case. Returns `{:error, reason}`
  ALSO when the lock-writing pid is dead BUT its recorded `tree=<os_pid>`
  is still alive (Move 3: a dead drain with a live spawned tree is NOT a
  stale lock — reclaiming it here is exactly what lets a second builder
  start beside an orphaned tree). A lock file naming a DEAD pid with NO
  live tree (or no `tree=` token at all) is reclaimed silently (stale-lock
  recovery — pre-existing behavior, unchanged).

  `opts`:

    * `:tree_os_pid` — OS pid (integer or string) of the process tree this
      lock-holder is supervising, recorded as `tree=<os_pid>` in the lock
      file. Omit when the caller has no such child (or already holds the
      lock bypass, e.g. a per-pitch child spawned under
      `CODEGEN_BUILD_LOCK_HELD=1`).
  """
  @spec acquire(String.t(), String.t(), (String.t() -> boolean()), keyword()) ::
          :ok | {:error, String.t()}
  def acquire(lock_path, label, pid_alive_fn, opts \\ []) do
    case File.read(lock_path) do
      {:ok, content} ->
        case parse_lock_line(content) do
          {pid_str, tree_os_pid} when pid_str != "" ->
            cond do
              pid_alive_fn.(pid_str) ->
                {:error,
                 "a build is already running (pid #{pid_str}) — refusing to start a second"}

              tree_os_pid != nil and pid_alive_fn.(tree_os_pid) ->
                {:error,
                 "lock-holder (pid #{pid_str}) is dead but its build tree (pid #{tree_os_pid}) " <>
                   "is still running — refusing to start a second builder beside a live orphan. " <>
                   "Inspect with `ps -p #{tree_os_pid} -o pid,etime,command`, then reap with " <>
                   "`kill -9 #{tree_os_pid}` if confirmed stale, before retrying."}

              true ->
                write(lock_path, label, opts)
            end

          _ ->
            write(lock_path, label, opts)
        end

      {:error, _reason} ->
        write(lock_path, label, opts)
    end
  end

  # Parses `"<pid> <label>[ tree=<os_pid>]\n"`. Returns `{pid_str, tree_os_pid
  # | nil}`. A malformed/missing `tree=` token (older lock format) yields
  # `nil` — preserving pre-Move-3 behavior exactly for every existing lock
  # file on disk.
  @spec parse_lock_line(String.t()) :: {String.t(), String.t() | nil} | :empty
  defp parse_lock_line(content) do
    case String.split(String.trim(content), " ") do
      [] ->
        :empty

      [pid_str | rest] ->
        tree_os_pid =
          rest
          |> Enum.find(&String.starts_with?(&1, "tree="))
          |> case do
            nil -> nil
            token -> String.trim_leading(token, "tree=")
          end

        {pid_str, tree_os_pid}
    end
  end

  defp write(lock_path, label, opts) do
    File.mkdir_p!(Path.dirname(lock_path))

    line =
      case Keyword.get(opts, :tree_os_pid) do
        nil -> "#{System.pid()} #{label}\n"
        tree_os_pid -> "#{System.pid()} #{label} tree=#{tree_os_pid}\n"
      end

    File.write!(lock_path, line)
    :ok
  end

  @doc "Releases `lock_path` (best-effort — missing file is not an error)."
  @spec release(String.t()) :: :ok
  def release(lock_path) do
    File.rm(lock_path)
    :ok
  end

  @doc """
  Rewrites `lock_path`'s `tree=<os_pid>` token to `tree_os_pid`, preserving
  the existing `<pid> <label>` prefix. Used by `LoopQueueDrain` — which
  acquires the lock ONCE at drain startup, before any per-pitch child
  exists — to keep the lock file's recorded tree pid current as each new
  spawn starts (Move 3 needs the CURRENTLY in-flight child's pid, not the
  drain's own pid, to be discoverable by a second builder's `acquire/4`
  check after this drain's BEAM has died).

  Best-effort: a missing/malformed lock file (lock released mid-spawn by a
  concurrent path, or the file predates the `tree=` format) is a no-op —
  this is diagnostic enrichment, never a correctness requirement for the
  spawn itself.
  """
  @spec update_tree_pid(String.t(), integer() | String.t()) :: :ok
  def update_tree_pid(lock_path, tree_os_pid) do
    case File.read(lock_path) do
      {:ok, content} ->
        case parse_lock_line(content) do
          {pid_str, _old_tree} when pid_str != "" ->
            label = extract_label(content)
            File.write!(lock_path, "#{pid_str} #{label} tree=#{tree_os_pid}\n")
            :ok

          _ ->
            :ok
        end

      # fail-loud-exempt: see @doc — best-effort diagnostic enrichment only.
      {:error, _reason} ->
        :ok
    end
  end

  # Extracts the `<label>` token (second word), stripping any existing
  # `tree=` token so update_tree_pid/2 never duplicates it.
  @spec extract_label(String.t()) :: String.t()
  defp extract_label(content) do
    case String.split(String.trim(content), " ") do
      [_pid, label | _rest] -> label
      _ -> "queue"
    end
  end

  @doc """
  Real `pid_alive_fn`: checks OS pid liveness via `kill -0 <pid>` exit
  status. Non-numeric `pid_str` is treated as not-alive (fail-closed on a
  corrupt lock file → lock is reclaimed rather than wedging forever).
  """
  @spec default_pid_alive?(String.t()) :: boolean()
  def default_pid_alive?(pid_str) do
    case Integer.parse(pid_str) do
      {pid, ""} ->
        case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
          {_out, 0} -> true
          {_out, _} -> false
        end

      _ ->
        false
    end
  end
end

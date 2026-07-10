defmodule CodegenTestHarness.BuildLock do
  @moduledoc """
  Per-cwd single-flight lock protocol shared by `LoopQueueDrain` (queue) and
  `OrchestrationLoop` (single `codegen-build` invocation). Both write/read
  the SAME physical file (`codegen/gate-pending/queue.lock`) so mutual
  exclusion holds across single AND queue builds on one git tree.

  Extracted from `LoopQueueDrain` (which previously owned this logic
  privately) so `OrchestrationLoop.run/1` can acquire the identical lock
  without duplicating the pid-liveness protocol.

  Lock file format: `"<pid> <label>\\n"` — `<label>` is free text (`"queue"`
  for the drain, `"solo"` for a single build) used only for diagnostics; the
  liveness check is keyed on `<pid>` alone.
  """

  @doc """
  Attempts to acquire `lock_path`. Returns `:ok` on success (lock file
  written with the current OS pid + `label`). Returns
  `{:error, reason}` when a LIVE pid already holds the lock (per
  `pid_alive_fn`). A lock file naming a DEAD pid is reclaimed silently
  (stale-lock recovery — pre-existing behavior ported unchanged from
  `LoopQueueDrain.acquire_lock/2`).
  """
  @spec acquire(String.t(), String.t(), (String.t() -> boolean())) ::
          :ok | {:error, String.t()}
  def acquire(lock_path, label, pid_alive_fn) do
    case File.read(lock_path) do
      {:ok, content} ->
        case String.split(String.trim(content), " ", parts: 2) do
          [pid_str | _] when pid_str != "" ->
            if pid_alive_fn.(pid_str) do
              {:error, "a build is already running (pid #{pid_str}) — refusing to start a second"}
            else
              write(lock_path, label)
            end

          _ ->
            write(lock_path, label)
        end

      {:error, _reason} ->
        write(lock_path, label)
    end
  end

  defp write(lock_path, label) do
    File.mkdir_p!(Path.dirname(lock_path))
    File.write!(lock_path, "#{System.pid()} #{label}\n")
    :ok
  end

  @doc "Releases `lock_path` (best-effort — missing file is not an error)."
  @spec release(String.t()) :: :ok
  def release(lock_path) do
    File.rm(lock_path)
    :ok
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

defmodule Kogen.ShapingAudit.Lock do
  @moduledoc false

  # Never unlink the guard inode. The kernel serializes independent BEAMs;
  # closing the port on owner exit closes stdin and releases the lock.
  @script """
  import fcntl, sys, time
  guard = open(sys.argv[1], "a+b")
  deadline = time.monotonic() + int(sys.argv[2]) / 1000
  while True:
      try:
          fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
          break
      except BlockingIOError:
          if time.monotonic() >= deadline:
              print("busy", flush=True)
              sys.exit(0)
          time.sleep(0.02)
  print("locked", flush=True)
  sys.stdin.buffer.read(1)
  """

  # Shared by request/input/approval records and per-slug audit records. The
  # audit cannot depend on the Shaping engine; both need the same safe guard
  # around stale deletion, acquisition, callback and release.
  def with_lock(path, wait_ms, fun) do
    File.mkdir_p!(Path.dirname(path))

    case acquire(path, wait_ms) do
      {:ok, port} ->
        try do
          {:ok, fun.()}
        after
          if Port.info(port), do: Port.close(port)
        end

      :busy ->
        {:error, :busy}
    end
  end

  defp acquire(path, wait_ms) do
    python = System.find_executable("python3") || raise "python3 is required for shaping locks"

    port =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:line, 1024},
        args: ["-B", "-c", @script, path <> ".guard", to_string(wait_ms)]
      ])

    receive do
      {^port, {:data, {:eol, "locked"}}} ->
        {:ok, port}

      {^port, {:data, {:eol, "busy"}}} ->
        if Port.info(port), do: Port.close(port)
        :busy

      {^port, {:exit_status, code}} ->
        raise "shaping lock guard exited before acquisition (#{code})"
    after
      wait_ms + 5_000 ->
        Port.close(port)
        raise "shaping lock guard did not respond"
    end
  end
end

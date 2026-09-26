defmodule Kogen.Build.VerificationRunner do
  @moduledoc """
  Runs one verification command as a child of the Build controller.

  The command runs outside the Developer process tree, in its own process
  group, with the controller's environment minus every verification or
  tracking context. Its combined output goes to a controller-owned log file
  created exclusively. After the command exits, any remaining member of its
  process group is terminated; a member that cannot be reaped marks the run
  `cleanup: failed`. Status comes only from the exit code, a time limit and
  cleanup, never from anything the command prints.

  The small process supervisor below is part of this compiled module, so the
  controller never loads or executes supervisor code from the Candidate.
  """

  # The write-boundary marker is removed so fixture Builds inside `check` and
  # live targets apply their own boundary; the Mix redirections are removed so
  # a Candidate's `make check` compiles with the Candidate's own `deps/` and
  # `_build/`, never control's.
  @scrubbed ~w(KOGEN_VERIFICATION_CONTEXT KOGEN_TRACKING_CONTEXT KOGEN_VERIFICATION_RETRY_LIMIT KOGEN_ROLE KOGEN_WRITE_BOUNDARY MIX_BUILD_PATH MIX_DEPS_PATH MIX_EXS)

  @supervisor ~S"""
  import datetime, json, os, signal, subprocess, sys, time

  spec = json.loads(sys.argv[1])

  def now():
      value = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds")
      return value.replace("+00:00", "Z")

  def alive(group):
      try:
          os.killpg(group, 0)
          return True
      except ProcessLookupError:
          return False
      except PermissionError:
          return True

  def settle(group, grace):
      deadline = time.monotonic() + grace
      while alive(group) and time.monotonic() < deadline:
          time.sleep(0.05)
      return not alive(group)

  def signal_group(group, number):
      try:
          os.killpg(group, number)
      except (ProcessLookupError, PermissionError):
          pass

  started, clock = now(), time.monotonic()
  timed_out, spawn_error, code, cleanup = False, None, 1, "clean"
  with open(spec["log"], "xb") as log:
      try:
          child = subprocess.Popen(spec["argv"], cwd=spec["cwd"], stdin=subprocess.DEVNULL,
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
      except OSError as error:
          spawn_error = str(error)
          log.write(("Kogen could not start verification command: %s\n" % error).encode())
      if spawn_error is None:
          try:
              code = child.wait(timeout=spec.get("timeout"))
          except subprocess.TimeoutExpired:
              timed_out = True
              signal_group(child.pid, signal.SIGKILL)
              code = child.wait()
          if code < 0:
              code = 128 - code
          if alive(child.pid):
              cleanup = "terminated"
              signal_group(child.pid, signal.SIGTERM)
              if not settle(child.pid, spec["grace"]):
                  signal_group(child.pid, signal.SIGKILL)
                  if not settle(child.pid, spec["grace"]):
                      cleanup = "failed"
  finished = now()
  print(json.dumps({"exit_code": code, "cleanup": cleanup, "timed_out": timed_out,
                    "spawn_error": spawn_error, "started_at": started, "finished_at": finished,
                    "elapsed_ms": int((time.monotonic() - clock) * 1000)}))
  """

  @doc "Environment entries removed from every controller-launched child."
  def scrubbed_environment, do: Enum.map(@scrubbed, &{&1, nil})

  @doc "Names of the environment variables removed from every child."
  def scrubbed_names, do: @scrubbed

  @doc """
  Runs `make <target>` in `root` (the Candidate), writing combined output to
  `log_path`. Returns the run facts and the log's bytes and digest.

  Option `:control_root` names the control checkout: unless the caller set
  one, the child's `KOGEN_LIVE_LOG_DIR` is control's
  `.kogen/runtime/live-evidence`, so evidence a live owner retains for a
  Candidate Build survives the Candidate's removal at publication.
  """
  @spec run_target(Path.t(), String.t(), Path.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def run_target(root, target, log_path, opts \\ []) do
    if Kogen.Check.valid_target_name?(target),
      do: run(["make", "-C", Path.expand(root), target], root, log_path, live_log_dir(opts)),
      else: {:error, "refused unsafe target name: #{inspect(target)}"}
  end

  @doc "The live-evidence directory a target child gets under `control_root`."
  @spec live_evidence_dir(Path.t()) :: Path.t()
  def live_evidence_dir(control_root),
    do: Path.join([control_root, ".kogen", "runtime", "live-evidence"])

  defp live_log_dir(opts) do
    case {Keyword.get(opts, :control_root), System.get_env("KOGEN_LIVE_LOG_DIR")} do
      {control, caller} when is_binary(control) and caller in [nil, ""] ->
        env = [{"KOGEN_LIVE_LOG_DIR", live_evidence_dir(control)}]
        Keyword.update(opts, :env, env, &(&1 ++ env))

      _ ->
        opts
    end
  end

  @doc """
  Runs `argv` in `cwd`. Options: `:timeout_ms` (default none), `:grace_ms`
  (default 2000) and `:env` (extra entries, applied after the scrub).
  """
  @spec run([String.t()], Path.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(argv, cwd, log_path, opts \\ []) when is_list(argv) and argv != [] do
    timeout = Keyword.get(opts, :timeout_ms)

    spec = %{
      "argv" => argv,
      "cwd" => Path.expand(cwd),
      "log" => Path.expand(log_path),
      "timeout" => timeout && timeout / 1000,
      "grace" => Keyword.get(opts, :grace_ms, 2_000) / 1000
    }

    env = scrubbed_environment() ++ Keyword.get(opts, :env, [])

    with :ok <- File.mkdir_p(Path.dirname(log_path)),
         {output, 0} <-
           System.cmd("python3", ["-c", @supervisor, Jason.encode!(spec)],
             env: env,
             stderr_to_stdout: true
           ),
         {:ok, facts} <- decode_facts(output),
         {:ok, bytes} <- File.read(log_path) do
      {:ok,
       Map.merge(facts, %{
         "log_path" => Path.expand(log_path),
         "log_sha256" => sha256(bytes),
         "log_bytes" => bytes
       })}
    else
      {output, code} when is_binary(output) ->
        {:error, "verification supervisor failed (#{code}): #{String.slice(output, -2000, 2000)}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "verification supervisor failed: #{inspect(reason)}"}
    end
  end

  @doc "Receipt status from the exit code, time limit and cleanup only."
  @spec status(map()) :: String.t()
  def status(%{"exit_code" => 0, "timed_out" => false, "cleanup" => cleanup})
      when cleanup in ["clean", "terminated"],
      do: "passed"

  def status(_facts), do: "failed"

  defp decode_facts(output) do
    line = output |> String.split("\n", trim: true) |> List.last()

    case line && Jason.decode(line) do
      {:ok, %{"exit_code" => code, "cleanup" => cleanup} = facts}
      when is_integer(code) and cleanup in ["clean", "terminated", "failed"] ->
        {:ok, facts}

      _ ->
        {:error, "verification supervisor returned malformed facts"}
    end
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end

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

  Execution itself is `Kogen.ProcessCustody`'s supervisor
  (`priv/kogen/process_supervisor.py`), the same one every role launch, Jev
  call and `prepare` step uses, generalised from the supervisor this module
  used to embed directly. The controller still never loads or executes
  supervisor code from the Candidate: the script is resolved from this
  controller's own compiled source tree.
  """

  # The write-boundary marker is removed so fixture Builds inside `check` and
  # live targets apply their own boundary; the Mix redirections are removed so
  # a Candidate's `make check` compiles with the Candidate's own `deps/` and
  # `_build/`, never control's.
  @scrubbed ~w(KOGEN_VERIFICATION_CONTEXT KOGEN_TRACKING_CONTEXT KOGEN_VERIFICATION_RETRY_LIMIT KOGEN_ROLE KOGEN_WRITE_BOUNDARY MIX_BUILD_PATH MIX_DEPS_PATH MIX_EXS)

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

  Option `:route` is the Build's selected route, as frozen at admission,
  exported as `KOGEN_ROUTE` to every child. With `provider_backed: true` (a
  live target) it is required and is also returned as `"route"` in the facts;
  the Candidate's `default_route` is never consulted.
  """
  @spec run_target(Path.t(), String.t(), Path.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def run_target(root, target, log_path, opts \\ []) do
    with :ok <- valid_target(target),
         :ok <- live_route(opts),
         {:ok, facts} <-
           run(
             ["make", "-C", Path.expand(root), target],
             root,
             log_path,
             route_env(live_log_dir(opts))
           ) do
      {:ok, put_route(facts, opts)}
    end
  end

  defp valid_target(target) do
    if Kogen.Check.valid_target_name?(target),
      do: :ok,
      else: {:error, "refused unsafe target name: #{inspect(target)}"}
  end

  # A provider-backed (live) target runs on the Build's selected route. With
  # no selected route it fails; there is no fallback to the default route.
  defp live_route(opts) do
    route = Keyword.get(opts, :route)

    if Keyword.get(opts, :provider_backed) == true and not (is_binary(route) and route != ""),
      do: {:error, "a live target needs the Build's selected route; none was given"},
      else: :ok
  end

  defp put_route(facts, opts) do
    route = Keyword.get(opts, :route)

    if Keyword.get(opts, :provider_backed) == true and is_binary(route),
      do: Map.put(facts, "route", route),
      else: facts
  end

  defp route_env(opts) do
    case Keyword.get(opts, :route) do
      route when is_binary(route) and route != "" ->
        Keyword.update(opts, :env, [{"KOGEN_ROUTE", route}], &(&1 ++ [{"KOGEN_ROUTE", route}]))

      _ ->
        opts
    end
  end

  @doc "The live-evidence directory a target child gets under `control_root`."
  @spec live_evidence_dir(Path.t()) :: Path.t()
  def live_evidence_dir(control_root),
    do: Path.join([control_root, ".kogen", "runtime", "live-evidence"])

  # An explicit `:live_log_dir` (a fan-out job's own target-specific evidence
  # root) always wins, so concurrent targets' outputs never collide.
  defp live_log_dir(opts) do
    case {Keyword.get(opts, :live_log_dir), Keyword.get(opts, :control_root),
          System.get_env("KOGEN_LIVE_LOG_DIR")} do
      {dir, _control, _caller} when is_binary(dir) ->
        env = [{"KOGEN_LIVE_LOG_DIR", dir}]
        Keyword.update(opts, :env, env, &(&1 ++ env))

      other ->
        default_live_log_dir(opts, other)
    end
  end

  defp default_live_log_dir(opts, {_dir, control, caller}) do
    case {control, caller} do
      {control, caller} when is_binary(control) and caller in [nil, ""] ->
        env = [{"KOGEN_LIVE_LOG_DIR", live_evidence_dir(control)}]
        Keyword.update(opts, :env, env, &(&1 ++ env))

      _ ->
        opts
    end
  end

  @doc """
  Runs `argv` in `cwd`. Options: `:timeout_ms` (default none), `:grace_ms`
  (default 2000), `:env` (extra entries, applied after the scrub),
  `:control_root` (the control checkout; when given, this run's group is
  registered on its build lock by default, so a stale run is reaped by a
  later Build) and `:role` (a label recorded with the group, default
  `"verification"`). `run_target/4` already forwards `:control_root` here
  (it also names the live-evidence directory); a `prepare` caller passes the
  same option.
  """
  @spec run([String.t()], Path.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(argv, cwd, log_path, opts \\ []) when is_list(argv) and argv != [] do
    env = scrubbed_environment() ++ Keyword.get(opts, :env, [])

    custody_opts = [
      log_path: log_path,
      env: env,
      timeout_ms: Keyword.get(opts, :timeout_ms),
      grace_ms: Keyword.get(opts, :grace_ms, 2_000),
      control: Keyword.get(opts, :control_root),
      role: Keyword.get(opts, :role, "verification"),
      on_start: Keyword.get(opts, :on_start)
    ]

    case Kogen.ProcessCustody.run(argv, cwd, custody_opts) do
      {:ok, facts} -> {:ok, facts}
      {:error, reason} -> {:error, "verification supervisor failed: #{reason}"}
    end
  end

  @doc "Receipt status from the exit code, time limit and cleanup only."
  @spec status(map()) :: String.t()
  def status(%{"exit_code" => 0, "timed_out" => false, "cleanup" => cleanup})
      when cleanup in ["clean", "terminated"],
      do: "passed"

  def status(_facts), do: "failed"
end

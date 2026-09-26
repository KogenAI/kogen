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
      role: Keyword.get(opts, :role, "verification")
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

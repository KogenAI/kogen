defmodule Kogen.Codex do
  @moduledoc """
  Owns managed runtime selection and explicit Kogen credential routing.
  A selection is held by the caller for the whole operation, including resume.
  Native Codex owns credentials and conversation formats; neither is inspected here.
  """
  use Boundary, deps: [], exports: [Environment, ProviderOutcome]

  alias Kogen.Codex.{Environment, State}

  @doc "The user-local managed root. The override is for private integration fixtures."
  def root do
    System.get_env("KOGEN_CODEX_ROOT") ||
      Path.join(System.user_home!(), "Library/Application Support/Kogen/codex")
  end

  @doc "Selects once, checks local native readiness, and holds an active-use receipt."
  def open(config, project \\ File.cwd!()) do
    case System.get_env("KOGEN_HARNESS") do
      nil -> open_managed(config, project)
      executable -> {:ok, %{executable: resolve_test_executable(executable), args: [], env: []}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp open_managed(config, project) do
    with {:ok, runtime} <- installed(),
         {:ok, scope} <- effective_scope(project),
         :ok <- require_login(runtime, scope, config, project) do
      operation = State.operation!(root())
      lease = State.lease!(root(), runtime, project)

      {:ok,
       %{
         runtime: runtime,
         scope: scope,
         config: config,
         project: project,
         operation: operation,
         lease: lease
       }}
    end
  end

  @doc "Fresh immutable settings for a launch, retaining the concrete runtime and native state."
  def launch_context(%{runtime: runtime} = selection) do
    Environment.prepare(
      runtime,
      selection.scope,
      selection.config,
      selection.project,
      selection.operation
    )
  end

  def launch_context(context), do: context

  @doc "Releases only this operation's active receipt; runtimes and native sessions are retained."
  def close(%{lease: lease}), do: File.rm(lease)
  def close(_context), do: :ok

  @doc false
  def with_active(runtime, project, function) do
    lease = State.lease!(root(), runtime, project)

    try do
      function.()
    after
      File.rm(lease)
    end
  end

  @doc "Read-only default inspection; no PATH fallback or installation."
  def installed do
    case installer("required") do
      {:ok, nil} -> {:error, "Kogen Codex is not installed. Run mix kogen.codex.install"}
      result -> result
    end
  end

  @doc false
  def installer(command, arguments \\ []) do
    script = Application.app_dir(:kogen, "priv/kogen/codex/install.py")

    python =
      System.find_executable("python3") ||
        raise "Kogen requires Python 3.11 or newer; use the project mise environment"

    case System.cmd(python, [script, Path.expand(root()), command | arguments]) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"ok" => true, "runtime" => runtime}} -> {:ok, runtime}
          _ -> {:error, "invalid managed Codex #{command} response"}
        end

      {output, status} ->
        reason =
          case Jason.decode(output) do
            {:ok, %{"error" => reason}} -> reason
            _ -> "exit #{status}"
          end

        {:error, "managed Codex #{command} failed: #{reason}"}
    end
  end

  @doc "Explicit install, without login or provider work."
  def install do
    management_allowed!("install")
    installer("install")
  end

  @doc "A local scope selector is independent of credential existence and session cleanup."
  def effective_scope(project \\ File.cwd!()) do
    name = State.scope_name(root(), project)
    {:ok, scope(name, project)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp scope(name, project) do
    suffix = if name == :shared, do: "shared", else: "projects/" <> State.project_id(project)
    %{name: name, path: Path.join([root(), "accounts", suffix]) |> Path.expand()}
  end

  @doc "Select scope before native login so cancellation never falls back."
  def login(args, config) do
    management_allowed!("login")

    with {:ok, selection, forwarded} <- login_arguments(args),
         :ok <- require_project(selection),
         {:ok, runtime} <- login_runtime(selection) do
      delegate_login(runtime, selection, forwarded, config)
    end
  end

  defp login_runtime(:default), do: {:ok, nil}
  defp login_runtime(_selection), do: installed()

  defp delegate_login(_runtime, :default, [], _config) do
    State.select_scope!(root(), File.cwd!(), :shared)

    IO.puts(
      "This project now uses the shared Kogen login. Retained project credentials were kept."
    )

    {:ok, 0}
  end

  defp delegate_login(runtime, selection, forwarded, config) do
    project = File.cwd!()
    if selection == :project, do: State.select_scope!(root(), project, :project)
    scope = scope(selection, project)
    State.ensure_scope!(scope.path)
    context = Environment.prepare(runtime, scope, config, project, State.operation!(root()))
    {:ok, terminal(context, ["login" | forwarded])}
  end

  @doc false
  def login_arguments(args) do
    {wrapper, rest} = Enum.split_while(args, &(&1 != "--"))
    forwarded = if rest == [], do: [], else: tl(rest)

    case {wrapper, forwarded} do
      {[], forwarded} ->
        {:ok, :shared, forwarded}

      {["--project"], forwarded} ->
        {:ok, :project, forwarded}

      {["--use-default"], []} ->
        {:ok, :default, []}

      _ ->
        {:error, "usage: mix kogen.codex.login [--project | --use-default] [-- native arguments]"}
    end
  end

  defp require_project(:shared), do: :ok

  defp require_project(_selection) do
    if File.regular?(".kogen/config.yaml"),
      do: :ok,
      else: {:error, "project scope requires a Kogen-enabled checkout"}
  end

  @doc false
  def require_login(runtime, scope, config, project) do
    case login_status(runtime, scope, config, project) do
      :configured ->
        :ok

      :missing ->
        {:error,
         "Selected #{scope.name} Kogen login is not configured. Run #{login_command(scope)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp login_command(%{name: :project}), do: "mix kogen.codex.login --project"
  defp login_command(_scope), do: "mix kogen.codex.login"

  @doc "Native local status is not a remote entitlement check; native text is never printed."
  def login_status(runtime, scope, config, project) do
    if File.dir?(scope.path) do
      State.validate_scope!(scope.path)
      operation = State.operation!(root())
      # A shaping-evaluation context receipt belongs to the actual interactive
      # launch, not this prerequisite status probe. Letting the inherited test
      # boundary reach both preparations would publish the probe context first
      # and make the real launch's exclusive receipt fail.
      caller_env = Map.delete(System.get_env(), "KOGEN_CODEX_CONTEXT_RECEIPT")
      context = Environment.prepare(runtime, scope, config, project, operation, caller_env)

      case System.cmd(context.executable, context.args ++ ["login", "status"],
             env: context.env,
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          :configured

        {_output, 1} ->
          :missing

        {_output, status} ->
          {:error, "native login status failed (exit #{status}) for #{scope.name} scope"}
      end
    else
      :missing
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc "Reports the default and live operation leases; retained releases are not active use."
  def status(config) do
    with {:ok, runtime} <- installer("required"),
         {:ok, scope} <- effective_scope() do
      state =
        if runtime, do: login_status(runtime, scope, config, File.cwd!()), else: :unavailable

      {:ok, %{runtime: runtime, active: State.active(root()), scope: scope, login: state}}
    end
  end

  @doc false
  def terminal(context, args) do
    port =
      Port.open({:spawn_executable, context.executable}, [
        :nouse_stdio,
        :exit_status,
        args: context.args ++ args,
        env:
          Enum.map(context.env, fn {key, value} ->
            {String.to_charlist(key),
             if(is_nil(value), do: false, else: String.to_charlist(value))}
          end)
      ])

    receive do
      {^port, {:exit_status, status}} -> status
    end
  end

  def management_allowed!(command) do
    if System.get_env("KOGEN_ROLE") in ["developer", "reviewer", "shaper"] do
      raise "mix kogen.codex.#{command} is an explicit user operation; managed roles cannot run setup or compatibility verification"
    end
  end

  defp resolve_test_executable(name) do
    if String.contains?(name, "/"),
      do: Path.expand(name),
      else: System.find_executable(name) || raise("test harness executable not found: #{name}")
  end
end

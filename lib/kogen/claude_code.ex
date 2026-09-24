defmodule Kogen.ClaudeCode do
  @moduledoc """
  Owns the managed Claude Code runtime and explicit Kogen login scopes.

  The runtime is one pinned native binary under Kogen's managed root, never a
  `claude` from PATH, and every launch sets `DISABLE_AUTOUPDATER=1`. Kogen's
  roles run unattended, so every launch also sets
  `CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT=1`, overriding any inherited
  value; otherwise Claude Code asks to confirm a recursive `rm` of
  command-substitution output even with `--dangerously-skip-permissions`.
  Each scope is a private `CLAUDE_CONFIG_DIR`. Claude Code keys a scope's macOS Keychain
  login by its path, so Kogen never moves or renames a scope, and it never
  reads, copies or prints credential values: readiness uses only the
  `loggedIn` and `authMethod` metadata of `claude auth status`.
  """
  use Boundary, deps: [], exports: []

  @pinned_version "2.1.281"
  @installer Path.expand("../../priv/kogen/claude_code/install.py", __DIR__)

  # Provider credentials and routing switches must never fund or redirect a
  # Kogen launch, and an inherited Claude Code session must not leak into one.
  @removed_prefixes ["ANTHROPIC_", "CLAUDE_CODE_", "CLAUDE_CONFIG_DIR", "CLAUDECODE"]
  @removed_names ["AWS_BEARER_TOKEN_BEDROCK", "VERTEX_REGION_CLAUDE"]

  @doc "The exact Claude Code release this checkout supports."
  def pinned_version, do: @pinned_version

  @doc "The user-local managed root. The override is for private offline fixtures."
  def root do
    System.get_env("KOGEN_CLAUDE_ROOT") ||
      Path.join(System.user_home!(), "Library/Application Support/Kogen/claude")
  end

  @doc """
  Selects the runtime and scope and checks readiness before any model launch.
  `config` is a resolved route whose harness is `claude`. `KOGEN_HARNESS` only
  replaces the Claude Code executable for offline fixtures.
  """
  def open(config, project \\ File.cwd!())

  def open(%{harness: "claude"} = config, project) do
    with {:ok, runtime} <- runtime(),
         {:ok, scope} <- effective_scope(project),
         :ok <- require_login(runtime, scope) do
      {:ok,
       %{harness: "claude", runtime: runtime, scope: scope, config: config, project: project}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  def open(config, _project),
    do:
      {:error,
       "Kogen Claude Code requires a claude route, got harness: #{inspect(Map.get(config, :harness))}"}

  @doc "Fresh launch settings for the selected runtime and scope."
  def launch_context(%{harness: "claude", runtime: runtime, scope: scope} = selection) do
    %{
      harness: "claude",
      executable: Map.fetch!(runtime, "executable"),
      args: [],
      env: environment(scope),
      config: selection.config,
      project: selection.project
    }
  end

  @doc "Selections hold no leases; runtimes, scopes and sessions are retained."
  def close(_selection), do: :ok

  @doc """
  The launch environment delta: the scope's config dir, no self-update, no
  auto memory shared across role sessions, no confirmation prompt for a
  recursive `rm` of command-substitution output, and every inherited provider
  credential, base URL, Bedrock/Vertex switch or Claude Code variable removed.
  """
  def environment(scope, caller_env \\ System.get_env()) do
    removed =
      for {name, _value} <- caller_env, removed?(name), do: {name, nil}

    (removed ++
       [
         {"CLAUDE_CONFIG_DIR", scope.path},
         {"DISABLE_AUTOUPDATER", "1"},
         {"CLAUDE_CODE_DISABLE_AUTO_MEMORY", "1"},
         {"CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT", "1"}
       ])
    |> Map.new()
    |> Map.to_list()
  end

  defp removed?(name),
    do: name in @removed_names or Enum.any?(@removed_prefixes, &String.starts_with?(name, &1))

  defp runtime do
    case System.get_env("KOGEN_HARNESS") do
      nil -> installed()
      executable -> {:ok, %{"executable" => test_executable(executable), "version" => "test"}}
    end
  end

  @doc "Read-only inspection of this checkout's pin; no PATH fallback or installation."
  def installed do
    case installer("required") do
      {:ok, nil} ->
        {:error,
         "Kogen Claude Code #{@pinned_version} is not installed. Run mix kogen.claude.install"}

      result ->
        result
    end
  end

  @doc "Explicit install of the pinned runtime, without login or provider work."
  def install do
    management_allowed!("install")
    installer("install")
  end

  @doc false
  def installer(command) do
    script = @installer

    python =
      System.find_executable("python3") ||
        raise "Kogen requires Python 3.11 or newer; use the project mise environment"

    case System.cmd(python, [script, Path.expand(root()), command]) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"ok" => true, "runtime" => runtime}} -> {:ok, runtime}
          _ -> {:error, "invalid managed Claude Code #{command} response"}
        end

      {output, status} ->
        reason =
          case Jason.decode(output) do
            {:ok, %{"error" => reason}} -> reason
            _ -> "exit #{status}"
          end

        {:error, "managed Claude Code #{command} failed: #{reason}"}
    end
  end

  @doc "The selected scope; a project selector is explicit and never inferred."
  def effective_scope(project \\ File.cwd!()) do
    {:ok, scope(scope_name(project), project)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp scope(name, project) do
    suffix = if name == :shared, do: "shared", else: "projects/" <> project_id(project)
    %{name: name, path: Path.join([root(), "accounts", suffix]) |> Path.expand()}
  end

  @doc false
  def project_id(project),
    do: :crypto.hash(:sha256, Path.expand(project)) |> Base.encode16(case: :lower)

  defp selector(project), do: Path.join([root(), "preferences", project_id(project)])

  defp scope_name(project) do
    path = selector(project)

    case File.lstat(path) do
      {:error, :enoent} ->
        :shared

      {:ok, %{type: :regular}} ->
        case File.read!(path) do
          "project\n" -> :project
          "shared\n" -> :shared
          _ -> raise "unrecognized Kogen Claude Code account selector: #{path}"
        end

      _ ->
        raise "unsafe Kogen Claude Code account selector: #{path}"
    end
  end

  defp select_scope!(project, name) do
    path = selector(project)
    scope_name(project)
    private_directory!(Path.dirname(path))
    temporary = path <> "." <> Integer.to_string(System.unique_integer([:positive]))

    try do
      File.write!(temporary, "#{name}\n", [:exclusive])
      File.chmod!(temporary, 0o600)
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end

  # Existing scope contents are Claude Code's; only a missing directory is created.
  defp ensure_scope!(path) do
    private_directory!(path)
    validate_scope!(path)
  end

  defp validate_scope!(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      _ -> raise "unexpected occupant at Kogen Claude Code scope: #{path}"
    end
  end

  defp private_directory!(path) do
    path = Path.expand(path)

    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        :ok

      {:error, :enoent} ->
        private_directory!(Path.dirname(path))

        case File.mkdir(path) do
          :ok -> File.chmod!(path, 0o700)
          {:error, :eexist} -> private_directory!(path)
          {:error, reason} -> raise File.Error, reason: reason, action: "create", path: path
        end

      _ ->
        raise "unexpected occupant at Kogen directory: #{path}"
    end
  end

  @doc """
  Opens the managed interactive `claude` in the selected scope so the user
  completes Claude Code's own first-run flow, including its login. Native
  arguments after `--` are forwarded unchanged. The scope is selected first,
  so cancellation never falls back to another login.
  """
  def login(args) do
    management_allowed!("login")

    with {:ok, selection, forwarded} <- login_arguments(args),
         :ok <- require_project(selection) do
      delegate_login(selection, forwarded)
    end
  end

  defp delegate_login(:default, []) do
    select_scope!(File.cwd!(), :shared)

    IO.puts(
      "This project now uses the shared Kogen Claude Code login. Retained project logins were kept."
    )

    {:ok, 0}
  end

  defp delegate_login(selection, forwarded) do
    with {:ok, runtime} <- installed() do
      project = File.cwd!()
      if selection == :project, do: select_scope!(project, :project)
      scope = scope(selection, project)
      ensure_scope!(scope.path)

      context = %{
        executable: Map.fetch!(runtime, "executable"),
        args: [],
        env: environment(scope)
      }

      {:ok, terminal(context, ["--dangerously-skip-permissions" | forwarded])}
    end
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
        {:error,
         "usage: mix kogen.claude.login [--project | --use-default] [-- native arguments]"}
    end
  end

  defp require_project(:shared), do: :ok

  defp require_project(_selection) do
    if File.regular?(".kogen/config.yaml"),
      do: :ok,
      else: {:error, "project scope requires a Kogen-enabled checkout"}
  end

  @doc false
  def require_login(runtime, scope) do
    case login_status(runtime, scope) do
      {:configured, _metadata} ->
        :ok

      :missing ->
        {:error,
         "Selected #{scope.name} Kogen Claude Code login is not configured. Run #{login_command(scope)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp login_command(%{name: :project}), do: "mix kogen.claude.login --project"
  defp login_command(_scope), do: "mix kogen.claude.login"

  @doc """
  Local login state from `claude auth status`, reduced to `loggedIn` and
  `authMethod`. Native output is never printed; it is not an entitlement or
  remaining-quota check.
  """
  def login_status(runtime, scope) do
    if File.dir?(scope.path) do
      case System.cmd(Map.fetch!(runtime, "executable"), ["auth", "status"],
             env: environment(scope),
             stderr_to_stdout: false
           ) do
        {output, _status} -> auth_metadata(output, scope)
      end
    else
      :missing
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp auth_metadata(output, scope) do
    case Jason.decode(String.trim(output)) do
      {:ok, %{"loggedIn" => true} = status} ->
        {:configured, %{logged_in: true, auth_method: to_string(status["authMethod"])}}

      {:ok, %{"loggedIn" => false}} ->
        :missing

      _ ->
        {:error, "Claude Code auth status was unreadable for the #{scope.name} scope"}
    end
  end

  @doc "Pin, installation, effective scope and local login metadata only."
  def status do
    with {:ok, runtime} <- installer("required"),
         {:ok, scope} <- effective_scope() do
      login = if runtime, do: login_status(runtime, scope), else: :unavailable
      {:ok, %{pin: @pinned_version, runtime: runtime, scope: scope, login: login}}
    end
  end

  defp terminal(context, args) do
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
      raise "mix kogen.claude.#{command} is an explicit user operation; managed roles cannot run setup"
    end
  end

  defp test_executable(name) do
    if String.contains?(name, "/"),
      do: Path.expand(name),
      else: System.find_executable(name) || raise("test harness executable not found: #{name}")
  end
end

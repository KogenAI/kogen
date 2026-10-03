defmodule Kogen.Kernel do
  @moduledoc "Coordinates Kogen domains and exposes the command-line entry point."
  use Boundary,
    deps: [
      Kogen.Contracts,
      Kogen.Proc,
      Kogen.Project,
      Kogen.Intent,
      Kogen.Provider,
      Kogen.Engine,
      Kogen.Workspace,
      Kogen.State,
      Kogen.Checks,
      Kogen.Harness,
      Kogen.Shaper
    ],
    exports: [
      Approval,
      CLI,
      Types.ApprovalPreview,
      Types.IntentStatus
    ]

  alias Kogen.Contracts.Intent
  alias Kogen.Contracts.Project
  alias Kogen.Contracts.ProviderError
  alias Kogen.Engine
  alias Kogen.Engine.Build.Request
  alias Kogen.Engine.Build.Result
  alias Kogen.Engine.Runtime
  alias Kogen.Kernel.Approval
  alias Kogen.Kernel.RuntimeDiscovery
  alias Kogen.Kernel.Types.ApprovalPreview
  alias Kogen.Kernel.Types.IntentStatus
  alias Kogen.Kernel.Workspaces
  alias Kogen.Provider.ChatGPT
  alias Kogen.Shaper
  alias Kogen.Shaper.Request, as: ShapeRequest
  alias Kogen.Shaper.Result, as: ShapeResult

  @type toolchain_error ::
          :mise_missing
          | {:toolchain_failed, String.t()}
          | :invalid_toolchain_environment
          | :too_many_script_symlinks
          | {:script_path_unavailable, term()}

  @spec version() :: String.t()
  def version, do: :kogen |> Application.spec(:vsn) |> List.to_string()

  @spec intent_check(Path.t()) :: {:ok, Intent.t()} | {:error, term()}
  def intent_check(path) when is_binary(path) do
    with {:ok, intent} <- Kogen.Intent.parse(path),
         [] <- Kogen.Intent.lint(intent) do
      {:ok, intent}
    else
      {:error, issues} -> {:error, {:parse, issues}}
      issues when is_list(issues) -> {:error, {:lint, issues}}
    end
  end

  @spec intent_check_binary(binary(), Path.t()) ::
          {:ok, Intent.t()} | {:error, term()}
  def intent_check_binary(source, path) when is_binary(source) and is_binary(path) do
    with {:ok, intent} <- Kogen.Intent.parse_binary(source, path),
         [] <- Kogen.Intent.lint(intent) do
      {:ok, intent}
    else
      {:error, issues} -> {:error, {:parse, issues}}
      issues when is_list(issues) -> {:error, {:lint, issues}}
    end
  end

  @spec approval_preview(String.t(), Path.t(), Path.t(), String.t(), String.t()) ::
          {:ok, ApprovalPreview.t()} | {:error, term()}
  def approval_preview(slug, project_root, origin, base, by) do
    with {:ok, runtime} <- runtime(),
         {:ok, process_env} <- project_environment(project_root, runtime) do
      Approval.prepare(slug, project_root, origin, base, by, process_env)
    end
  end

  @spec approve(ApprovalPreview.t()) :: {:ok, String.t()} | {:error, term()}
  def approve(%ApprovalPreview{} = preview), do: Approval.commit(preview)

  @spec build(String.t(), Path.t(), Path.t(), String.t(), String.t(), String.t()) ::
          {:ok, Result.t()} | {:error, term()}
  def build(slug, project_root, origin, base, model, effort) do
    with {:ok, runtime} <- runtime(),
         {:ok, process_env} <- project_environment(project_root, runtime),
         {:ok, provider_config, source} <- provider_config(),
         {:ok, home} <- runtime_home(runtime) do
      runtime = Runtime.for_project(runtime, process_env)

      request = %Request{
        slug: slug,
        home: home,
        project_root: project_root,
        workspace_root: Workspaces.root(project_root, home),
        origin: origin,
        base: base,
        model: model,
        effort: effort,
        runtime: runtime,
        provider_mod: ChatGPT,
        provider_config: provider_config,
        credential_source: source
      }

      Engine.run(request)
    end
  end

  @spec shape(String.t(), Path.t(), String.t(), String.t(), String.t()) ::
          {:ok, ShapeResult.t()} | {:error, term()}
  def shape(slug, project_root, task, model, effort) do
    with {:ok, runtime} <- runtime(),
         {:ok, project} <- Kogen.Project.load(project_root),
         {:ok, process_env} <- Engine.candidate_environment(project_root, runtime, project),
         {:ok, provider_config, _source} <- provider_config() do
      request = %ShapeRequest{
        workdir: project_root,
        slug: slug,
        task: task,
        model: model,
        effort: effort,
        provider_mod: ChatGPT,
        provider_config: provider_config,
        env: process_env,
        git_env: Runtime.git_environment(process_env),
        run_dir: shape_run_dir(process_env, slug)
      }

      Shaper.shape(request)
    end
  end

  @doc false
  @spec build(Request.t()) :: {:ok, Result.t()} | {:error, term()}
  def build(%Request{} = request), do: Engine.run(request)

  @spec status(Path.t(), Path.t(), String.t()) :: {:ok, [IntentStatus.t()]} | {:error, term()}
  def status(project_root, origin, base) do
    with {:ok, runtime} <- runtime(),
         {:ok, process_env} <- project_environment(project_root, runtime),
         {:ok, home} <- runtime_home(runtime) do
      git_env = Runtime.git_environment(process_env)
      root = Workspaces.root(project_root, home)
      Kogen.Kernel.Status.list(project_root, root, origin, base, git_env)
    end
  end

  @spec report(String.t(), Path.t(), Path.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def report(slug, project_root, origin, base) do
    with {:ok, runtime} <- runtime(),
         {:ok, process_env} <- project_environment(project_root, runtime),
         {:ok, home} <- runtime_home(runtime) do
      git_env = Runtime.git_environment(process_env)

      with {:ok, root} <-
             Kogen.Kernel.StateView.preferred_root(
               Workspaces.root(project_root, home),
               legacy_state_root(project_root),
               slug
             ) do
        Kogen.Kernel.Report.read(slug, root, origin, base, git_env)
      end
    end
  end

  @spec reconcile(String.t(), Path.t(), Path.t(), String.t()) ::
          {:ok, :crashed | :landed | :unchanged} | {:error, term()}
  def reconcile(run_id, project_root, origin, base) do
    with {:ok, runtime} <- runtime(),
         {:ok, process_env} <- project_environment(project_root, runtime),
         {:ok, home} <- runtime_home(runtime) do
      git_env = Runtime.git_environment(process_env)

      Kogen.Kernel.Reconcile.run(
        run_id,
        project_root,
        Workspaces.root(project_root, home),
        origin,
        base,
        git_env
      )
    end
  end

  @doc false
  @spec project_environment(Path.t(), Runtime.t()) ::
          {:ok, %{String.t() => String.t()}}
          | {
              :error,
              toolchain_error()
            }
  def project_environment(workdir, %Runtime{} = runtime),
    do: Engine.project_environment(workdir, runtime)

  @doc false
  @spec candidate_environment(Path.t(), Runtime.t(), Project.t()) ::
          {:ok, %{String.t() => String.t()}} | {:error, toolchain_error()}
  def candidate_environment(workdir, %Runtime{} = runtime, %Project{} = project),
    do: Engine.candidate_environment(workdir, runtime, project)

  @doc false
  @spec runtime() :: {:ok, Runtime.t()} | {:error, toolchain_error()}
  def runtime do
    RuntimeDiscovery.runtime()
  end

  @doc false
  @spec provider_config() ::
          {:ok, ChatGPT.Config.t(), :kogen_owned | :codex_borrowed | :custom}
          | {
              :error,
              ProviderError.t()
            }
  def provider_config do
    RuntimeDiscovery.provider_config()
  end

  defp legacy_state_root(project_root), do: Path.join(project_root, ".kogen")

  defp runtime_home(%Runtime{} = runtime) do
    case Runtime.home(runtime) do
      home when is_binary(home) -> {:ok, home}
      nil -> RuntimeDiscovery.home()
    end
  end

  defp shape_run_dir(process_env, slug) do
    run_id =
      "#{System.monotonic_time(:microsecond)}-#{System.unique_integer([:positive, :monotonic])}"

    Path.join([
      Runtime.temporary_directory(process_env),
      "kogen-shaper",
      slug,
      run_id
    ])
  end
end

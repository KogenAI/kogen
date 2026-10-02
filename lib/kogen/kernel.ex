defmodule Kogen.Kernel do
  @moduledoc "Coordinates Kogen domains and exposes the command-line entry point."
  use Boundary,
    deps: [
      Kogen.Contracts,
      Kogen.Proc,
      Kogen.Project,
      Kogen.Intent,
      Kogen.Provider,
      Kogen.Build,
      Kogen.Workspace,
      Kogen.State,
      Kogen.Checks,
      Kogen.Harness
    ],
    exports: [CLI, Types.ApprovalPreview, Types.BuildResult, Types.IntentStatus]

  alias Kogen.Contracts.Intent
  alias Kogen.Contracts.ProviderError
  alias Kogen.Kernel.Approval
  alias Kogen.Kernel.Build.Engine
  alias Kogen.Kernel.Build.Request
  alias Kogen.Kernel.Environment
  alias Kogen.Kernel.Runtime
  alias Kogen.Kernel.RuntimeDiscovery
  alias Kogen.Kernel.Types.ApprovalPreview
  alias Kogen.Kernel.Types.BuildResult
  alias Kogen.Kernel.Types.IntentStatus
  alias Kogen.Provider.ChatGPT

  @type toolchain_error ::
          :mise_missing
          | :toolchain_failed
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
      git_env = Runtime.git_environment(process_env)
      Approval.prepare(slug, project_root, origin, base, by, git_env)
    end
  end

  @spec approve(ApprovalPreview.t()) :: {:ok, String.t()} | {:error, term()}
  def approve(%ApprovalPreview{} = preview), do: Approval.commit(preview)

  @spec build(String.t(), Path.t(), Path.t(), String.t(), String.t(), String.t()) ::
          {:ok, BuildResult.t()} | {:error, term()}
  def build(slug, project_root, origin, base, model, effort) do
    with {:ok, runtime} <- runtime(),
         {:ok, process_env} <- project_environment(project_root, runtime),
         {:ok, provider_config, source} <- provider_config() do
      runtime = Runtime.for_project(runtime, process_env)

      request = %Request{
        slug: slug,
        project_root: project_root,
        origin: origin,
        base: base,
        model: model,
        effort: effort,
        runtime: runtime,
        provider_config: provider_config,
        credential_source: source
      }

      Engine.run(request)
    end
  end

  @spec status(Path.t(), Path.t(), String.t()) :: {:ok, [IntentStatus.t()]} | {:error, term()}
  def status(project_root, origin, base) do
    with {:ok, runtime} <- runtime(),
         {:ok, process_env} <- project_environment(project_root, runtime) do
      git_env = Runtime.git_environment(process_env)
      Kogen.Kernel.Status.list(project_root, origin, base, git_env)
    end
  end

  @spec report(String.t(), Path.t(), Path.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def report(slug, project_root, origin, base) do
    with {:ok, runtime} <- runtime(),
         {:ok, process_env} <- project_environment(project_root, runtime) do
      git_env = Runtime.git_environment(process_env)
      Kogen.Kernel.Report.read(slug, project_root, origin, base, git_env)
    end
  end

  @spec reconcile(String.t(), Path.t(), Path.t(), String.t()) ::
          {:ok, :landed | :unchanged} | {:error, term()}
  def reconcile(run_id, project_root, origin, base) do
    with {:ok, runtime} <- runtime(),
         {:ok, process_env} <- project_environment(project_root, runtime) do
      git_env = Runtime.git_environment(process_env)
      Kogen.Kernel.Reconcile.run(run_id, project_root, origin, base, git_env)
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
    do: Environment.project(workdir, runtime)

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
end

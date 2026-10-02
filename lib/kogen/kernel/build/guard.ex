defmodule Kogen.Kernel.Build.Guard do
  @moduledoc false

  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Intent
  alias Kogen.Contracts.Project

  @spec check(Path.t(), String.t(), Intent.t(), Project.t(), map(), map()) ::
          :ok | {:error, Failure.t()}
  def check(workdir, base_sha, intent, project, manifest, git_env) do
    with :ok <- protected(workdir, base_sha, manifest, git_env) do
      scoped(workdir, base_sha, intent, project, git_env)
    end
  end

  defp protected(workdir, base_sha, manifest, git_env) do
    case Kogen.Checks.protected_violations(workdir, base_sha, manifest, git_env) do
      {:ok, []} ->
        :ok

      {:ok, paths} ->
        failure(:protected_edit, "Protected paths changed: #{Enum.join(paths, ", ")}")

      {:error, reason} ->
        failure(
          :workspace_failed,
          "Cannot inspect protected paths: #{inspect(reason)}",
          :controller
        )
    end
  end

  defp scoped(workdir, base_sha, intent, project, git_env) do
    case Kogen.Checks.scope_violations(
           workdir,
           base_sha,
           intent,
           project,
           allowed_extra(intent),
           git_env
         ) do
      {:ok, []} ->
        :ok

      {:ok, paths} ->
        failure(:scope_edit, "Out-of-scope paths changed: #{Enum.join(paths, ", ")}")

      {:error, reason} ->
        failure(
          :workspace_failed,
          "Cannot inspect changed paths: #{inspect(reason)}",
          :controller
        )
    end
  end

  defp allowed_extra(intent) do
    [
      ".kogen/intents/#{intent.slug}",
      ".kogen/acceptance/#{intent.slug}_test.exs",
      "test/acceptance/#{intent.slug}_test.exs"
    ]
  end

  defp failure(reason, detail, class \\ :candidate),
    do: {:error, %Failure{class: class, reason: reason, detail: detail}}
end

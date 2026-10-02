defmodule Kogen.Kernel.Approval do
  @moduledoc false

  alias Kogen.Contracts.Intent, as: IntentData
  alias Kogen.Contracts.Project, as: ProjectData
  alias Kogen.Intent
  alias Kogen.Kernel.Types.ApprovalPreview
  alias Kogen.Project
  alias Kogen.State
  alias Kogen.State.Approval, as: ApprovalRecord
  alias Kogen.Workspace

  @spec prepare(String.t(), Path.t(), Path.t(), String.t(), String.t(), map()) ::
          {:ok, ApprovalPreview.t()} | {:error, term()}
  def prepare(slug, project_root, origin, base, by, git_env) do
    with :ok <- valid_request(slug, project_root, origin, base, by),
         {:ok, project} <- Project.load(project_root),
         {:ok, bytes} <- read_intent(project_root, slug),
         {:ok, intent} <- Intent.parse_binary(bytes, intent_path(slug)),
         :ok <- clean_intent(intent),
         {:ok, acceptance_files} <- acceptance_files(project_root, slug),
         {:ok, base_sha} <- Workspace.ref_read(origin, "refs/heads/#{base}", git_env),
         {:ok, protected_manifest} <-
           protected_manifest(project_root, project, slug, bytes, acceptance_files) do
      approval = %ApprovalRecord{
        slug: slug,
        intent_bytes: bytes,
        intent_sha256: Intent.hash(bytes),
        target_branch: base,
        base_sha: base_sha,
        domains: intent.domains,
        acceptance_files: acceptance_files,
        protected_manifest: protected_manifest,
        by: by,
        at: DateTime.utc_now()
      }

      {:ok,
       %ApprovalPreview{
         approval: approval,
         intent: intent,
         project_root: project_root,
         origin: origin,
         git_env: git_env
       }}
    end
  end

  @spec commit(ApprovalPreview.t()) :: {:ok, String.t()} | {:error, term()}
  def commit(%ApprovalPreview{} = preview) do
    State.approve(preview.origin, preview.approval, preview.git_env)
  end

  defp valid_request(slug, project_root, origin, base, by) do
    if valid_slug?(slug) and absolute_directory?(project_root) and absolute_directory?(origin) and
         valid_branch?(base) and is_binary(by) and String.trim(by) != "" and
         not String.contains?(by, ["\n", "\r"]) do
      :ok
    else
      {:error, :invalid_approval_request}
    end
  end

  defp clean_intent(%IntentData{} = intent) do
    case Intent.lint(intent) do
      [] -> :ok
      issues -> {:error, {:lint, issues}}
    end
  end

  defp read_intent(project_root, slug) do
    case File.read(Path.join(project_root, intent_path(slug))) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:intent_unavailable, reason}}
    end
  end

  defp acceptance_files(project_root, slug) do
    relative = acceptance_source_path(slug)

    case File.read(Path.join(project_root, relative)) do
      {:ok, bytes} -> {:ok, %{relative => bytes}}
      {:error, reason} -> {:error, {:acceptance_unavailable, reason}}
    end
  end

  defp protected_manifest(project_root, %ProjectData{} = project, slug, intent_bytes, files) do
    protected_paths = Enum.flat_map(project.protected_paths, &expand_glob(project_root, &1))

    approved_files = [
      {intent_path(slug), intent_bytes},
      {acceptance_source_path(slug), Map.fetch!(files, acceptance_source_path(slug))},
      {candidate_acceptance_path(slug), Map.fetch!(files, acceptance_source_path(slug))}
    ]

    with {:ok, manifest} <- hash_paths(project_root, protected_paths) do
      add_approved_files(manifest, approved_files)
    end
  end

  defp expand_glob(root, pattern) do
    root
    |> Path.join(pattern)
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, root))
  end

  defp hash_paths(root, paths) do
    paths
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, manifest} ->
      case File.read(Path.join(root, path)) do
        {:ok, bytes} -> {:cont, {:ok, Map.put(manifest, path, sha256(bytes))}}
        {:error, reason} -> {:halt, {:error, {:protected_file_unavailable, path, reason}}}
      end
    end)
  end

  defp add_approved_files(manifest, files) do
    {:ok,
     Enum.reduce(files, manifest, fn {path, bytes}, current ->
       Map.put(current, path, sha256(bytes))
     end)}
  end

  defp valid_slug?(slug),
    do: is_binary(slug) and Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug)

  defp valid_branch?(branch) when is_binary(branch) do
    branch != "" and not String.starts_with?(branch, "/") and
      not Enum.any?(String.split(branch, "/"), &(&1 in ["", ".", "..", ".lock"])) and
      Regex.match?(~r{\A[A-Za-z0-9._/-]+\z}, branch)
  end

  defp valid_branch?(_branch), do: false

  defp absolute_directory?(path),
    do: is_binary(path) and Path.type(path) == :absolute and File.dir?(path)

  defp intent_path(slug), do: ".kogen/intents/#{slug}/intent.md"
  defp acceptance_source_path(slug), do: ".kogen/acceptance/#{slug}_test.exs"
  defp candidate_acceptance_path(slug), do: "test/acceptance/#{slug}_test.exs"
  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end

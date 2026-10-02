defmodule Kogen.State.ApprovalStore do
  @moduledoc false

  alias Kogen.State.Approval
  alias Kogen.State.Serialization

  @approval_ref_prefix "refs/kogen/intents/"
  @approval_json "approval.json"

  @spec approve(term(), Approval.t(), map(), module()) :: {:ok, String.t()} | {:error, term()}
  def approve(repo, %Approval{} = approval, git_env, workspace) when is_map(git_env) do
    with :ok <- validate(approval),
         {:ok, files} <- package_files(approval),
         {:ok, parent} <- existing_parent(repo, approval.slug, git_env, workspace),
         {:ok, sha} <- commit_package(repo, files, parent, approval, git_env, workspace),
         :ok <- move_approval_ref(repo, approval.slug, sha, parent, git_env, workspace) do
      {:ok, sha}
    end
  end

  @spec read(term(), String.t(), map(), module()) :: {:ok, Approval.t()} | {:error, term()}
  def read(repo, slug, git_env, workspace) when is_binary(slug) and is_map(git_env) do
    ref = @approval_ref_prefix <> slug

    with true <- valid_slug?(slug),
         {:ok, sha} <- workspace_call(workspace, :ref_read, [repo, ref, git_env]),
         {:ok, record_bytes} <-
           workspace_call(workspace, :read_file_at, [repo, sha, approval_path(slug), git_env]),
         {:ok, json} <- Serialization.decode(record_bytes),
         {:ok, approval} <- reconstruct(repo, sha, slug, json, git_env, workspace) do
      {:ok, approval}
    else
      false -> {:error, :invalid_slug}
      {:error, :missing} -> {:error, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validate(Approval.t()) :: :ok | {:error, atom()}
  def validate(%Approval{} = approval) do
    with :ok <- validate_intent(approval),
         :ok <- validate_fields(approval),
         :ok <- validate_acceptance_files(approval) do
      validate_manifest(approval.protected_manifest)
    end
  end

  defp validate_intent(%Approval{intent_bytes: bytes} = approval) when is_binary(bytes) do
    hash = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
    require_valid(hash == approval.intent_sha256, :intent_hash_mismatch)
  end

  defp validate_intent(_approval), do: {:error, :invalid_intent_bytes}

  defp validate_fields(approval) do
    with :ok <- require_valid(valid_slug?(approval.slug), :invalid_slug),
         :ok <- require_valid(valid_single_line?(approval.target_branch), :invalid_target_branch),
         :ok <- require_valid(valid_single_line?(approval.base_sha), :invalid_base_sha),
         :ok <- validate_domains(approval.domains),
         :ok <- require_valid(valid_single_line?(approval.by), :invalid_approver) do
      require_valid(match?(%DateTime{}, approval.at), :invalid_approval_time)
    end
  end

  defp validate_domains(domains) when is_list(domains) do
    require_valid(Enum.all?(domains, &valid_single_line?/1), :invalid_domains)
  end

  defp validate_domains(_domains), do: {:error, :invalid_domains}

  defp validate_acceptance_files(%Approval{} = approval) do
    reserved = [intent_path(approval.slug), approval_path(approval.slug)]

    if is_map(approval.acceptance_files) and valid_files?(approval.acceptance_files, reserved),
      do: :ok,
      else: {:error, :invalid_acceptance_path}
  end

  defp validate_manifest(manifest) when is_map(manifest) do
    if valid_manifest?(manifest), do: :ok, else: {:error, :invalid_protected_manifest}
  end

  defp validate_manifest(_manifest), do: {:error, :invalid_protected_manifest}

  defp require_valid(true, _reason), do: :ok
  defp require_valid(false, reason), do: {:error, reason}

  defp package_files(approval) do
    metadata = %{
      schema: 1,
      slug: approval.slug,
      intent_sha256: approval.intent_sha256,
      target_branch: approval.target_branch,
      base_sha: approval.base_sha,
      domains: approval.domains,
      acceptance_paths: approval.acceptance_files |> Map.keys() |> Enum.sort(),
      protected_manifest: approval.protected_manifest,
      by: approval.by,
      at: DateTime.to_iso8601(approval.at)
    }

    with {:ok, encoded} <- Serialization.encode(metadata) do
      files =
        approval.acceptance_files
        |> Map.put(intent_path(approval.slug), approval.intent_bytes)
        |> Map.put(approval_path(approval.slug), encoded)

      {:ok, files}
    end
  end

  defp existing_parent(repo, slug, git_env, workspace) do
    case workspace_call(workspace, :ref_read, [repo, @approval_ref_prefix <> slug, git_env]) do
      {:ok, sha} -> {:ok, [sha]}
      {:error, :missing} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit_package(repo, files, parents, approval, git_env, workspace) do
    message = approval_message(approval)

    workspace_call(workspace, :commit_tree_with_files, [
      repo,
      files,
      parents,
      message,
      git_env
    ])
  end

  defp move_approval_ref(repo, slug, sha, [], git_env, workspace) do
    workspace_call(workspace, :ref_create, [repo, @approval_ref_prefix <> slug, sha, git_env])
  end

  defp move_approval_ref(repo, slug, sha, [old], git_env, workspace) do
    workspace_call(workspace, :ref_update, [repo, @approval_ref_prefix <> slug, sha, old, git_env])
  end

  defp reconstruct(repo, sha, slug, json, git_env, workspace) do
    with {:ok, metadata} <- metadata_from_json(json, slug),
         {:ok, intent_bytes} <- read_file(repo, sha, intent_path(slug), git_env, workspace),
         {:ok, acceptance_files} <-
           read_acceptance_files(repo, sha, metadata.acceptance_paths, git_env, workspace),
         {:ok, message} <- workspace_call(workspace, :commit_message, [repo, sha, git_env]),
         :ok <- verify_trailers(message, metadata),
         approval = %Approval{
           slug: slug,
           intent_bytes: intent_bytes,
           intent_sha256: metadata.intent_sha256,
           target_branch: metadata.target_branch,
           base_sha: metadata.base_sha,
           domains: metadata.domains,
           acceptance_files: acceptance_files,
           protected_manifest: metadata.protected_manifest,
           by: metadata.by,
           at: metadata.at
         },
         :ok <- validate(approval) do
      {:ok, approval}
    end
  end

  defp metadata_from_json(json, slug) do
    with 1 <- Map.get(json, "schema"),
         ^slug <- Map.get(json, "slug"),
         hash when is_binary(hash) <- Map.get(json, "intent_sha256"),
         branch when is_binary(branch) <- Map.get(json, "target_branch"),
         base when is_binary(base) <- Map.get(json, "base_sha"),
         domains when is_list(domains) <- Map.get(json, "domains"),
         paths when is_list(paths) <- Map.get(json, "acceptance_paths"),
         manifest when is_map(manifest) <- Map.get(json, "protected_manifest"),
         by when is_binary(by) <- Map.get(json, "by"),
         at_text when is_binary(at_text) <- Map.get(json, "at"),
         {:ok, at, _offset} <- DateTime.from_iso8601(at_text),
         true <- Enum.all?(domains, &is_binary/1),
         true <- Enum.all?(paths, &is_binary/1),
         true <- Enum.all?(paths, &safe_repo_path?/1),
         true <- Enum.all?(paths, &(&1 not in [intent_path(slug), approval_path(slug)])),
         true <-
           Enum.all?(manifest, fn {path, digest} -> is_binary(path) and is_binary(digest) end) do
      {:ok,
       %{
         slug: slug,
         intent_sha256: hash,
         target_branch: branch,
         base_sha: base,
         domains: domains,
         acceptance_paths: paths,
         protected_manifest: manifest,
         by: by,
         at: at
       }}
    else
      _invalid -> {:error, :invalid_approval}
    end
  end

  defp read_file(repo, sha, path, git_env, workspace) do
    workspace_call(workspace, :read_file_at, [repo, sha, path, git_env])
  end

  defp read_acceptance_files(repo, sha, paths, git_env, workspace) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, files} ->
      case read_file(repo, sha, path, git_env, workspace) do
        {:ok, bytes} -> {:cont, {:ok, Map.put(files, path, bytes)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp verify_trailers(message, metadata) do
    trailers = trailers(message)

    expected = %{
      "Kogen-Approval" => metadata.slug,
      "Kogen-Approved-By" => metadata.by,
      "Kogen-Approved-Hash" => metadata.intent_sha256,
      "Kogen-Approved-At" => DateTime.to_iso8601(metadata.at)
    }

    if Enum.all?(expected, fn {key, value} -> Map.get(trailers, key) == value end),
      do: :ok,
      else: {:error, :approval_trailer_mismatch}
  end

  defp trailers(message) do
    message
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, result ->
      case String.split(line, ": ", parts: 2) do
        [key, value] -> Map.put(result, key, value)
        _other -> result
      end
    end)
  end

  defp approval_message(approval) do
    "Kogen immutable approval package\n\n" <>
      "Kogen-Approval: #{approval.slug}\n" <>
      "Kogen-Approved-By: #{approval.by}\n" <>
      "Kogen-Approved-Hash: #{approval.intent_sha256}\n" <>
      "Kogen-Approved-At: #{DateTime.to_iso8601(approval.at)}"
  end

  defp valid_files?(files, reserved) do
    Enum.all?(files, fn {path, bytes} ->
      safe_repo_path?(path) and is_binary(bytes) and path not in reserved
    end)
  end

  defp valid_manifest?(manifest) do
    Enum.all?(manifest, fn {path, digest} ->
      safe_repo_path?(path) and is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)
    end)
  end

  defp safe_repo_path?(path) when is_binary(path) do
    parts = String.split(path, "/")

    Path.type(path) == :relative and path != "" and
      Enum.all?(parts, &(&1 not in ["", ".", "..", ".git"]))
  end

  defp safe_repo_path?(_path), do: false

  defp valid_single_line?(value) when is_binary(value) do
    value != "" and not String.contains?(value, ["\n", "\r"])
  end

  defp valid_single_line?(_value), do: false

  defp valid_slug?(slug) do
    is_binary(slug) and Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug)
  end

  defp intent_path(slug), do: ".kogen/intents/#{slug}/intent.md"
  defp approval_path(slug), do: ".kogen/intents/#{slug}/#{@approval_json}"

  defp workspace_call(workspace, function, arguments), do: apply(workspace, function, arguments)
end

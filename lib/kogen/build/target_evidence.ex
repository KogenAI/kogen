defmodule Kogen.Build.TargetEvidence do
  @moduledoc false

  @prefix "KOGEN_TARGET_EVIDENCE_MANIFEST\t"
  @digest ~r/^[0-9a-f]{64}$/

  @spec capture(binary(), String.t(), String.t(), Path.t()) ::
          {:ok, nil | map()} | {:error, String.t()}
  def capture(output, target, attempt_token, root \\ ".")
      when is_binary(output) and is_binary(target) and is_binary(attempt_token) do
    case frames(output) do
      [] ->
        {:ok, nil}

      [encoded] ->
        with {:ok, locator} <- decode_object(encoded, "target evidence frame"),
             :ok <- exact_keys(locator, ~w(manifest_path sha256), "target evidence frame"),
             {:ok, manifest_path} <- safe_path(locator["manifest_path"], root),
             :ok <- digest(locator["sha256"], "manifest"),
             {:ok, manifest_bytes} <- read_regular(manifest_path, root),
             :ok <- matches_digest(manifest_bytes, locator["sha256"], "manifest"),
             {:ok, manifest} <- decode_object(manifest_bytes, "target evidence manifest"),
             :ok <-
               exact_keys(
                 manifest,
                 ~w(required_evidence schema_version),
                 "target evidence manifest"
               ),
             :ok <- schema_version(manifest["schema_version"]),
             {:ok, entries} <- entries(manifest["required_evidence"], root) do
          {:ok,
           %{
             "target" => target,
             "attempt_token" => attempt_token,
             "manifest" => snapshot(locator["manifest_path"], manifest_bytes),
             "required_evidence" => entries
           }}
        end

      _many ->
        {:error, "target emitted duplicate evidence manifest frames"}
    end
  end

  @spec verify(map(), Path.t()) :: :ok | {:error, String.t()}
  def verify(snapshot, root \\ ".")

  def verify(snapshot, root) when is_map(snapshot) do
    with true <- is_binary(snapshot["target"]) and snapshot["target"] != "",
         true <- is_binary(snapshot["attempt_token"]) and snapshot["attempt_token"] != "",
         :ok <- verify_snapshot(snapshot["manifest"], root),
         entries when is_list(entries) and entries != [] <- snapshot["required_evidence"],
         :ok <- verify_snapshots(entries, root) do
      :ok
    else
      false -> {:error, "retained target evidence has invalid provenance"}
      _ -> {:error, "retained target evidence has invalid schema or bytes"}
    end
  end

  def verify(_snapshot, _root), do: {:error, "retained target evidence must be an object"}

  defp frames(output) do
    lines = :binary.split(output, "\n", [:global])
    complete_lines = if String.ends_with?(output, "\n"), do: lines, else: Enum.drop(lines, -1)

    complete_lines
    |> Enum.flat_map(&Regex.scan(~r/#{@prefix}([^\r]*)/, &1, capture: :all_but_first))
    |> Enum.map(&hd/1)
  end

  defp decode_object(bytes, label) do
    case Jason.decode(bytes) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, "#{label} must contain one valid JSON object"}
    end
  end

  defp exact_keys(value, expected, label) do
    if Enum.sort(Map.keys(value)) == Enum.sort(expected),
      do: :ok,
      else: {:error, "#{label} must contain exactly #{Enum.join(expected, ", ")}"}
  end

  defp schema_version(1), do: :ok
  defp schema_version(_), do: {:error, "target evidence manifest has unsupported schema_version"}

  defp entries(entries, root) when is_list(entries) and entries != [] do
    Enum.reduce_while(entries, {:ok, {MapSet.new(), []}}, fn entry, {:ok, {seen, acc}} ->
      with true <- is_map(entry),
           :ok <- exact_keys(entry, ~w(path sha256), "required evidence entry"),
           {:ok, path} <- safe_path(entry["path"], root),
           false <- MapSet.member?(seen, entry["path"]),
           :ok <- digest(entry["sha256"], "required evidence"),
           {:ok, bytes} <- read_regular(path, root),
           :ok <- matches_digest(bytes, entry["sha256"], "required evidence #{entry["path"]}") do
        {:cont, {:ok, {MapSet.put(seen, entry["path"]), acc ++ [snapshot(entry["path"], bytes)]}}}
      else
        false -> {:halt, {:error, "target evidence manifest contains a duplicate path"}}
        {:error, _reason} = error -> {:halt, error}
        _ -> {:halt, {:error, "required evidence entry must be an object"}}
      end
    end)
    |> case do
      {:ok, {_seen, snapshots}} -> {:ok, snapshots}
      error -> error
    end
  end

  defp entries(_, _root),
    do: {:error, "target evidence manifest requires a nonempty required_evidence list"}

  defp safe_path(path, root) when is_binary(path) and path != "" do
    segments = String.split(path, "/", trim: false)

    if Path.type(path) == :relative and not String.contains?(path, [<<0>>, "\\"]) and
         Enum.all?(segments, &(&1 not in ["", ".", ".."])) do
      expanded_root = Path.expand(root)
      expanded = Path.expand(path, expanded_root)

      if String.starts_with?(expanded, expanded_root <> "/") and
           no_symlink_components?(expanded_root, segments),
         do: {:ok, expanded},
         else: {:error, "unsafe target evidence path: #{inspect(path)}"}
    else
      {:error, "unsafe target evidence path: #{inspect(path)}"}
    end
  end

  defp safe_path(path, _root), do: {:error, "unsafe target evidence path: #{inspect(path)}"}

  defp no_symlink_components?(root, segments) do
    segments
    |> Enum.scan(root, &Path.join(&2, &1))
    |> Enum.all?(fn path ->
      case File.lstat(path) do
        {:ok, %{type: :symlink}} -> false
        _ -> true
      end
    end)
  end

  defp read_regular(path, root) do
    with {:ok, %{type: :regular}} <- File.stat(path),
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    else
      _ ->
        {:error,
         "target evidence path is missing or not a regular file: #{Path.relative_to(path, Path.expand(root))}"}
    end
  end

  defp digest(value, _label) when is_binary(value) do
    if Regex.match?(@digest, value),
      do: :ok,
      else: {:error, "target evidence digest must be lowercase SHA-256"}
  end

  defp digest(_value, _label), do: {:error, "target evidence digest must be lowercase SHA-256"}

  defp matches_digest(bytes, expected, label) do
    if sha256(bytes) == expected,
      do: :ok,
      else: {:error, "#{label} digest mismatch"}
  end

  defp snapshot(path, bytes) do
    %{"path" => path, "sha256" => sha256(bytes), "content_base64" => Base.encode64(bytes)}
  end

  defp verify_snapshots(snapshots, root) do
    Enum.reduce_while(snapshots, :ok, fn item, :ok ->
      case verify_snapshot(item, root) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp verify_snapshot(snapshot, root) when is_map(snapshot) do
    with :ok <-
           exact_keys(
             snapshot,
             ~w(content_base64 path sha256),
             "retained target evidence snapshot"
           ),
         {:ok, path} <- safe_path(snapshot["path"], root),
         :ok <- digest(snapshot["sha256"], "retained target evidence"),
         {:ok, decoded} <- decode64(snapshot["content_base64"]),
         :ok <- matches_digest(decoded, snapshot["sha256"], "retained target evidence"),
         {:ok, source} <- read_regular(path, root) do
      matches_digest(source, snapshot["sha256"], "bound target evidence source")
    end
  end

  defp verify_snapshot(_, _root),
    do: {:error, "retained target evidence snapshot must be an object"}

  defp decode64(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, "retained target evidence has invalid base64 bytes"}
    end
  end

  defp decode64(_), do: {:error, "retained target evidence has invalid base64 bytes"}

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end

defmodule Kogen.Build.Evidence do
  @moduledoc """
  Resolves compact Complete evidence to its exact bound local tracking record.

  Compact results remain readable without this operation. Full inspection is
  deliberately strict: it never searches for a substitute record.
  """
  use Boundary, deps: []

  @spec resolve(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def resolve(summary_path, checkout_root \\ File.cwd!()) do
    with {:ok, bytes} <- File.read(summary_path),
         {:ok, summary} <- Jason.decode(bytes),
         :ok <- supported_summary(summary),
         {:ok, full} <- fetch_map(summary, "full_record"),
         :ok <- supported_record_binding(full),
         {:ok, record_path} <- resolve_path(full["path"], checkout_root),
         {:ok, record_bytes} <- File.read(record_path),
         :ok <- exact_bytes(full, record_bytes),
         {:ok, record} <- Jason.decode(record_bytes),
         :ok <- matching_record_version(full, record),
         :ok <- matching_identity(summary, record, record_path),
         :ok <- matching_route(summary, record) do
      {:ok, record}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, "malformed evidence JSON: #{Exception.message(error)}"}

      {:error, reason} when is_atom(reason) ->
        {:error, "bound full evidence unavailable: #{:file.format_error(reason)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp supported_summary(%{"format" => "kogen-build-summary", "schema_version" => 1}), do: :ok
  defp supported_summary(_), do: {:error, "unsupported Build summary format or version"}

  defp supported_record_binding(%{
         "format" => "kogen-scenario-tracking-record",
         "schema_version" => 1
       }),
       do: :ok

  defp supported_record_binding(_), do: {:error, "unsupported bound tracking format or version"}

  defp fetch_map(map, key) do
    case Map.get(map, key) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, "Build summary lacks #{key}"}
    end
  end

  defp resolve_path(path, root) when is_binary(path) and path != "" do
    expanded =
      if Path.type(path) == :absolute, do: Path.expand(path), else: Path.expand(path, root)

    {:ok, expanded}
  end

  defp resolve_path(_path, _root),
    do: {:error, "Build summary has an invalid full-record locator"}

  defp exact_bytes(full, bytes) do
    digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    cond do
      full["byte_count"] != byte_size(bytes) ->
        {:error, "bound full evidence byte count mismatch"}

      full["sha256"] != digest ->
        {:error, "bound full evidence SHA-256 mismatch"}

      true ->
        :ok
    end
  end

  defp matching_identity(summary, record, record_path) do
    summary_id = get_in(summary, ["intent", "id"])
    record_id = get_in(record, ["intent", "id"])
    accepted = record["attempts"] |> List.last()
    summary_attempts = summary["attempts"]

    cond do
      not (is_binary(summary_id) and summary_id == record_id) ->
        {:error, "bound full evidence Intent identity mismatch"}

      summary["build_id"] != Path.basename(Path.dirname(record_path)) ->
        {:error, "bound full evidence Build identity mismatch"}

      summary["candidate_id"] != accepted["candidate_id"] ->
        {:error, "bound full evidence accepted Candidate mismatch"}

      summary["developer_session_id"] != accepted["developer_session_id"] ->
        {:error, "bound full evidence Developer session mismatch"}

      not is_list(summary_attempts) or
          Enum.map(summary_attempts, &attempt_identity/1) !=
            Enum.map(record["attempts"], &attempt_identity/1) ->
        {:error, "bound full evidence attempt identity mismatch"}

      true ->
        :ok
    end
  end

  # Summaries written before routes existed carry no route and stay readable.
  defp matching_route(%{"route" => route}, record) do
    if Map.take(record["route"] || %{}, ["name", "harness"]) == route,
      do: :ok,
      else: {:error, "bound full evidence route mismatch"}
  end

  defp matching_route(_summary, _record), do: :ok

  defp attempt_identity(attempt) do
    %{
      "number" => attempt["number"],
      "attempt_token" => attempt["attempt_token"],
      "status" => attempt["status"],
      "developer_session_id" => attempt["developer_session_id"],
      "reviewer_session_id" => attempt["reviewer_session_id"] || attempt["reviewer_session"],
      "candidate_id" => attempt["candidate_id"]
    }
  end

  defp matching_record_version(full, record) do
    if record["schema_version"] == full["schema_version"],
      do: :ok,
      else: {:error, "bound full evidence schema version mismatch"}
  end
end

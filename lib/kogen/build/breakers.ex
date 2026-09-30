# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule Kogen.Build.Breakers do
  @moduledoc """
  Admission breakers backed by the durable failure reports.

  This module deliberately has no Build state.  Reports and environment clear
  files on the control checkout are the source of truth, so removing a report
  or changing the Approved package takes effect at the next admission.
  """

  @runtime_glob ".kogen/runtime/scenario-tracking/*/failure-report.json"
  @clear_glob ".kogen/runtime/scenario-tracking/*/environment-clear.json"
  @agreement_files ~w(INTENT.md IMPLEMENTATION.md scenarios.yaml risks.yaml questions.md questions.yaml)

  @doc "Stable item-breaker identity across approval bookkeeping and package moves."
  def contract_digest(package, intent_id) when is_binary(package) and is_binary(intent_id) do
    intent =
      case YamlElixir.read_from_file(Path.join(package, "intent.yaml")) do
        {:ok, data} when is_map(data) ->
          Map.drop(data, ~w(status approval shaping_continuations build_failure))

        _ ->
          %{}
      end

    files =
      for name <- @agreement_files,
          File.regular?(Path.join(package, name)),
          do: {name, File.read!(Path.join(package, name))}

    :crypto.hash(:sha256, :erlang.term_to_binary({intent_id, intent, files}))
    |> Base.encode16(case: :lower)
  end

  @doc "Returns decoded failure reports, with their absolute paths, in run order."
  @spec reports(Path.t()) :: [%{path: Path.t(), report: map()}]
  def reports(control) when is_binary(control) do
    control = Path.expand(control)

    Path.wildcard(Path.join(control, @runtime_glob))
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, bytes} ->
          case Jason.decode(bytes) do
            {:ok, report} when is_map(report) -> [%{path: Path.expand(path), report: report}]
            _ -> []
          end

        _ ->
          []
      end
    end)
    |> Enum.sort_by(&report_sort_key/1)
  end

  def reports(_control), do: []

  @doc "Returns the latest matching non-stop item report, if any."
  @spec latest_item_report(Path.t(), String.t(), String.t()) ::
          nil | %{path: Path.t(), report: map()}
  def latest_item_report(control, intent_id, package_digest)
      when is_binary(control) and is_binary(intent_id) and is_binary(package_digest) do
    reports(control)
    |> Enum.filter(fn %{report: report} ->
      report["counts_toward"] == "item" and
        report["intent_id"] == intent_id and
        (report["contract_digest"] || report["approved_package_digest"]) == package_digest and
        get_in(report, ["signature", "source"]) != "stop"
    end)
    |> List.last()
  end

  def latest_item_report(_control, _intent_id, _package_digest), do: nil

  @doc "Computes the cross-Intent trailing environment run and whether it is tripped."
  @spec environment_state(Path.t()) :: %{
          run: [%{path: Path.t(), report: map()}],
          tripped: boolean()
        }
  def environment_state(control) when is_binary(control) do
    entries = reports(control)
    cleared_at = latest_cleared_at(control)

    run =
      entries
      |> Enum.filter(&after_clear?(&1, cleared_at))
      |> Enum.reduce([], fn entry, run ->
        case get_in(entry, [:report, "counts_toward"]) do
          "environment" -> run ++ [entry]
          "item" -> []
          _ -> run
        end
      end)

    %{run: run, tripped: length(run) >= 3}
  end

  def environment_state(_control), do: %{run: [], tripped: false}

  @doc "Formats the exact refusal emitted after a failed readiness probe."
  @spec readiness_refusal_message([map()], term()) :: String.t()
  def readiness_refusal_message(run, readiness_error) when is_list(run) do
    reports =
      run
      |> Enum.map_join(", ", fn %{path: path, report: report} ->
        case report["next_command"] do
          command when is_binary(command) and command != "" -> "#{path} (#{command})"
          _ -> path
        end
      end)

    "Build refused (environment breaker): #{length(run)} environment stops in a row; readiness: #{readiness_error}; failure reports: #{reports}"
  end

  @doc "Writes one exclusive environment clear file beside a tracking record."
  @spec write_clear(Path.t(), String.t(), [map()]) :: :ok | {:error, String.t()}
  def write_clear(tracking_path, reason, run)
      when is_binary(tracking_path) and is_binary(reason) and is_list(run) do
    if run == [] do
      :ok
    else
      directory = tracking_directory(tracking_path)

      path = Path.join(directory, "environment-clear.json")

      with :ok <- File.mkdir_p(directory) do
        write_clear_exclusive(path, clear_payload(reason, run))
      end
    end
  end

  def write_clear(_tracking_path, _reason, _run), do: {:error, "invalid environment clear inputs"}

  @doc "Returns the clear-file path for a tracking record path or directory."
  def clear_path(tracking_path) when is_binary(tracking_path) do
    Path.join(tracking_directory(tracking_path), "environment-clear.json")
  end

  defp tracking_directory(path) do
    path = Path.expand(path)
    if Path.basename(path) == "record.json", do: Path.dirname(path), else: path
  end

  defp report_sort_key(%{report: report}) do
    {timestamp_key(report["stopped_at"]), report["build_id"] || ""}
  end

  defp timestamp_key(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :microsecond)
      _ -> -1
    end
  end

  defp timestamp_key(_), do: -1

  defp latest_cleared_at(control) do
    control
    |> Path.expand()
    |> Path.join(@clear_glob)
    |> Path.wildcard()
    |> Enum.reduce(nil, fn path, latest ->
      with {:ok, bytes} <- File.read(path),
           {:ok, clear} <- Jason.decode(bytes),
           {:ok, value, _offset} <- DateTime.from_iso8601(clear["cleared_at"] || "") do
        if is_nil(latest) or DateTime.compare(value, latest) == :gt, do: value, else: latest
      else
        _ -> latest
      end
    end)
  end

  defp after_clear?(_entry, nil), do: true

  defp after_clear?(%{report: report}, cleared_at) do
    case DateTime.from_iso8601(report["stopped_at"] || "") do
      {:ok, stopped_at, _offset} -> DateTime.compare(stopped_at, cleared_at) == :gt
      _ -> false
    end
  end

  defp clear_payload(reason, run) do
    %{
      "schema_version" => 1,
      "cleared_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "reason" => reason,
      "reports" => Enum.map(run, & &1.path)
    }
  end

  defp write_clear_exclusive(path, payload) do
    bytes = Jason.encode_to_iodata!(payload, pretty: true)

    temporary =
      Path.join(
        Path.dirname(path),
        ".environment-clear-#{System.unique_integer([:positive])}.tmp"
      )

    with {:ok, io} <- File.open(temporary, [:write, :binary, :exclusive]),
         :ok <- IO.binwrite(io, bytes),
         :ok <- :file.sync(io),
         :ok <- File.close(io) do
      case :file.make_link(String.to_charlist(temporary), String.to_charlist(path)) do
        :ok ->
          File.rm(temporary)
          :ok

        {:error, :eexist} ->
          File.rm(temporary)
          :ok

        {:error, reason} ->
          File.rm(temporary)
          {:error, "could not write environment clear #{path}: #{inspect(reason)}"}
      end
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, "could not write environment clear #{path}: #{inspect(reason)}"}
    end
  end
end

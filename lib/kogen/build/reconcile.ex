defmodule Kogen.Build.Reconcile do
  # credo:disable-for-this-file Credo.Check.Refactor.Nesting
  @moduledoc "Reconciles owner records left running by a dead Build controller."

  alias Kogen.Build.{FailureReport, Workspace}

  @runtime ".kogen/runtime/scenario-tracking"

  @doc "Reports dead running owners and repairs their effective status."
  def run(control) when is_binary(control) do
    control = Path.expand(control)

    Workspace.list(control)
    |> Enum.reduce_while(:ok, fn
      {:ok, listed}, :ok ->
        reconcile_owner(control, listed)

      _entry, :ok ->
        {:cont, :ok}
    end)
  end

  defp reconcile_owner(control, listed) do
    build_id = listed["build_id"]
    owner_path = Workspace.owner_path(control, build_id)

    with {:ok, owner_bytes} <- File.read(owner_path),
         {:ok, owner} <- Jason.decode(owner_bytes),
         true <- owner["status"] == "running",
         {:ok, record_path, record_bytes, record} <- tracking_record(control, build_id) do
      tracking_build_id = owner["tracking_build_id"] || build_id
      report_path = FailureReport.report_path(control, tracking_build_id)

      if File.exists?(report_path) do
        with {:ok, report} <- report_file(report_path),
             :ok <-
               Workspace.set_owner_status(control, build_id, "stopped: #{report["category"]}") do
          {:cont, :ok}
        else
          _ -> {:cont, :ok}
        end
      else
        category =
          if record["status"] == "accepted", do: "publication-interrupted", else: "interrupted"

        reason =
          "#{category}: Build controller exited without a stop (record status: #{record["status"]})"

        published =
          if category == "publication-interrupted",
            do: not is_nil(Workspace.published_tip(control, owner)),
            else: nil

        case FailureReport.record_interrupted(
               control,
               owner,
               record_path,
               record_bytes,
               record,
               category,
               reason,
               published
             ) do
          {:ok, _path} ->
            Workspace.set_owner_status(control, build_id, "stopped: #{category}")
            {:cont, :ok}

          {:error, _reason} ->
            {:cont, :ok}
        end
      end
    else
      _ -> {:cont, :ok}
    end
  end

  defp tracking_record(control, build_id) do
    tracking_id =
      case File.read(Workspace.owner_path(control, build_id)) do
        {:ok, bytes} ->
          case Jason.decode(bytes) do
            {:ok, %{"tracking_build_id" => id}} when is_binary(id) -> id
            _ -> build_id
          end

        _ ->
          build_id
      end

    path = Path.join([control, @runtime, tracking_id, "record.json"])

    with {:ok, bytes} <- File.read(path),
         {:ok, record} <- Jason.decode(bytes) do
      {:ok, path, bytes, record}
    else
      _ -> :missing
    end
  end

  defp report_file(path) do
    case File.read(path) do
      {:ok, bytes} -> Jason.decode(bytes)
      {:error, reason} -> {:error, reason}
    end
  end
end

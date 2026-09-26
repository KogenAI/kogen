defmodule Kogen.LiveTrackingRetention do
  @moduledoc false

  # Replaces the live Shape-to-Build fixture's former private
  # `preserve_tracking/3`. That helper copied only `record.json`, so a nested
  # Build that cited its own tracking record (a `record-versions/` sidecar,
  # `Kogen.Build.Tracking.retain_record_version/2`) failed
  # `Kogen.Build.Evidence.resolve/2` once the disposable fixture was deleted.
  # This copies the whole nested `.kogen/runtime/scenario-tracking/<build-id>/`
  # tree instead: `record.json`, its `record-versions/` sidecars,
  # `review-packets/`, and the controller verification directory (receipts,
  # logs, ledger diffs).

  @doc """
  Retains every nested Build's `.kogen/runtime/scenario-tracking/<build-id>/`
  directory found under `fixture` into `<log_dir>/scenario-tracking/<build-id>/`,
  replacing an existing destination, and rewrites each retained
  `build-summary*.json` under `complete_dir` so its `full_record.path` points
  at the retained record instead of the (soon-deleted) fixture copy.
  """
  @spec preserve!(Path.t(), Path.t(), Path.t()) :: :ok
  def preserve!(fixture, complete_dir, log_dir) do
    tracking_source = Path.join(fixture, ".kogen/runtime/scenario-tracking")
    records = Path.wildcard(Path.join(tracking_source, "*/record.json"))

    retained_by_source =
      for path <- records, into: %{} do
        build_id = path |> Path.dirname() |> Path.basename()
        source_dir = Path.join(tracking_source, build_id)
        destination_dir = Path.join([log_dir, "scenario-tracking", build_id])

        File.mkdir_p!(Path.dirname(destination_dir))
        File.rm_rf!(destination_dir)
        File.cp_r!(source_dir, destination_dir)

        {Path.relative_to(path, fixture), Path.join(destination_dir, "record.json")}
      end

    for path <- Path.wildcard(Path.join(complete_dir, "build-summary*.json")) do
      summary = path |> File.read!() |> Jason.decode!()
      source = get_in(summary, ["full_record", "path"])

      destination =
        Map.get(retained_by_source, source) ||
          raise "Kogen.LiveTrackingRetention: no retained tracking record for #{inspect(source)}"

      updated = put_in(summary, ["full_record", "path"], destination)
      File.write!(Path.join(log_dir, Path.basename(path)), Jason.encode!(updated) <> "\n")
    end

    for path <- Path.wildcard(Path.join(complete_dir, "scenario-tracking*.json")) do
      File.cp!(path, Path.join(log_dir, Path.basename(path)))
    end

    :ok
  end
end

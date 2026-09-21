defmodule Kogen.TestReliabilityCatalog do
  @moduledoc false

  @allowed ~w(keep rewrite split repair delete)
  @required ~w(id file declaration disposition public_outcome consumer consumer_witness positive_control wrong_control wrong_control_locator failure_recovery implementation)a

  def load!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  def validate(catalog, root, changed_paths \\ nil) when is_map(catalog) do
    rows = catalog["declarations"]

    errors =
      []
      |> require(catalog["schema_version"] == 1, "unsupported catalog schema")
      |> require(is_list(rows) and rows != [], "catalog has no declarations")
      |> require(
        is_list(rows) and catalog["declaration_count"] == length(rows),
        "catalog declaration count is contradictory"
      )
      |> then(fn errors ->
        if is_list(rows),
          do: validate_rows(catalog, rows, root, changed_paths, errors),
          else: errors
      end)

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  def validate_remediation(catalog, remediation) do
    rows = catalog["declarations"] || []
    resolved = remediation["resolved"] || []
    fields = ~w(id disposition scenario implementation wrong_control_locator resolution)

    expected = Enum.map(rows, &Map.take(&1, fields))

    cond do
      remediation["schema_version"] != 1 ->
        {:error, ["unsupported remediation schema"]}

      remediation["intent_id"] != catalog["intent_id"] ->
        {:error, ["remediation intent differs"]}

      remediation["declaration_count"] != length(resolved) ->
        {:error, ["remediation count differs"]}

      resolved != expected ->
        {:error, ["remediation rows differ from catalog"]}

      true ->
        :ok
    end
  end

  def exunit_declarations(catalog) do
    catalog["declarations"]
    |> Enum.filter(&String.ends_with?(&1["file"] || "", "_test.exs"))
    |> Enum.map(&{&1["file"], &1["declaration"]})
    |> Enum.sort()
  end

  defp validate_rows(catalog, rows, root, changed_paths, errors) do
    claimed = Enum.map(rows, &{&1["file"], &1["declaration"]})
    sources = rows |> Enum.map(& &1["file"]) |> Enum.uniq() |> Enum.sort()

    errors
    |> require(length(Enum.uniq(claimed)) == length(claimed), "duplicate declaration identity")
    |> require(
      Enum.all?(sources, &File.regular?(Path.join(root, &1))),
      "catalog source is absent"
    )
    |> require(
      sources == Enum.sort(catalog["maintained_sources"] || []),
      "maintained source inventory is contradictory"
    )
    |> require(Enum.any?(rows, &(&1["disposition"] != "keep")), "blanket keep is forbidden")
    |> require(
      unique_text?(rows, "public_outcome"),
      "public outcomes must be declaration-specific"
    )
    |> require(
      unique_text?(rows, "wrong_control_locator"),
      "wrong controls must be declaration-specific"
    )
    |> then(fn acc -> Enum.reduce(rows, acc, &validate_row(&1, root, changed_paths, &2)) end)
  end

  defp validate_row(row, root, changed_paths, errors) do
    paths = Enum.map(~w(positive_control wrong_control failure_recovery implementation), &row[&1])

    missing =
      Enum.reject(
        @required,
        &(is_binary(row[to_string(&1)]) and String.trim(row[to_string(&1)]) != "")
      )

    errors
    |> require(missing == [], "#{row["id"] || "unknown"}: missing #{Enum.join(missing, ", ")}")
    |> require(row["disposition"] in @allowed, "#{row["id"]}: invalid disposition")
    |> require(
      Enum.all?(paths, &regular_repo_path?(root, &1)),
      "#{row["id"]}: evidence path is absent or unsafe"
    )
    |> require(
      length(Enum.uniq(paths)) == length(paths),
      "#{row["id"]}: evidence roles alias one path"
    )
    |> require(
      consumer_mentions?(root, row),
      "#{row["id"]}: consumer does not expose claimed behavior"
    )
    |> require(
      changed_implementation?(row, changed_paths),
      "#{row["id"]}: implementation is unchanged without preservation proof"
    )
    |> require(source_bound?(root, row), "#{row["id"]}: source binding is stale")
  end

  defp changed_implementation?(_row, nil), do: true

  defp changed_implementation?(
         %{"implementation" => path, "disposition" => disposition} = row,
         changed
       ) do
    path in changed or
      (disposition == "keep" and is_binary(row["preservation_control"]) and
         row["preservation_control"] != path and row["preservation_control"] in changed)
  end

  defp consumer_mentions?(root, row) do
    case File.read(Path.join(root, row["consumer"] || "")) do
      {:ok, source} ->
        String.contains?(source, row["consumer_witness"] || "") and
          row["consumer_witness"] not in [nil, ""]

      _ ->
        false
    end
  end

  defp source_bound?(root, row) do
    case File.read(Path.join(root, row["file"] || "")) do
      {:ok, bytes} ->
        Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == row["source_sha256"]

      _ ->
        false
    end
  end

  defp regular_repo_path?(root, path) when is_binary(path) do
    expanded = Path.expand(path, root)
    String.starts_with?(expanded, Path.expand(root) <> "/") and File.regular?(expanded)
  end

  defp regular_repo_path?(_, _), do: false

  defp unique_text?(rows, field) do
    values = Enum.map(rows, & &1[field])

    Enum.all?(values, &(is_binary(&1) and String.length(String.trim(&1)) >= 16)) and
      length(values) == length(Enum.uniq(values))
  end

  def discover(root) do
    root
    |> Path.join("test/**/*_test.exs")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      relative = Path.relative_to(path, root)

      Regex.scan(~r/\btest\s+"([^"]+)"/, File.read!(path), capture: :all_but_first)
      |> Enum.map(fn [name] -> {relative, name} end)
    end)
    |> Enum.sort()
  end

  defp require(errors, true, _message), do: errors
  defp require(errors, false, message), do: [message | errors]
end

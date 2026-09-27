defmodule Kogen.ShapingAudit.Report do
  @moduledoc """
  Reads and atomically writes `report.json` and `report.md` under
  `.kogen/runtime/shaping-audits/<slug>/<revision>/`, and `--status`'s
  freshness check against the current package.
  """

  @schema_version 1

  @doc "The directory a report for `slug`/`revision` lives in."
  @spec dir(Path.t(), String.t(), String.t()) :: Path.t()
  def dir(root, slug, revision) do
    Path.join([root, ".kogen/runtime/shaping-audits", slug, revision])
  end

  @doc "The slug's runtime directory."
  @spec runtime_dir(Path.t(), String.t()) :: Path.t()
  def runtime_dir(root, slug) do
    Path.join([root, ".kogen/runtime/shaping-audits", slug])
  end

  @doc "Writes `report.json` and `report.md`, atomically. Returns the report.json path."
  @spec write(Path.t(), String.t(), map()) :: {:ok, Path.t()}
  def write(root, slug, report) do
    report = Map.put(report, "schema_version", @schema_version)
    directory = dir(root, slug, Map.fetch!(report, "revision"))
    File.mkdir_p!(directory)

    json_path = Path.join(directory, "report.json")
    md_path = Path.join(directory, "report.md")

    atomic_write(json_path, Jason.encode!(report, pretty: true) <> "\n")
    atomic_write(md_path, to_markdown(report))

    {:ok, json_path}
  end

  defp atomic_write(path, contents) do
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(tmp, contents)
    File.rename!(tmp, path)
  end

  @doc "Reads `report.json` for `slug`/`revision`, if present."
  @spec read(Path.t(), String.t(), String.t()) :: {:ok, map()} | {:error, :missing}
  def read(root, slug, revision) do
    path = Path.join(dir(root, slug, revision), "report.json")

    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, report} -> {:ok, report}
          {:error, _reason} -> {:error, :missing}
        end

      {:error, _reason} ->
        {:error, :missing}
    end
  end

  @doc """
  Compares a report at `revision` against the current `head` and `route`:
  `:current` (matches both), `{:stale, [changed]}` (names `"head"` and/or
  `"route"`), or `:missing` (no report, unreadable, or an unknown
  `schema_version`).
  """
  @spec status(Path.t(), String.t(), String.t(), String.t(), String.t()) ::
          :current | {:stale, [String.t()]} | :missing
  def status(root, slug, revision, head, route) do
    with {:ok, report} <- read(root, slug, revision),
         @schema_version <- report["schema_version"] do
      changed =
        [
          if(report["head"] != head, do: "head"),
          if(report["route"] != route, do: "route")
        ]
        |> Enum.reject(&is_nil/1)

      if changed == [], do: :current, else: {:stale, changed}
    else
      _ -> :missing
    end
  end

  @doc """
  The most recently recorded revision for `slug`: `hook-state.json`'s
  `last_revision` when present, otherwise the newest `report.json` under the
  slug's revision directories (by modification time).
  """
  @spec latest_revision(Path.t(), String.t()) :: {:ok, String.t()} | {:error, :missing}
  def latest_revision(root, slug) do
    case from_hook_state(root, slug) do
      {:ok, revision} -> {:ok, revision}
      {:error, :missing} -> from_newest_report_dir(root, slug)
    end
  end

  defp from_hook_state(root, slug) do
    path = Path.join(runtime_dir(root, slug), "hook-state.json")

    with {:ok, contents} <- File.read(path),
         {:ok, %{"last_revision" => revision}} when is_binary(revision) <- Jason.decode(contents) do
      {:ok, revision}
    else
      _ -> {:error, :missing}
    end
  end

  defp from_newest_report_dir(root, slug) do
    dir = runtime_dir(root, slug)

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 in ["hook.jsonl", "hook-state.json", "auditor"]))
        |> Enum.filter(&File.regular?(Path.join([dir, &1, "report.json"])))
        |> Enum.max_by(&report_mtime(dir, &1), fn -> nil end)
        |> case do
          nil -> {:error, :missing}
          revision -> {:ok, revision}
        end

      {:error, _reason} ->
        {:error, :missing}
    end
  end

  defp report_mtime(dir, revision) do
    path = Path.join([dir, revision, "report.json"])

    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _reason} -> 0
    end
  end

  @doc "Renders `report.json`'s map as the human-readable `report.md`."
  @spec to_markdown(map()) :: String.t()
  def to_markdown(report) do
    findings = report["findings"] || []
    layers = report["layers"] || %{}

    lines =
      [
        "# Shaping audit: #{report["slug"]}",
        "",
        "- package: `#{report["package"]}`",
        "- revision: `#{report["revision"]}`",
        "- head: `#{report["head"]}`",
        "- route: `#{report["route"]}`",
        "- readiness: **#{report["readiness"]}**",
        "",
        "## Layers"
      ] ++
        Enum.map(layers, fn {name, layer} -> "- #{name}: #{layer["status"]}" end) ++
        ["", "## Findings"] ++
        if(findings == [],
          do: ["(none)"],
          else: Enum.map(findings, &finding_line/1)
        )

    Enum.join(lines, "\n") <> "\n"
  end

  defp finding_line(finding) do
    "- `#{finding["id"]}` (#{finding["layer"]}, #{finding["severity"]}): #{finding["message"]}"
  end
end

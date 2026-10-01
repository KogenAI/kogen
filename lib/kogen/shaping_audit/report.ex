defmodule Kogen.ShapingAudit.Report do
  @moduledoc """
  Reads and atomically writes `report.json` and `report.md` under
  `.kogen/runtime/shaping-audits/<slug>/<revision>/`, and `--status`'s
  freshness check against the current package.
  """

  alias Kogen.ShapingAudit.Auditor

  @schema_version 3

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

  @doc """
  Writes `report.json` and `report.md`, atomically. Returns the report.json path.

  A report whose `"scope"` is `"checkpoint"` is never written as
  `report.json`: it goes to `checkpoint.json` and `checkpoint.md` beside it
  (so it cannot overwrite a full report), and the returned path is
  `checkpoint.json`. `read/3` and `status/5` only ever see `report.json`.
  """
  @spec write(Path.t(), String.t(), map()) :: {:ok, Path.t()}
  def write(root, slug, report) do
    report = Map.put(report, "schema_version", @schema_version)
    directory = dir(root, slug, Map.fetch!(report, "revision"))
    File.mkdir_p!(directory)

    {json_name, md_name} =
      if report["scope"] == "checkpoint",
        do: {"checkpoint.json", "checkpoint.md"},
        else: {"report.json", "report.md"}

    json_path = Path.join(directory, json_name)
    md_path = Path.join(directory, md_name)

    atomic_write(json_path, Jason.encode!(report, pretty: true) <> "\n")
    atomic_write(md_path, to_markdown(report))

    {:ok, json_path}
  end

  defp atomic_write(path, contents) do
    tmp = path <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)
    File.write!(tmp, contents, [:exclusive])
    File.rename!(tmp, path)
  end

  @doc "Reads `report.json` for `slug`/`revision`, if present."
  @spec read(Path.t(), String.t(), String.t()) :: {:ok, map()} | {:error, :missing}
  def read(root, slug, revision), do: read_file(root, slug, revision, "report.json")

  @doc "Reads the advisory `checkpoint.json` for `slug`/`revision`, if present."
  @spec read_checkpoint(Path.t(), String.t(), String.t()) :: {:ok, map()} | {:error, :missing}
  def read_checkpoint(root, slug, revision),
    do: read_file(root, slug, revision, "checkpoint.json")

  defp read_file(root, slug, revision, name) do
    path = Path.join(dir(root, slug, revision), name)

    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, report} when is_map(report) -> validate_read(root, slug, revision, report)
          _ -> {:error, :missing}
        end

      {:error, _reason} ->
        {:error, :missing}
    end
  end

  # All consumers (cache, Stop, runner, status and approval) pass this seam.
  # Schema 2 positives could inherit a clean result across revisions. Retain
  # their files as diagnostics, but never expose them as positive evidence.
  defp validate_read(root, slug, revision, %{"readiness" => "ready"} = report) do
    ctx = %{
      root: root,
      slug: slug,
      revision: revision,
      head: report["head"],
      route: report["route"],
      config_fingerprint: report["config_fingerprint"]
    }

    auditor =
      case report["layers"] do
        %{"auditor" => layer} -> layer
        _ -> nil
      end

    if report["schema_version"] == @schema_version and report["scope"] == "full" and
         report["slug"] == slug and report["revision"] == revision and
         is_binary(report["config_fingerprint"]) and
         Auditor.confirmed?(ctx, auditor) do
      {:ok, report}
    else
      {:error, :missing}
    end
  end

  defp validate_read(_root, _slug, _revision, report), do: {:ok, report}

  @doc """
  Compares a report at `revision` against the current `head` and `route`:
  `:current` (matches both), `{:stale, [changed]}` (names `"head"` and/or
  `"route"`), or `:missing` (no report, unreadable, an unknown
  `schema_version`, or positive evidence that lacks the latest counted
  ledger attempt's exact binding and current contract provenance).
  """
  @spec status(Path.t(), String.t(), String.t(), String.t(), String.t()) ::
          :current | {:stale, [String.t()]} | :missing
  def status(root, slug, revision, head, route, expected_fingerprint \\ nil) do
    with {:ok, report} <- read(root, slug, revision),
         @schema_version <- report["schema_version"] do
      changed =
        [
          if(report["head"] != head, do: "head"),
          if(report["route"] != route, do: "route"),
          if(
            report["config_fingerprint"] !=
              (expected_fingerprint || current_fingerprint(root, route)),
            do: "configuration"
          )
        ]
        |> Enum.reject(&is_nil/1)

      if changed == [], do: :current, else: {:stale, changed}
    else
      _ -> :missing
    end
  end

  defp current_fingerprint(root, route) do
    case Kogen.Intent.read_config(Path.join(root, ".kogen/config.yaml"), route) do
      {:ok, config} -> Kogen.Intent.config_fingerprint(config)
      _ -> :unavailable
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
        |> Enum.reject(&(&1 in ["hook.jsonl", "hook-state.json", "auditor", "audit.lock"]))
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
        "- scope: #{report["scope"]}",
        "",
        "## Layers"
      ] ++
        Enum.map(layers, fn {name, layer} -> "- #{name}: #{layer["status"]}" end) ++
        auditor_context_lines(Map.get(layers, "auditor", %{})) ++
        ["", "## Findings"] ++
        if(findings == [],
          do: ["(none)"],
          else: Enum.map(findings, &finding_line/1)
        )

    Enum.join(lines, "\n") <> "\n"
  end

  defp auditor_context_lines(layer) do
    budget_lines =
      case layer["budget_state"] do
        %{"normal_limit" => limit, "normal_count" => count} = budget ->
          exhausted = if budget["normal_exhausted"], do: "exhausted", else: "available"

          [
            "",
            "## Auditor budget",
            "- normal runs: #{count}/#{limit} (#{exhausted})",
            "- confirmation grant: #{budget["confirmation_grant"] || "unknown"}"
          ]

        _ ->
          []
      end

    budget_lines ++ previous_audit_lines(layer["previous_audit"])
  end

  defp previous_audit_lines(%{"findings" => findings} = previous) when is_list(findings) do
    binding = previous_binding(previous)

    [
      "",
      "## Previous auditor result",
      "- status: `#{previous["status"] || "unknown"}`",
      "- binding: #{binding}",
      "Historical findings below are diagnostics; they are not counted for current readiness."
    ] ++
      if(findings == [], do: ["(none)"], else: Enum.map(findings, &finding_line/1))
  end

  defp previous_audit_lines(_previous), do: []

  defp previous_binding(previous) do
    "revision `#{previous["revision"] || "unknown"}`, HEAD `#{previous["head"] || "unknown"}`, " <>
      "route `#{previous["route"] || "unknown"}`"
  end

  defp finding_line(finding) do
    "- `#{finding["id"]}` (#{finding["layer"]}, #{finding["severity"]}): #{finding["message"]}"
  end
end

defmodule KogenChecks.Check.CtxBag do
  @moduledoc """
  Flags context bags in lib code. `ctx` and `context` are always flagged as parameter
  names. Other names are flagged when they are threaded through enough clauses and
  expose many unrelated fields or callbacks; parameters matched as structs are typed.
  """
  use Credo.Check,
    category: :design,
    base_priority: :high,
    param_defaults: [
      banned_names: [:ctx, :context],
      allowed_names: [:conn, :socket],
      min_clauses: 4,
      min_passed_ratio: 0.5,
      min_fields: 8,
      min_ambient: 2,
      ambient_fields:
        ~w(root cwd dir env tmp_dir tmp now clock time runner proc cmd git io shell
                         config opts options control state log log_path logger harness provider http
                         client repo context ctx timeout deadline registry store cache runtime deps services)a,
      included_paths: ["lib/"]
    ],
    explanations: [
      check: "Pass a function the values it needs instead of threading a context bag."
    ]

  alias KogenChecks.Check.CtxBag.Analysis

  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), Keyword.t()) :: [Credo.Issue.t()]
  def run(%SourceFile{filename: filename} = source_file, params) do
    if included?(filename, Params.get(params, :included_paths, __MODULE__)) do
      reports = source_file |> SourceFile.ast() |> Analysis.analyze()
      Enum.flat_map(reports, &module_issues(&1, source_file, params))
    else
      []
    end
  end

  defp included?(filename, prefixes) do
    Enum.any?(prefixes, fn prefix ->
      String.starts_with?(filename, prefix) or String.contains?(filename, "/" <> prefix)
    end)
  end

  defp module_issues(report, source_file, params) do
    report.parameters
    |> Enum.group_by(& &1.name)
    |> Enum.flat_map(fn {name, clauses} -> issue_for(name, clauses, source_file, params) end)
  end

  defp issue_for(name, clauses, source_file, params) do
    if name in Params.get(params, :allowed_names, __MODULE__) do
      []
    else
      choose_issue(name, clauses, source_file, params)
    end
  end

  defp choose_issue(name, clauses, source_file, params) do
    banned = name in Params.get(params, :banned_names, __MODULE__)

    if banned or structural?(name, clauses, params) do
      [build_issue(name, clauses, source_file, params, banned)]
    else
      []
    end
  end

  defp structural?(name, clauses, params) do
    fields = union_fields(clauses)
    callbacks = union_callbacks(clauses)
    ambient = Params.get(params, :ambient_fields, __MODULE__)
    ambient_count = ambient_count(name, fields, callbacks, ambient)
    count = length(clauses)
    passed = Enum.count(clauses, & &1.passed?)

    count >= Params.get(params, :min_clauses, __MODULE__) and
      passed / count >= Params.get(params, :min_passed_ratio, __MODULE__) and
      MapSet.size(fields) >= Params.get(params, :min_fields, __MODULE__) and
      ambient_count >= Params.get(params, :min_ambient, __MODULE__) and
      not Enum.any?(clauses, & &1.typed?)
  end

  defp ambient_count(name, fields, callbacks, ambient) do
    field_set = fields |> Enum.filter(&(&1 in ambient)) |> MapSet.new()
    service_fields = MapSet.union(field_set, callbacks)

    service_fields =
      if name in ambient, do: MapSet.put(service_fields, {:self, name}), else: service_fields

    MapSet.size(service_fields)
  end

  defp union_fields(clauses), do: Enum.reduce(clauses, MapSet.new(), &MapSet.union(&2, &1.fields))

  defp union_callbacks(clauses),
    do: Enum.reduce(clauses, MapSet.new(), &MapSet.union(&2, &1.callbacks))

  defp build_issue(name, clauses, source_file, params, banned) do
    fields = union_fields(clauses)
    passed = Enum.count(clauses, & &1.passed?)
    sample = fields |> Enum.take(6) |> Enum.map_join(", ", &inspect/1)
    label = if banned, do: "is a banned bag name", else: "is threaded like a context bag"

    format_issue(IssueMeta.for(source_file, params),
      message:
        "`#{name}` #{label}: #{length(clauses)} clauses take it, #{passed} pass it on, " <>
          "#{MapSet.size(fields)} fields read (#{sample}). Pass the values each function needs.",
      trigger: Atom.to_string(name),
      line_no: clauses |> Enum.map(& &1.line) |> Enum.min()
    )
  end
end

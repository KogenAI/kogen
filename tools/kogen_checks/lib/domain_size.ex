defmodule KogenChecks.Check.DomainSize do
  @moduledoc "Sum of lib lines per domain (lib/kogen/<d>.ex + lib/kogen/<d>/**) <= max."
  use Credo.Check,
    category: :refactor,
    base_priority: :high,
    param_defaults: [max_lines: 3000, overrides: %{"kernel" => 600}],
    explanations: [check: "A domain over its ceiling must be re-sliced, never exempted."]

  @impl Credo.Check
  def run_on_all_source_files(exec, source_files, params) do
    max = Params.get(params, :max_lines, __MODULE__)
    overrides = Params.get(params, :overrides, __MODULE__)

    source_files
    |> Enum.flat_map(fn sf ->
      case Path.split(sf.filename) do
        ["lib", "kogen", d | _] -> [{Path.rootname(d), sf}]
        _ -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {d, files} ->
      total = files |> Enum.map(&length(SourceFile.lines(&1))) |> Enum.sum()
      limit = Map.get(overrides, d, max)

      if total > limit do
        sf = Enum.max_by(files, &length(SourceFile.lines(&1)))

        issue =
          format_issue(IssueMeta.for(sf, params),
            message:
              "Domain `#{d}` has #{total} lib lines (max #{limit}); largest file is this one. " <>
                "Re-slice the Intent or split the domain.",
            line_no: 1,
            trigger: d
          )

        Credo.Execution.ExecutionIssues.append(exec, issue)
      end
    end)

    :ok
  end

  @impl Credo.Check
  def run(_source_file, _params), do: []
end

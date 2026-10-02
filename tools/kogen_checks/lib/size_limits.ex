defmodule KogenChecks.Check.SizeLimits do
  @moduledoc """
  Hard ceilings: lines per file, lines per defmodule, lines per def/defp
  (spanning all clauses written as separate defs is NOT summed; each clause counts).
  """
  use Credo.Check,
    category: :refactor,
    base_priority: :high,
    param_defaults: [max_file_lines: 400, max_module_lines: 400, max_function_lines: 40],
    explanations: [check: "Split instead of growing. No exemptions."]

  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), Keyword.t()) :: [Credo.Issue.t()]
  def run(%SourceFile{} = source_file, params) do
    im = IssueMeta.for(source_file, params)
    max_file = Params.get(params, :max_file_lines, __MODULE__)
    max_mod = Params.get(params, :max_module_lines, __MODULE__)
    max_fun = Params.get(params, :max_function_lines, __MODULE__)
    total = source_file |> SourceFile.lines() |> length()

    file_issues =
      if total > max_file do
        [
          format_issue(im,
            message:
              "File has #{total} lines (max #{max_file}). Split it into smaller modules in the same domain.",
            line_no: 1,
            trigger: Path.basename(source_file.filename)
          )
        ]
      else
        []
      end

    file_issues ++
      Credo.Code.prewalk(source_file, &walk(&1, &2, im, max_mod, max_fun))
  end

  defp walk({:defmodule, meta, [name | _]} = ast, acc, im, max_mod, _max_fun) do
    {ast, span_issue(acc, im, meta, "module #{Macro.to_string(name)}", max_mod)}
  end

  defp walk({kind, meta, [head | _]} = ast, acc, im, _max_mod, max_fun)
       when kind in [:def, :defp, :defmacro, :defmacrop] do
    {ast, span_issue(acc, im, meta, "#{kind} #{fun_name(head)}", max_fun)}
  end

  defp walk(ast, acc, _im, _max_mod, _max_fun), do: {ast, acc}

  defp span_issue(acc, im, meta, what, max) do
    with line when is_integer(line) <- meta[:line],
         end_line when is_integer(end_line) <- get_in(meta, [:end, :line]),
         span when span > max <- end_line - line + 1 do
      [
        format_issue(im,
          message: "#{what} spans #{span} lines (max #{max}). Extract smaller functions/modules.",
          line_no: line,
          trigger: what
        )
        | acc
      ]
    else
      _ -> acc
    end
  end

  defp fun_name({:when, _, [head | _]}), do: fun_name(head)
  defp fun_name({name, _, args}) when is_atom(name), do: "#{name}/#{length(List.wrap(args))}"
  defp fun_name(_), do: "?"
end

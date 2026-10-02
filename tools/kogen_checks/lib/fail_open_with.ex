defmodule KogenChecks.Check.FailOpenWith do
  @moduledoc "Flags `with ... else` branches that turn unrecognized errors into success-shaped values."
  use Credo.Check,
    category: :warning,
    base_priority: :high,
    param_defaults: [included_paths: ["lib/"]],
    explanations: [
      check: "Match the errors a `with` can produce or let the unmatched value propagate."
    ]

  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), Keyword.t()) :: [Credo.Issue.t()]
  def run(%SourceFile{filename: filename} = source_file, params) do
    if included?(filename, Params.get(params, :included_paths, __MODULE__)) do
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &walk(&1, &2, issue_meta))
    else
      []
    end
  end

  defp included?(filename, prefixes) do
    Enum.any?(prefixes, fn prefix ->
      String.starts_with?(filename, prefix) or String.contains?(filename, "/" <> prefix)
    end)
  end

  defp walk({:with, meta, args} = node, issues, issue_meta) when is_list(args) and args != [] do
    case List.last(args) do
      keywords when is_list(keywords) ->
        {node, check_else(Keyword.get(keywords, :else), meta, issue_meta) ++ issues}

      _ ->
        {node, issues}
    end
  end

  defp walk(node, issues, _issue_meta), do: {node, issues}

  defp check_else(nil, _meta, _issue_meta), do: []

  defp check_else(clauses, meta, issue_meta) when is_list(clauses) do
    arrows = for {:->, _, [[pattern], body]} <- clauses, do: {pattern, body}

    if Enum.any?(arrows, &fail_open?/1) do
      [
        format_issue(issue_meta,
          message:
            "with/else maps an unexpected failure to a success-shaped value. Match real error shapes or drop `else`.",
          trigger: "with",
          line_no: meta[:line]
        )
      ]
    else
      []
    end
  end

  defp check_else(_clauses, _meta, _issue_meta), do: []

  defp fail_open?({pattern, body}) do
    catch_all_failure?(pattern, last(body)) or error_to_literal?(pattern, last(body))
  end

  defp catch_all_failure?(pattern, result) do
    catch_all?(pattern) and not same_value?(pattern, result) and not error_result?(result)
  end

  defp error_to_literal?(pattern, result) do
    error_pattern?(pattern) and literal?(result)
  end

  defp catch_all?({name, _, context}) when is_atom(name) and is_atom(context), do: true

  defp catch_all?(_pattern), do: false

  defp error_pattern?({:error, _}), do: true
  defp error_pattern?({:{}, _, [:error | _]}), do: true
  defp error_pattern?([{:error, _} | _]), do: true
  defp error_pattern?(_pattern), do: false

  defp same_value?({name, _, context}, {name, _, result_context})
       when is_atom(name) and is_atom(context) and is_atom(result_context), do: true

  defp same_value?(_pattern, _result), do: false

  defp error_result?({:error, _}), do: true
  defp error_result?({:{}, _, [:error | _]}), do: true
  defp error_result?(:error), do: true
  defp error_result?({:halt, result}), do: error_result?(result)

  defp error_result?({function, _, _}) when function in [:raise, :reraise, :throw, :exit],
    do: true

  defp error_result?(_result), do: false

  defp literal?(value) when value in [nil, true, false, :ok, [], ""] or is_number(value), do: true
  defp literal?({:ok, value}), do: literal?(value)
  defp literal?({:%{}, _, []}), do: true
  defp literal?(_value), do: false

  defp last({:__block__, _, expressions}) when expressions != [], do: List.last(expressions)
  defp last(expression), do: expression
end

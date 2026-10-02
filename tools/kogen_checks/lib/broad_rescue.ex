defmodule KogenChecks.Check.BroadRescue do
  @moduledoc """
  Flags `rescue _ ->` / `rescue e ->` / `rescue e in [Exception|RuntimeError] ->` and
  `catch _, _ ->` clauses whose body does not re-raise. Narrow rescues
  (`e in [File.Error]`) pass. Laundering a bug into a value hides controller defects.
  """
  use Credo.Check,
    category: :warning,
    base_priority: :high,
    explanations: [check: "Rescue specific exceptions at an I/O edge, or let it crash."]

  @broad [Exception, RuntimeError, ErlangError]

  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), Keyword.t()) :: [Credo.Issue.t()]
  def run(%SourceFile{} = source_file, params) do
    im = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &walk(&1, &2, im))
  end

  defp walk({kw, clauses} = ast, acc, im) when kw in [:rescue, :catch] and is_list(clauses) do
    issues =
      for {:->, meta, [args, body]} <- clauses,
          broad?(kw, List.last(args)),
          not reraises?(body) do
        format_issue(im,
          message:
            "Broad #{kw} without re-raise swallows bugs. Rescue the specific exception at the I/O edge " <>
              "and return a typed {:error, reason}, or let it crash.",
          trigger: to_string(kw),
          line_no: meta[:line]
        )
      end

    {ast, issues ++ acc}
  end

  defp walk(ast, acc, _im), do: {ast, acc}

  defp broad?(:rescue, {name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp broad?(:rescue, {:in, _, [_, mods]}), do: Enum.any?(List.wrap(mods), &broad_mod?/1)
  defp broad?(:catch, {:_, _, _}), do: true
  defp broad?(:catch, {name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp broad?(_, _), do: false

  defp broad_mod?({:__aliases__, _, parts}), do: Module.concat(parts) in @broad
  defp broad_mod?(_), do: false

  defp reraises?(body) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {f, _, _} = n, _ when f in [:reraise, :raise, :throw, :exit] -> {n, true}
        n, found -> {n, found}
      end)

    found
  end
end

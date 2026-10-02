defmodule KogenChecks.Check.ForbiddenCall do
  @moduledoc """
  Bans specific remote calls (Module.fun or :erlang_mod.fun), each with its own
  message and its own list of allowed path prefixes. Catches direct calls and
  captures (&File.cd!/1). `import`/`alias ..., as:` of a banned module is flagged too.
  """
  use Credo.Check,
    category: :warning,
    base_priority: :high,
    param_defaults: [rules: []],
    explanations: [check: "Ambient or unbounded calls must go through ctx / the Proc port."]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    rules =
      params
      |> Params.get(:rules, __MODULE__)
      |> Enum.reject(fn rule -> allowed?(source_file.filename, rule[:allow] || []) end)

    if rules == [] do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      index = Map.new(for r <- rules, {m, f} <- r.calls, do: {{norm(m), f}, r})
      mods = Map.new(for r <- rules, {m, _} <- r.calls, do: {norm(m), r})

      source_file
      |> Credo.Code.prewalk(&walk(&1, &2, index, mods, issue_meta))
      |> Enum.reverse()
    end
  end

  defp walk({{:., meta, [mod_ast, fun]}, _, _} = ast, acc, index, _mods, im) when is_atom(fun) do
    {ast, maybe_issue(acc, index, mod_name(mod_ast), fun, meta, im)}
  end

  defp walk({:import, meta, [mod_ast | _]} = ast, acc, _index, mods, im) do
    name = mod_name(mod_ast)

    case mods[name] do
      nil -> {ast, acc}
      rule -> {ast, [issue(im, meta, "import #{inspect(name)}", rule) | acc]}
    end
  end

  defp walk(ast, acc, _index, _mods, _im), do: {ast, acc}

  defp maybe_issue(acc, index, mod, fun, meta, im) do
    case index[{mod, fun}] do
      nil -> acc
      rule -> [issue(im, meta, "#{inspect(mod)}.#{fun}", rule) | acc]
    end
  end

  defp issue(im, meta, trigger, rule) do
    format_issue(im,
      message: "#{trigger} is banned here. #{rule.message}",
      trigger: trigger,
      line_no: meta[:line]
    )
  end

  defp mod_name({:__aliases__, _, parts}) do
    if Enum.all?(parts, &is_atom/1), do: Module.concat(parts)
  end

  defp mod_name(atom) when is_atom(atom), do: atom
  defp mod_name(_), do: nil

  defp norm(m) when is_atom(m), do: m

  defp allowed?(filename, prefixes), do: Enum.any?(prefixes, &String.starts_with?(filename, &1))
end

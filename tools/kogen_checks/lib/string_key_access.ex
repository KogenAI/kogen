defmodule KogenChecks.Check.StringKeyAccess do
  @moduledoc """
  Flags string-keyed maps in lib code. Only modules named in `codec_modules` may
  work directly with wire-format keys; other modules should decode into structs.
  """
  use Credo.Check,
    category: :design,
    base_priority: :high,
    param_defaults: [included_paths: ["lib/"], codec_modules: []],
    explanations: [
      check: "Decode external data in declared codecs and use struct fields in core code."
    ]

  @map_functions [
    :get,
    :fetch,
    :fetch!,
    :has_key?,
    :put,
    :put_new,
    :update,
    :update!,
    :delete,
    :pop,
    :get_lazy
  ]

  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), Keyword.t()) :: [Credo.Issue.t()]
  def run(%SourceFile{filename: filename} = source_file, params) do
    if included?(filename, Params.get(params, :included_paths, __MODULE__)) do
      ast = source_file |> SourceFile.ast() |> remove_codec_modules(params)
      ast |> Macro.prewalk([], &walk(&1, &2, IssueMeta.for(source_file, params))) |> elem(1)
    else
      []
    end
  end

  defp included?(filename, prefixes) do
    Enum.any?(prefixes, fn prefix ->
      String.starts_with?(filename, prefix) or String.contains?(filename, "/" <> prefix)
    end)
  end

  defp remove_codec_modules(ast, params) do
    codec_modules = Params.get(params, :codec_modules, __MODULE__)

    Macro.prewalk(ast, fn
      {:defmodule, _, [{:__aliases__, _, parts}, _]} = node ->
        if Module.concat(parts) in codec_modules, do: nil, else: node

      node ->
        node
    end)
  end

  defp walk(node, issues, issue_meta) do
    case string_key(node) do
      nil -> {node, issues}
      {line, expression} -> {node, [issue(issue_meta, line, expression) | issues]}
    end
  end

  defp string_key({{:., _, [Access, :get]}, meta, [_map, key]}) when is_binary(key),
    do: {meta[:line], "map[#{inspect(key)}]"}

  defp string_key({{:., _, [{:__aliases__, _, [:Map]}, function]}, meta, [_map, key | _]})
       when function in @map_functions and is_binary(key),
       do: {meta[:line], "Map.#{function}(map, #{inspect(key)})"}

  defp string_key({function, meta, [_map, [key | _]]})
       when function in [:get_in, :put_in, :update_in, :pop_in] and is_binary(key),
       do: {meta[:line], "#{function}(map, [#{inspect(key)}, ...])"}

  defp string_key({:%{}, meta, pairs}) when is_list(pairs) do
    case Enum.find(pairs, &match?({key, _} when is_binary(key), &1)) do
      {key, _value} -> {meta[:line], "%{#{inspect(key)} => ...}"}
      nil -> nil
    end
  end

  defp string_key(_node), do: nil

  defp issue(issue_meta, line, expression) do
    format_issue(issue_meta,
      message:
        "String-keyed map access (#{expression}) is outside a declared codec. Decode into a struct and use fields.",
      trigger: expression,
      line_no: line
    )
  end
end

defmodule KogenChecks.Check.CtxBag.Analysis do
  @moduledoc false

  defmodule Parameter do
    @moduledoc false
    @enforce_keys [:name, :line]
    defstruct name: nil,
              line: nil,
              passed?: false,
              typed?: false,
              fields: MapSet.new(),
              callbacks: MapSet.new()

    @type t :: %__MODULE__{
            name: atom(),
            line: pos_integer(),
            passed?: boolean(),
            typed?: boolean(),
            fields: MapSet.t(atom()),
            callbacks: MapSet.t(atom())
          }
  end

  defmodule ModuleReport do
    @moduledoc false
    @enforce_keys [:name, :parameters]
    defstruct [:name, :parameters]

    @type t :: %__MODULE__{name: String.t(), parameters: [Parameter.t()]}
  end

  @map_access [
    :get,
    :fetch,
    :fetch!,
    :get_lazy,
    :has_key?,
    :pop,
    :put,
    :put_new,
    :update,
    :update!
  ]

  @spec analyze(Macro.t() | nil) :: [ModuleReport.t()]
  def analyze(nil), do: []

  def analyze(ast) do
    ast
    |> Macro.prewalk([], fn
      {:defmodule, _, [name, body]} = node, reports ->
        report = %ModuleReport{name: Macro.to_string(name), parameters: parameters(body)}
        {node, [report | reports]}

      node, reports ->
        {node, reports}
    end)
    |> elem(1)
  end

  defp parameters(body) do
    body
    |> Macro.prewalk([], fn
      {:defmodule, _, _}, acc ->
        {:skip, acc}

      {kind, meta, [head, clauses]} = node, acc when kind in [:def, :defp] and is_list(clauses) ->
        {node, clause_parameters(kind, meta, head, clauses, acc)}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  defp clause_parameters(_kind, meta, head, clauses, acc) do
    {call, _guard} = split_guard(head)

    args =
      case call do
        {_name, _, values} when is_list(values) -> values
        _ -> []
      end

    body = Keyword.get(clauses, :do)
    line = meta[:line] || 1

    Enum.reduce(args, acc, fn arg, found ->
      Enum.reduce(parameter_names(arg), found, fn name, found ->
        [
          %Parameter{
            name: name,
            line: line,
            passed?: passed?(body, name),
            typed?: typed?(args, name),
            fields: MapSet.union(reads(body, name), head_fields(arg, name)),
            callbacks: called_fields(body, name)
          }
          | found
        ]
      end)
    end)
  end

  defp split_guard({:when, _, [head, guard]}), do: {head, guard}
  defp split_guard(head), do: {head, nil}

  defp parameter_names({:=, _, [left, right]}),
    do: parameter_names(left) ++ parameter_names(right)

  defp parameter_names({:\\, _, [value, _default]}), do: parameter_names(value)

  defp parameter_names({name, _, context}) when is_atom(name) and is_atom(context),
    do: if(String.starts_with?(Atom.to_string(name), "_"), do: [], else: [name])

  defp parameter_names(_), do: []

  defp passed?(nil, _name), do: false

  defp passed?(body, name) do
    body
    |> Macro.prewalk(false, fn
      {:|>, _, [{^name, _, context}, _right]} = node, _found when is_atom(context) ->
        {node, true}

      {{:., _, [_module, function]}, _, args} = node, found
      when is_atom(function) and is_list(args) ->
        {node, found or argument_has_name?(args, name)}

      {function, _, args} = node, found when is_atom(function) and is_list(args) ->
        {node, found or argument_has_name?(args, name)}

      node, found ->
        {node, found}
    end)
    |> elem(1)
  end

  defp argument_has_name?(args, name),
    do: Enum.any?(args, &match?({^name, _, context} when is_atom(context), &1))

  defp reads(nil, _name), do: MapSet.new()

  defp reads(body, name) do
    body
    |> Macro.prewalk(MapSet.new(), fn
      {{:., _, [{^name, _, context}, field]}, meta, []} = node, fields
      when is_atom(context) and is_atom(field) ->
        if meta[:no_parens], do: {node, MapSet.put(fields, field)}, else: {node, fields}

      {{:., _, [Access, :get]}, _, [{^name, _, context}, key]} = node, fields
      when is_atom(context) and is_atom(key) ->
        {node, MapSet.put(fields, key)}

      {{:., _, [{:__aliases__, _, [module]}, function]}, _, [{^name, _, context}, key | _]} = node,
      fields
      when module in [:Map, :Keyword] and function in @map_access and is_atom(context) and
             is_atom(key) ->
        {node, MapSet.put(fields, key)}

      node, fields ->
        {node, fields}
    end)
    |> elem(1)
  end

  defp head_fields(pattern, name) do
    pattern
    |> Macro.prewalk(MapSet.new(), fn
      {:=, _, [{:%{}, _, pairs}, {^name, _, context}]} = node, fields
      when is_list(pairs) and is_atom(context) ->
        {node, add_atom_keys(fields, pairs)}

      {:=, _, [{^name, _, context}, {:%{}, _, pairs}]} = node, fields
      when is_list(pairs) and is_atom(context) ->
        {node, add_atom_keys(fields, pairs)}

      node, fields ->
        {node, fields}
    end)
    |> elem(1)
  end

  defp add_atom_keys(fields, pairs) do
    Enum.reduce(pairs, fields, fn
      {key, _value}, fields when is_atom(key) -> MapSet.put(fields, key)
      _, fields -> fields
    end)
  end

  defp typed?(args, name) do
    Enum.any?(args, fn arg -> struct_binding?(arg, name) end)
  end

  defp struct_binding?({:=, _, [left, right]}, name) do
    has_struct = contains_struct?(left) or contains_struct?(right)
    has_struct and name in (parameter_names(left) ++ parameter_names(right))
  end

  defp struct_binding?(_, _name), do: false

  defp contains_struct?({:%, _, _}), do: true

  defp contains_struct?(node) when is_tuple(node) or is_list(node),
    do:
      node
      |> Macro.prewalk(false, fn
        {:%, _, _} = ast, _ -> {ast, true}
        ast, found -> {ast, found}
      end)
      |> elem(1)

  defp contains_struct?(_), do: false

  defp called_fields(nil, _name), do: MapSet.new()

  defp called_fields(body, name) do
    body
    |> Macro.prewalk(MapSet.new(), fn
      {{:., _, [{{:., _, [{^name, _, context}, field]}, _, []}]}, _, _args} = node, fields
      when is_atom(context) and is_atom(field) ->
        {node, MapSet.put(fields, field)}

      node, fields ->
        {node, fields}
    end)
    |> elem(1)
  end
end

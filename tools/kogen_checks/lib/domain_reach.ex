defmodule KogenChecks.Check.DomainReach do
  @moduledoc """
  A file under lib/kogen/<d>/ or test/<d>/ may reference only Kogen.<D>.*, Kogen.Contracts.*
  and modules in `also_allowed` (e.g. Kogen.Testkit for tests). `kernel` is exempt.
  Syntactic (aliases/calls/structs), so it also covers test/ and gives a domain-named message;
  Boundary remains the compile-time authority for lib/.
  """
  use Credo.Check,
    category: :design,
    base_priority: :high,
    param_defaults: [root: Kogen, shared: [Kogen.Contracts], exempt: ["kernel"], also_allowed: []],
    explanations: [
      check: "Domains depend only on contracts; reach other domains through ports in ctx."
    ]

  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params) do
    root = Params.get(params, :root, __MODULE__)
    exempt = Params.get(params, :exempt, __MODULE__)

    case domain_of(filename) do
      nil ->
        []

      d ->
        if d in exempt do
          []
        else
          own = Module.concat(root, Macro.camelize(d))

          ok = [
            own
            | Params.get(params, :shared, __MODULE__) ++
                Params.get(params, :also_allowed, __MODULE__)
          ]

          im = IssueMeta.for(source_file, params)
          root_parts = Module.split(root)

          source_file
          |> Credo.Code.prewalk(&walk(&1, &2, root_parts, ok, d, im))
          |> Enum.uniq_by(& &1.line_no)
        end
    end
  end

  defp domain_of(filename) do
    case Path.split(filename) do
      ["lib", "kogen", facade] when is_binary(facade) ->
        if Path.extname(facade) == ".ex", do: nil, else: Path.rootname(facade)

      ["lib", "kogen", d | _] ->
        Path.rootname(d)

      ["test", d | _] when d != "support" ->
        d

      _ ->
        nil
    end
  end

  defp walk({:__aliases__, meta, [p | _] = parts} = ast, acc, root_parts, ok, d, im)
       when is_atom(p) do
    names = parts |> Enum.map(&inspect/1) |> Enum.map(&String.trim_leading(&1, ":"))

    if Enum.all?(parts, &is_atom/1) and List.starts_with?(names, root_parts) and
         length(names) > length(root_parts) do
      mod = Module.concat(parts)

      if Enum.any?(ok, &(mod == &1 or String.starts_with?(to_string(mod), to_string(&1) <> "."))) do
        {ast, acc}
      else
        msg =
          "Domain `#{d}` references #{inspect(mod)}. Domains may use only their own modules and " <>
            "Kogen.Contracts; call another domain through its port in ctx (e.g. ctx.workspace)."

        {ast, [format_issue(im, message: msg, trigger: inspect(mod), line_no: meta[:line]) | acc]}
      end
    else
      {ast, acc}
    end
  end

  defp walk(ast, acc, _root, _ok, _d, _im), do: {ast, acc}
end

defmodule KogenChecks.Check.DomainReach do
  @moduledoc """
  A domain file may reference its own modules, contracts, and declared acyclic domain
  dependencies. Test-only support modules are configured separately. Boundary remains
  the compile-time authority for lib references.
  """
  use Credo.Check,
    category: :design,
    base_priority: :high,
    param_defaults: [root: Kogen, shared: [Kogen.Contracts], dependencies: %{}, also_allowed: []],
    explanations: [check: "Domain references follow the declared acyclic dependency graph."]

  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), Keyword.t()) :: [Credo.Issue.t()]
  def run(%SourceFile{filename: filename} = source_file, params) do
    case domain_of(filename) do
      nil -> []
      domain -> check_domain(source_file, params, domain, filename)
    end
  end

  defp check_domain(source_file, params, domain, filename) do
    root = Params.get(params, :root, __MODULE__)
    own = Module.concat(root, Macro.camelize(domain))
    dependencies = Params.get(params, :dependencies, __MODULE__)
    domain_deps = Map.get(dependencies, own, [])
    test_support = test_support(filename, params)
    allowed = [own | Params.get(params, :shared, __MODULE__) ++ domain_deps ++ test_support]
    issue_meta = IssueMeta.for(source_file, params)
    root_parts = Module.split(root)

    source_file
    |> Credo.Code.prewalk(&walk(&1, &2, root_parts, allowed, domain, issue_meta))
    |> Enum.uniq_by(& &1.line_no)
  end

  defp test_support(filename, params) do
    if test_file?(filename), do: Params.get(params, :also_allowed, __MODULE__), else: []
  end

  defp test_file?(filename), do: List.first(Path.split(filename)) == "test"

  defp domain_of(filename) do
    case Path.split(filename) do
      ["lib", "kogen", facade] when is_binary(facade) ->
        if Path.extname(facade) == ".ex", do: nil, else: Path.rootname(facade)

      ["lib", "kogen", domain | _] ->
        Path.rootname(domain)

      ["test", domain | _] when domain != "support" ->
        Path.rootname(domain)

      _ ->
        nil
    end
  end

  defp walk(
         {:__aliases__, meta, [part | _] = parts} = ast,
         issues,
         root_parts,
         allowed,
         domain,
         issue_meta
       )
       when is_atom(part) do
    names = Enum.map(parts, &Atom.to_string/1)

    if Enum.all?(parts, &is_atom/1) and List.starts_with?(names, root_parts) and
         length(names) > length(root_parts) do
      module = Module.concat(parts)

      if allowed?(module, allowed) do
        {ast, issues}
      else
        {ast, [dependency_issue(issue_meta, meta, module, domain) | issues]}
      end
    else
      {ast, issues}
    end
  end

  defp walk(ast, issues, _root, _allowed, _domain, _issue_meta), do: {ast, issues}

  defp allowed?(module, allowed) do
    Enum.any?(allowed, fn allowed_module ->
      module == allowed_module or
        String.starts_with?(Atom.to_string(module), Atom.to_string(allowed_module) <> ".")
    end)
  end

  defp dependency_issue(issue_meta, meta, module, domain) do
    format_issue(issue_meta,
      message:
        "Domain `#{domain}` references #{inspect(module)} outside its declared dependency graph.",
      trigger: inspect(module),
      line_no: meta[:line]
    )
  end
end

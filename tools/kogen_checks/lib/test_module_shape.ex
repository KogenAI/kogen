defmodule KogenChecks.Check.TestModuleShape do
  @moduledoc """
  Requires async test cases and caps the run count per test module. A literal
  `parameterize:` list multiplies the module's test count; serial exceptions belong
  in the protected Credo configuration.
  """
  use Credo.Check,
    category: :warning,
    base_priority: :high,
    param_defaults: [max_tests: 30, serial_allowed: []],
    explanations: [check: "Test modules run async and stay small."]

  defmodule ModuleStats do
    @moduledoc false
    defstruct line: 1, uses: [], tests: 0, params: 1, serial_allowed?: false
  end

  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), Keyword.t()) :: [Credo.Issue.t()]
  def run(%SourceFile{filename: filename} = source_file, params) do
    if String.ends_with?(filename, "_test.exs") do
      max = Params.get(params, :max_tests, __MODULE__)
      serial_ok = filename in Params.get(params, :serial_allowed, __MODULE__)

      source_file
      |> SourceFile.ast()
      |> collect_modules(serial_ok)
      |> Enum.flat_map(&issues(&1, source_file, params, max))
    else
      []
    end
  end

  defp collect_modules(ast, serial_ok) do
    ast
    |> Macro.prewalk([], fn
      {:defmodule, meta, [_name, body]} = node, modules ->
        stats = module_stats(body, meta[:line] || 1, serial_ok)
        {node, [stats | modules]}

      node, modules ->
        {node, modules}
    end)
    |> elem(1)
  end

  defp module_stats(body, line, serial_ok) do
    stats = %ModuleStats{line: line, serial_allowed?: serial_ok}

    body
    |> Macro.prewalk(stats, fn
      {:defmodule, _, _}, current ->
        {:skip, current}

      node, current ->
        collect(node, current)
    end)
    |> elem(1)
  end

  defp collect({:use, meta, [{:__aliases__, _, parts}, opts]} = node, stats) when is_list(opts) do
    if case_module?(parts) do
      count = if is_list(opts[:parameterize]), do: length(opts[:parameterize]), else: 1
      use_stats = {meta[:line] || stats.line, async_case?(parts, opts)}
      {node, %{stats | uses: [use_stats | stats.uses], params: count}}
    else
      {node, stats}
    end
  end

  defp collect({:use, meta, [{:__aliases__, _, parts}]} = node, stats) do
    if case_module?(parts) do
      use_stats = {meta[:line] || stats.line, async_case?(parts, [])}
      {node, %{stats | uses: [use_stats | stats.uses]}}
    else
      {node, stats}
    end
  end

  defp collect({:test, _, [name | _]} = node, stats) when is_binary(name) or is_tuple(name),
    do: {node, %{stats | tests: stats.tests + 1}}

  defp collect(node, stats), do: {node, stats}

  defp case_module?(parts),
    do: parts |> List.last() |> Atom.to_string() |> String.ends_with?("Case")

  defp async_case?([:Kogen, :Testkit, :Case], opts),
    do: not Keyword.has_key?(opts, :async) or opts[:async] == true

  defp async_case?(_parts, opts),
    do:
      opts[:async] == true or
        (Keyword.has_key?(opts, :layer) and not Keyword.has_key?(opts, :async))

  defp issues(stats, source_file, params, max) do
    source_file
    |> IssueMeta.for(params)
    |> then(&async_issues(stats, &1))
    |> Kernel.++(size_issues(stats, source_file, params, max))
  end

  defp async_issues(stats, issue_meta) do
    for {line, async} <- stats.uses, async != true, not stats.serial_allowed? do
      format_issue(issue_meta,
        message:
          "Test module is not `async: true`. Inject explicit values instead of mutating globals; add a reviewed serial entry only when needed.",
        line_no: line,
        trigger: "use"
      )
    end
  end

  defp size_issues(stats, source_file, params, max) do
    runs = stats.tests * stats.params

    if runs > max do
      [
        format_issue(IssueMeta.for(source_file, params),
          message:
            "Test module defines #{runs} test runs (#{stats.tests} tests x #{stats.params} params; max #{max}). Split it into smaller test modules.",
          line_no: stats.line,
          trigger: "defmodule"
        )
      ]
    else
      []
    end
  end
end

defmodule KogenChecks.Check.TestModuleShape do
  @moduledoc """
  For *_test.exs files:
  * every test case must use `async: true`; Kogen.Testkit.Case is async by construction;
    serial exceptions live in the protected .credo.exs and need a human edit;
  * at most `max_tests` test cases per module, where a `parameterize:` list literal
    multiplies the count (develop's BuildPreconditions: 56 tests x params = 350 runs).
  """
  use Credo.Check,
    category: :warning,
    base_priority: :high,
    param_defaults: [max_tests: 30, serial_allowed: []],
    explanations: [check: "Tests run async and modules stay small."]

  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params) do
    if String.ends_with?(filename, "_test.exs") do
      im = IssueMeta.for(source_file, params)
      max = Params.get(params, :max_tests, __MODULE__)
      serial_ok = filename in Params.get(params, :serial_allowed, __MODULE__)

      source_file
      |> Credo.Code.prewalk(&collect/2, %{uses: [], tests: 0, params: 1, line: 1})
      |> Map.put(:serial_ok, serial_ok)
      |> issues(im, max)
    else
      []
    end
  end

  defp collect({:defmodule, meta, _} = ast, acc), do: {ast, %{acc | line: meta[:line] || 1}}

  defp collect({:use, meta, [{:__aliases__, _, parts}, opts]} = ast, acc) when is_list(opts) do
    if case_module?(parts) do
      n = if is_list(opts[:parameterize]), do: length(opts[:parameterize]), else: 1

      {ast,
       %{
         acc
         | uses: [
             {meta[:line], async_case?(parts, opts)} | acc.uses
           ],
           params: n
       }}
    else
      {ast, acc}
    end
  end

  defp collect({:use, meta, [{:__aliases__, _, parts}]} = ast, acc) do
    if case_module?(parts),
      do: {ast, %{acc | uses: [{meta[:line], async_case?(parts, [])} | acc.uses]}},
      else: {ast, acc}
  end

  defp collect({:test, _, [name | _]} = ast, acc) when is_binary(name) or is_tuple(name),
    do: {ast, %{acc | tests: acc.tests + 1}}

  defp collect(ast, acc), do: {ast, acc}

  defp case_module?(parts),
    do: parts |> List.last() |> Atom.to_string() |> String.ends_with?("Case")

  defp async_case?([:Kogen, :Testkit, :Case], opts),
    do: not Keyword.has_key?(opts, :async) or opts[:async] == true

  defp async_case?(_parts, opts),
    do:
      opts[:async] == true or
        (Keyword.has_key?(opts, :layer) and not Keyword.has_key?(opts, :async))

  defp issues(acc, im, max) do
    async_issues =
      for {line, async} <- acc.uses, async != true, not acc.serial_ok do
        format_issue(im,
          message:
            "Test module is not `async: true`. Inject ctx (root/env/clock) instead of mutating globals. " <>
              "Serial modules need a human-approved entry in .credo.exs serial_allowed.",
          line_no: line,
          trigger: "use"
        )
      end

    runs = acc.tests * acc.params

    size_issues =
      if runs > max do
        [
          format_issue(im,
            message:
              "Test module defines #{runs} test runs (#{acc.tests} tests x #{acc.params} params; max #{max}). " <>
                "Split by behaviour, or drop parameters that most tests ignore.",
            line_no: acc.line,
            trigger: "defmodule"
          )
        ]
      else
        []
      end

    async_issues ++ size_issues
  end
end

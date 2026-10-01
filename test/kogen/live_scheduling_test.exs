defmodule Kogen.LiveSchedulingTest do
  use ExUnit.Case, async: true

  @probe Path.expand("../support/scheduling_overlap_probe.exs", __DIR__)
  @connected_source Path.expand("live_shape_to_build_test.exs", __DIR__)
  @rework_source Path.expand("live_reviewer_rework_test.exs", __DIR__)

  test "actual isolated dispatchers overlap across the two live owner modules" do
    {root, output, status} = run_probe()
    on_exit(fn -> File.rm_rf!(root) end)

    assert status == 0, output

    assert File.read!(Path.join(root, "rendezvous/connected.steps")) ==
             "started\ndependent-finished\n"

    assert File.read!(Path.join(root, "rendezvous/rework.steps")) ==
             "started\ndependent-finished\n"

    assert Path.wildcard(Path.join(root, "tmp/kogen-isolated-*")) == []
  end

  test "an isolated owner failure reaches the scheduling suite and cleanup still settles" do
    {root, output, status} = run_probe("connected")
    on_exit(fn -> File.rm_rf!(root) end)

    assert status != 0
    assert output =~ "requested connected owner failure"
    assert Path.wildcard(Path.join(root, "tmp/kogen-isolated-*")) == []
  end

  # These assertions protect properties of the live owner modules' code. They
  # read the parsed syntax tree, so reflowing, renaming a local or moving a
  # comment cannot fail them; only a real change to a call, a comparison or a
  # module definition can.
  test "live Shape lifecycle carries the selected route and approves only an audited presentation" do
    source = parse!(@connected_source)

    assert has_code?(source, ~s{System.get_env("KOGEN_ROUTE")})
    assert has_call?(source, [:Intent], :read_config, [".kogen/config.yaml", :_])
    assert has_code?(source, "copied_config.route == config.route")
    refute has_code?(source, ~s{copied_config.route == "optimum"})

    # The connected run drives the real automatic Build.
    assert has_call?(source, [:System], :cmd, ["mix", ["kogen.build", :_], :_])
    refute mentions?(source, "kogen.phase")

    # Shaping runs through the headless engine commands only: the start
    # carries the selected route, and approval names the presentation the
    # engine made only from a current audited-ready report.
    assert mentions?(source, "kogen.shape")

    assert mentions?(source, "--route")

    assert has_code?(
             source,
             "shape_through_engine!(fixture, log_dir, brief_path, answers_path, request, config.route)"
           )

    assert mentions?(source, "--approve")
    assert has_code?(source, "(status[\"presented\"] || %{})[\"id\"]")
    assert has_code?(source, ~s{approval["source"] == "mix kogen.shape --approve"})
    refute mentions?(source, "shape_to_build_probe")
    refute mentions?(source, ".exp")
    refute mentions?(source, "spawn mix")
  end

  test "live selection keeps connected and rework owners in distinct async modules" do
    source = parse!(@connected_source)
    rework_source = parse!(@rework_source)

    assert defines_module?(source, [:Kogen, :LiveShapeToBuildTest])
    refute defines_module?(source, [:Kogen, :LiveReviewerReworkTest])
    assert defines_module?(rework_source, [:Kogen, :LiveReviewerReworkTest])
    assert count_code(source, "use ExUnit.Case, async: true") == 1
    assert count_code(rework_source, "use ExUnit.Case, async: true") == 1
    assert has_code?(rework_source, ~s{System.get_env("KOGEN_ROUTE")})
    assert has_code?(rework_source, "Kogen.LiveReviewerReworkFixture.run(route.route)")
    refute has_code?(rework_source, ~s{LiveReviewerReworkFixture.run("optimum")})
    refute mentions?(rework_source, "live_shape_to_build_test.exs")
  end

  defp parse!(path), do: path |> File.read!() |> Code.string_to_quoted!()

  defp strip(ast), do: Macro.prewalk(ast, &Macro.update_meta(&1, fn _ -> [] end))

  defp subtrees(ast) do
    {_, found} = Macro.prewalk(ast, [], fn node, acc -> {node, [strip(node) | acc]} end)
    found
  end

  defp count_code(ast, code),
    do: Enum.count(subtrees(ast), &(&1 == code |> Code.string_to_quoted!() |> strip()))

  defp has_code?(ast, code), do: count_code(ast, code) > 0

  # A remote call `Alias.Tail.function(args...)` whose module alias ends in
  # `module_tail`. `:_` matches anything; a shorter `args` list is a prefix of
  # the real arguments only when it ends in `:_` as its last element.
  defp has_call?(ast, module_tail, function, args) do
    Enum.any?(subtrees(ast), fn
      {{:., [], [{:__aliases__, [], aliases}, ^function]}, [], call_args} ->
        List.starts_with?(Enum.reverse(aliases), Enum.reverse(module_tail)) and
          args_match?(args, call_args)

      _ ->
        false
    end)
  end

  defp args_match?(:_, _), do: true

  defp args_match?(pattern, actual) when is_list(pattern) do
    case Enum.reverse(pattern) do
      [:_ | rest] ->
        prefix = Enum.reverse(rest)
        length(actual) >= length(prefix) and match_all?(prefix, Enum.take(actual, length(prefix)))

      _ ->
        length(pattern) == length(actual) and match_all?(pattern, actual)
    end
  end

  defp match_all?(patterns, actuals),
    do: Enum.all?(Enum.zip(patterns, actuals), fn {p, a} -> shape_match?(p, a) end)

  defp shape_match?(:_, _), do: true

  defp shape_match?({:|, [head, :_]}, {:|, [], [actual_head, _tail]}),
    do: shape_match?(head, actual_head)

  defp shape_match?(pattern, actual) when is_list(pattern) and is_list(actual),
    do: length(pattern) == length(actual) and match_all?(pattern, actual)

  defp shape_match?(pattern, actual), do: pattern == actual

  # True when any string literal (heredocs and the literal parts of
  # interpolated strings included) or atom contains `text`.
  defp mentions?(ast, text) do
    Enum.any?(subtrees(ast), fn
      node when is_binary(node) -> String.contains?(node, text)
      node when is_atom(node) -> node |> Atom.to_string() |> String.contains?(text)
      _ -> false
    end)
  end

  defp defines_module?(ast, aliases) do
    Enum.any?(subtrees(ast), fn
      {:defmodule, [], [{:__aliases__, [], ^aliases} | _]} -> true
      _ -> false
    end)
  end

  defp run_probe(failing_owner \\ "") do
    root =
      Path.join(
        System.tmp_dir!(),
        "kogen-scheduling-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    rendezvous = Path.join(root, "rendezvous")
    tmp = Path.join(root, "tmp")
    File.mkdir_p!(rendezvous)
    File.mkdir_p!(tmp)

    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(&(Path.type(&1) == :absolute))
      |> Enum.reject(&String.contains?(&1, "kogen-test-code-"))
      |> Enum.uniq()

    args =
      Enum.flat_map(code_paths, fn path -> ["-pa", path] end) ++
        [
          "-r",
          Path.expand("../test_helper.exs", __DIR__),
          "-r",
          @probe,
          "-e",
          "result = ExUnit.run(); if result.failures != 0, do: System.halt(1)"
        ]

    {output, status} =
      System.cmd("elixir", args,
        cd: System.fetch_env!("KOGEN_TEST_ROOT"),
        env: [
          {"SCHEDULING_RENDEZVOUS", rendezvous},
          {"SCHEDULING_FAIL", failing_owner},
          {"TMPDIR", tmp}
        ],
        stderr_to_stdout: true
      )

    {root, output, status}
  end
end

defmodule Kogen.IsolationTest do
  use ExUnit.Case, async: true

  @probe Path.expand("../support/isolation_probe.exs", __DIR__)

  test "independent children overlap and isolate cwd, environment, and temporary roots" do
    root = tmp_dir!()
    original_env = System.get_env("PROBE_LOCAL")

    tasks =
      for {name, peer} <- [{"a", "b"}, {"b", "a"}] do
        Task.async(fn ->
          Kogen.IsolatedCase.run(@probe, "test overlap",
            parameters: %{test: :"test overlap"},
            env: [{"PROBE_ROOT", root}, {"PROBE_NAME", name}, {"PROBE_PEER", peer}]
          )
        end)
      end

    for task <- tasks, do: assert({:ok, _} = Task.await(task, 10_000))
    assert System.get_env("PROBE_LOCAL") == original_env

    # Each child starts at the explicit checkout root, whatever the shared
    # parent VM's own (mutable) working directory is, and moves only itself.
    test_root = System.fetch_env!("KOGEN_TEST_ROOT")
    assert File.read!(Path.join(root, "a.start_cwd")) == test_root
    assert File.read!(Path.join(root, "b.start_cwd")) == test_root
    assert File.read!(Path.join(root, "a.count")) == "once\n"
    assert File.read!(Path.join(root, "b.count")) == "once\n"
    a_tmp = File.read!(Path.join(root, "a.tmp"))
    b_tmp = File.read!(Path.join(root, "b.tmp"))
    assert a_tmp != b_tmp
    refute File.exists?(a_tmp)
    refute File.exists?(b_tmp)
  end

  test "assertions and nonzero child exits propagate with diagnostics" do
    marker = Path.join(tmp_dir!(), "failure-child.pid")

    assert {:error, {:exit_status, 1}, output} =
             Kogen.IsolatedCase.run(@probe, "test nonexistent")

    assert output =~ "expected exactly one passing isolated test"

    assert {:error, {:exit_status, 1}, output} =
             Kogen.IsolatedCase.run(@probe, "test assertion failure",
               env: [{"PROBE_PID", marker}]
             )

    assert output =~ "intentional isolated assertion"
    pid = marker |> File.read!() |> String.trim()
    assert {_, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
    assert status != 0, "failed test subprocess #{pid} survived cleanup"

    assert {:error, {:exit_status, 23}, output} =
             Kogen.IsolatedCase.run(@probe, "test nonzero exit",
               env: [{"PROBE_PID", marker <> ".abrupt"}]
             )

    assert output =~ "intentional isolated exit"
    abrupt_pid = File.read!(marker <> ".abrupt") |> String.trim()
    assert {_, status} = System.cmd("/bin/kill", ["-0", abrupt_pid], stderr_to_stdout: true)
    assert status != 0, "abruptly halted VM left subprocess #{abrupt_pid} alive"
  end

  test "raw zero exit and forged completion output fail closed" do
    assert {:error, {:completion_receipt, :missing}, _output} =
             Kogen.IsolatedCase.run(@probe, "test abrupt zero before ExUnit completion")

    assert {:error, {:completion_receipt, :duplicate_or_malformed}, output} =
             Kogen.IsolatedCase.run(@probe, "test forged completion output")

    assert output =~ "KOGEN_ISOLATED_COMPLETION"
  end

  test "timeouts propagate and parent cancellation reaps a running subprocess" do
    marker = Path.join(tmp_dir!(), "child.pid")

    assert {:error, :timeout, _} =
             Kogen.IsolatedCase.run(@probe, "test timeout with child",
               timeout: 1,
               env: [{"PROBE_PID", marker}]
             )

    # Wait for evidence of a running subprocess before cancelling its owner.
    # This separates the cleanup assertion from variable VM startup latency.
    owner =
      spawn(fn ->
        Kogen.IsolatedCase.run(@probe, "test timeout with child", env: [{"PROBE_PID", marker}])
      end)

    monitor = Process.monitor(owner)

    assert Enum.any?(1..500, fn _ ->
             if File.exists?(marker),
               do: true,
               else:
                 (
                   Process.sleep(10)
                   false
                 )
           end)

    pid = marker |> File.read!() |> String.trim()
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    assert Enum.any?(1..100, fn _ ->
             {_, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)

             if status != 0,
               do: true,
               else:
                 (
                   Process.sleep(10)
                   false
                 )
           end),
           "cancelled subprocess #{pid} survived cleanup"
  end

  test "readiness starts collection timing only after startup and diagnoses each phase" do
    stale_marker = Path.join(tmp_dir!(), "foreign-ready")
    File.write!(stale_marker, "foreign\n")

    assert {:ok, output} =
             Kogen.IsolatedCase.run(@probe, "test delayed readiness",
               readiness: "PROBE_READY",
               startup_timeout: 15_000,
               collection_timeout: 500,
               env: [{"PROBE_DELAY_MS", "800"}, {"PROBE_READY", stale_marker}]
             )

    assert output =~ "Result: 1 passed"
    assert File.read!(stale_marker) == "foreign\n"

    assert {:error, :readiness_timeout, output} =
             Kogen.IsolatedCase.run(@probe, "test missing readiness",
               readiness: "PROBE_READY",
               startup_timeout: 100,
               collection_timeout: 1_000
             )

    assert output =~ "isolated children terminated"

    assert {:error, {:readiness_exit, 19}, output} =
             Kogen.IsolatedCase.run(@probe, "test exit before readiness",
               readiness: "PROBE_READY",
               startup_timeout: 15_000
             )

    assert output =~ "exited before readiness marker"

    assert {:error, :timeout, output} =
             Kogen.IsolatedCase.run(@probe, "test delayed readiness",
               readiness: "PROBE_READY",
               startup_timeout: 15_000,
               collection_timeout: 250,
               env: [{"PROBE_AFTER_READY_MS", "1000"}]
             )

    assert output =~ "isolated children terminated"
  end

  test "callers without readiness retain launch-relative collection timing" do
    assert {:error, :timeout, _output} =
             Kogen.IsolatedCase.run(@probe, "test delayed readiness",
               collection_timeout: 100,
               env: [{"PROBE_DELAY_MS", "500"}, {"PROBE_READY", Path.join(tmp_dir!(), "unused")}]
             )
  end

  test "every maintained test module explicitly enables async execution" do
    for source <- Path.wildcard(Path.expand("*_test.exs", __DIR__)) do
      text = File.read!(source)

      assert Regex.match?(~r/use (?:ExUnit.Case|Kogen.IsolatedCase),\s*async: true/, text),
             "#{source} must explicitly use async: true"
    end
  end

  # `setup` and `setup_all` of an isolated-case module also run in the shared
  # parent VM, where a process-global mutation races every other module. Each
  # mutation must sit inside an `if ...isolated_child?()` branch.
  @global_mutations [
    {[:System], :put_env},
    {[:System], :delete_env},
    {[:File], :cd},
    {[:File], :cd!},
    {[:Application], :put_env},
    {[:Application], :put_all_env},
    {[:Application], :delete_env}
  ]

  test "isolated-case setup mutates process-global state only behind isolated_child?()" do
    violations =
      for source <- Path.wildcard(Path.expand("*_test.exs", __DIR__)),
          ast = source |> File.read!() |> Code.string_to_quoted!(),
          uses_isolated_case?(ast),
          {name, line} <- unguarded_setup_mutations(ast) do
        "#{Path.relative_to(source, __DIR__)}:#{line} #{name}"
      end

    assert violations == [],
           "setup in an isolated-case module mutates shared-VM state outside " <>
             "`if isolated_child?()`:\n" <> Enum.join(violations, "\n")
  end

  defp uses_isolated_case?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {:use, _, [{:__aliases__, _, [:Kogen, :IsolatedCase]} | _]} = node, _ -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  defp unguarded_setup_mutations(ast) do
    {_, {bodies, named, defs}} =
      Macro.prewalk(ast, {[], [], %{}}, fn
        {setup, _, args} = node, {bodies, named, defs} when setup in [:setup, :setup_all] ->
          case List.wrap(args) do
            [name] when is_atom(name) -> {node, {bodies, [name | named], defs}}
            args -> {node, {[args | bodies], named, defs}}
          end

        {kind, _, [{name, _, _}, [do: body]]} = node, {bodies, named, defs}
        when kind in [:def, :defp] and is_atom(name) ->
          {node, {bodies, named, Map.update(defs, name, [body], &[body | &1])}}

        node, acc ->
          {node, acc}
      end)

    named_bodies = Enum.flat_map(named, &Map.get(defs, &1, []))

    Enum.flat_map(bodies ++ named_bodies, &mutations(&1, false))
  end

  # Walks `node` and returns `{"Module.function", line}` for each mutation not
  # inside a branch of an `if` whose condition calls `isolated_child?`.
  defp mutations({:if, _, [condition | branches]}, guarded?) do
    guarded? = guarded? or mentions_guard?(condition)
    mutations(condition, guarded?) ++ Enum.flat_map(branches, &mutations(&1, guarded?))
  end

  defp mutations({{:., _, [{:__aliases__, _, aliases}, function]}, meta, args} = node, guarded?) do
    own =
      if not guarded? and {aliases, function} in @global_mutations,
        do: [{"#{Enum.join(aliases, ".")}.#{function}", meta[:line]}],
        else: []

    _ = node
    own ++ Enum.flat_map(args, &mutations(&1, guarded?))
  end

  defp mutations({left, _, right}, guarded?),
    do: mutations(left, guarded?) ++ mutations(right, guarded?)

  defp mutations({left, right}, guarded?),
    do: mutations(left, guarded?) ++ mutations(right, guarded?)

  defp mutations(list, guarded?) when is_list(list),
    do: Enum.flat_map(list, &mutations(&1, guarded?))

  defp mutations(_other, _guarded?), do: []

  defp mentions_guard?(condition) do
    {_, found} =
      Macro.prewalk(condition, false, fn
        {{:., _, [_, :isolated_child?]}, _, _} = node, _ -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  test "the offline provider denial shim fails closed and leaves a receipt" do
    fixture = tmp_dir!()
    shim = Path.expand("../support/codex", __DIR__)
    assert {_, 1} = System.cmd(shim, ["unexpected-provider-launch"], cd: fixture)
    receipt = File.read!(Path.join(fixture, ".kogen/runtime/path-shim-invoked"))
    assert receipt =~ "PATH-SHIM-CODEX-INVOKED: unexpected-provider-launch"
  end

  defp tmp_dir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "kogen-isolation-probe-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end

defmodule Kogen.IsolatedMacroReadinessTest do
  use Kogen.IsolatedCase, async: true

  @tag readiness: "PROBE_READY", startup_timeout: 15_000, collection_timeout: 1_000
  test "macro dispatch observes child readiness" do
    Process.sleep(200)
    File.write!(System.fetch_env!("PROBE_READY"), "ready\n")
  end
end

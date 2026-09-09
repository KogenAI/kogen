Code.require_file("../support/dependency_fixture.ex", __DIR__)

defmodule Kogen.DependencyFixtureTest do
  use ExUnit.Case, async: true

  @moduletag timeout: 120_000

  test "private dependency copies retain yamerl headers and compile concurrently" do
    root = Path.expand("../..", __DIR__)
    source_deps = Path.join(root, "deps")

    fixture_root =
      Path.join(
        System.tmp_dir!(),
        "kogen-dependency-fixture-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(fixture_root)
    on_exit(fn -> File.rm_rf!(fixture_root) end)

    fixtures = Enum.map(["one", "two"], &Path.join(fixture_root, &1))

    Enum.each(fixtures, fn fixture ->
      deps = Kogen.DependencyFixture.copy!(source_deps, Path.join(fixture, "deps"))
      write_yamerl_project!(root, fixture)

      assert File.regular?(Path.join(deps, "yamerl/include/yamerl_nodes.hrl"))
      refute File.exists?(Path.join(deps, "yamerl/_build"))
      assert File.lstat!(deps).type == :directory
    end)

    header = "yamerl/include/yamerl_nodes.hrl"
    source_header = File.read!(Path.join(source_deps, header))
    [first_fixture, second_fixture] = fixtures
    first_header = Path.join([first_fixture, "deps", header])

    File.write!(first_header, source_header <> "\n% private fixture mutation\n")
    assert File.read!(Path.join([second_fixture, "deps", header])) == source_header
    assert File.read!(Path.join(source_deps, header)) == source_header
    File.write!(first_header, source_header)

    results =
      Task.async_stream(fixtures, &compile_yamerl/1,
        max_concurrency: length(fixtures),
        ordered: false,
        timeout: 90_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {_output, 0}}, &1)), inspect(results)

    for fixture <- fixtures do
      assert File.regular?(Path.join(fixture, "_build/cold/lib/yamerl/ebin/yamerl.beam"))
    end
  end

  defp compile_yamerl(fixture) do
    System.cmd("mix", ["deps.compile", "yamerl", "--force"],
      cd: fixture,
      env: [
        {"HEX_OFFLINE", "1"},
        {"MIX_BUILD_PATH", "_build/cold"},
        {"ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1"}
      ],
      stderr_to_stdout: true
    )
  end

  defp write_yamerl_project!(root, fixture) do
    File.mkdir_p!(fixture)
    File.cp!(Path.join(root, "mix.exs"), Path.join(fixture, "mix.exs"))
    File.cp!(Path.join(root, "mix.lock"), Path.join(fixture, "mix.lock"))
  end
end

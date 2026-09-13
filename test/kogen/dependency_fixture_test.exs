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

  test "linked sources become private regular data and build caches remain excluded" do
    root = tmp_dir!()
    source = Path.join(root, "source")
    external = Path.join(root, "external")
    File.mkdir_p!(Path.join(source, "nested"))
    File.mkdir_p!(external)
    File.write!(Path.join(external, "file"), "source sentinel\n")
    File.write!(Path.join(external, "directory-file"), "directory sentinel\n")
    File.ln_s!(Path.join(external, "file"), Path.join(source, "linked-file"))
    File.ln_s!(external, Path.join(source, "linked-directory"))
    File.mkdir_p!(Path.join(source, "_build"))
    File.write!(Path.join(source, "_build/stale"), "cache")

    destination = Kogen.DependencyFixture.copy!(source, Path.join(root, "copy"))
    assert File.lstat!(Path.join(destination, "linked-file")).type == :regular
    assert File.lstat!(Path.join(destination, "linked-directory")).type == :directory
    refute File.exists?(Path.join(destination, "_build"))

    File.write!(Path.join(destination, "linked-file"), "private\n")
    File.write!(Path.join(destination, "linked-directory/directory-file"), "private directory\n")
    assert File.read!(Path.join(external, "file")) == "source sentinel\n"
    assert File.read!(Path.join(external, "directory-file")) == "directory sentinel\n"
  end

  test "every existing destination kind is rejected without mutation" do
    root = tmp_dir!()
    source = Path.join(root, "source")
    File.mkdir!(source)
    File.write!(Path.join(source, "fresh"), "fresh\n")

    destinations = [
      {"directory",
       fn path ->
         File.mkdir!(path)
         File.write!(Path.join(path, "sentinel"), "directory\n")
       end},
      {"file", fn path -> File.write!(path, "file\n") end}
    ]

    Enum.each(destinations, fn {name, prepare} ->
      destination = Path.join(root, name)
      prepare.(destination)
      before = snapshot(destination)

      assert_raise ArgumentError, ~r/destination already exists/, fn ->
        Kogen.DependencyFixture.copy!(source, destination)
      end

      assert snapshot(destination) == before
    end)

    target = Path.join(root, "target")
    File.mkdir!(target)
    File.write!(Path.join(target, "sentinel"), "target\n")

    for {name, link_target} <- [
          {"valid-link", target},
          {"dangling-link", Path.join(root, "missing")}
        ] do
      destination = Path.join(root, name)
      File.ln_s!(link_target, destination)

      assert_raise ArgumentError, ~r/destination already exists/, fn ->
        Kogen.DependencyFixture.copy!(source, destination)
      end

      assert File.lstat!(destination).type == :symlink
    end

    assert File.read!(Path.join(target, "sentinel")) == "target\n"
    refute File.exists?(Path.join(target, "fresh"))
  end

  test "invalid source links fail and remove only the newly owned partial copy" do
    root = tmp_dir!()

    for kind <- [:broken, :cyclic] do
      source = Path.join(root, Atom.to_string(kind))
      destination = Path.join(root, "#{kind}-copy")
      File.mkdir!(source)

      case kind do
        :broken -> File.ln_s!(Path.join(root, "absent"), Path.join(source, "link"))
        :cyclic -> File.ln_s!("link", Path.join(source, "link"))
      end

      assert_raise RuntimeError, ~r/dependency source copy failed/, fn ->
        Kogen.DependencyFixture.copy!(source, destination)
      end

      refute match?({:ok, _}, File.lstat(destination))
      assert File.lstat!(Path.join(source, "link")).type == :symlink
    end
  end

  test "a source read failure never returns or retains a partial fixture" do
    root = tmp_dir!()
    source = Path.join(root, "source-failure")
    destination = Path.join(root, "copy-failure")
    blocked = Path.join(source, "blocked")
    File.mkdir!(source)
    File.write!(blocked, "unreadable\n")
    File.chmod!(blocked, 0o000)
    on_exit(fn -> File.chmod(blocked, 0o600) end)

    assert_raise RuntimeError, ~r/dependency source copy failed/, fn ->
      Kogen.DependencyFixture.copy!(source, destination)
    end

    refute match?({:ok, _}, File.lstat(destination))
    assert File.lstat!(blocked).type == :regular
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

  defp tmp_dir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "kogen-dependency-copy-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp snapshot(path) do
    case File.lstat!(path).type do
      :directory ->
        {:directory, path |> File.ls!() |> Enum.sort(), File.read!(Path.join(path, "sentinel"))}

      :regular ->
        {:regular, File.read!(path)}
    end
  end
end

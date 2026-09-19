Code.require_file("../support/compiled_fixture.exs", __DIR__)

defmodule Kogen.CodexPublicTasksTest do
  use Kogen.IsolatedCase, async: true

  @source Path.expand("../..", __DIR__)

  test "fresh and continued public Shape stop for a missing managed runtime before native launch" do
    fixture = fixture!("codex-public-shape")
    on_exit(fn -> File.rm_rf(fixture) end)
    init_git!(fixture)
    write_draft!(fixture)
    write_draft!(fixture)
    trace = Path.join(fixture, "native.jsonl")
    env = [{"KOGEN_CODEX_ROOT", Path.join(fixture, "absent-managed")}, {"KOGEN_ROLE", ""}]

    for args <- [["kogen.shape"], ["kogen.shape", "unfinished"]] do
      {output, 1} = Kogen.CompiledFixture.mix_task!(fixture, args, env)
      assert output =~ "mix kogen.codex.install"
    end

    refute File.exists?(trace)
  end

  test "public Shape reports the selected project login without falling back to shared" do
    fixture = fixture!("codex-public-project")
    on_exit(fn -> File.rm_rf(fixture) end)
    init_git!(fixture)
    write_draft!(fixture)
    trace = Path.join(fixture, "native.jsonl")
    env = managed_env(fixture, trace)

    {_output, 130} =
      Kogen.CompiledFixture.mix_task!(
        fixture,
        ["kogen.codex.login", "--project", "--", "--cancel"],
        env
      )

    project_scope = native_calls(trace) |> List.last() |> Map.fetch!("scope")

    for args <- [["kogen.shape"], ["kogen.shape", "unfinished"]] do
      {output, 1} = Kogen.CompiledFixture.mix_task!(fixture, args, env)
      assert output =~ "Selected project Kogen login is not configured"
      assert output =~ "mix kogen.codex.login --project"
    end

    assert native_calls(trace) |> Enum.any?(&(&1["scope"] == project_scope))
    refute native_calls(trace) |> Enum.any?(&String.ends_with?(&1["scope"], "/shared"))
  end

  test "public Build retains ordinary preconditions and then reports missing managed readiness" do
    fixture = fixture!("codex-public-build")
    on_exit(fn -> File.rm_rf(fixture) end)
    init_git!(fixture)
    slug = write_build_package!(fixture)

    env = [{"KOGEN_CODEX_ROOT", Path.join(fixture, "absent-managed")}, {"KOGEN_ROLE", ""}]
    {output, 1} = Kogen.CompiledFixture.mix_task!(fixture, ["kogen.build", slug], env)
    assert output =~ "mix kogen.codex.install"
  end

  test "public Build names the selected project login when its retained credentials are missing" do
    fixture = fixture!("codex-public-build-project")
    on_exit(fn -> File.rm_rf(fixture) end)
    init_git!(fixture)
    slug = write_build_package!(fixture)
    trace = Path.join(fixture, "native.jsonl")
    env = managed_env(fixture, trace)

    {_output, 130} =
      Kogen.CompiledFixture.mix_task!(
        fixture,
        ["kogen.codex.login", "--project", "--", "--cancel"],
        env
      )

    {output, 1} = Kogen.CompiledFixture.mix_task!(fixture, ["kogen.build", slug], env)
    assert output =~ "Selected project Kogen login is not configured"
    assert output =~ "mix kogen.codex.login --project"
  end

  test "public login forwards native arguments, preserves separate scopes, and returns cancellation" do
    fixture = fixture!("codex-public-login")
    on_exit(fn -> File.rm_rf(fixture) end)
    init_git!(fixture)
    trace = Path.join(fixture, "native.jsonl")
    env = managed_env(fixture, trace)

    {_output, 0} =
      Kogen.CompiledFixture.mix_task!(fixture, ["kogen.codex.login", "--", "--help"], env)

    {_output, 130} =
      Kogen.CompiledFixture.mix_task!(
        fixture,
        ["kogen.codex.login", "--project", "--", "--cancel"],
        env
      )

    for scope <- [[], ["--project"]] do
      {_output, 7} =
        Kogen.CompiledFixture.mix_task!(
          fixture,
          ["kogen.codex.login"] ++ scope ++ ["--", "--device-auth"],
          env
        )
    end

    calls = native_calls(trace)
    assert Enum.count(calls, &(&1["native"] == ["--device-auth"])) == 2
    assert Enum.any?(calls, &(&1["native"] == ["--help"]))
    assert Enum.any?(calls, &(&1["native"] == ["--cancel"]))
    [shared, project] = Enum.map(calls, & &1["scope"]) |> Enum.uniq()
    refute shared == project
  end

  defp fixture!(label) do
    fixture = Kogen.CompiledFixture.create!(@source, label)
    File.write!(Path.join(fixture, ".gitignore"), "\n/managed/\n/native.jsonl\n", [:append])
    Kogen.VerificationFixture.install!(fixture)
    fixture
  end

  test "public native login preserves terminal stdin and writes only its selected scope" do
    fixture = fixture!("codex-login-pty")
    on_exit(fn -> File.rm_rf!(fixture) end)
    init_git!(fixture)
    trace = Path.join(fixture, "native.jsonl")
    env = managed_env(fixture, trace)

    command =
      ["elixir", "--erl", "+S 2:2 +SDcpu 1 +SDio 1"] ++
        (:code.get_path()
         |> Enum.map(&List.to_string/1)
         |> Enum.filter(&(Path.type(&1) == :absolute and Path.basename(&1) == "ebin"))
         |> Enum.sort()
         |> Enum.flat_map(&["-pa", &1])) ++
        ["-S", "mix", "kogen.codex.login", "--project", "--", "--with-api-key"]

    {output, 0} =
      System.cmd(
        "python3",
        [
          Path.join(@source, "test/support/codex_login_terminal_driver.py"),
          fixture,
          "synthetic-login-value" | command
        ],
        env: [{"MIX_BUILD_PATH", Path.join(fixture, "_build")} | env]
      )

    assert Jason.decode!(output)["status"] == 0, output
    [call] = native_calls(trace)
    assert call["tty"] == true
    assert call["stdin"] == "synthetic-login-value\n"
    assert File.read!(Path.join(call["scope"], "auth.json")) == "synthetic-login-value\n"
    refute File.exists?(Path.join([fixture, "managed", "accounts", "shared", "auth.json"]))
  end

  defp managed_env(fixture, trace) do
    root = Path.join(fixture, "managed")
    utility = Path.join(@source, "test/support/managed_codex_fixture.py")
    installer = Path.join(@source, "priv/kogen/codex/install.py")
    {_, 0} = System.cmd("python3", [utility, root, installer])

    [executable] =
      Path.wildcard(Path.join([root, "runtimes", "0.154.0-*", "vendor", "*", "bin", "codex"]))

    File.cp!(Path.join(@source, "test/support/codex_login_terminal.py"), executable)
    File.chmod!(executable, 0o755)
    runtime = executable |> Path.dirname() |> Path.dirname() |> Path.dirname() |> Path.dirname()

    rewrite_manifest!(installer, runtime)
    [{"KOGEN_CODEX_ROOT", root}, {"KOGEN_TEST_NATIVE_TRACE", trace}, {"KOGEN_ROLE", ""}]
  end

  defp rewrite_manifest!(installer, runtime) do
    code =
      "import importlib.util,pathlib,sys; s=importlib.util.spec_from_file_location('i',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); m._write_manifest(pathlib.Path(sys.argv[2]),'0.154.0',m.platform_name())"

    {_, 0} = System.cmd("python3", ["-c", code, installer, runtime])
  end

  defp init_git!(fixture) do
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: fixture)
    {_, 0} = System.cmd("git", ["add", "."], cd: fixture)

    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=Fixture",
          "-c",
          "user.email=fixture@example.invalid",
          "commit",
          "-qm",
          "fixture"
        ],
        cd: fixture
      )
  end

  defp write_draft!(fixture) do
    path = Path.join(fixture, ".kogen/intents/drafts/unfinished")
    File.mkdir_p!(path)

    File.write!(Path.join(path, "intent.yaml"), """
    id: 01960000-0000-7000-8000-000000000abc
    slug: unfinished
    shaped_against: {branch: main, head: placeholder}
    shaping: {harness: codex, model: fake, effort: low, started: '2026-01-01T00:00:00Z'}
    """)
  end

  defp write_build_package!(fixture) do
    slug = "managed-readiness"
    path = Path.join([fixture, ".kogen", "intents", "approved", slug])
    File.mkdir_p!(path)

    File.write!(Path.join(path, "intent.yaml"), """
    id: 01960000-0000-7000-8000-000000000def
    slug: #{slug}
    title: Managed readiness fixture
    may_change_guarded_paths:
      - lib/**
    """)

    File.write!(Path.join(path, "scenarios.yaml"), """
    - id: readiness
      given: a valid fixture and missing Kogen runtime
      when: the user starts Build
      then: Build names explicit managed-runtime setup
      wrong_result: Build launches a provider
      verified_by: [check]
      evidence: offline public-task fixture
      proof:
        offline: [test/kogen/focused_fixture_test.exs]
        paid_target: none
        paid_reason: "offline-sufficient: public task fixture observes admission failure"
        affected_paths: [lib/**]
    """)

    Kogen.VerificationFixture.install!(fixture)

    slug
  end

  defp native_calls(path) do
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end
end

defmodule Kogen.Codex.EnvironmentTest do
  use Kogen.IsolatedCase, async: true

  alias Kogen.Codex.Environment
  alias Kogen.Harness.Codex, as: CodexHarness

  test "prepares a private launch and removes inherited provider settings" do
    root = temporary_root!()
    old = System.get_env("OPENAI_API_KEY")
    System.put_env("OPENAI_API_KEY", "personal-key")

    on_exit(fn ->
      if old, do: System.put_env("OPENAI_API_KEY", old), else: System.delete_env("OPENAI_API_KEY")
      File.rm_rf(root)
    end)

    %{project: project, operation: operation, scope: scope} = paths!(root)
    credentials = Path.join(scope.path, "auth.json")
    sessions = Path.join(scope.path, "sessions.bin")
    File.write!(credentials, <<0, 1, 2, 3>>)
    File.write!(sessions, "retained native session")

    result =
      Environment.prepare(
        %{"executable" => "/managed/codex"},
        scope,
        profiles(),
        project,
        operation
      )

    assert result.executable == "/managed/codex"
    assert {"OPENAI_API_KEY", nil} in result.env
    assert {"CODEX_HOME", scope.path} in result.env
    assert {"KOGEN_ENV_RESTORE_PENDING", "1"} in result.env

    assert ["--disable", "apps", "--disable", "plugins", "--disable", "shell_snapshot" | _] =
             result.args

    assert "cli_auth_credentials_store=\"file\"" in result.args
    assert File.dir?(scope.path)

    homes = for {"HOME", path} <- result.env, do: path
    assert [home] = homes
    assert home != System.get_env("HOME")
    assert File.regular?(Path.join(Path.dirname(home), "scout.toml"))
    definition = Path.join([scope.path, "agents", "kogen_boundary.toml"])
    assert File.read!(definition) =~ "built-in helper roles remain authoritative"
    assert File.read!(credentials) == <<0, 1, 2, 3>>
    assert File.read!(sessions) == "retained native session"
  end

  test "native bookkeeping survives launches while foreign settings are refused on resume" do
    root = temporary_root!()
    on_exit(fn -> File.rm_rf(root) end)
    %{project: project, operation: operation, scope: scope} = paths!(root)
    settings = Path.join(scope.path, "config.toml")
    credentials = Path.join(scope.path, "auth.json")
    sessions = Path.join(scope.path, "sessions.bin")
    File.write!(credentials, "synthetic account")
    File.write!(sessions, "retained session")

    bytes = """
    [projects."/another/project"]
    trust_level = "trusted"
    [tui]
    screen_reader_detection_done = true
    [tui.model_availability_nux]
    "gpt-5.6-sol" = 1
    """

    File.write!(settings, bytes)

    context =
      Environment.prepare(
        %{"executable" => "/managed/codex"},
        scope,
        profiles(),
        project,
        operation
      )

    assert ~s(projects."/another/project".trust_level="untrusted") in context.args
    assert File.read!(settings) == bytes

    for hostile <- [
          "model = 'personal'",
          "[mcp_servers.hostile]\ncommand = 'hostile'",
          "[projects.\"/another/project\"]\ntrust_level = 'trusted'\nextra = true",
          "[tui.model_availability_nux]\nmodel = true",
          "[tui]\nnotifications = ['command']",
          "[tui]\nscreen_reader_detection_done = 'yes'",
          "not valid TOML"
        ] do
      File.write!(settings, hostile)

      assert_raise RuntimeError, ~r/unexpected discovery settings/, fn ->
        Environment.prepare(
          %{"executable" => "/managed/codex"},
          scope,
          profiles(),
          project,
          operation
        )
      end

      assert File.read!(settings) == hostile
      assert File.read!(credentials) == "synthetic account"
      assert File.read!(sessions) == "retained session"
    end

    File.rm!(settings)
    File.ln_s!(credentials, settings)

    assert_raise RuntimeError, ~r/unexpected discovery settings/, fn ->
      Environment.prepare(
        %{"executable" => "/managed/codex"},
        scope,
        profiles(),
        project,
        operation
      )
    end

    assert File.read!(credentials) == "synthetic account"
  end

  test "each preparation has an immutable generation while state remains operation owned" do
    root = temporary_root!()
    on_exit(fn -> File.rm_rf(root) end)
    %{project: project, operation: invocation, scope: scope} = paths!(root)

    first =
      Environment.prepare(%{"executable" => "codex"}, scope, profiles(), project, invocation)

    second =
      Environment.prepare(%{"executable" => "codex"}, scope, profiles(), project, invocation)

    first_home = value!(first.env, "HOME")
    second_home = value!(second.env, "HOME")
    refute first_home == second_home
    assert value!(first.env, "SQLITE_HOME") == value!(second.env, "SQLITE_HOME")
    assert File.regular?(Path.join(Path.dirname(first_home), "worker.toml"))
    assert File.regular?(Path.join(Path.dirname(second_home), "worker.toml"))

    changed = put_in(profiles().helpers.worker.model, "different-worker")
    third = Environment.prepare(%{"executable" => "codex"}, scope, changed, project, invocation)
    assert File.read!(Path.join(Path.dirname(first_home), "worker.toml")) =~ "terra"

    assert File.read!(Path.join(Path.dirname(value!(third.env, "HOME")), "worker.toml")) =~
             "different-worker"
  end

  test "the tracked codex route writes the exact GPT-6 helper profiles" do
    root = temporary_root!()
    on_exit(fn -> File.rm_rf(root) end)
    %{project: project, operation: operation, scope: scope} = paths!(root)
    assert {:ok, config} = Kogen.Intent.read_config(".kogen/config.yaml", "codex")
    result = Environment.prepare(%{"executable" => "codex"}, scope, config, project, operation)
    generation = Path.dirname(value!(result.env, "HOME"))

    expected = %{
      "scout" => {"gpt-6-luna", "low"},
      "worker" => {"gpt-6-luna", "high"},
      "expert" => {"gpt-6-sol", "high"}
    }

    for {role, {model, effort}} <- expected do
      path = Path.join(generation, "#{role}.toml")

      assert File.read!(path) ==
               "model = \"#{model}\"\nmodel_reasoning_effort = \"#{effort}\"\n"

      assert "agents.#{role}.config_file=#{Jason.encode!(path)}" in result.args
    end
  end

  test "concurrent preparations receive distinct private generations" do
    root = temporary_root!()
    on_exit(fn -> File.rm_rf(root) end)
    %{project: project, operation: invocation, scope: scope} = paths!(root)

    homes =
      1..8
      |> Task.async_stream(
        fn _ ->
          Environment.prepare(%{"executable" => "codex"}, scope, profiles(), project, invocation)
          |> Map.fetch!(:env)
          |> value!("HOME")
        end,
        max_concurrency: 8,
        ordered: false
      )
      |> Enum.map(fn {:ok, home} -> home end)

    assert length(homes) == length(Enum.uniq(homes))
  end

  test "uses a static named executor registry and an immutable dispatcher snapshot" do
    root = temporary_root!()
    on_exit(fn -> File.rm_rf(root) end)
    %{project: project, operation: invocation, scope: scope} = paths!(root)
    receipt = Path.join(root, "executor-environment")
    native = Path.join(root, "native")

    File.write!(native, "#!/bin/sh\nenv > \"$KOGEN_EXECUTOR_RECEIPT\"\n")
    File.chmod!(native, 0o700)

    caller = %{
      "HOME" => "/caller-home",
      "XDG_CONFIG_HOME" => "/caller-config",
      "XDG_DATA_HOME" => "",
      "XDG_CACHE_HOME" => nil,
      "XDG_STATE_HOME" => nil,
      "KOGEN_CODEX_EXECUTOR_ENTRYPOINT" => "/personal/executor",
      "KOGEN_CODEX_EXECUTABLE" => "/personal/codex",
      "KOGEN_CODEX_EXECUTOR_LAUNCH_MARKER" => "personal",
      "KOGEN_EXECUTOR_RECEIPT" => receipt
    }

    context =
      Environment.prepare(
        %{"executable" => native},
        scope,
        profiles(),
        project,
        invocation,
        caller
      )

    entrypoint = value!(context.env, "KOGEN_CODEX_EXECUTOR_ENTRYPOINT")
    registry = Path.join(scope.path, "environments.toml")

    assert File.regular?(entrypoint)
    assert File.stat!(entrypoint).mode |> Bitwise.band(0o777) == 0o700

    assert File.read!(registry) ==
             """
             default = "kogen"
             include_local = false
             [[environments]]
             id = "kogen"
             program = "/bin/sh"
             args = ["-c", "exec \\"${KOGEN_CODEX_EXECUTOR_ENTRYPOINT:?missing managed launch context}\\""]
             """

    refute File.read!(registry) =~ project
    refute File.read!(registry) =~ native
    assert value!(context.env, "KOGEN_CODEX_EXECUTABLE") == native
    assert value!(context.env, "KOGEN_CODEX_EXECUTOR_LAUNCH_MARKER") == "1"

    assert {_output, 0} = System.cmd(entrypoint, [], env: context.env)
    environment = File.read!(receipt)

    assert environment =~ "HOME=/caller-home\n"
    assert environment =~ "XDG_CONFIG_HOME=/caller-config\n"
    assert environment =~ "XDG_DATA_HOME=\n"
    refute environment =~ "XDG_CACHE_HOME="
    refute environment =~ "XDG_STATE_HOME="
    assert environment =~ "CODEX_HOME=#{scope.path}\n"

    File.write!(registry, "foreign registry\n")

    assert_raise RuntimeError, ~r/incompatible managed executor registry/, fn ->
      Environment.prepare(
        %{"executable" => native},
        scope,
        profiles(),
        project,
        invocation,
        caller
      )
    end
  end

  test "refuses a symlink where private invocation state would be created" do
    root = temporary_root!()
    on_exit(fn -> File.rm_rf(root) end)
    %{project: project, operation: invocation, scope: scope} = paths!(root)
    target = Path.join(root, "outside")
    File.mkdir_p!(target)
    File.ln_s!(target, Path.join(invocation, "generations"))

    assert_raise RuntimeError, ~r/unexpected occupant/, fn ->
      Environment.prepare(%{"executable" => "codex"}, scope, profiles(), project, invocation)
    end
  end

  test "the direct restoration helper preserves unset XDG semantics" do
    hook = Path.expand("../../.codex/hooks/environment.py", __DIR__)

    script =
      "import importlib.util, json, os; spec=importlib.util.spec_from_file_location('e', #{inspect(hook)}); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); m.restore_environment(); print(json.dumps({'home': os.getenv('HOME'), 'config': os.getenv('XDG_CONFIG_HOME'), 'data': os.getenv('XDG_DATA_HOME'), 'cache': os.getenv('XDG_CACHE_HOME'), 'codex': os.getenv('CODEX_HOME')}))"

    {output, 0} =
      System.cmd("python3", ["-c", script],
        env: [
          {"KOGEN_ENV_RESTORE_PENDING", "1"},
          {"KOGEN_CALLER_HOME", "/caller"},
          {"KOGEN_CALLER_XDG_CONFIG_HOME", "/caller/config"},
          {"KOGEN_CALLER_XDG_CONFIG_HOME_ABSENT", nil},
          {"KOGEN_CALLER_XDG_CONFIG_HOME_EMPTY", nil},
          {"KOGEN_CALLER_XDG_DATA_HOME_ABSENT", "1"},
          {"KOGEN_CALLER_XDG_DATA_HOME_EMPTY", nil},
          {"KOGEN_CALLER_XDG_CACHE_HOME_EMPTY", "1"},
          {"KOGEN_CALLER_XDG_CACHE_HOME_ABSENT", nil},
          {"HOME", "/private"},
          {"XDG_CONFIG_HOME", "/private/config"},
          {"XDG_DATA_HOME", "/private/data"},
          {"CODEX_HOME", "/kogen/scope"}
        ]
      )

    assert %{
             "home" => "/caller",
             "config" => "/caller/config",
             "data" => nil,
             "cache" => "",
             "codex" => "/kogen/scope"
           } =
             Jason.decode!(output)
  end

  test "retained launch context is JSON-safe and the managed resume consumer preserves argv and environment" do
    root = temporary_root!()
    on_exit(fn -> File.rm_rf(root) end)
    %{project: project, operation: operation, scope: scope} = paths!(root)
    context_path = Path.join(root, "launch-context.json")
    receipt = Path.join(root, "dispatch-receipt")
    native = Path.join(root, "native")

    File.write!(
      native,
      "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$KOGEN_CONTEXT_DISPATCH_RECEIPT\"\nprintf 'config=<%s>\\nopenai=<%s>\\nrole=<%s>\\n' \"${XDG_CONFIG_HOME-unset}\" \"${OPENAI_API_KEY-unset}\" \"${KOGEN_ROLE-unset}\" >> \"$KOGEN_CONTEXT_DISPATCH_RECEIPT\"\n"
    )

    File.chmod!(native, 0o700)

    context =
      Environment.prepare(
        %{"executable" => native},
        scope,
        profiles(),
        project,
        operation,
        %{
          "HOME" => "/caller",
          "XDG_CONFIG_HOME" => "",
          "KOGEN_ROLE" => "developer",
          "KOGEN_CONTEXT_DISPATCH_RECEIPT" => receipt,
          "KOGEN_CODEX_CONTEXT_RECEIPT" => context_path
        }
      )

    decoded = context_path |> File.read!() |> Jason.decode!()
    assert is_list(decoded["env"])
    assert Enum.all?(decoded["env"], &(is_list(&1) and length(&1) == 2))

    assert context.env
           |> Enum.any?(&(&1 == {"XDG_CONFIG_HOME", value!(context.env, "XDG_CONFIG_HOME")}))

    consumer = Path.expand("../support/shaping_evaluation/managed_resume.py", __DIR__)

    assert {_output, 0} =
             System.cmd("python3", [consumer, context_path, "resume-token"],
               env: [{"KOGEN_ROLE", "shaper"}]
             )

    dispatch = File.read!(receipt)
    assert dispatch =~ "resume-token\n"
    assert dispatch =~ "config=<#{value!(context.env, "XDG_CONFIG_HOME")}>\n"
    assert dispatch =~ "openai=<unset>\n"
    assert dispatch =~ "role=<shaper>\n"
    assert decoded["env"] |> Enum.any?(&(&1 == ["KOGEN_ROLE", "developer"]))
  end

  test "a :setup preparation writes no helper-profile files and emits no agents.* args" do
    root = temporary_root!()
    on_exit(fn -> File.rm_rf(root) end)
    %{project: project, operation: operation, scope: scope} = paths!(root)

    context =
      Environment.prepare(%{"executable" => "codex"}, scope, :setup, project, operation)

    generation_dir =
      root
      |> Path.join("operation/generations")
      |> File.ls!()
      |> List.first()

    generation = Path.join([root, "operation/generations", generation_dir])
    refute File.exists?(Path.join(generation, "scout.toml"))
    refute File.exists?(Path.join(generation, "worker.toml"))
    refute File.exists?(Path.join(generation, "expert.toml"))
    refute Enum.any?(context.args, &String.starts_with?(&1, "agents."))
  end

  test "a role launch with incomplete helper profiles fails loudly instead of writing empty ones" do
    root = temporary_root!()
    on_exit(fn -> File.rm_rf(root) end)
    %{project: project, operation: operation, scope: scope} = paths!(root)
    incomplete = put_in(profiles().helpers.worker.model, "")

    assert_raise ArgumentError,
                 "Codex role launch requires a complete helpers.worker profile (model and effort)",
                 fn ->
                   Environment.prepare(
                     %{"executable" => "codex"},
                     scope,
                     incomplete,
                     project,
                     operation
                   )
                 end

    missing_effort = put_in(profiles(), [:helpers, :expert], %{model: "astra"})

    assert_raise ArgumentError,
                 "Codex role launch requires a complete helpers.expert profile (model and effort)",
                 fn ->
                   Environment.prepare(
                     %{"executable" => "codex"},
                     scope,
                     missing_effort,
                     project,
                     operation
                   )
                 end
  end

  test "every Codex role and helper launch carries exactly one central tool output limit" do
    root = temporary_root!()
    on_exit(fn -> File.rm_rf(root) end)
    %{project: project, operation: operation, scope: scope} = paths!(root)
    home = Path.join(root, "caller-home")
    caller = %{"HOME" => home}

    context =
      Environment.prepare(
        %{"executable" => "codex"},
        scope,
        profiles(),
        project,
        operation,
        caller
      )

    generation = Path.dirname(value!(context.env, "HOME"))
    toml = &Jason.encode!/1

    base =
      [
        "cli_auth_credentials_store=\"file\"",
        "check_for_update_on_startup=false",
        "project_root_markers=[\".git\"]",
        "projects.#{toml.(project)}.trust_level=\"trusted\"",
        "shell_environment_policy.inherit=\"all\"",
        "shell_environment_policy.exclude=[\"XDG_CONFIG_HOME\", \"XDG_DATA_HOME\", \"XDG_CACHE_HOME\", \"XDG_STATE_HOME\"]",
        "shell_environment_policy.set.HOME=#{toml.(home)}",
        "shell_environment_policy.experimental_use_profile=false",
        "sqlite_home=#{toml.(Path.join([operation, "state", "sqlite"]))}",
        "tool_output_token_limit=4000"
      ]
      |> Enum.flat_map(&["-c", &1])

    prefix =
      ["--disable", "apps", "--disable", "plugins", "--disable", "shell_snapshot"] ++ base

    # Existing arguments keep their values and relative order; the limit sits
    # in the central list before the per-helper profile arguments.
    assert Enum.take(context.args, length(prefix)) == prefix
    helper_args = Enum.drop(context.args, length(prefix))

    assert Enum.map(Enum.chunk_every(helper_args, 2), fn ["-c", setting] ->
             setting |> String.split("=", parts: 2) |> hd()
           end) == [
             "agents.scout.config_file",
             "agents.scout.description",
             "agents.worker.config_file",
             "agents.worker.description",
             "agents.expert.config_file",
             "agents.expert.description"
           ]

    for role <- ~w(scout worker expert) do
      assert "agents.#{role}.config_file=#{toml.(Path.join(generation, "#{role}.toml"))}" in helper_args
    end

    # Native helpers are spawned by the root Codex process and inherit its -c
    # overrides, so each root launch carries the one limit for its helpers.
    launches = %{
      "shaping" => CodexHarness.shaper_args("astra", "low", write_prompt!(root)),
      "developer" => CodexHarness.developer_args("astra", "low"),
      "developer resume" => CodexHarness.developer_args("astra", "low", "session-1"),
      "reviewer" => CodexHarness.reviewer_args("astra", "low")
    }

    for {role, role_args} <- launches do
      argv = context.args ++ role_args
      assert limit_count(argv) == 1, role
      assert "tool_output_token_limit=4000" not in role_args, role
    end

    # A setup (login) preparation uses the same central list.
    setup = Environment.prepare(%{"executable" => "codex"}, scope, :setup, project, operation)
    assert limit_count(setup.args) == 1
  end

  defp limit_count(argv) do
    argv
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(&(&1 == ["-c", "tool_output_token_limit=4000"]))
  end

  defp write_prompt!(root) do
    path = Path.join(root, "shaping-prompt.md")
    File.write!(path, "shape\n")
    path
  end

  defp profiles do
    %{
      shaping: %{model: "astra", effort: "low"},
      developer: %{model: "astra", effort: "low"},
      reviewer: %{model: "astra", effort: "low"},
      helpers: %{
        scout: %{model: "luna", effort: "low"},
        worker: %{model: "terra", effort: "medium"},
        expert: %{model: "astra", effort: "medium"}
      }
    }
  end

  defp value!(env, name),
    do: Enum.find_value(env, fn {key, value} -> if key == name, do: value end)

  defp temporary_root! do
    path = Path.join(System.tmp_dir!(), "kogen-environment-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp paths!(root) do
    project = Path.join(root, "project")
    operation = Path.join(root, "operation")
    scope_path = Path.join(root, "scope")

    for path <- [project, operation, scope_path], do: File.mkdir_p!(path)
    File.write!(Path.join(scope_path, ".kogen-owned"), "account-v1\n")
    %{project: project, operation: operation, scope: %{name: :shared, path: scope_path}}
  end
end

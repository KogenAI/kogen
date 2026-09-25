Code.require_file("../support/native_helper_fixture.ex", __DIR__)
Code.require_file("../support/route_config.ex", __DIR__)

defmodule Kogen.NativeHelperLiveTest do
  @moduledoc false
  use Kogen.IsolatedCase, async: true

  alias Kogen.NativeHelperFixture
  alias Kogen.RouteConfig
  alias Mix.Tasks.Kogen.Expert

  @moduletag :live
  @moduletag timeout: 1_200_000

  test "a bounded fresh native dispatch records actual child routing evidence" do
    config = RouteConfig.codex_route!()
    project_root = File.cwd!()
    log_dir = log_dir!(project_root)
    fixture = fixture_dir!(project_root)
    previous_raw_log_dir = System.get_env("KOGEN_RAW_LOG_DIR")

    assert {:ok, managed} = Kogen.Codex.open(config, project_root)

    on_exit(fn -> File.rm_rf!(fixture) end)
    on_exit(fn -> Kogen.Codex.close(managed) end)
    on_exit(fn -> restore_env("KOGEN_RAW_LOG_DIR", previous_raw_log_dir) end)

    fixture = setup_fixture!(fixture)
    protocol = NativeHelperFixture.protocol(config, "developer")
    prompt = NativeHelperFixture.prompt(config, "developer")
    File.write!(Path.join(log_dir, "protocol.json"), Jason.encode!(protocol) <> "\n")
    File.write!(Path.join(log_dir, "parent-prompt.md"), prompt)
    System.put_env("KOGEN_RAW_LOG_DIR", log_dir)

    File.cd!(Path.dirname(fixture), fn ->
      context = managed |> Map.put(:project, fixture) |> Kogen.Codex.launch_context()

      assert {:ok, %{session_id: parent_id}} =
               Kogen.Harness.launch_developer(
                 prompt,
                 config.developer.model,
                 config.developer.effort,
                 [],
                 context
               )

      receipt =
        NativeHelperFixture.collect_receipt!(
          Path.join(managed.scope.path, "sessions"),
          Path.join(log_dir, "raw"),
          parent_id,
          fixture,
          protocol
        )

      File.write!(Path.join(log_dir, "native-receipt.json"), Jason.encode!(receipt) <> "\n")
      assert :ok = NativeHelperFixture.validate_receipt(receipt, protocol)
    end)
  end

  # The real cross-harness role boundary on the named Claude-dominant route:
  # the Developer's frozen KOGEN_EXPERT assignment drives `mix kogen.expert`
  # as a subprocess (stdin question, as a Claude Developer really runs it),
  # running on managed Codex; the Codex session store proves the executed
  # model and effort of the fresh session.
  @hybrid_route "claude-dominant-adversarial-codex"

  test "the hybrid route's Codex Expert runs on its assigned harness with its exact profile" do
    project_root = File.cwd!()
    log_dir = log_dir!(project_root)
    {:ok, route} = Kogen.Intent.read_config(".kogen/config.yaml", @hybrid_route)

    assert Kogen.Intent.role_harness(route, :developer) == "claude"
    assert Kogen.Intent.role_harness(route, :expert) == "codex"

    [{"KOGEN_EXPERT", json}] = Kogen.Harness.expert_environment(route, :developer)
    assert {:ok, %{harness: "codex"}} = Expert.assignment(json)
    {:ok, scope} = Kogen.Codex.effective_scope(project_root)
    sessions = Path.join(scope.path, "sessions")

    nonce =
      "KOGEN-EXPERT-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"

    question = "Answer with exactly the text #{nonce} and do nothing else."
    {output, status} = expert_subprocess!(project_root, json, question)
    File.write!(Path.join(log_dir, "expert-subprocess.log"), output)
    assert status == 0, output
    assert output =~ nonce

    expert_session = session_containing!(sessions, nonce)

    receipt = %{
      "route" => route.route,
      "caller" => %{"role" => "developer", "harness" => "claude"},
      "expert" => %{
        "harness" => "codex",
        "launch" => "mix kogen.expert (subprocess, KOGEN_EXPERT, stdin)",
        "requested" => [route.expert.model, route.expert.effort],
        "session_id" => expert_session.id,
        "executed" => executed_profiles(expert_session.file)
      }
    }

    File.write!(Path.join(log_dir, "cross-harness-expert.json"), Jason.encode!(receipt) <> "\n")
    assert receipt["expert"]["executed"] == [[route.expert.model, route.expert.effort]]
  end

  # Runs the real task in a separate OS process with only the frozen
  # assignment; the question arrives on stdin.
  defp expert_subprocess!(project_root, assignment, question) do
    elixir = System.find_executable("elixir") || raise "elixir executable not found"

    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.flat_map(&["-pa", &1])

    System.cmd(
      "sh",
      ["-c", ~s(printf '%s' "$KOGEN_EXPERT_QUESTION" | exec "$@"), "sh", elixir] ++
        code_paths ++ ["-S", "mix", "kogen.expert"],
      cd: project_root,
      env: [
        {"MIX_ENV", "test"},
        {"KOGEN_EXPERT", assignment},
        {"KOGEN_EXPERT_QUESTION", question},
        {"KOGEN_ROLE", "developer"}
      ],
      stderr_to_stdout: true
    )
  end

  defp session_containing!(sessions, nonce) do
    matches =
      sessions
      |> Path.join("**/*.jsonl")
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ nonce))

    assert [file] = matches,
           "expected exactly one Codex session with #{nonce}: #{inspect(matches)}"

    id =
      file
      |> File.stream!()
      |> Enum.find_value(fn line ->
        case Jason.decode(line) do
          {:ok, %{"type" => "session_meta", "payload" => %{"id" => id}}} -> id
          _ -> nil
        end
      end)

    %{file: file, id: id}
  end

  defp executed_profiles(session_file) do
    session_file
    |> File.stream!()
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"type" => "turn_context", "payload" => %{"model" => model} = payload}} ->
          [[model, payload["effort"]]]

        _ ->
          []
      end
    end)
    |> Enum.uniq()
  end

  defp log_dir!(project_root) do
    base =
      System.get_env("KOGEN_LIVE_LOG_DIR") ||
        Path.join(project_root, ".kogen/runtime/live-evidence")

    dir =
      Path.join(
        Path.expand(base, project_root),
        "native-helper-#{System.pid()}-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
      )

    File.mkdir_p!(dir)
    dir
  end

  defp fixture_dir!(project_root) do
    root = Path.join(project_root, ".kogen/runtime/live-native-helper")
    File.mkdir_p!(root)

    dir =
      Path.join(
        root,
        "fixture-#{System.pid()}-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
      )

    File.mkdir_p!(dir)
    dir
  end

  defp setup_fixture!(root) do
    fixture = NativeHelperFixture.write_fixture!(root)
    File.write!(Path.join(root, "README.md"), "Bounded native helper routing fixture\n")
    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: root)
    fixture
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end

Code.require_file("../support/native_helper_fixture.ex", __DIR__)

defmodule Kogen.NativeHelperLiveTest do
  @moduledoc false
  use Kogen.IsolatedCase, async: true

  alias Kogen.NativeHelperFixture

  @moduletag :live
  @moduletag timeout: 600_000

  test "a bounded fresh native dispatch records actual child routing evidence" do
    {:ok, config} = Kogen.Intent.read_config()
    project_root = File.cwd!()
    log_dir = log_dir!(project_root)
    fixture = fixture_dir!(project_root)
    previous_raw_log_dir = System.get_env("KOGEN_RAW_LOG_DIR")

    on_exit(fn -> File.rm_rf!(fixture) end)
    on_exit(fn -> restore_env("KOGEN_RAW_LOG_DIR", previous_raw_log_dir) end)

    fixture = setup_fixture!(fixture)
    protocol = NativeHelperFixture.protocol(config, "developer")
    prompt = NativeHelperFixture.prompt(config, "developer")
    File.write!(Path.join(log_dir, "protocol.json"), Jason.encode!(protocol) <> "\n")
    File.write!(Path.join(log_dir, "parent-prompt.md"), prompt)
    System.put_env("KOGEN_RAW_LOG_DIR", log_dir)

    File.cd!(Path.dirname(fixture), fn ->
      assert {:ok, %{session_id: parent_id}} =
               Kogen.Harness.launch_developer(
                 prompt,
                 config.developer.model,
                 config.developer.effort,
                 []
               )

      receipt =
        NativeHelperFixture.collect_receipt!(
          Path.join(
            System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex"),
            "sessions"
          ),
          Path.join(log_dir, "raw"),
          parent_id,
          fixture,
          protocol
        )

      File.write!(Path.join(log_dir, "native-receipt.json"), Jason.encode!(receipt) <> "\n")
      assert :ok = NativeHelperFixture.validate_receipt(receipt, protocol)
    end)
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

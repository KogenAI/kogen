defmodule Kogen.UnifiedStateAdmissionTest do
  use ExUnit.Case, async: true

  alias Kogen.Build.Verification

  @session "unified-admission-session"

  test "production initializer and hook reject deleted, corrupt, rolled back, and terminal state before dispatch" do
    root = fixture!()
    on_exit(fn -> File.rm_rf!(root) end)

    for mutation <- [:deleted, :corrupt, :rollback, :exhausted, :deleted_exhausted] do
      File.rm(Path.join(root, "dispatches"))
      tracking = Path.join(root, ".kogen/runtime/scenario-tracking/#{mutation}/record.json")

      assert {:ok, execution} =
               Verification.initialize(
                 tracking,
                 "token-#{mutation}",
                 0,
                 ["check"],
                 2
               )

      File.write!(Path.join(root, "mode"), "fail\n")
      assert dispatches(root) == 0
      assert response(root, execution) =~ ~s("decision":"block")
      assert dispatches(root) == 1
      first_state = File.read!(execution.state_path)

      assert response(root, execution) =~ ~s("decision":"block")
      assert dispatches(root) == 2

      case mutation do
        :deleted ->
          File.rm!(execution.state_path)

        :corrupt ->
          File.write!(execution.state_path, "not-json\n")

        :rollback ->
          File.write!(execution.state_path, first_state)

        :exhausted ->
          assert response(root, execution) =~ ~s("continue":false)

        :deleted_exhausted ->
          assert response(root, execution) =~ ~s("continue":false)
          File.rm!(execution.state_path)
      end

      before_replay = dispatches(root)
      replay = response(root, execution)
      assert replay =~ ~s("continue":false)
      assert dispatches(root) == before_replay
      assert File.read!(execution.context["history_path"]) != ""
    end
  end

  test "initialized state permits ordinary repair and a complete pass" do
    root = fixture!()
    on_exit(fn -> File.rm_rf!(root) end)
    tracking = Path.join(root, ".kogen/runtime/scenario-tracking/repair/record.json")

    {:ok, execution} = Verification.initialize(tracking, "repair-token", 0, ["check"], 2)

    File.write!(Path.join(root, "mode"), "fail\n")
    assert response(root, execution) =~ ~s("decision":"block")
    File.write!(Path.join(root, "mode"), "pass\n")
    assert response(root, execution) == "{\"continue\":true}\n"
    assert dispatches(root) == 2
  end

  defp response(root, execution) do
    input = Path.join(root, "input.json")
    File.write!(input, Jason.encode!(%{"session_id" => @session}))

    {output, 0} =
      System.cmd("sh", ["-c", "sh .codex/hooks/check.sh < input.json"],
        cd: root,
        env: [
          {"KOGEN_ROLE", "developer"},
          {"KOGEN_VERIFICATION_CONTEXT", execution.context_path},
          {"KOGEN_TRACKING_CONTEXT", ""}
        ],
        stderr_to_stdout: true
      )

    output
  end

  defp dispatches(root) do
    case File.read(Path.join(root, "dispatches")) do
      {:ok, value} -> value |> String.split("\n", trim: true) |> length()
      {:error, :enoent} -> 0
    end
  end

  defp fixture! do
    root =
      Path.join(
        System.tmp_dir!(),
        "kogen-unified-admission-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, ".codex/hooks"))
    File.cp!(".codex/hooks/check.sh", Path.join(root, ".codex/hooks/check.sh"))
    File.cp!(".codex/hooks/stop_runner.py", Path.join(root, ".codex/hooks/stop_runner.py"))
    File.write!(Path.join(root, ".gitignore"), ".kogen/runtime/\ndispatches\nmode\ninput.json\n")
    File.write!(Path.join(root, "README.md"), "fixture\n")

    File.write!(
      Path.join(root, "Makefile"),
      "check:\n\t@echo check >> dispatches\n\t@grep -q '^pass' mode\n"
    )

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: root)
    {_, 0} = System.cmd("git", ["config", "user.name", "Fixture"], cd: root)
    {_, 0} = System.cmd("git", ["config", "user.email", "fixture@example.invalid"], cd: root)
    {_, 0} = System.cmd("git", ["add", "-A"], cd: root)
    {_, 0} = System.cmd("git", ["commit", "-qm", "baseline"], cd: root)
    root
  end
end

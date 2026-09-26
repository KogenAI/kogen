defmodule Kogen.UnifiedStateAdmissionTest do
  use ExUnit.Case, async: true

  @session "unified-admission-session"

  test "production initializer and hook reject deleted, corrupt, rolled back, and terminal state before dispatch" do
    root = fixture!()
    on_exit(fn -> File.rm_rf!(root) end)

    for mutation <- [:deleted, :corrupt, :rollback, :exhausted, :deleted_exhausted] do
      File.rm(Path.join(root, "dispatches"))

      execution =
        initialize!(root, "#{mutation}", "token-#{mutation}", 0, ["check"], 2)

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
      assert File.read!(execution.history_path) != ""
    end
  end

  test "initialized state permits ordinary repair and a complete pass" do
    root = fixture!()
    on_exit(fn -> File.rm_rf!(root) end)

    execution = initialize!(root, "repair", "repair-token", 0, ["check"], 2)

    File.write!(Path.join(root, "mode"), "fail\n")
    assert response(root, execution) =~ ~s("decision":"block")
    File.write!(Path.join(root, "mode"), "pass\n")
    assert response(root, execution) == "{\"continue\":true}\n"
    assert dispatches(root) == 2
  end

  # Builds the same v1 unified verification context, initial state and
  # chronology that `Kogen.Build.Verification.initialize/6` writes today (see
  # `git show HEAD:lib/kogen/build/verification.ex`). That controller module
  # is being rewritten concurrently, so this test drives the v1 hook protocol
  # directly rather than depending on it.
  defp initialize!(root, build_id, token, outer_attempt, targets, retries) do
    directory =
      Path.join([
        root,
        ".kogen/runtime/scenario-tracking/#{build_id}",
        "verification",
        "attempt-#{outer_attempt}-#{token}"
      ])

    context_path = Path.join(directory, "context.json")
    state_path = Path.join(directory, "state.json")
    history_path = Path.join(directory, "state-history.jsonl")
    log_root = Path.join(directory, "logs")

    context = %{
      "schema_version" => 1,
      "mode" => "unified",
      "build_id" => build_id,
      "outer_attempt" => outer_attempt,
      "attempt_token" => token,
      "project_root" => root,
      "targets" => targets,
      "verification_retries" => retries,
      "state_path" => Path.expand(state_path),
      "history_path" => Path.expand(history_path),
      "log_root" => Path.expand(log_root),
      "plan" => nil
    }

    bytes = Jason.encode!(context) <> "\n"

    initial_state = %{
      "schema_version" => 1,
      "context_sha256" => sha256(bytes),
      "attempt_token" => token,
      "outer_attempt" => outer_attempt,
      "developer_session_id" => nil,
      "candidate_id" => nil,
      "cycles" => [],
      "failures_since_pass" => 0,
      "terminal_state" => "pending"
    }

    initial_bytes = Jason.encode!(initial_state) <> "\n"

    File.mkdir_p!(directory)
    File.mkdir_p!(log_root)
    File.write!(context_path, bytes)
    File.write!(state_path, initial_bytes)
    File.write!(history_path, initial_bytes)

    %{
      context_path: Path.expand(context_path),
      state_path: Path.expand(state_path),
      history_path: Path.expand(history_path)
    }
  end

  defp sha256(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  defp response(root, execution) do
    input = Path.join(root, "input.json")
    File.write!(input, Jason.encode!(%{"session_id" => @session}))

    {output, 0} =
      System.cmd("sh", ["-c", "sh .codex/hooks/check.sh < input.json"],
        cd: root,
        env: [
          {"KOGEN_ROLE", "developer"},
          {"KOGEN_VERIFICATION_CONTEXT", execution.context_path}
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

    for hook <- ["check.sh", "environment.py", "stop_runner.py"] do
      File.cp!(Path.join(".codex/hooks", hook), Path.join(root, ".codex/hooks/#{hook}"))
    end

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

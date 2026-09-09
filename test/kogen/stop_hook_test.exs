defmodule Kogen.StopHookTest do
  use ExUnit.Case, async: true

  @session_id "developer-thread-123"

  test "production Stop hook blocks then records a passing staged ignored Candidate in a spaced path" do
    in_fixture!(fn dir ->
      hook = Path.join(dir, ".codex/hooks/check.sh")

      assert {block, 0} = run_hook(hook, dir)
      assert block =~ ~s("decision":"block")

      failed = verification(dir)
      assert failed["status"] == "failed"
      assert failed["exit_code"] == 1
      assert failed["session_id"] == @session_id

      File.write!(Path.join(dir, "proof-fixed.txt"), "HOOK-PASS\n")
      assert {_output, 0} = System.cmd("git", ["add", "-f", "ignored-candidate.txt"], cd: dir)

      assert {"{\"continue\":true}\n", 0} = run_hook(hook, dir)

      passed = verification(dir)
      assert passed["status"] == "passed"
      assert passed["exit_code"] == 0
      assert passed["session_id"] == @session_id
      assert passed["candidate"] != failed["candidate"]

      assert {_, 0} =
               System.cmd(
                 "git",
                 ["cat-file", "-e", "#{passed["candidate"]}:ignored-candidate.txt"],
                 cd: dir
               )
    end)
  end

  test "production Stop hook blocks rather than accepting a missing Developer session id" do
    in_fixture!(fn dir ->
      hook = Path.join(dir, ".codex/hooks/check.sh")

      assert {block, 0} = run_hook(hook, dir, nil)
      assert block =~ "did not receive the Developer session id"
      refute File.exists?(Path.join(dir, ".kogen/runtime/verification.json"))
    end)
  end

  test "production Stop hook round-trips quotes, backslashes, and every shell-representable control byte" do
    in_fixture!(fn dir ->
      hook = Path.join(dir, ".codex/hooks/check.sh")
      controls = Enum.map_join(1..31, &<<&1>>)
      expected_prefix = "quote\" slash\\" <> controls

      encoded_controls =
        Enum.map_join(1..31, fn code ->
          "\\#{String.pad_leading(Integer.to_string(code, 8), 3, "0")}"
        end)

      encoded_prefix = "quote\" slash\\\\" <> encoded_controls

      File.write!(
        Path.join(dir, "Makefile"),
        "check:\n\t@printf '%b' '#{encoded_prefix}'\n\t@false\n"
      )

      assert {block, 0} = run_hook(hook, dir)
      assert block =~ ~s("decision":"block")

      reason = verification(dir)["reason"]
      assert String.starts_with?(reason, expected_prefix)

      assert reason ==
               dir
               |> Path.join(".kogen/runtime/stop-check.log")
               |> File.read!()
               |> String.trim_trailing("\n")
    end)
  end

  test "Shaping Controller and Reviewer Stop events do not run the Developer check" do
    in_fixture!(fn dir ->
      hook = Path.join(dir, ".codex/hooks/check.sh")

      for role <- ["shaper", "reviewer"] do
        assert {"{\"continue\":true}\n", 0} = run_hook(hook, dir, nil, role)
        refute File.exists?(Path.join(dir, ".kogen/runtime/verification.json"))
        refute File.exists?(Path.join(dir, ".kogen/runtime/stop-check.log"))
      end
    end)
  end

  defp run_hook(_hook, dir, session_id \\ @session_id, role \\ "developer") do
    input_path = Path.join(dir, "hook-input.json")
    input = if session_id, do: Jason.encode!(%{"session_id" => session_id}), else: "{}"
    File.write!(input_path, input)
    hooks = Path.join(dir, ".codex/hooks.json") |> File.read!() |> Jason.decode!()
    command = get_in(hooks, ["hooks", "Stop", Access.at(0), "hooks", Access.at(0), "command"])

    System.cmd("sh", ["-c", command <> " < \"$1\"", "--", input_path],
      cd: dir,
      env: [{"KOGEN_ROLE", role}],
      stderr_to_stdout: true
    )
  end

  defp verification(dir) do
    dir
    |> Path.join(".kogen/runtime/verification.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp in_fixture!(fun) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen stop hook #{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(dir, ".codex/hooks"))
    on_exit(fn -> File.rm_rf(dir) end)

    source_hook = Path.join(__DIR__, "../../.codex/hooks/check.sh")
    destination_hook = Path.join(dir, ".codex/hooks/check.sh")
    File.copy!(source_hook, destination_hook)
    File.copy!(Path.join(__DIR__, "../../.codex/hooks.json"), Path.join(dir, ".codex/hooks.json"))
    File.chmod!(destination_hook, 0o755)

    File.write!(Path.join(dir, "README.md"), "fixture\n")
    File.write!(Path.join(dir, ".gitignore"), "ignored-candidate.txt\n.kogen/runtime/\n")
    File.write!(Path.join(dir, "ignored-candidate.txt"), "force staged candidate\n")

    File.write!(
      Path.join(dir, "Makefile"),
      "check:\n\t@test -f proof-fixed.txt\n\t@test \"$$(cat proof-fixed.txt)\" = \"HOOK-PASS\"\n"
    )

    assert {_output, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: dir)
    assert {_output, 0} = System.cmd("git", ["add", "README.md"], cd: dir)

    assert {_output, 0} =
             System.cmd("git", ["commit", "-q", "-m", "baseline"],
               cd: dir,
               env: git_identity()
             )

    fun.(dir)
  end

  defp git_identity do
    [
      {"GIT_AUTHOR_NAME", "Kogen Fixture"},
      {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Fixture"},
      {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
    ]
  end
end

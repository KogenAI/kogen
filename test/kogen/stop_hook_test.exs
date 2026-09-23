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

  for {flag, label} <- [
        {"--assume-unchanged", "assume-unchanged"},
        {"--skip-worktree", "skip-worktree"}
      ] do
    test "production Stop hook refuses a #{label} index flag without changing the real index" do
      in_fixture!(fn dir ->
        hook = Path.join(dir, ".codex/hooks/check.sh")
        readme = Path.join(dir, "README.md")
        File.write!(readme, "changed behind the flag\n")
        File.write!(Path.join(dir, "Makefile"), "check:\n\t@touch check-ran\n")

        assert {_output, 0} =
                 System.cmd("git", ["update-index", unquote(flag), "README.md"], cd: dir)

        assert {index_before, 0} = System.cmd("git", ["write-tree"], cd: dir)
        assert {flag_before, 0} = System.cmd("git", ["ls-files", "-v", "README.md"], cd: dir)

        assert {block, 0} = run_hook(hook, dir)
        assert block =~ ~s("decision":"block")

        failed = verification(dir)
        assert failed["status"] == "failed"
        assert failed["candidate"] == ""
        assert failed["reason"] =~ "Candidate identity refused"
        assert failed["reason"] =~ unquote(label)
        refute File.exists?(Path.join(dir, "check-ran"))
        assert {^index_before, 0} = System.cmd("git", ["write-tree"], cd: dir)
        assert {^flag_before, 0} = System.cmd("git", ["ls-files", "-v", "README.md"], cd: dir)
      end)
    end
  end

  test "Claude Code settings register the unchanged Stop hook, which blocks then passes on Claude Code Stop input" do
    in_fixture!(fn dir ->
      settings =
        Path.join(__DIR__, "../../priv/kogen/claude_code/settings.json")
        |> File.read!()
        |> Jason.decode!()

      codex = Path.join(dir, ".codex/hooks.json") |> File.read!() |> Jason.decode!()
      [claude_stop] = get_in(settings, ["hooks", "Stop", Access.at(0), "hooks"])
      [codex_stop] = get_in(codex, ["hooks", "Stop", Access.at(0), "hooks"])
      assert claude_stop["command"] == codex_stop["command"]

      [pre] = get_in(settings, ["hooks", "PreToolUse"])
      [codex_pre] = get_in(codex, ["hooks", "PreToolUse"])
      assert pre == codex_pre

      input =
        Jason.encode!(%{
          "session_id" => @session_id,
          "transcript_path" => Path.join(dir, "transcript.jsonl"),
          "cwd" => dir,
          "hook_event_name" => "Stop",
          "stop_hook_active" => false
        })

      assert {block, 0} = run_command(claude_stop["command"], dir, input)
      assert Jason.decode!(block)["decision"] == "block"
      assert verification(dir)["status"] == "failed"

      File.write!(Path.join(dir, "proof-fixed.txt"), "HOOK-PASS\n")
      assert {"{\"continue\":true}\n", 0} = run_command(claude_stop["command"], dir, input)
      assert verification(dir)["session_id"] == @session_id
    end)
  end

  defp run_command(command, dir, input) do
    input_path = Path.join(dir, "claude-hook-input.json")
    File.write!(input_path, input)

    System.cmd("sh", ["-c", command <> " < \"$1\"", "--", input_path],
      cd: dir,
      env: [
        {"KOGEN_ROLE", "developer"},
        {"KOGEN_VERIFICATION_CONTEXT", ""},
        {"KOGEN_TRACKING_CONTEXT", ""}
      ],
      stderr_to_stdout: true
    )
  end

  defp run_hook(_hook, dir, session_id \\ @session_id, role \\ "developer") do
    input_path = Path.join(dir, "hook-input.json")
    input = if session_id, do: Jason.encode!(%{"session_id" => session_id}), else: "{}"
    File.write!(input_path, input)
    hooks = Path.join(dir, ".codex/hooks.json") |> File.read!() |> Jason.decode!()
    command = get_in(hooks, ["hooks", "Stop", Access.at(0), "hooks", Access.at(0), "command"])

    System.cmd("sh", ["-c", command <> " < \"$1\"", "--", input_path],
      cd: dir,
      # The parent process may itself be a Build Developer with a bound unified
      # context. This standalone fixture exercises the legacy/unbound hook path
      # in its own repository, so do not leak the parent's binding into it.
      env: [
        {"KOGEN_ROLE", role},
        {"KOGEN_VERIFICATION_CONTEXT", ""},
        {"KOGEN_TRACKING_CONTEXT", ""}
      ],
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

    File.copy!(
      Path.join(__DIR__, "../../.codex/hooks/stop_runner.py"),
      Path.join(dir, ".codex/hooks/stop_runner.py")
    )

    File.cp!(
      Path.join(__DIR__, "../../.codex/hooks/environment.py"),
      Path.join(dir, ".codex/hooks/environment.py")
    )

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

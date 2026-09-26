defmodule Kogen.StopHookTest do
  use ExUnit.Case, async: true

  @session_id "developer-thread-123"

  test "production Stop hook blocks then records a passing staged ignored Candidate in a spaced path" do
    in_fixture!(fn dir ->
      hook = Path.join(dir, ".codex/hooks/check.sh")
      ctx = write_v1_context!(dir)

      assert {block, 0} = run_hook(hook, dir, ctx)
      assert block =~ ~s("decision":"block")
      assert dispatches(dir) == 1

      failed = verification(dir)
      assert failed["status"] == "failed"
      assert failed["exit_code"] != 0
      assert failed["session_id"] == @session_id

      File.write!(Path.join(dir, "mode"), "pass\n")
      assert {_output, 0} = System.cmd("git", ["add", "-f", "ignored-candidate.txt"], cd: dir)

      assert {"{\"continue\":true}\n", 0} = run_hook(hook, dir, ctx)
      assert dispatches(dir) == 2

      passed = verification(dir)
      assert passed["status"] == "passed"
      assert passed["exit_code"] == 0
      assert passed["session_id"] == @session_id
      assert passed["candidate"] != failed["candidate"]

      state = Jason.decode!(File.read!(ctx.state_path))
      assert length(state["cycles"]) == 2
      assert Enum.map(state["cycles"], & &1["status"]) == ["failed", "passed"]

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
      ctx = write_v1_context!(dir)

      assert {block, 0} = run_hook(hook, dir, ctx, nil)
      assert block =~ "did not receive the Developer session id"
      refute File.exists?(Path.join(dir, ".kogen/runtime/verification.json"))
      assert dispatches(dir) == 0
    end)
  end

  test "production Stop hook round-trips quotes, backslashes, and every shell-representable control byte" do
    in_fixture!(fn dir ->
      hook = Path.join(dir, ".codex/hooks/check.sh")
      ctx = write_v1_context!(dir)
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

      assert {block, 0} = run_hook(hook, dir, ctx)
      assert block =~ ~s("decision":"block")

      reason = verification(dir)["reason"]
      assert String.starts_with?(reason, expected_prefix)

      assert String.trim_trailing(reason, "\n") ==
               dir
               |> Path.join(".kogen/runtime/stop-check.log")
               |> File.read!()
               |> String.trim_trailing("\n")
    end)
  end

  test "Shaping Controller and Reviewer Stop events do not run the Developer check" do
    in_fixture!(fn dir ->
      hook = Path.join(dir, ".codex/hooks/check.sh")
      ctx = write_v1_context!(dir)

      for role <- ["shaper", "reviewer"] do
        assert {"{\"continue\":true}\n", 0} = run_hook(hook, dir, ctx, nil, role)
        refute File.exists?(Path.join(dir, ".kogen/runtime/verification.json"))
        refute File.exists?(Path.join(dir, ".kogen/runtime/stop-check.log"))
        assert dispatches(dir) == 0
      end
    end)
  end

  test "Stop hook takes no action without a v1 unified verification context" do
    in_fixture!(fn dir ->
      hook = Path.join(dir, ".codex/hooks/check.sh")

      # (a) no context at all.
      assert {"{\"continue\":true}\n", 0} =
               run_hook_with_env(hook, dir, [{"KOGEN_VERIFICATION_CONTEXT", nil}])

      refute File.exists?(Path.join(dir, ".kogen/runtime"))
      assert dispatches(dir) == 0

      # (a) an empty context value.
      assert {"{\"continue\":true}\n", 0} =
               run_hook_with_env(hook, dir, [{"KOGEN_VERIFICATION_CONTEXT", ""}])

      refute File.exists?(Path.join(dir, ".kogen/runtime"))
      assert dispatches(dir) == 0

      # (a) a non-v1 context (schema_version 2).
      non_v1_path = Path.join(dir, "non-v1-context.json")

      File.write!(
        non_v1_path,
        Jason.encode!(%{"schema_version" => 2, "mode" => "unified"})
      )

      assert {"{\"continue\":true}\n", 0} =
               run_hook_with_env(hook, dir, [{"KOGEN_VERIFICATION_CONTEXT", non_v1_path}])

      refute File.exists?(Path.join(dir, ".kogen/runtime"))
      assert dispatches(dir) == 0

      # (a) the legacy KOGEN_TRACKING_CONTEXT path is gone: it is never read,
      # so a Developer Stop with only that set still just continues.
      legacy_path = Path.join(dir, "legacy-context.json")
      File.write!(legacy_path, Jason.encode!(%{"verification_targets" => ["check"]}))

      assert {"{\"continue\":true}\n", 0} =
               run_hook_with_env(hook, dir, [
                 {"KOGEN_VERIFICATION_CONTEXT", nil},
                 {"KOGEN_TRACKING_CONTEXT", legacy_path}
               ])

      refute File.exists?(Path.join(dir, ".kogen/runtime"))
      assert dispatches(dir) == 0
    end)
  end

  test "a valid v1 unified context runs the controller-selected target and settles pass and fail cycles" do
    in_fixture!(fn dir ->
      hook = Path.join(dir, ".codex/hooks/check.sh")
      ctx = write_v1_context!(dir)

      assert {~s({"decision":"block") <> _, 0} = run_hook(hook, dir, ctx)
      assert dispatches(dir) == 1
      assert File.exists?(Path.join(dir, ".kogen/runtime"))

      File.write!(Path.join(dir, "mode"), "pass\n")

      assert {"{\"continue\":true}\n", 0} = run_hook(hook, dir, ctx)
      assert dispatches(dir) == 2

      state = Jason.decode!(File.read!(ctx.state_path))
      assert state["terminal_state"] == "passed"
      assert length(state["cycles"]) == 2
    end)
  end

  for {flag, label} <- [
        {"--assume-unchanged", "assume-unchanged"},
        {"--skip-worktree", "skip-worktree"}
      ] do
    test "production Stop hook refuses a #{label} index flag without changing the real index" do
      in_fixture!(fn dir ->
        hook = Path.join(dir, ".codex/hooks/check.sh")
        ctx = write_v1_context!(dir)
        readme = Path.join(dir, "README.md")
        File.write!(readme, "changed behind the flag\n")

        assert {_output, 0} =
                 System.cmd("git", ["update-index", unquote(flag), "README.md"], cd: dir)

        assert {index_before, 0} = System.cmd("git", ["write-tree"], cd: dir)
        assert {flag_before, 0} = System.cmd("git", ["ls-files", "-v", "README.md"], cd: dir)

        state_before = File.read!(ctx.state_path)

        assert {block, 0} = run_hook(hook, dir, ctx)
        decoded = Jason.decode!(block)
        assert decoded["continue"] == false
        assert decoded["stopReason"] =~ "Candidate identity refused"
        assert decoded["stopReason"] =~ unquote(label)

        assert dispatches(dir) == 0
        assert File.read!(ctx.state_path) == state_before
        refute File.exists?(Path.join(dir, ".kogen/runtime/verification.json"))
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

      ctx = write_v1_context!(dir)

      input =
        Jason.encode!(%{
          "session_id" => @session_id,
          "transcript_path" => Path.join(dir, "transcript.jsonl"),
          "cwd" => dir,
          "hook_event_name" => "Stop",
          "stop_hook_active" => false
        })

      assert {block, 0} = run_command(claude_stop["command"], dir, input, ctx)
      assert Jason.decode!(block)["decision"] == "block"
      assert verification(dir)["status"] == "failed"

      File.write!(Path.join(dir, "mode"), "pass\n")
      assert {"{\"continue\":true}\n", 0} = run_command(claude_stop["command"], dir, input, ctx)
      assert verification(dir)["session_id"] == @session_id
    end)
  end

  defp run_command(command, dir, input, ctx) do
    input_path = Path.join(dir, "claude-hook-input.json")
    File.write!(input_path, input)

    System.cmd("sh", ["-c", command <> " < \"$1\"", "--", input_path],
      cd: dir,
      env: [
        {"KOGEN_ROLE", "developer"},
        {"KOGEN_VERIFICATION_CONTEXT", ctx.context_path}
      ],
      stderr_to_stdout: true
    )
  end

  defp run_hook(_hook, dir, ctx, session_id \\ @session_id, role \\ "developer") do
    extra = if ctx, do: [{"KOGEN_VERIFICATION_CONTEXT", ctx.context_path}], else: []
    run_hook_with_env_and_session(dir, extra, session_id, role)
  end

  defp run_hook_with_env(_hook, dir, env) do
    run_hook_with_env_and_session(dir, env, @session_id, "developer")
  end

  defp run_hook_with_env_and_session(dir, extra_env, session_id, role) do
    input_path = Path.join(dir, "hook-input.json")
    input = if session_id, do: Jason.encode!(%{"session_id" => session_id}), else: "{}"
    File.write!(input_path, input)
    hooks = Path.join(dir, ".codex/hooks.json") |> File.read!() |> Jason.decode!()
    command = get_in(hooks, ["hooks", "Stop", Access.at(0), "hooks", Access.at(0), "command"])

    System.cmd("sh", ["-c", command <> " < \"$1\"", "--", input_path],
      cd: dir,
      # The parent process may itself be a Build Developer with a bound unified
      # context. This standalone fixture exercises this hook in its own
      # repository, so do not leak the parent's binding into it; only the
      # environment this test sets explicitly is present.
      env: [{"KOGEN_ROLE", role} | extra_env],
      stderr_to_stdout: true
    )
  end

  defp verification(dir) do
    dir
    |> Path.join(".kogen/runtime/verification.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp dispatches(dir) do
    case File.read(Path.join(dir, "dispatches")) do
      {:ok, value} -> value |> String.split("\n", trim: true) |> length()
      {:error, :enoent} -> 0
    end
  end

  # Builds a v1 unified verification context, plus its initial pending state
  # and chronology, in the same shape and location
  # `Kogen.Build.Verification.initialize/6` writes today (see `git show
  # HEAD:lib/kogen/build/verification.ex`). The controller module itself is
  # being rewritten concurrently, so this fixture builds the protocol bytes
  # directly rather than calling it.
  defp write_v1_context!(dir, opts \\ []) do
    targets = Keyword.get(opts, :targets, ["check"])
    outer_attempt = Keyword.get(opts, :outer_attempt, 0)
    token = Keyword.get(opts, :token, "attempt-token-1")
    retries = Keyword.get(opts, :retries, 2)

    build_dir = Path.join(dir, ".kogen/runtime/scenario-tracking/build-1")
    directory = Path.join([build_dir, "verification", "attempt-#{outer_attempt}-#{token}"])
    context_path = Path.join(directory, "context.json")
    state_path = Path.join(directory, "state.json")
    history_path = Path.join(directory, "state-history.jsonl")
    log_root = Path.join(directory, "logs")

    context = %{
      "schema_version" => 1,
      "mode" => "unified",
      "build_id" => "build-1",
      "outer_attempt" => outer_attempt,
      "attempt_token" => token,
      "project_root" => dir,
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

    File.write!(
      Path.join(dir, ".gitignore"),
      "ignored-candidate.txt\n.kogen/runtime/\ndispatches\nmode\n"
    )

    File.write!(Path.join(dir, "ignored-candidate.txt"), "force staged candidate\n")
    File.write!(Path.join(dir, "mode"), "fail\n")

    # A counting fake Make target: every real invocation appends a line to
    # `dispatches` (git-ignored, outside `.kogen/runtime`), so tests can prove
    # exactly how many times, if any, `check` actually ran.
    File.write!(
      Path.join(dir, "Makefile"),
      "check:\n\t@echo check >> dispatches\n\t@grep -q '^pass' mode\n"
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

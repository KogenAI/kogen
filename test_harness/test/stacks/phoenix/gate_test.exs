defmodule CodegenTestHarness.Stacks.Phoenix.GateTest do
  @moduledoc """
  Gate contract for the phoenix stack.

  Asserts that `codegen-build --stack=phoenix` exit code reflects the
  dev-gate verdict: exit 0 means a committed, compilable app was produced.
  Mirrors the exit-code assertion shape of scaffold_test.exs.
  """

  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 6_600_000

  @prompt ~s(Build a Phoenix LiveView todo app. The router MUST have ) <>
            ~s(live "/", TodoLive, :index. TodoLive MUST render a ) <>
            ~s(<form id="new-todo-form"> with an <input name="todo[title]"> ) <>
            ~s(and a <button data-testid="add-todo">.)

  setup do
    {:ok, cwd: Fixtures.isolated_tmp_dir(stack: :phoenix)}
  end

  test "codegen-build exit 0 implies committed compilable phoenix app", %{cwd: cwd} do
    output =
      Fixtures.run_codegen_build(cwd, @prompt, stack: "phoenix", test_name: "gate_phoenix_exit0")

    assert File.exists?(Path.join(cwd, "mix.exs")),
           "expected mix.exs in #{cwd}\n--- output ---\n#{output}"

    Assertions.assert_mix_compiles!(cwd)
    Assertions.assert_generated_tests_pass!(cwd)
    Assertions.assert_git_committed!(cwd)

    live_files =
      cwd
      |> Path.join("lib/*_web/live/**/*.ex")
      |> Path.wildcard()

    assert live_files != [],
           "expected at least one LiveView file under lib/*_web/live/ in #{cwd}"

    router_files = Path.wildcard(Path.join(cwd, "lib/*_web/router.ex"))
    assert router_files != [], "no router.ex found under lib/*_web/ in #{cwd}"
    [router | _] = router_files
    Assertions.assert_router_root_route_replaced!(router)
    Assertions.assert_renders!(cwd, :phoenix)

    # Structured gate-result.json must be produced by the dev-gate hook
    gate_result_path = Path.join(cwd, "codegen/gate-pending/gate-result.json")

    assert File.exists?(gate_result_path),
           "expected gate-result.json at #{gate_result_path} — dev-gate hook must write structured result"

    gate_result = gate_result_path |> File.read!() |> Jason.decode!()

    assert gate_result["verdict"] == "clear",
           "expected gate-result.json verdict=clear, got: #{inspect(gate_result["verdict"])}"

    assert is_binary(gate_result["gate"]) and gate_result["gate"] != "",
           "expected gate-result.json gate field to be non-empty string"

    Fixtures.bench_assertions_passed!("phoenix", "gate_phoenix_exit0")
  end

  test "phoenix gate failure writes non-clear verdict", %{cwd: cwd} do
    hook = Path.join(File.cwd!(), "../harnesses/claude/hooks/phoenix-dev-gate.sh")
    hook = Path.expand(hook)

    # Scaffold a minimal committed phoenix app so the hook has a real project_dir
    File.write!(Path.join(cwd, "mix.exs"), "# placeholder")
    File.mkdir_p!(Path.join(cwd, "codegen/logging"))

    {_output, 0} =
      System.cmd("git", ["add", "."], cd: cwd, stderr_to_stdout: true)

    {_output, 0} =
      System.cmd("git", ["commit", "-m", "init app"],
        cd: cwd,
        stderr_to_stdout: true,
        env: [
          {"GIT_AUTHOR_NAME", "t"},
          {"GIT_AUTHOR_EMAIL", "t@t"},
          {"GIT_COMMITTER_NAME", "t"},
          {"GIT_COMMITTER_EMAIL", "t@t"}
        ]
      )

    # Write a step log whose Gate is `false` — deterministic failure
    log_path =
      Path.join(
        cwd,
        "codegen/logging/#{DateTime.utc_now() |> Calendar.strftime("%Y%m%d_%H%M%S")}_step1_fail.md"
      )

    File.write!(log_path, """
    # Step

    ## Plan

    **Gate**: `false`
    """)

    transcript_path = Path.join(cwd, "transcript.jsonl")

    File.write!(
      transcript_path,
      Jason.encode!(%{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{"type" => "tool_use", "name" => "Write", "input" => %{"file_path" => log_path}}
          ]
        }
      }) <> "\n"
    )

    input =
      Jason.encode!(%{
        "hook_event_name" => "SubagentStop",
        "agent_type" => "developer-phoenix-backend",
        "agent_id" => "abc",
        "session_id" => "test-failure-phoenix",
        "cwd" => cwd,
        "stop_hook_active" => false,
        "transcript_path" => transcript_path
      })

    {_out, _rc} =
      System.cmd("bash", ["-c", "printf '%s' \"$INPUT\" | bash \"$HOOK\""],
        cd: cwd,
        stderr_to_stdout: true,
        env: [{"INPUT", input}, {"HOOK", hook}]
      )

    gate_result_path = Path.join(cwd, "codegen/gate-pending/gate-result.json")

    assert File.exists?(gate_result_path),
           "expected gate-result.json at #{gate_result_path} after forced gate failure"

    gate_result = gate_result_path |> File.read!() |> Jason.decode!()

    assert gate_result["verdict"] != "clear",
           "expected gate-result.json verdict != clear after forced failure, got: #{inspect(gate_result["verdict"])}"
  end
end

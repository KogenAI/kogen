defmodule CodegenTestHarness.OrchestrationLoopTest do
  use ExUnit.Case, async: true

  alias CodegenTestHarness.OrchestrationLoop

  @phoenix_sequence ~w(planner-phoenix developer-phoenix-backend reviewer-phoenix context-curator committer)
  @static_sequence ~w(developer-static reviewer-static context-curator committer)

  describe "role_sequence/1" do
    test "phoenix is plan-first" do
      assert OrchestrationLoop.role_sequence("phoenix") == @phoenix_sequence
    end

    test "static is developer-first" do
      assert OrchestrationLoop.role_sequence("static") == @static_sequence
    end

    test "unknown stack raises" do
      assert_raise RuntimeError, ~r/unknown stack/, fn ->
        OrchestrationLoop.role_sequence("bogus")
      end
    end
  end

  # Stub invoke_fn: always succeeds, records call order in an Agent.
  defp always_ok_invoke_fn(calls_agent) do
    fn role, _harness, _ctx, _opts ->
      Agent.update(calls_agent, fn calls -> calls ++ [role] end)
      {:ok, %{"status" => "success", "value" => "did #{role}"}}
    end
  end

  defp always_clear_gate_fn do
    fn _cwd, _opts -> {:clear, "make test"} end
  end

  setup do
    {:ok, calls_agent} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(calls_agent), do: Agent.stop(calls_agent) end)
    {:ok, calls_agent: calls_agent}
  end

  describe "run/1 — sequence order" do
    test "phoenix sequence invokes all roles in order on success", %{calls_agent: calls_agent} do
      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "phoenix",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: always_clear_gate_fn()
               )

      assert Agent.get(calls_agent, & &1) == @phoenix_sequence
    end

    test "static sequence invokes all roles in order on success", %{calls_agent: calls_agent} do
      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: always_clear_gate_fn()
               )

      assert Agent.get(calls_agent, & &1) == @static_sequence
    end
  end

  describe "run/1 — role failure handling" do
    test "role fails once then succeeds on retry — cycle still completes", %{
      calls_agent: calls_agent
    } do
      {:ok, fail_once_agent} = Agent.start_link(fn -> MapSet.new() end)
      on_exit(fn -> if Process.alive?(fail_once_agent), do: Agent.stop(fail_once_agent) end)

      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        already_failed = Agent.get(fail_once_agent, &MapSet.member?(&1, role))

        if role == "reviewer-static" and not already_failed do
          Agent.update(fail_once_agent, &MapSet.put(&1, role))
          {:error, "transient blip"}
        else
          {:ok, %{"status" => "success"}}
        end
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 gate_fn: always_clear_gate_fn()
               )

      # reviewer-static was invoked twice (fail then retry-succeed)
      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "reviewer-static")) == 2
    end

    test "role fails twice in a row → {:error, reason}, non-zero (no silent continue)" do
      invoke_fn = fn _role, _harness, _ctx, _opts -> {:error, "deterministic failure"} end

      assert {:error, reason} =
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 gate_fn: always_clear_gate_fn()
               )

      assert reason =~ "failed twice"
    end

    test "codegen-call status=failed maps to {:error, reason} via invoke_role/4" do
      codegen_call_fn = fn _harness, _model, _effort, _sp, _tools, _prompt ->
        %{"result" => %{"status" => "failed", "reason" => "boom", "value" => nil}}
      end

      resolve_fn = fn _role, _harness -> {"/tmp/sp.txt", "sonnet", "medium", "Bash"} end

      assert {:error, "boom"} =
               OrchestrationLoop.invoke_role(
                 "developer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 codegen_call_fn: codegen_call_fn
               )
    end

    test "codegen-call unexpected envelope shape raises (crash loud)" do
      codegen_call_fn = fn _harness, _model, _effort, _sp, _tools, _prompt ->
        %{"unexpected" => "shape"}
      end

      resolve_fn = fn _role, _harness -> {"/tmp/sp.txt", "sonnet", "medium", "Bash"} end

      assert_raise RuntimeError, ~r/unexpected codegen-call envelope/, fn ->
        OrchestrationLoop.invoke_role(
          "developer-static",
          "claude_code",
          %{cwd: "/tmp", pitch: "x", artifacts: %{}},
          resolve_fn: resolve_fn,
          codegen_call_fn: codegen_call_fn
        )
      end
    end
  end

  describe "run/1 — gate handling" do
    test "gate verdict=failed → developer re-run within budget, then success on retry", %{
      calls_agent: calls_agent
    } do
      {:ok, gate_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(gate_calls_agent), do: Agent.stop(gate_calls_agent) end)

      gate_fn = fn _cwd, _opts ->
        n = Agent.get_and_update(gate_calls_agent, fn n -> {n, n + 1} end)
        if n == 0, do: {:failed, "make test"}, else: {:clear, "make test"}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: gate_fn
               )

      # developer-static invoked twice: once initially, once after gate=failed retry
      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "developer-static")) == 2
    end

    test "gate verdict stays failed past budget → {:error, reason}, non-zero", %{
      calls_agent: calls_agent
    } do
      gate_fn = fn _cwd, _opts -> {:failed, "make test"} end

      assert {:error, reason} =
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: gate_fn
               )

      assert reason =~ "gate verdict=failed"
    end

    test "gate verdict=inconclusive is treated the same as failed (retried, then error)", %{
      calls_agent: calls_agent
    } do
      gate_fn = fn _cwd, _opts -> {:inconclusive, "make test"} end

      assert {:error, reason} =
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: gate_fn
               )

      assert reason =~ "gate verdict=inconclusive"
    end
  end

  describe "COMMITTED terminal" do
    test "full static run reaching committer with clear gate returns :ok (terminal)", %{
      calls_agent: calls_agent
    } do
      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: always_clear_gate_fn()
               )

      assert List.last(Agent.get(calls_agent, & &1)) == "committer"
    end
  end

  describe "run/1 — cycle-state advancement" do
    test "advances GATED → REVIEWED → CURATED → COMMITTED in order for static stack", %{
      calls_agent: calls_agent
    } do
      {:ok, states_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(states_agent), do: Agent.stop(states_agent) end)

      advance_fn = fn state, _step_log, _session_id, _verdict, _project_dir ->
        Agent.update(states_agent, fn states -> states ++ [state] end)
        :ok
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: always_clear_gate_fn(),
                 advance_cycle_state_fn: advance_fn
               )

      assert Agent.get(states_agent, & &1) == ["GATED", "REVIEWED", "CURATED", "COMMITTED"]
    end

    test "GATED write carries verdict=clear; later states carry empty verdict" do
      {:ok, calls_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(calls_agent), do: Agent.stop(calls_agent) end)

      {:ok, verdicts_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(verdicts_agent), do: Agent.stop(verdicts_agent) end)

      advance_fn = fn state, _step_log, _session_id, verdict, _project_dir ->
        Agent.update(verdicts_agent, fn v -> v ++ [{state, verdict}] end)
        :ok
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: always_clear_gate_fn(),
                 advance_cycle_state_fn: advance_fn
               )

      assert Agent.get(verdicts_agent, & &1) == [
               {"GATED", "clear"},
               {"REVIEWED", ""},
               {"CURATED", ""},
               {"COMMITTED", ""}
             ]
    end
  end

  describe "run/1 — format step" do
    test "runs format step after developer role and after curator role", %{
      calls_agent: calls_agent
    } do
      {:ok, format_calls_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(format_calls_agent), do: Agent.stop(format_calls_agent) end)

      format_fn = fn cwd ->
        Agent.update(format_calls_agent, fn calls -> calls ++ [cwd] end)
        :ok
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: always_clear_gate_fn(),
                 format_fn: format_fn
               )

      # developer-static (pre-gate) + context-curator (pre-commit) = 2 format calls
      assert Agent.get(format_calls_agent, & &1) == ["/tmp/irrelevant", "/tmp/irrelevant"]
    end
  end

  describe "guard_bundle_flag!/2 — B-bucket guard bundle wiring" do
    setup do
      dir = Path.join(System.tmp_dir!(), "guard_bundle_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "claude_code returns --settings=@<path> when the settings file exists", %{dir: dir} do
      settings_path = Path.join(dir, "claude-code-settings.json")
      File.write!(settings_path, "{}")

      assert OrchestrationLoop.guard_bundle_flag!("claude_code", claude_settings_path: settings_path) ==
               ["--settings=@#{settings_path}"]
    end

    test "claude_code raises when the settings file is absent (refuse to run unguarded)", %{
      dir: dir
    } do
      missing_path = Path.join(dir, "nope-settings.json")

      assert_raise RuntimeError, ~r/claude settings bundle not found.*refusing to run a role unguarded/, fn ->
        OrchestrationLoop.guard_bundle_flag!("claude_code", claude_settings_path: missing_path)
      end
    end

    test "pi returns --extension=@<path> when the extension dir exists", %{dir: dir} do
      ext_dir = Path.join(dir, "enforcement")
      File.mkdir_p!(ext_dir)

      assert OrchestrationLoop.guard_bundle_flag!("pi", pi_enforcement_ext_path: ext_dir) ==
               ["--extension=@#{ext_dir}"]
    end

    test "pi raises when the extension dir is absent (refuse to run unguarded)", %{dir: dir} do
      missing_dir = Path.join(dir, "nope-enforcement")

      assert_raise RuntimeError, ~r/pi enforcement extension not found.*refusing to run a role unguarded/, fn ->
        OrchestrationLoop.guard_bundle_flag!("pi", pi_enforcement_ext_path: missing_dir)
      end
    end

    test "unknown harness raises" do
      assert_raise RuntimeError, ~r/unknown harness/, fn ->
        OrchestrationLoop.guard_bundle_flag!("bogus")
      end
    end

    test "real installed claude settings bundle resolves without override (positive control)" do
      # No override — proves the real default path (harnesses/claude/claude-code-loop-settings.json,
      # the minimal per-role loop bundle) exists in this checkout, so a live loop run would NOT raise.
      assert ["--settings=@" <> path] = OrchestrationLoop.guard_bundle_flag!("claude_code")
      assert String.ends_with?(path, "claude-code-loop-settings.json")
    end

    test "real pi enforcement extension resolves without override (positive control)" do
      assert ["--extension=@" <> path] = OrchestrationLoop.guard_bundle_flag!("pi")
      assert String.ends_with?(path, "enforcement")
    end
  end
end

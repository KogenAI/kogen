defmodule CodegenTestHarness.OrchestrationLoopTest do
  use ExUnit.Case, async: true

  alias CodegenTestHarness.OrchestrationLoop

  @phoenix_sequence ~w(planner-phoenix developer-phoenix-backend reviewer-phoenix context-curator committer)
  @static_sequence ~w(developer-static reviewer-static context-curator committer)

  describe "build_prompt/2 — reviewer git-diff-as-source directive" do
    test "reviewer-phoenix prompt tells reviewer to derive changes via git diff HEAD" do
      ctx = %{cwd: "/tmp", pitch: "do the thing", artifacts: %{}}
      content = OrchestrationLoop.build_prompt("reviewer-phoenix", ctx)

      assert content =~ "git diff HEAD"
      assert content =~ "git status --porcelain"
      assert content =~ "UNCOMMITTED"
      assert content =~ "REVIEW_VERDICT: APPROVED"
    end

    test "reviewer-static prompt tells reviewer to derive changes via git diff HEAD" do
      ctx = %{cwd: "/tmp", pitch: "do the thing", artifacts: %{}}
      content = OrchestrationLoop.build_prompt("reviewer-static", ctx)

      assert content =~ "git diff HEAD"
      assert content =~ "git status --porcelain"
      assert content =~ "UNCOMMITTED"
      assert content =~ "REVIEW_VERDICT: APPROVED"
    end
  end

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

  defp no_op_gate_preflight_fn do
    fn _cwd -> {"make test", "short", 0} end
  end

  # Real advance_cycle_state/5 shells out to `write_cycle_state`, which does
  # `mkdir -p "#{cwd}/codegen/gate-pending"` + writes cycle-state.json on
  # disk. Every test below shares the literal "/tmp/irrelevant" cwd and runs
  # `async: true` — without this no-op stub, concurrent tests race on the
  # same physical file, causing intermittent `{_output, 0} = System.cmd(...)`
  # MatchError failures under load. Use for any run/1 call whose gate_fn can
  # reach :clear (GATED) and that doesn't assert on advance_cycle_state_fn
  # itself.
  defp no_op_advance_cycle_state_fn do
    fn _state, _step_log, _session_id, _verdict, _project_dir -> :ok end
  end

  defp all_present_preflight_probe_fn do
    fn _cwd ->
      "--agent '__codegen_loop_preflight_probe__' not found. Available agents: " <>
        "planner-phoenix, developer-phoenix-backend, developer-phoenix-frontend, " <>
        "reviewer-phoenix, context-curator, committer, developer-static, reviewer-static"
    end
  end

  # Default realized-check stub for every test that doesn't exercise the
  # turn-0 realized-check preflight itself — always reports "not realized" so
  # the full role chain runs, matching pre-realized-check behavior. Mirrors
  # no_op_gate_preflight_fn/all_present_preflight_probe_fn's role: a safe
  # default so unrelated run/1 tests never shell out to a real codegen-call.
  defp not_realized_fn do
    fn _pitch, _cwd -> {:ok, %{"realized" => false, "confidence" => "low", "evidence" => ""}} end
  end

  defp realized_high_confidence_fn(evidence \\ "commit 13acbe2 — all requirements met") do
    fn _pitch, _cwd ->
      {:ok, %{"realized" => true, "confidence" => "high", "evidence" => evidence}}
    end
  end

  setup do
    {:ok, calls_agent} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(calls_agent), do: Agent.stop(calls_agent) end)
    {:ok, calls_agent: calls_agent}
  end

  describe "run/1 — turn-0 realized-check preflight" do
    test "high-confidence realized verdict with evidence skips the entire role chain",
         %{calls_agent: calls_agent} do
      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "phoenix",
                 cwd: "/tmp/irrelevant",
                 pitch: "already done",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: realized_high_confidence_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert Agent.get(calls_agent, & &1) == []
    end

    test "realized:false runs the full chain (fail closed on not-realized)",
         %{calls_agent: calls_agent} do
      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert Agent.get(calls_agent, & &1) == @static_sequence
    end

    test "high-confidence realized but empty evidence runs the full chain (fail closed)",
         %{calls_agent: calls_agent} do
      empty_evidence_fn = fn _pitch, _cwd ->
        {:ok, %{"realized" => true, "confidence" => "high", "evidence" => ""}}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: empty_evidence_fn,
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert Agent.get(calls_agent, & &1) == @static_sequence
    end

    test "realized:true but confidence:low runs the full chain (fail closed)",
         %{calls_agent: calls_agent} do
      low_confidence_fn = fn _pitch, _cwd ->
        {:ok, %{"realized" => true, "confidence" => "low", "evidence" => "maybe commit abc123"}}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: low_confidence_fn,
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert Agent.get(calls_agent, & &1) == @static_sequence
    end

    test "realized-check error result runs the full chain (fail closed)",
         %{calls_agent: calls_agent} do
      error_fn = fn _pitch, _cwd -> {:error, "codegen-call exited non-zero"} end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: error_fn,
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert Agent.get(calls_agent, & &1) == @static_sequence
    end
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
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
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
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert Agent.get(calls_agent, & &1) == @static_sequence
    end
  end

  describe "run/1 — reviewer→fix cycle (#7)" do
    test "CHANGES_REQUESTED re-invokes the developer, then completes on APPROVED",
         %{calls_agent: calls_agent} do
      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static" do
            seen = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "reviewer-static"))

            if seen <= 1,
              do: "REVIEW_VERDICT: CHANGES_REQUESTED — fix the nav link",
              else: "REVIEW_VERDICT: APPROVED"
          else
            "did #{role}"
          end

        {:ok, %{"status" => "success", "value" => value}}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      calls = Agent.get(calls_agent, & &1)
      assert Enum.count(calls, &(&1 == "developer-static")) == 2
      assert Enum.count(calls, &(&1 == "reviewer-static")) == 2
      assert "committer" in calls
    end

    test "APPROVED runs the developer exactly once", %{calls_agent: calls_agent} do
      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)
        value = if role == "reviewer-static", do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"
        {:ok, %{"status" => "success", "value" => value}}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "x",
                 invoke_fn: invoke_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      calls = Agent.get(calls_agent, & &1)
      assert Enum.count(calls, &(&1 == "developer-static")) == 1
      assert Enum.count(calls, &(&1 == "reviewer-static")) == 1
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
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
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
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn()
               )

      assert reason =~ "failed twice"
    end

    test "codegen-call status=failed maps to {:error, reason} via invoke_role/4" do
      codegen_call_fn = fn _harness, _model, _effort, _sp, _tools, _prompt ->
        %{"result" => %{"status" => "failed", "reason" => "boom", "value" => nil}}
      end

      resolve_fn = fn _role, _harness -> {"sonnet", "medium"} end

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

      resolve_fn = fn _role, _harness -> {"sonnet", "medium"} end

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
                 gate_fn: gate_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
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
                 gate_fn: gate_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn()
               )

      assert reason =~ "gate verdict=failed"
    end

    test "stray gate verdict crashes loud (defensive)", %{
      calls_agent: calls_agent
    } do
      gate_fn = fn _cwd, _opts -> {:bogus, "make test"} end

      assert_raise RuntimeError, ~r/unexpected gate verdict/, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "static",
          cwd: "/tmp/irrelevant",
          pitch: "do the thing",
          invoke_fn: always_ok_invoke_fn(calls_agent),
          gate_fn: gate_fn,
          gate_preflight_fn: no_op_gate_preflight_fn(),
          preflight_probe_fn: all_present_preflight_probe_fn(),
          realized_check_fn: not_realized_fn()
        )
      end
    end
  end

  describe "build_prompt/2 — gate self-verify threading" do
    test "developer prompt includes the threaded gate command + self-verify instruction" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{gate_command: "make test"}
      }

      content = OrchestrationLoop.build_prompt("developer-static", ctx)

      assert content =~ "Gate — self-verify"
      assert content =~ "make test"
      assert content =~ "fix EVERY red"
      assert content =~ "CODEGEN_LOOP=1"
    end

    test "no gate_command artifact → no self-verify block appended" do
      ctx = %{cwd: "/tmp", pitch: "do the thing", artifacts: %{}}

      content = OrchestrationLoop.build_prompt("developer-static", ctx)

      refute content =~ "Gate — self-verify"
    end

    test "non-developer role prompt is not enriched with the self-verify block" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{gate_command: "make test"}
      }

      content = OrchestrationLoop.build_prompt("reviewer-static", ctx)

      refute content =~ "Gate — self-verify"
    end
  end

  describe "run/1 — gate progress-based retry bound" do
    test "signature changes each attempt → re-invokes past legacy count-1 bound, then clears",
         %{calls_agent: calls_agent} do
      {:ok, gate_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(gate_calls_agent), do: Agent.stop(gate_calls_agent) end)

      # Fails 3 times (more than the legacy max_gate_retries: 1 default),
      # then clears — only possible under the progress bound, not the old
      # raw-count bound.
      gate_fn = fn _cwd, _opts ->
        n = Agent.get_and_update(gate_calls_agent, fn n -> {n, n + 1} end)
        if n < 3, do: {:failed, "make test"}, else: {:clear, "make test"}
      end

      # A fresh, always-different signature each call simulates continuous
      # progress (the developer edits something every retry).
      {:ok, sig_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(sig_calls_agent), do: Agent.stop(sig_calls_agent) end)

      signature_fn = fn _cwd ->
        n = Agent.get_and_update(sig_calls_agent, fn n -> {n, n + 1} end)
        "sig-#{n}"
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: gate_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn(),
                 tree_signature_fn: signature_fn,
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      # developer-static invoked 4 times: initial + 3 progress-bounded retries
      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "developer-static")) == 4
    end

    test "signature unchanged (no progress) → stops retrying, {:error, reason}", %{
      calls_agent: calls_agent
    } do
      gate_fn = fn _cwd, _opts -> {:failed, "make test"} end
      signature_fn = fn _cwd -> "same-sig" end

      assert {:error, reason} =
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: gate_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn(),
                 tree_signature_fn: signature_fn
               )

      assert reason =~ "gate verdict=failed"
      # allowed exactly one retry (first attempt always allowed), then the
      # unchanged signature on the second failure stops further retries.
      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "developer-static")) == 2
    end

    test "hard ceiling (15) caps retries even with continuous progress", %{
      calls_agent: calls_agent
    } do
      gate_fn = fn _cwd, _opts -> {:failed, "make test"} end

      {:ok, sig_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(sig_calls_agent), do: Agent.stop(sig_calls_agent) end)

      signature_fn = fn _cwd ->
        n = Agent.get_and_update(sig_calls_agent, fn n -> {n, n + 1} end)
        "sig-#{n}"
      end

      assert {:error, reason} =
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: gate_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn(),
                 tree_signature_fn: signature_fn
               )

      assert reason =~ "gate verdict=failed"
      # 15 is the hard ceiling on retries (attempt < 15 allows attempts
      # 0..14): initial call + 15 retries = 16 total developer invocations.
      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "developer-static")) == 16
    end

    test "non-git cwd (unavailable signature) falls back to legacy count bound", %{
      calls_agent: calls_agent
    } do
      # No :tree_signature_fn override — the real tree_signature/1 runs
      # against the synthetic non-git cwd and returns "" (unavailable),
      # exercising the count-based fallback exactly like the pre-existing
      # "gate verdict stays failed past budget" test above.
      gate_fn = fn _cwd, _opts -> {:failed, "make test"} end

      assert {:error, reason} =
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: gate_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn()
               )

      assert reason =~ "gate verdict=failed"
      # default :max_gate_retries is 1 → initial call + one re-invocation.
      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "developer-static")) == 2
    end

    test "gate-run.log content is folded into last_failure_reason on retry", %{
      calls_agent: calls_agent
    } do
      tmp_cwd =
        Path.join(System.tmp_dir!(), "loop-gate-log-fold-#{System.unique_integer([:positive])}")

      log_dir = Path.join([tmp_cwd, "codegen", "gate-pending"])
      File.mkdir_p!(log_dir)
      File.write!(Path.join(log_dir, "gate-run.log"), "COMPILE ERROR: undefined function foo/1")
      on_exit(fn -> File.rm_rf!(tmp_cwd) end)

      {:ok, gate_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(gate_calls_agent), do: Agent.stop(gate_calls_agent) end)

      gate_fn = fn _cwd, _opts ->
        n = Agent.get_and_update(gate_calls_agent, fn n -> {n, n + 1} end)
        if n == 0, do: {:failed, "make test"}, else: {:clear, "make test"}
      end

      {:ok, seen_reason_agent} = Agent.start_link(fn -> nil end)
      on_exit(fn -> if Process.alive?(seen_reason_agent), do: Agent.stop(seen_reason_agent) end)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "developer-static" do
          reason = get_in(ctx, [:artifacts, :last_failure_reason])
          Agent.update(seen_reason_agent, fn _ -> reason end)
        end

        {:ok, %{"status" => "success", "value" => "did #{role}"}}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: tmp_cwd,
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 gate_fn: gate_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn()
               )

      seen_reason = Agent.get(seen_reason_agent, & &1)
      assert seen_reason =~ "COMPILE ERROR: undefined function foo/1"
    end
  end

  describe "tree_signature/1" do
    test "non-git cwd returns empty string (unavailable)" do
      assert OrchestrationLoop.tree_signature(
               "/tmp/definitely-not-a-git-repo-#{System.unique_integer([:positive])}"
             ) ==
               ""
    end

    test "real git work tree returns a non-empty, stable content hash" do
      tmp_cwd =
        Path.join(System.tmp_dir!(), "loop-tree-sig-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_cwd)
      on_exit(fn -> File.rm_rf!(tmp_cwd) end)

      {_out, 0} = System.cmd("git", ["init", "-q"], cd: tmp_cwd)
      {_out, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_cwd)
      {_out, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: tmp_cwd)
      {_out, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: tmp_cwd)
      File.write!(Path.join(tmp_cwd, "a.txt"), "hello")
      {_out, 0} = System.cmd("git", ["add", "a.txt"], cd: tmp_cwd)
      {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: tmp_cwd)

      sig1 = OrchestrationLoop.tree_signature(tmp_cwd)
      assert sig1 != ""

      sig1_again = OrchestrationLoop.tree_signature(tmp_cwd)
      assert sig1 == sig1_again

      File.write!(Path.join(tmp_cwd, "b.txt"), "new file")
      sig2 = OrchestrationLoop.tree_signature(tmp_cwd)
      assert sig2 != sig1
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
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
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
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn(),
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
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn(),
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
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn(),
                 format_fn: format_fn,
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      # developer-static (pre-gate) + context-curator (pre-commit) = 2 format calls
      assert Agent.get(format_calls_agent, & &1) == ["/tmp/irrelevant", "/tmp/irrelevant"]
    end
  end

  defp always_clean_factcheck_fn do
    fn _cwd -> {:clean} end
  end

  describe "run/1 — factcheck fix cycle" do
    test "clean scan advances CURATED and reaches the committer", %{calls_agent: calls_agent} do
      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 factcheck_scan_fn: always_clean_factcheck_fn()
               )

      assert Agent.get(calls_agent, & &1) == @static_sequence
    end

    test "violation once then clean re-invokes context-curator exactly once, then reaches committer",
         %{calls_agent: calls_agent} do
      {:ok, scan_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(scan_calls_agent), do: Agent.stop(scan_calls_agent) end)

      scan_fn = fn _cwd ->
        n = Agent.get_and_update(scan_calls_agent, fn c -> {c, c + 1} end)
        if n == 0, do: {:violations, "CLAUDE.md:1 bad path"}, else: {:clean}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 factcheck_scan_fn: scan_fn
               )

      curator_calls = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "context-curator"))
      assert curator_calls == 2
      assert List.last(Agent.get(calls_agent, & &1)) == "committer"
      assert Agent.get(scan_calls_agent, & &1) == 2
    end

    test "violations exhausting max_factcheck_cycles returns {:error, reason}; CURATED never advances, committer never invoked",
         %{calls_agent: calls_agent} do
      {:ok, states_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(states_agent), do: Agent.stop(states_agent) end)

      advance_fn = fn state, _step_log, _session_id, _verdict, _project_dir ->
        Agent.update(states_agent, fn states -> states ++ [state] end)
        :ok
      end

      always_violates_fn = fn _cwd -> {:violations, "CLAUDE.md:1 bad path"} end

      result =
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "static",
          cwd: "/tmp/irrelevant",
          pitch: "do the thing",
          invoke_fn: always_ok_invoke_fn(calls_agent),
          gate_fn: always_clear_gate_fn(),
          gate_preflight_fn: no_op_gate_preflight_fn(),
          preflight_probe_fn: all_present_preflight_probe_fn(),
          realized_check_fn: not_realized_fn(),
          advance_cycle_state_fn: advance_fn,
          factcheck_scan_fn: always_violates_fn,
          max_factcheck_cycles: 1
        )

      assert {:error, reason} = result
      assert reason =~ "factcheck unresolved"
      assert reason =~ "CLAUDE.md:1 bad path"
      refute "CURATED" in Agent.get(states_agent, & &1)
      refute "committer" in Agent.get(calls_agent, & &1)
    end

    test "factcheck_scan_fn raising propagates (loop crashes loud)", %{calls_agent: calls_agent} do
      raising_fn = fn _cwd -> raise "scan script exploded" end

      assert_raise RuntimeError, ~r/scan script exploded/, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "static",
          cwd: "/tmp/irrelevant",
          pitch: "do the thing",
          invoke_fn: always_ok_invoke_fn(calls_agent),
          gate_fn: always_clear_gate_fn(),
          gate_preflight_fn: no_op_gate_preflight_fn(),
          preflight_probe_fn: all_present_preflight_probe_fn(),
          realized_check_fn: not_realized_fn(),
          advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
          factcheck_scan_fn: raising_fn
        )
      end
    end

    test "factcheck_scan_fn returning an unexpected shape raises (no silent clean)", %{
      calls_agent: calls_agent
    } do
      bogus_fn = fn _cwd -> :not_a_valid_shape end

      assert_raise CaseClauseError, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "static",
          cwd: "/tmp/irrelevant",
          pitch: "do the thing",
          invoke_fn: always_ok_invoke_fn(calls_agent),
          gate_fn: always_clear_gate_fn(),
          gate_preflight_fn: no_op_gate_preflight_fn(),
          preflight_probe_fn: all_present_preflight_probe_fn(),
          realized_check_fn: not_realized_fn(),
          advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
          factcheck_scan_fn: bogus_fn
        )
      end
    end
  end

  # Like always_ok_invoke_fn/1, but commits the working tree when it "runs"
  # the committer role — needed because these tests use a REAL git repo cwd
  # (to exercise the real `changed_orientation_docs/1` diff-scope logic), so
  # `verify_committed!/2` actually checks tree cleanliness post-committer.
  defp always_ok_invoke_fn_with_real_commit(calls_agent) do
    fn
      "committer", _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ ["committer"] end)
        System.cmd("git", ["add", "-A"], cd: ctx.cwd)
        System.cmd("git", ["commit", "-q", "-m", "test commit"], cd: ctx.cwd)
        {:ok, %{"status" => "success", "value" => "did committer"}}

      role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)
        {:ok, %{"status" => "success", "value" => "did #{role}"}}
    end
  end

  describe "run/1 — default factcheck scan diff-scoping (real scan.sh, temp git repo)" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "factcheck_diffscope_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(dir, "context"))
      System.cmd("git", ["init", "-q"], cd: dir)
      System.cmd("git", ["config", "user.email", "t@t"], cd: dir)
      System.cmd("git", ["config", "user.name", "t"], cd: dir)
      System.cmd("git", ["config", "commit.gpgsign", "false"], cd: dir)
      File.write!(Path.join(dir, "PROJECT_CONTEXT.md"), "# PROJECT_CONTEXT.md\n")
      System.cmd("git", ["add", "PROJECT_CONTEXT.md"], cd: dir)
      System.cmd("git", ["commit", "-q", "-m", "init"], cd: dir)

      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "no orientation docs changed this cycle → {:clean} without shelling the scan, even with ambient rot elsewhere",
         %{calls_agent: calls_agent, dir: dir} do
      # Ambient rot: a committed (untouched-this-cycle) doc with a dead path claim.
      File.mkdir_p!(Path.join(dir, "context"))

      File.write!(
        Path.join([dir, "context", "rotten.md"]),
        "See `widgetapp/nope.ex` for details.\n"
      )

      System.cmd("git", ["add", "context/rotten.md"], cd: dir)
      System.cmd("git", ["commit", "-q", "-m", "seed rotten doc"], cd: dir)

      # This cycle changes only an unrelated, non-orientation file.
      File.write!(Path.join(dir, "unrelated.txt"), "unrelated change\n")

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: dir,
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn_with_real_commit(calls_agent),
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert List.last(Agent.get(calls_agent, & &1)) == "committer"
    end

    test "orientation doc changed this cycle with a genuine dead-path violation → factcheck fails loud",
         %{calls_agent: calls_agent, dir: dir} do
      File.write!(
        Path.join([dir, "context", "foo.md"]),
        "See `widgetapp/nope.ex` for details.\n"
      )

      result =
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "static",
          cwd: dir,
          pitch: "do the thing",
          invoke_fn: always_ok_invoke_fn(calls_agent),
          gate_fn: always_clear_gate_fn(),
          gate_preflight_fn: no_op_gate_preflight_fn(),
          preflight_probe_fn: all_present_preflight_probe_fn(),
          realized_check_fn: not_realized_fn(),
          advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
          max_factcheck_cycles: 0
        )

      assert {:error, reason} = result
      assert reason =~ "factcheck unresolved"
      assert reason =~ "widgetapp/nope.ex"
    end

    test "Elixir source-root fallback resolves a changed doc's module-convention path claim → {:ok}",
         %{calls_agent: calls_agent, dir: dir} do
      File.mkdir_p!(Path.join([dir, "lib", "widgetapp"]))
      File.write!(Path.join([dir, "lib", "widgetapp", "billing.ex"]), "code\n")

      File.write!(
        Path.join([dir, "context", "foo.md"]),
        "See `widgetapp/billing.ex` for details.\n"
      )

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: dir,
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn_with_real_commit(calls_agent),
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert List.last(Agent.get(calls_agent, & &1)) == "committer"
    end
  end

  describe "guard_bundle_flag!/2 — B-bucket guard bundle wiring" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "guard_bundle_test_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "claude_code returns --settings=@<path> when the settings file exists", %{dir: dir} do
      settings_path = Path.join(dir, "claude-code-settings.json")
      File.write!(settings_path, "{}")

      assert OrchestrationLoop.guard_bundle_flag!("claude_code",
               claude_settings_path: settings_path
             ) ==
               ["--settings=@#{settings_path}"]
    end

    test "claude_code raises when the settings file is absent (refuse to run unguarded)", %{
      dir: dir
    } do
      missing_path = Path.join(dir, "nope-settings.json")

      assert_raise RuntimeError,
                   ~r/claude settings bundle not found.*refusing to run a role unguarded/,
                   fn ->
                     OrchestrationLoop.guard_bundle_flag!("claude_code",
                       claude_settings_path: missing_path
                     )
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

      assert_raise RuntimeError,
                   ~r/pi enforcement extension not found.*refusing to run a role unguarded/,
                   fn ->
                     OrchestrationLoop.guard_bundle_flag!("pi",
                       pi_enforcement_ext_path: missing_dir
                     )
                   end
    end

    test "unknown harness raises" do
      assert_raise RuntimeError, ~r/unknown harness/, fn ->
        OrchestrationLoop.guard_bundle_flag!("bogus")
      end
    end

    test "real installed claude settings bundle resolves without override (positive control)" do
      # No override — proves the real default path (harnesses/claude/claude-code-settings.json,
      # the full installed settings) exists in this checkout, so a live loop run would NOT raise.
      assert ["--settings=@" <> path] = OrchestrationLoop.guard_bundle_flag!("claude_code")
      assert String.ends_with?(path, "claude-code-settings.json")
    end

    test "real pi enforcement extension resolves without override (positive control)" do
      assert ["--extension=@" <> path] = OrchestrationLoop.guard_bundle_flag!("pi")
      assert String.ends_with?(path, "enforcement")
    end
  end

  describe "telemetry accumulation" do
    test "zero_telemetry/0 returns an all-zero map" do
      assert OrchestrationLoop.zero_telemetry() == %{
               cost_usd: 0.0,
               input_tokens: 0,
               output_tokens: 0,
               cache_read_tokens: 0,
               cache_creation_tokens: 0,
               num_turns: 0,
               role_calls: 0,
               per_role: %{}
             }
    end

    test "accumulate_telemetry/2 bumps role_calls, cost_usd, and per_role on a usage envelope" do
      Process.delete(:loop_telemetry)

      envelope = %{
        "usage" => %{
          "cost_usd" => 0.5,
          "input_tokens" => 100,
          "output_tokens" => 20,
          "cache_read_input_tokens" => 5,
          "cache_creation_input_tokens" => 1,
          "num_turns" => 3
        }
      }

      assert :ok == OrchestrationLoop.accumulate_telemetry("developer-static", envelope)

      t = OrchestrationLoop.get_telemetry()
      assert t.role_calls == 1
      assert t.cost_usd == 0.5
      assert t.input_tokens == 100
      assert t.output_tokens == 20
      assert t.cache_read_tokens == 5
      assert t.cache_creation_tokens == 1
      assert t.num_turns == 3
      assert Map.has_key?(t.per_role, "developer-static")

      # A second call accumulates on top rather than replacing.
      assert :ok == OrchestrationLoop.accumulate_telemetry("developer-static", envelope)
      t2 = OrchestrationLoop.get_telemetry()
      assert t2.role_calls == 2
      assert t2.cost_usd == 1.0

      Process.delete(:loop_telemetry)
    end

    test "accumulate_telemetry/2 no-ops (returns :ok, does not bump) on an envelope with no usage key" do
      Process.delete(:loop_telemetry)

      assert :ok == OrchestrationLoop.accumulate_telemetry("developer-static", %{"result" => %{}})
      assert OrchestrationLoop.get_telemetry() == OrchestrationLoop.zero_telemetry()

      Process.delete(:loop_telemetry)
    end
  end

  describe "per-role transcript capture" do
    test "transcript_path/4 returns nil when cycle_id is nil" do
      assert OrchestrationLoop.transcript_path(nil, "/x", 1, "developer-static") == nil
    end

    test "transcript_path/4 builds a zero-padded NN-<role>.jsonl path under codegen/logging/<cycle_id>" do
      path =
        OrchestrationLoop.transcript_path("20260705_070557_slug", "/x", 1, "developer-static")

      assert String.ends_with?(
               path,
               "codegen/logging/20260705_070557_slug/01-developer-static.jsonl"
             )

      path10 =
        OrchestrationLoop.transcript_path("20260705_070557_slug", "/x", 10, "developer-static")

      assert String.ends_with?(
               path10,
               "codegen/logging/20260705_070557_slug/10-developer-static.jsonl"
             )
    end

    test "invoke_role/4 writes a cycle-summary.jsonl entry when a cycle_id is set" do
      cwd = Path.join(System.tmp_dir!(), "octel-#{System.unique_integer([:positive])}")
      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf(cwd) end)

      Process.put(:loop_cycle_id, "20260705_x_slug")
      Process.put(:loop_transcript_seq, 0)

      envelope = %{
        "result" => %{"status" => "success", "value" => "x"},
        "usage" => %{"num_turns" => 3, "cost_usd" => 0.02}
      }

      OrchestrationLoop.invoke_role(
        "developer-static",
        "claude_code",
        %{cwd: cwd, pitch: "p", artifacts: %{}},
        resolve_fn: fn _r, _h -> {"sonnet", "medium"} end,
        codegen_call_fn: fn _h, _m, _e, _sp, _t, _pr -> envelope end
      )

      summary_path =
        Path.join([cwd, "codegen", "logging", "20260705_x_slug", "cycle-summary.jsonl"])

      assert File.exists?(summary_path)

      [line] = summary_path |> File.read!() |> String.split("\n", trim: true)
      decoded = Jason.decode!(line)

      assert decoded["num_turns"] == 3
      assert decoded["role"] == "developer-static"
      assert decoded["seq"] == 1
      assert decoded["status"] == "success"
      assert String.ends_with?(decoded["transcript"], "01-developer-static.jsonl")
    end

    test "invoke_role/4 writes no cycle-summary file when cycle_id is nil" do
      cwd = Path.join(System.tmp_dir!(), "octel-#{System.unique_integer([:positive])}")
      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf(cwd) end)

      Process.put(:loop_cycle_id, nil)
      Process.put(:loop_transcript_seq, 0)

      envelope = %{
        "result" => %{"status" => "success", "value" => "x"},
        "usage" => %{"num_turns" => 3, "cost_usd" => 0.02}
      }

      OrchestrationLoop.invoke_role(
        "developer-static",
        "claude_code",
        %{cwd: cwd, pitch: "p", artifacts: %{}},
        resolve_fn: fn _r, _h -> {"sonnet", "medium"} end,
        codegen_call_fn: fn _h, _m, _e, _sp, _t, _pr -> envelope end
      )

      refute File.exists?(Path.join([cwd, "codegen", "logging"]))
    end
  end

  describe "verify_committed! (structural gap #9)" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "verify_committed_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      {_out, 0} = System.cmd("git", ["init", "-q"], cd: dir)
      {_out, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
      {_out, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: dir)
      {_out, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: dir)

      File.write!(Path.join(dir, "README.md"), "init\n")
      {_out, 0} = System.cmd("git", ["add", "-A"], cd: dir)
      {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: dir)

      {:ok, dir: dir}
    end

    test "committer returning success on a DIRTY tree raises (false-success guard)", %{
      calls_agent: calls_agent,
      dir: dir
    } do
      # Leave an uncommitted file — the committer role will claim success
      # without actually running `git commit`.
      File.write!(Path.join(dir, "uncommitted.txt"), "oops\n")

      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static", do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end

      assert_raise RuntimeError, ~r/working tree is NOT clean/, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "static",
          cwd: dir,
          pitch: "do the thing",
          invoke_fn: invoke_fn,
          gate_fn: always_clear_gate_fn(),
          gate_preflight_fn: no_op_gate_preflight_fn(),
          preflight_probe_fn: all_present_preflight_probe_fn(),
          realized_check_fn: not_realized_fn()
        )
      end
    end

    test "committer returning success on a CLEAN tree with real work committed proceeds to :ok",
         %{
           calls_agent: calls_agent,
           dir: dir
         } do
      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "committer" do
          File.write!(Path.join(dir, "feature.txt"), "done\n")
          {_o, 0} = System.cmd("git", ["add", "-A"], cd: dir)
          {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "impl"], cd: dir)
        end

        value =
          if role == "reviewer-static", do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end

      # advance_cycle_state_fn is stubbed to a no-op: the real implementation
      # writes codegen/gate-pending/cycle-state.json under `dir`, which would
      # itself show up as an untracked file and trip verify_committed!'s
      # clean-tree check — irrelevant to what this test verifies.
      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: dir,
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn(),
                 advance_cycle_state_fn: fn _state,
                                            _step_log,
                                            _session_id,
                                            _verdict,
                                            _project_dir ->
                   :ok
                 end
               )
    end

    test "committer producing TWO commits raises (split-commit guard, exactly-one enforced)", %{
      calls_agent: calls_agent,
      dir: dir
    } do
      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "committer" do
          File.write!(Path.join(dir, "a.txt"), "one\n")
          {_o, 0} = System.cmd("git", ["add", "-A"], cd: dir)
          {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "c1"], cd: dir)
          File.write!(Path.join(dir, "b.txt"), "two\n")
          {_o, 0} = System.cmd("git", ["add", "-A"], cd: dir)
          {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "c2"], cd: dir)
        end

        value =
          if role == "reviewer-static", do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end

      assert_raise RuntimeError, ~r/exactly one commit|expected 1|split commits/, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "static",
          cwd: dir,
          pitch: "do the thing",
          invoke_fn: invoke_fn,
          gate_fn: always_clear_gate_fn(),
          gate_preflight_fn: no_op_gate_preflight_fn(),
          preflight_probe_fn: all_present_preflight_probe_fn(),
          realized_check_fn: not_realized_fn(),
          advance_cycle_state_fn: fn _state, _step_log, _session_id, _verdict, _project_dir ->
            :ok
          end
        )
      end
    end

    test "committer orphaning the base via git reset raises (ancestry backstop)", %{
      calls_agent: calls_agent,
      dir: dir
    } do
      # Simulate a prior cycle's already-committed commit (the base this
      # cycle must preserve).
      File.write!(Path.join(dir, "prior_cycle.txt"), "prior work\n")
      {_o, 0} = System.cmd("git", ["add", "-A"], cd: dir)
      {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "prior cycle commit"], cd: dir)

      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "committer" do
          # Orphaning move: reset past the prior-cycle commit (base_head),
          # then make exactly ONE new commit on the older history. This
          # passes the count+diff guard but must trip the ancestry backstop.
          {_o, 0} = System.cmd("git", ["reset", "--hard", "HEAD~1"], cd: dir)
          File.write!(Path.join(dir, "new_work.txt"), "new\n")
          {_o, 0} = System.cmd("git", ["add", "-A"], cd: dir)
          {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "orphaning commit"], cd: dir)
        end

        value =
          if role == "reviewer-static", do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end

      assert_raise RuntimeError, ~r/no longer an ancestor|orphaned the base/, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "static",
          cwd: dir,
          pitch: "do the thing",
          invoke_fn: invoke_fn,
          gate_fn: always_clear_gate_fn(),
          gate_preflight_fn: no_op_gate_preflight_fn(),
          preflight_probe_fn: all_present_preflight_probe_fn(),
          realized_check_fn: not_realized_fn(),
          advance_cycle_state_fn: fn _state, _step_log, _session_id, _verdict, _project_dir ->
            :ok
          end
        )
      end
    end

    test "no-op cycle (clean tree, zero work produced) raises — never loop_committed", %{
      calls_agent: calls_agent,
      dir: dir
    } do
      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static", do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end

      assert_raise RuntimeError, ~r/NO work was produced|no-op false-success/, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "static",
          cwd: dir,
          pitch: "do the thing",
          invoke_fn: invoke_fn,
          gate_fn: always_clear_gate_fn(),
          gate_preflight_fn: no_op_gate_preflight_fn(),
          preflight_probe_fn: all_present_preflight_probe_fn(),
          realized_check_fn: not_realized_fn(),
          advance_cycle_state_fn: fn _state, _step_log, _session_id, _verdict, _project_dir ->
            :ok
          end
        )
      end
    end
  end

  describe "run/1 — turn-0 gate preflight (loop-gate-preflight-turn0)" do
    test "unresolvable gate refuses BEFORE any role is invoked",
         %{calls_agent: calls_agent} do
      raising_preflight = fn _cwd ->
        raise "LoopGate: gate_select_decide could not resolve a gate — " <>
                "__GATE_UNRESOLVED__:/x/.claude/gate-config.sh present but GATE_COMMAND is empty"
      end

      assert_raise RuntimeError, ~r/gate unresolved/, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "phoenix",
          cwd: "/tmp/irrelevant",
          pitch: "do the thing",
          invoke_fn: always_ok_invoke_fn(calls_agent),
          gate_fn: always_clear_gate_fn(),
          gate_preflight_fn: raising_preflight,
          preflight_probe_fn: all_present_preflight_probe_fn(),
          realized_check_fn: not_realized_fn()
        )
      end

      # The refusal MUST happen before the first role spend.
      assert Agent.get(calls_agent, & &1) == []
    end

    test "resolvable gate proceeds through the full sequence",
         %{calls_agent: calls_agent} do
      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "phoenix",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert Agent.get(calls_agent, & &1) == @phoenix_sequence
    end
  end

  describe "run/1 — turn-0 role-agent resolution preflight (loop-agent-resolution-preflight)" do
    test "a missing required role raises BEFORE any role is invoked", %{calls_agent: calls_agent} do
      missing_committer_probe = fn _cwd ->
        "--agent '__codegen_loop_preflight_probe__' not found. Available agents: " <>
          "planner-phoenix, developer-phoenix-backend, developer-phoenix-frontend, " <>
          "reviewer-phoenix, context-curator"
      end

      assert_raise RuntimeError, ~r/required role agent\(s\) not resolvable: committer/, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "phoenix",
          cwd: "/tmp/irrelevant",
          pitch: "do the thing",
          invoke_fn: always_ok_invoke_fn(calls_agent),
          gate_fn: always_clear_gate_fn(),
          gate_preflight_fn: no_op_gate_preflight_fn(),
          preflight_probe_fn: missing_committer_probe,
          realized_check_fn: not_realized_fn()
        )
      end

      # The refusal MUST happen before the first role spend.
      assert Agent.get(calls_agent, & &1) == []
    end

    test "an inconclusive probe (no parseable agent list) raises", %{calls_agent: calls_agent} do
      inconclusive_probe = fn _cwd -> "some unrelated CLI error with no agent list" end

      assert_raise RuntimeError, ~r/could not confirm role-agent resolution/, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "phoenix",
          cwd: "/tmp/irrelevant",
          pitch: "do the thing",
          invoke_fn: always_ok_invoke_fn(calls_agent),
          gate_fn: always_clear_gate_fn(),
          gate_preflight_fn: no_op_gate_preflight_fn(),
          preflight_probe_fn: inconclusive_probe,
          realized_check_fn: not_realized_fn()
        )
      end

      assert Agent.get(calls_agent, & &1) == []
    end

    test "all roles present proceeds through the full sequence", %{calls_agent: calls_agent} do
      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "phoenix",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 realized_check_fn: not_realized_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert Agent.get(calls_agent, & &1) == @phoenix_sequence
    end
  end
end

# Isolated in a sibling async: false module because these tests mutate the
# process-global CODEGEN_BUILD_LOCK_HELD env var that test_helper.exs sets
# for the WHOLE suite (see comment there) — sharing async: true execution
# with OrchestrationLoopTest's ~38 unrelated role-sequencing tests would
# otherwise race on that same global. Mirrors the codebase's documented
# System.put_env isolation pattern (see context/rules-stacks.md "Test
# Discipline").
defmodule CodegenTestHarness.OrchestrationLoopLockTest do
  use ExUnit.Case, async: false

  alias CodegenTestHarness.OrchestrationLoop

  setup do
    # Suite-wide bypass (test_helper.exs) must be OFF for these tests — they
    # exercise the lock/orphan-scan mechanism itself.
    System.delete_env("CODEGEN_BUILD_LOCK_HELD")
    on_exit(fn -> System.put_env("CODEGEN_BUILD_LOCK_HELD", "1") end)

    dir =
      Path.join(
        System.tmp_dir!(),
        "orchestration_loop_lock_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir, lock_path: Path.join([dir, "codegen", "gate-pending", "queue.lock"])}
  end

  defp minimal_run_opts(ctx, extra) do
    defaults = [
      harness: "claude_code",
      stack: "phoenix",
      cwd: ctx.dir,
      pitch: "do the thing",
      invoke_fn: fn _role, _harness, _ctx, _opts -> {:ok, %{"status" => "success"}} end,
      gate_fn: fn _cwd, _opts -> {:clear, "make test"} end,
      gate_preflight_fn: fn _cwd -> {"make test", "short", 0} end,
      preflight_probe_fn: fn _cwd ->
        "--agent '__codegen_loop_preflight_probe__' not found. Available agents: " <>
          "planner-phoenix, developer-phoenix-backend, developer-phoenix-frontend, " <>
          "reviewer-phoenix, context-curator, committer, developer-static, reviewer-static"
      end,
      realized_check_fn: fn _pitch, _cwd ->
        {:ok, %{"realized" => false, "confidence" => "low", "evidence" => ""}}
      end,
      advance_cycle_state_fn: fn _state, _step_log, _session_id, _verdict, _project_dir -> :ok end,
      orphan_scan_fn: fn _cwd -> [] end
    ]

    Keyword.merge(defaults, extra)
  end

  test "acquires and releases the per-cwd lock across a successful run", ctx do
    refute File.exists?(ctx.lock_path)

    assert :ok == OrchestrationLoop.run(minimal_run_opts(ctx, []))

    # Lock released after a successful run — file removed.
    refute File.exists?(ctx.lock_path)
  end

  test "refuses when a live pid already holds the lock", ctx do
    File.mkdir_p!(Path.dirname(ctx.lock_path))
    File.write!(ctx.lock_path, "12345 solo\n")

    assert {:error, reason} =
             OrchestrationLoop.run(
               minimal_run_opts(ctx, lock_path: ctx.lock_path, pid_alive_fn: fn _pid -> true end)
             )

    assert reason =~ "already running"
    assert reason =~ "12345"
  end

  test "reclaims a stale (dead-pid) lock and proceeds", ctx do
    File.mkdir_p!(Path.dirname(ctx.lock_path))
    File.write!(ctx.lock_path, "99999 solo\n")

    assert :ok ==
             OrchestrationLoop.run(
               minimal_run_opts(ctx,
                 lock_path: ctx.lock_path,
                 pid_alive_fn: fn _pid -> false end
               )
             )

    refute File.exists?(ctx.lock_path)
  end

  test "releases the lock even when the run body raises", ctx do
    raising_invoke_fn = fn _role, _harness, _ctx, _opts -> raise "boom" end

    assert_raise RuntimeError, "boom", fn ->
      OrchestrationLoop.run(minimal_run_opts(ctx, invoke_fn: raising_invoke_fn))
    end

    refute File.exists?(ctx.lock_path)
  end

  test "CODEGEN_BUILD_LOCK_HELD=1 bypasses lock acquisition entirely", ctx do
    System.put_env("CODEGEN_BUILD_LOCK_HELD", "1")
    on_exit(fn -> System.delete_env("CODEGEN_BUILD_LOCK_HELD") end)

    File.mkdir_p!(Path.dirname(ctx.lock_path))
    File.write!(ctx.lock_path, "12345 solo\n")

    # Would refuse if the lock were checked (pid_alive_fn -> true); bypass
    # means run_body executes directly, ignoring the held lock entirely.
    assert :ok ==
             OrchestrationLoop.run(
               minimal_run_opts(ctx, lock_path: ctx.lock_path, pid_alive_fn: fn _pid -> true end)
             )

    # Bypassed run never touches the lock file — it is left exactly as
    # written by the (simulated) queue drain parent.
    assert File.read!(ctx.lock_path) == "12345 solo\n"
  end

  test "refuses when an orphan mix codegen.loop process is detected for this cwd", ctx do
    assert {:error, reason} =
             OrchestrationLoop.run(
               minimal_run_opts(ctx, orphan_scan_fn: fn _cwd -> ["54321"] end)
             )

    assert reason =~ "orphan"
    assert reason =~ "54321"
    # Lock released on the orphan-refuse path too — no permanent wedge.
    refute File.exists?(ctx.lock_path)
  end

  test "orphan scan sees no hits proceeds normally", ctx do
    assert :ok == OrchestrationLoop.run(minimal_run_opts(ctx, orphan_scan_fn: fn _cwd -> [] end))
  end

  test "default_orphan_scan/1 returns [] when pgrep finds no match" do
    assert OrchestrationLoop.default_orphan_scan("/no/such/cwd/#{:erlang.unique_integer()}") == []
  end
end

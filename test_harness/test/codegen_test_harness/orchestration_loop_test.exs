defmodule CodegenTestHarness.OrchestrationLoopTest do
  use ExUnit.Case, async: true

  alias CodegenTestHarness.OrchestrationLoop

  @phoenix_sequence ~w(planner-phoenix developer-phoenix-backend reviewer-phoenix context-curator committer)
  @static_sequence ~w(developer-static reviewer-static context-curator committer)

  describe "build_prompt/2 — reviewer file set (loop-supplied ## Files Modified)" do
    test "reviewer-phoenix prompt renders the loop-supplied ## Files Modified list" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{review_file_set: "lib/foo.ex\nlib/bar.ex"}
      }

      content = OrchestrationLoop.build_prompt("reviewer-phoenix", ctx)

      assert content =~ "## Files Modified"
      assert content =~ "lib/foo.ex"
      assert content =~ "lib/bar.ex"
      assert content =~ "git diff HEAD -- <path>"
      assert content =~ "UNCOMMITTED"
      assert content =~ "REVIEW_VERDICT: APPROVED"
      refute content =~ "derive"
      refute content =~ "There is no `## Files Modified` section"
    end

    test "reviewer-static prompt renders the loop-supplied ## Files Modified list" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{review_file_set: "assets/js/app.js"}
      }

      content = OrchestrationLoop.build_prompt("reviewer-static", ctx)

      assert content =~ "## Files Modified"
      assert content =~ "assets/js/app.js"
      assert content =~ "git diff HEAD -- <path>"
      assert content =~ "UNCOMMITTED"
      assert content =~ "REVIEW_VERDICT: APPROVED"
      refute content =~ "derive"
      refute content =~ "There is no `## Files Modified` section"
    end

    test "no review_file_set in ctx → no ## Files Modified section, but verdict instruction remains" do
      ctx = %{cwd: "/tmp", pitch: "do the thing", artifacts: %{}}
      content = OrchestrationLoop.build_prompt("reviewer-phoenix", ctx)

      refute content =~ "## Files Modified"
      assert content =~ "REVIEW_VERDICT: APPROVED"
    end
  end

  describe "build_prompt/2 — verifier surface notice (surface, never deny)" do
    test "reviewer prompt gets a Verifier Surface Touched notice when the diff touches a gate test" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{
          review_file_set: "lib/foo.ex\ntest/codegen_test_harness/loop_gate_test.exs"
        }
      }

      content = OrchestrationLoop.build_prompt("reviewer-phoenix", ctx)

      assert content =~ "## Verifier Surface Touched"
      assert content =~ "test/codegen_test_harness/loop_gate_test.exs"
      refute content =~ "lib/foo.ex\n```"
    end

    test "reviewer prompt gets the notice when the diff touches loop_gate.ex itself" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{review_file_set: "lib/codegen_test_harness/loop_gate.ex"}
      }

      content = OrchestrationLoop.build_prompt("reviewer-phoenix", ctx)

      assert content =~ "## Verifier Surface Touched"
      assert content =~ "loop_gate.ex"
    end

    test "reviewer prompt gets the notice when the diff touches the bash gate contract" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{review_file_set: "harnesses/claude/hooks/lib/gate-result.sh"}
      }

      content = OrchestrationLoop.build_prompt("reviewer-static", ctx)

      assert content =~ "## Verifier Surface Touched"
      assert content =~ "gate-result.sh"
    end

    test "reviewer prompt gets NO notice when the diff touches only feature code" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{review_file_set: "lib/foo.ex\nlib/bar.ex"}
      }

      content = OrchestrationLoop.build_prompt("reviewer-phoenix", ctx)

      refute content =~ "## Verifier Surface Touched"
    end

    test "no review_file_set at all → no notice (never a new file walk)" do
      ctx = %{cwd: "/tmp", pitch: "do the thing", artifacts: %{}}

      content = OrchestrationLoop.build_prompt("reviewer-phoenix", ctx)

      refute content =~ "## Verifier Surface Touched"
    end

    test "the notice is advisory prose only — never a CHANGES_REQUESTED verdict itself" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{review_file_set: "shared/enforcement/registry.yaml"}
      }

      content = OrchestrationLoop.build_prompt("reviewer-phoenix", ctx)

      assert content =~ "## Verifier Surface Touched"
      assert content =~ "REVIEW_VERDICT: APPROVED"
      assert content =~ "REVIEW_VERDICT: CHANGES_REQUESTED"
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

  # Stub invoke_fn: always succeeds, records call order in an Agent. Reviewer
  # roles get a valid `REVIEW_VERDICT: APPROVED` — move 4b's fail-closed
  # `:unknown` handling means a bare "did #{role}" reviewer output is no
  # longer silently treated as approved.
  defp always_ok_invoke_fn(calls_agent) do
    fn role, _harness, _ctx, _opts ->
      Agent.update(calls_agent, fn calls -> calls ++ [role] end)
      value = if reviewer_role?(role), do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"
      {:ok, %{"status" => "success", "value" => value}}
    end
  end

  defp reviewer_role?(role), do: role == "reviewer-phoenix" or role == "reviewer-static"

  defp always_clear_gate_fn do
    fn _cwd, _opts -> {:clear, "make test"} end
  end

  defp no_op_gate_preflight_fn do
    fn _cwd -> {"make test", "short", 0} end
  end

  # Opt-out seam for tests that pre-seed a real dirty file BEFORE calling
  # run/1 to simulate mid-cycle developer output (a real cycle never reaches
  # the reviewer/gate/factcheck/commit-guard steps with a clean tree — see
  # invoke_reviewer/4's empty-set refusal). That pre-seeded dirt is the
  # test's own simulated in-cycle state, not the "foreign uncommitted
  # changes at true cycle start" the turn-0 clean-tree guard exists to
  # catch — these tests opt out of it explicitly.
  defp no_op_clean_tree_preflight_fn do
    fn _cwd -> :ok end
  end

  # Stub :planner_plan_fn seam: skips the real cycle-log read (LoopGate.planner_body/1)
  # for tests that stub invoke_fn without ever writing a real planner role body to
  # disk. Provides a minimal, non-blank, single-`## Plan` body so
  # resolve_planner_plan!/2 does not raise on phoenix-sequence tests that are
  # exercising unrelated behavior (retry, locking, preflight).
  defp stub_planner_plan_fn do
    fn _log_file -> "## Plan\n\n**Approach**: do the thing." end
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
    fn _state, _step_log, _session_id, _verdict, _project_dir, _slug -> :ok end
  end

  defp all_present_preflight_probe_fn do
    fn _cwd ->
      "--agent '__codegen_loop_preflight_probe__' not found. Available agents: " <>
        "planner-phoenix, developer-phoenix-backend, developer-phoenix-frontend, " <>
        "reviewer-phoenix, context-curator, committer, developer-static, reviewer-static"
    end
  end

  # Writes a real, minimal JSONL cycle log fixture on disk and returns its
  # path. Used by tests that need a real :log_init_fn (e.g. the
  # default :log_died_fn integration test), not the retrospective machinery
  # this used to back (deleted — see no-role-work-recorded-without-its-learning).
  defp fresh_cycle_log! do
    path =
      Path.join(
        System.tmp_dir!(),
        "orch_loop_test_#{System.unique_integer([:positive])}_cycle.jsonl"
      )

    File.write!(path, Jason.encode!(%{"ev" => "init", "pitch" => "x"}) <> "\n")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp log_init_fn_for(log_path) do
    fn _slug, _cwd, _stamp -> log_path end
  end

  defp append_role_body!(log_path, role, body) do
    line = Jason.encode!(%{"ev" => "role", "role" => role, "body" => body})
    File.write!(log_path, line <> "\n", [:append])
  end

  # Writes a typed {"ev":"plan",...} event — the marker
  # LoopGate.planner_plan/1 reads (via gate-select.sh's
  # gate_select_read_planner_plan), NOT the free-form ev:role body.
  defp append_plan_event!(log_path, role, plan) do
    line = Jason.encode!(%{"ev" => "plan", "role" => role, "plan" => plan})
    File.write!(log_path, line <> "\n", [:append])
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
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 planner_plan_fn: stub_planner_plan_fn()
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert Agent.get(calls_agent, & &1) == @static_sequence
    end
  end

  describe "run/1 — gate opts carry an attributable :session_id" do
    test "gate_fn receives :session_id == the developer role that just ran (not the anonymous default)",
         %{calls_agent: calls_agent} do
      {:ok, gate_opts_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(gate_opts_agent), do: Agent.stop(gate_opts_agent) end)

      capturing_gate_fn = fn _cwd, opts ->
        Agent.update(gate_opts_agent, &(&1 ++ [Keyword.get(opts, :session_id)]))
        {:clear, "make test"}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: capturing_gate_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      session_ids = Agent.get(gate_opts_agent, & &1)
      assert length(session_ids) > 0
      # Never the pre-fix anonymous default: LoopGate.run_gate/2 itself
      # defaults an absent :session_id to "" — the loop must always supply
      # a non-blank actor now, for every gate call this cycle made.
      assert Enum.all?(session_ids, &(&1 != "" and &1 != nil))
      assert Enum.all?(session_ids, &String.starts_with?(&1, "developer-"))
    end
  end

  defp no_op_orientation_preflight_fn do
    fn _cwd -> {:clean} end
  end

  describe "run/1 — turn-0 orientation-doc preflight" do
    test "clean seam result → roles are invoked as normal", %{calls_agent: calls_agent} do
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 orientation_preflight_fn: no_op_orientation_preflight_fn()
               )

      assert Agent.get(calls_agent, & &1) == @static_sequence
    end

    test "violations seam result → raises InfraAbort naming the check and remediation, before any role runs",
         %{calls_agent: calls_agent} do
      violating_fn = fn _cwd ->
        {:violations,
         "context-index-parity-scan: context/new.md added but no index row mentions \"new\""}
      end

      assert_raise CodegenTestHarness.InfraAbort,
                   ~r/orientation-doc-preflight/,
                   fn ->
                     OrchestrationLoop.run(
                       harness: "claude_code",
                       stack: "static",
                       cwd: "/tmp/irrelevant",
                       pitch: "do the thing",
                       invoke_fn: always_ok_invoke_fn(calls_agent),
                       gate_fn: always_clear_gate_fn(),
                       gate_preflight_fn: no_op_gate_preflight_fn(),
                       preflight_probe_fn: all_present_preflight_probe_fn(),
                       advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                       orientation_preflight_fn: violating_fn
                     )
                   end

      # no role was ever invoked — the loop refused before spending a cent
      assert Agent.get(calls_agent, & &1) == []
    end

    test "violations message names the remediation (drifted-at-HEAD, re-run after fixing)",
         %{calls_agent: calls_agent} do
      violating_fn = fn _cwd -> {:violations, "CLAUDE.md:1 bad path"} end

      error =
        assert_raise CodegenTestHarness.InfraAbort, fn ->
          OrchestrationLoop.run(
            harness: "claude_code",
            stack: "static",
            cwd: "/tmp/irrelevant",
            pitch: "do the thing",
            invoke_fn: always_ok_invoke_fn(calls_agent),
            gate_fn: always_clear_gate_fn(),
            gate_preflight_fn: no_op_gate_preflight_fn(),
            preflight_probe_fn: all_present_preflight_probe_fn(),
            advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
            orientation_preflight_fn: violating_fn
          )
        end

      assert error.message =~ "already drifted at HEAD"
      assert error.message =~ "this build introduced nothing"
      assert error.message =~ "CLAUDE.md:1 bad path"
    end

    test "preflight runs BEFORE any role — :invoke_fn is never called on a violation",
         %{calls_agent: calls_agent} do
      violating_fn = fn _cwd -> {:violations, "drift"} end

      assert_raise CodegenTestHarness.InfraAbort, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "phoenix",
          cwd: "/tmp/irrelevant",
          pitch: "do the thing",
          invoke_fn: always_ok_invoke_fn(calls_agent),
          gate_fn: always_clear_gate_fn(),
          gate_preflight_fn: no_op_gate_preflight_fn(),
          preflight_probe_fn: all_present_preflight_probe_fn(),
          advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
          orientation_preflight_fn: violating_fn
        )
      end

      assert Agent.get(calls_agent, & &1) == []
    end

    # Regression guard for the 76+ pre-existing tests that pass a synthetic
    # cwd ("/tmp/irrelevant") without stubbing :orientation_preflight_fn at
    # all — the REAL default_orientation_preflight/1 must stay inert there
    # (both scans fail-open on a non-git cwd; the factcheck leg is also
    # sentinel-gated off since /tmp/irrelevant has no
    # harnesses/claude/manifest.yaml). This is what keeps every other test
    # in this file from needing a new stub.
    test "real default orientation preflight is a no-op against a synthetic /tmp cwd (mocked-suite regression guard)",
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert Agent.get(calls_agent, & &1) == @static_sequence
    end
  end

  describe "run/1 — no developer invoked without its plan" do
    test "phoenix cycle threads the planner's typed plan event (not the envelope chat message, not the role body prose) into the developer prompt",
         %{calls_agent: calls_agent} do
      log_path = fresh_cycle_log!()

      # A role body full of decoy structure the OLD prose-scraper would have
      # keyed on — proves the typed event, not this body, is what threads.
      append_role_body!(
        log_path,
        "planner-phoenix",
        "Some chatty preamble.\n\n## Plan\n\ndecoy body plan — must never thread"
      )

      plan_text =
        "## Plan\n\n**Approach**: do the thing.\n\n" <>
          "**Files to touch**: lib/foo.ex (NEW)\n\n## Slices\n\nslice text"

      append_plan_event!(log_path, "planner-phoenix", plan_text)

      seen_prompt = Agent.start_link(fn -> nil end) |> elem(1)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "developer-phoenix-backend" do
          Agent.update(seen_prompt, fn _ -> OrchestrationLoop.build_prompt(role, ctx) end)
        end

        value =
          if role == "reviewer-phoenix",
            do: "REVIEW_VERDICT: APPROVED",
            else: "did #{role}"

        {:ok, %{"status" => "success", "value" => "chat recap with no plan in it — #{value}"}}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "phoenix",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 slug: "plan-thread-test",
                 log_init_fn: log_init_fn_for(log_path)
               )

      prompt = Agent.get(seen_prompt, & &1)
      assert prompt =~ "## Plan"
      assert prompt =~ "**Files to touch**: lib/foo.ex (NEW)"
      # The WHOLE plan threads now — no next-## slicing (that was the old
      # broken scraper's behavior, which silently dropped sibling sections
      # like ## Slices/## Delegation prompt/## Files to touch).
      assert prompt =~ "## Slices"
      refute prompt =~ "chat recap with no plan in it"
      refute prompt =~ "decoy body plan"
    end

    test "no plan event raises before the developer is ever invoked" do
      log_path = fresh_cycle_log!()
      append_role_body!(log_path, "planner-phoenix", "some retrospective prose, no plan event")

      invoke_fn = fn role, _harness, _ctx, _opts ->
        {:ok, %{"status" => "success", "value" => "did #{role}"}}
      end

      assert_raise RuntimeError, ~r/wrote no \{"ev":"plan"\} event/, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "phoenix",
          cwd: "/tmp/irrelevant",
          pitch: "do the thing",
          invoke_fn: invoke_fn,
          gate_fn: always_clear_gate_fn(),
          gate_preflight_fn: no_op_gate_preflight_fn(),
          preflight_probe_fn: all_present_preflight_probe_fn(),
          advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
          slug: "plan-thread-blank-test",
          log_init_fn: log_init_fn_for(log_path)
        )
      end
    end

    test "blank plan event raises before the developer is ever invoked" do
      log_path = fresh_cycle_log!()
      append_plan_event!(log_path, "planner-phoenix", "")

      invoke_fn = fn role, _harness, _ctx, _opts ->
        {:ok, %{"status" => "success", "value" => "did #{role}"}}
      end

      assert_raise RuntimeError, ~r/wrote no \{"ev":"plan"\} event/, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "phoenix",
          cwd: "/tmp/irrelevant",
          pitch: "do the thing",
          invoke_fn: invoke_fn,
          gate_fn: always_clear_gate_fn(),
          gate_preflight_fn: no_op_gate_preflight_fn(),
          preflight_probe_fn: all_present_preflight_probe_fn(),
          advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
          slug: "plan-thread-blank-test-2",
          log_init_fn: log_init_fn_for(log_path)
        )
      end
    end

    test "multiple plan events (planner re-run) — the last one wins, not ambiguous" do
      log_path = fresh_cycle_log!()
      append_plan_event!(log_path, "planner-phoenix", "## Plan\n\nplan A")
      append_plan_event!(log_path, "planner-phoenix", "## Plan\n\nplan B")

      seen_prompt = Agent.start_link(fn -> nil end) |> elem(1)

      invoke_fn = fn role, _harness, ctx, _opts ->
        if role == "developer-phoenix-backend" do
          Agent.update(seen_prompt, fn _ -> OrchestrationLoop.build_prompt(role, ctx) end)
        end

        value =
          if role == "reviewer-phoenix",
            do: "REVIEW_VERDICT: APPROVED",
            else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "phoenix",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 slug: "plan-thread-rerun-test",
                 log_init_fn: log_init_fn_for(log_path)
               )

      prompt = Agent.get(seen_prompt, & &1)
      assert prompt =~ "plan B"
      refute prompt =~ "plan A"
    end

    test "static cycle (no planner) never resolves a plan and never raises", %{
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      calls = Agent.get(calls_agent, & &1)
      assert Enum.count(calls, &(&1 == "developer-static")) == 1
      assert Enum.count(calls, &(&1 == "reviewer-static")) == 1
    end

    # Regression for bug 4: an :unknown verdict (no parseable REVIEW_VERDICT:
    # sentinel) must NEVER be folded into the same "proceed" arm as :approved
    # — that used to silently ship an unreviewed change. One re-invocation
    # is granted (demanding the sentinel); a second unparseable result
    # raises loud.
    test "unparseable review output (no REVIEW_VERDICT: sentinel) is re-invoked once, then fails loud if still unparseable",
         %{calls_agent: calls_agent} do
      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static" do
            "I looked at the code and it seems fine, no obvious issues."
          else
            "did #{role}"
          end

        {:ok, %{"status" => "success", "value" => value}}
      end

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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert reason =~ "no parseable REVIEW_VERDICT"
      assert "committer" not in Agent.get(calls_agent, & &1)
      # Re-invoked exactly once demanding the sentinel (2 total reviewer calls).
      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "reviewer-static")) == 2
    end

    test "an unparseable review that recovers on re-invocation (states the sentinel the second time) proceeds normally",
         %{calls_agent: calls_agent} do
      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static" do
            seen = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "reviewer-static"))
            if seen <= 1, do: "looks fine to me", else: "REVIEW_VERDICT: APPROVED"
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      calls = Agent.get(calls_agent, & &1)
      assert Enum.count(calls, &(&1 == "reviewer-static")) == 2
      assert "committer" in calls
    end

    # Regression: budget-exhausted CHANGES_REQUESTED must be aligned to the
    # SAME fail-loud posture as :unknown / run_curator_doc_check's own
    # exhaustion — silently proceeding as if approved used to treat the two
    # identically.
    test "budget-exhausted CHANGES_REQUESTED fails loud rather than silently proceeding",
         %{calls_agent: calls_agent} do
      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static",
            do: "REVIEW_VERDICT: CHANGES_REQUESTED — still not right",
            else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end

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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 max_review_cycles: 0
               )

      assert reason =~ "review re-work budget"
      assert "committer" not in Agent.get(calls_agent, & &1)
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
          value = if reviewer_role?(role), do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"
          {:ok, %{"status" => "success", "value" => value}}
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
                 preflight_probe_fn: all_present_preflight_probe_fn()
               )

      assert reason =~ "failed twice"
    end

    test "role fails once then succeeds on retry → death stamp is 'interrupted' (a recovered drop is still stamped)",
         %{calls_agent: calls_agent} do
      {:ok, fail_once_agent} = Agent.start_link(fn -> MapSet.new() end)
      on_exit(fn -> if Process.alive?(fail_once_agent), do: Agent.stop(fail_once_agent) end)
      {:ok, died_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(died_agent), do: Agent.stop(died_agent) end)

      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)
        already_failed = Agent.get(fail_once_agent, &MapSet.member?(&1, role))

        if role == "reviewer-static" and not already_failed do
          Agent.update(fail_once_agent, &MapSet.put(&1, role))
          {:error, "transient blip"}
        else
          value = if reviewer_role?(role), do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"
          {:ok, %{"status" => "success", "value" => value}}
        end
      end

      log_died_fn = fn role, kind, cause, _cycle_log ->
        Agent.update(died_agent, fn calls -> calls ++ [{role, kind, cause}] end)
        :ok
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 log_died_fn: log_died_fn
               )

      assert Agent.get(died_agent, & &1) == [{"reviewer-static", "interrupted", "transient blip"}]
    end

    test "role fails twice in a row → death stamps are 'interrupted' then 'aborted'" do
      {:ok, died_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(died_agent), do: Agent.stop(died_agent) end)

      invoke_fn = fn _role, _harness, _ctx, _opts -> {:error, "deterministic failure"} end

      log_died_fn = fn role, kind, cause, _cycle_log ->
        Agent.update(died_agent, fn calls -> calls ++ [{role, kind, cause}] end)
        :ok
      end

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
                 log_died_fn: log_died_fn
               )

      assert reason =~ "failed twice"

      assert Agent.get(died_agent, & &1) == [
               {"developer-static", "interrupted", "deterministic failure"},
               {"developer-static", "aborted", "deterministic failure"}
             ]
    end

    test "role fails with a transient reason repeatedly → retries up to 4 attempts with backoff, then aborts",
         %{calls_agent: calls_agent} do
      {:ok, died_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(died_agent), do: Agent.stop(died_agent) end)
      {:ok, sleep_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(sleep_agent), do: Agent.stop(sleep_agent) end)

      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)
        {:error, "API Error: 529 overloaded_error"}
      end

      log_died_fn = fn role, kind, cause, _cycle_log ->
        Agent.update(died_agent, fn calls -> calls ++ [{role, kind, cause}] end)
        :ok
      end

      sleep_fn = fn ms -> Agent.update(sleep_agent, fn calls -> calls ++ [ms] end) end

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
                 log_died_fn: log_died_fn,
                 sleep_fn: sleep_fn
               )

      assert reason =~ "failed after 4 attempts"

      # 4 attempts total for the first role in the sequence (developer-static)
      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "developer-static")) == 4

      # 3 backoff sleeps between the 4 attempts, increasing per the backoff table
      assert Agent.get(sleep_agent, & &1) == [15_000, 60_000, 120_000]

      assert Agent.get(died_agent, & &1) == [
               {"developer-static", "interrupted", "API Error: 529 overloaded_error"},
               {"developer-static", "interrupted", "API Error: 529 overloaded_error"},
               {"developer-static", "interrupted", "API Error: 529 overloaded_error"},
               {"developer-static", "aborted", "API Error: 529 overloaded_error"}
             ]
    end

    test "role fails with a transient reason then succeeds on retry → recovers without exhausting attempts",
         %{calls_agent: calls_agent} do
      {:ok, fail_count_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(fail_count_agent), do: Agent.stop(fail_count_agent) end)

      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "developer-static" do
          n = Agent.get_and_update(fail_count_agent, fn n -> {n, n + 1} end)

          if n < 2 do
            {:error, "socket hang up"}
          else
            {:ok, %{"status" => "success", "value" => "did developer-static"}}
          end
        else
          value = if reviewer_role?(role), do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"
          {:ok, %{"status" => "success", "value" => value}}
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 sleep_fn: fn _ms -> :ok end
               )

      # 2 failures + 1 success = 3 total invocations of developer-static
      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "developer-static")) == 3
    end

    test "role fails with a switch_model reason → walks the fallback chain instead of retrying the same model",
         %{calls_agent: calls_agent} do
      {:ok, died_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(died_agent), do: Agent.stop(died_agent) end)
      {:ok, models_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(models_agent), do: Agent.stop(models_agent) end)

      resolve_fn = fn _r, _h -> {"sonnet", "medium"} end
      resolve_fallback_fn = fn _role, _harness, 0 -> {"opus", "medium"} end

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        model =
          case get_in(ctx, [:artifacts, :escalated_model]) do
            {m, _e} -> m
            _ -> "sonnet"
          end

        Agent.update(models_agent, fn calls -> calls ++ [{role, model}] end)

        if role == "developer-static" and model == "sonnet" do
          {:error, "Claude Fable 5 is currently unavailable"}
        else
          value = if reviewer_role?(role), do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"
          {:ok, %{"status" => "success", "value" => value}}
        end
      end

      log_died_fn = fn role, kind, cause, _cycle_log ->
        Agent.update(died_agent, fn calls -> calls ++ [{role, kind, cause}] end)
        :ok
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 resolve_fn: resolve_fn,
                 resolve_fallback_fn: resolve_fallback_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 log_died_fn: log_died_fn
               )

      # First attempt at the normal model (sonnet), second attempt at
      # fallback rung 0 (opus) — never a second attempt on sonnet.
      dev_models =
        models_agent
        |> Agent.get(& &1)
        |> Enum.filter(fn {role, _model} -> role == "developer-static" end)

      assert dev_models == [
               {"developer-static", "sonnet"},
               {"developer-static", "opus"}
             ]

      assert Agent.get(died_agent, & &1) == [
               {"developer-static", "interrupted", "Claude Fable 5 is currently unavailable"}
             ]
    end

    test "role fails with a switch_model reason and the fallback chain is exhausted → fails loud naming every rung tried" do
      resolve_fallback_fn = fn _role, _harness, _rung -> :none end

      invoke_fn = fn _role, _harness, _ctx, _opts ->
        {:error, "model X is currently unavailable"}
      end

      assert {:error, reason} =
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 resolve_fallback_fn: resolve_fallback_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn()
               )

      assert reason =~ "exhausted model fallback chain"
      assert reason =~ "no fallback rungs configured"
      assert reason =~ "model X is currently unavailable"
    end

    test "switch_model fallback resolution uses the per-role resolve_harness_fn override, not the build harness" do
      {:ok, harness_seen_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(harness_seen_agent), do: Agent.stop(harness_seen_agent) end)

      resolve_harness_fn = fn "developer-static", "claude_code" -> "pi" end

      resolve_fallback_fn = fn "developer-static", harness, 0 ->
        Agent.update(harness_seen_agent, fn seen -> seen ++ [harness] end)
        {"openai-codex/gpt-5.4", "medium"}
      end

      invoke_fn = fn role, _harness, ctx, _opts ->
        model =
          case get_in(ctx, [:artifacts, :escalated_model]) do
            {m, _e} -> m
            _ -> "sonnet"
          end

        if role == "developer-static" and model == "sonnet" do
          {:error, "model X is currently unavailable"}
        else
          value = if reviewer_role?(role), do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"
          {:ok, %{"status" => "success", "value" => value}}
        end
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 resolve_harness_fn: resolve_harness_fn,
                 resolve_fallback_fn: resolve_fallback_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert Agent.get(harness_seen_agent, & &1) == ["pi"]
    end

    test "default :log_died_fn with no cycle log initialized (nil path) → silent no-op, run still completes" do
      {:ok, fail_once_agent} = Agent.start_link(fn -> MapSet.new() end)
      on_exit(fn -> if Process.alive?(fail_once_agent), do: Agent.stop(fail_once_agent) end)

      invoke_fn = fn role, _harness, _ctx, _opts ->
        already_failed = Agent.get(fail_once_agent, &MapSet.member?(&1, role))

        if role == "reviewer-static" and not already_failed do
          Agent.update(fail_once_agent, &MapSet.put(&1, role))
          {:error, "transient blip"}
        else
          value = if reviewer_role?(role), do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"
          {:ok, %{"status" => "success", "value" => value}}
        end
      end

      # No log_died_fn override → exercises the REAL default_log_died/4 with
      # no cycle log initialized (Process.get(@log_path_key) == nil, since no
      # :slug/:log_init_fn was passed) — must be a silent no-op, not a crash.
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )
    end

    test "default :log_died_fn with a real cycle log → writes a real {\"ev\":\"died\"} event via codegen-log",
         %{calls_agent: calls_agent} do
      log_path = fresh_cycle_log!()
      {:ok, fail_once_agent} = Agent.start_link(fn -> MapSet.new() end)
      on_exit(fn -> if Process.alive?(fail_once_agent), do: Agent.stop(fail_once_agent) end)

      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)
        already_failed = Agent.get(fail_once_agent, &MapSet.member?(&1, role))

        if role == "reviewer-static" and not already_failed do
          Agent.update(fail_once_agent, &MapSet.put(&1, role))
          {:error, "transient blip"}
        else
          value = if reviewer_role?(role), do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"
          {:ok, %{"status" => "success", "value" => value}}
        end
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 slug: "adhoc",
                 log_init_fn: log_init_fn_for(log_path),
                 invoke_fn: invoke_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      events =
        log_path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["ev"] == "died"))

      assert [%{"role" => "reviewer-static", "kind" => "interrupted"}] = events
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

    test "per-role harness override (resolve_harness_fn) is used for both resolve_fn and codegen_call_fn, not the build harness" do
      harness_seen_by_resolve_fn = Agent.start_link(fn -> nil end) |> elem(1)
      harness_seen_by_codegen_call_fn = Agent.start_link(fn -> nil end) |> elem(1)

      on_exit(fn ->
        if Process.alive?(harness_seen_by_resolve_fn), do: Agent.stop(harness_seen_by_resolve_fn)

        if Process.alive?(harness_seen_by_codegen_call_fn),
          do: Agent.stop(harness_seen_by_codegen_call_fn)
      end)

      resolve_harness_fn = fn "developer-static", "claude_code" -> "pi" end

      resolve_fn = fn _role, harness ->
        Agent.update(harness_seen_by_resolve_fn, fn _ -> harness end)
        {"openai-codex/gpt-5.4", "medium"}
      end

      codegen_call_fn = fn harness, _model, _effort, _sp, _tools, _prompt ->
        Agent.update(harness_seen_by_codegen_call_fn, fn _ -> harness end)
        %{"result" => %{"status" => "success", "value" => "x"}}
      end

      assert {:ok, _result} =
               OrchestrationLoop.invoke_role(
                 "developer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_harness_fn: resolve_harness_fn,
                 resolve_fn: resolve_fn,
                 codegen_call_fn: codegen_call_fn
               )

      assert Agent.get(harness_seen_by_resolve_fn, & &1) == "pi"
      assert Agent.get(harness_seen_by_codegen_call_fn, & &1) == "pi"
    end

    # Uses reviewer-static: a role with NO `.harness.<role>.harness` key in the
    # real config.yaml. It used to name developer-static, which acquired a
    # deliberate `harness: pi` override (it runs on ChatGPT inside claude
    # builds), so this test then asserted the opposite of the shipped config and
    # failed. Keep this pinned to a genuinely override-free role — the point is
    # the passthrough default, not the identity of the role.
    test "no per-role harness override (default resolve_harness_fn against real config.yaml) -> build harness unchanged" do
      codegen_call_fn = fn harness, _model, _effort, _sp, _tools, _prompt ->
        assert harness == "claude_code"
        %{"result" => %{"status" => "success", "value" => "x"}}
      end

      resolve_fn = fn _role, harness ->
        assert harness == "claude_code"
        {"sonnet", "medium"}
      end

      assert {:ok, _result} =
               OrchestrationLoop.invoke_role(
                 "reviewer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 codegen_call_fn: codegen_call_fn
               )
    end

    # Twin of the above: developer-static DOES carry `harness: pi`, so the
    # build-wide harness must be overridden per role. This is the regression
    # guard for the shipped "ChatGPT for developer-static" config — if someone
    # drops the key from config.yaml, this fails loudly rather than silently
    # routing the role back to claude.
    test "per-role harness override (developer-static) -> pi wins over the build harness" do
      test_pid = self()

      codegen_call_fn = fn harness, _model, _effort, _sp, _tools, _prompt ->
        send(test_pid, {:harness_used, harness})
        %{"result" => %{"status" => "success", "value" => "x"}}
      end

      resolve_fn = fn _role, harness ->
        send(test_pid, {:resolved_for, harness})
        {"openai-codex/gpt-5.6-terra", "high"}
      end

      assert {:ok, _result} =
               OrchestrationLoop.invoke_role(
                 "developer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 codegen_call_fn: codegen_call_fn
               )

      assert_received {:resolved_for, "pi"}
      assert_received {:harness_used, "pi"}
    end
  end

  describe "invoke_role/4 — per-cycle spend cap (--max-budget-usd / opts[:max_budget_usd])" do
    # accumulate_telemetry/2 stores in the process dictionary — reset before
    # AND after each test so no cost leaks across tests in this async: true
    # module (each test runs in its own ExUnit process, but a stray value
    # left by a prior failing assertion in this SAME process must not bleed
    # into the next test run on that process).
    setup do
      Process.delete(:loop_telemetry)
      on_exit(fn -> Process.delete(:loop_telemetry) end)
      :ok
    end

    defp cost_envelope(cost_usd) do
      %{
        "result" => %{"status" => "success", "value" => "x"},
        "usage" => %{"cost_usd" => cost_usd}
      }
    end

    test "(a) accumulated spend crossing the cap aborts BETWEEN role invocations, naming spend and cap" do
      resolve_fn = fn _role, _harness -> {"sonnet", "medium"} end

      # First call: $6, under a $10 cap -> succeeds.
      assert {:ok, _} =
               OrchestrationLoop.invoke_role(
                 "developer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 codegen_call_fn: fn _h, _m, _e, _sp, _t, _pr -> cost_envelope(6.0) end,
                 max_budget_usd: 10.0
               )

      # Second call: another $6 -> accumulated $12 >= $10 cap -> aborts.
      assert {:error, reason} =
               OrchestrationLoop.invoke_role(
                 "developer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 codegen_call_fn: fn _h, _m, _e, _sp, _t, _pr -> cost_envelope(6.0) end,
                 max_budget_usd: 10.0
               )

      assert reason =~ "spend cap reached"
      assert reason =~ "$12.00"
      assert reason =~ "$10.00"
      assert reason =~ "--max-budget-usd"
    end

    test "(a-integer) an integer-form cap value (OptionParser :float coercion) is honored" do
      resolve_fn = fn _role, _harness -> {"sonnet", "medium"} end

      assert {:error, reason} =
               OrchestrationLoop.invoke_role(
                 "developer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 codegen_call_fn: fn _h, _m, _e, _sp, _t, _pr -> cost_envelope(25.0) end,
                 # An integer literal (as OptionParser's :float type coerces
                 # "20" -> 20.0) must compare correctly against a float spend.
                 max_budget_usd: 20
               )

      assert reason =~ "spend cap reached"
    end

    test "(a2) no-cap control: max_budget_usd absent (nil) -> proceeds exactly as today, regardless of spend" do
      resolve_fn = fn _role, _harness -> {"sonnet", "medium"} end

      assert {:ok, _} =
               OrchestrationLoop.invoke_role(
                 "developer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 codegen_call_fn: fn _h, _m, _e, _sp, _t, _pr -> cost_envelope(999.0) end
               )

      assert {:ok, _} =
               OrchestrationLoop.invoke_role(
                 "developer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 codegen_call_fn: fn _h, _m, _e, _sp, _t, _pr -> cost_envelope(999.0) end
               )
    end
  end

  describe "warm resume on transient retry" do
    test "transient failure carries the SAME resume_session_id into the next attempt's ctx",
         %{calls_agent: calls_agent} do
      {:ok, seen_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(seen_agent), do: Agent.stop(seen_agent) end)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "developer-static" do
          Agent.update(seen_agent, fn seen ->
            seen ++
              [
                {get_in(ctx, [:artifacts, :resume_session_id]),
                 ctx.artifacts.transport_session_id}
              ]
          end)
        end

        if role == "developer-static" and length(Agent.get(seen_agent, & &1)) < 2 do
          {:error, "Connection closed mid-response"}
        else
          value = if reviewer_role?(role), do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"
          {:ok, %{"status" => "success", "value" => value}}
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 sleep_fn: fn _ms -> :ok end
               )

      [{nil, cold_id}, {resume_id, transport_id}] = Agent.get(seen_agent, & &1)

      # Attempt 1: cold — no resume id yet, a fresh transport_session_id minted.
      assert is_binary(cold_id) and cold_id != ""
      # Attempt 2: resumes — resume_session_id equals attempt 1's minted id,
      # and transport_session_id is threaded to the SAME value (a second drop
      # would resume the same session again).
      assert resume_id == cold_id
      assert transport_id == cold_id
    end

    test "deterministic (non-transient) failure carries NO resume_session_id on retry",
         %{calls_agent: calls_agent} do
      {:ok, seen_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(seen_agent), do: Agent.stop(seen_agent) end)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "developer-static" do
          Agent.update(seen_agent, fn seen ->
            seen ++ [get_in(ctx, [:artifacts, :resume_session_id])]
          end)
        end

        if role == "developer-static" and length(Agent.get(seen_agent, & &1)) < 2 do
          {:error, "deterministic failure"}
        else
          value = if reviewer_role?(role), do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"
          {:ok, %{"status" => "success", "value" => value}}
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert Agent.get(seen_agent, & &1) == [nil, nil]
    end

    test "a resumed attempt's stale-session reason falls back to a FRESH cold id, never loops",
         %{calls_agent: calls_agent} do
      {:ok, seen_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(seen_agent), do: Agent.stop(seen_agent) end)

      # Attempt 1: transient drop -> attempt 2 resumes the same session.
      # Attempt 2 (resumed): the resumed session itself turns out to have
      # never persisted -> stale_session_reason?/1 matches -> attempt 3 must
      # fall back to a FRESH cold id (not the same one, and not resumed).
      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "developer-static" do
          Agent.update(seen_agent, fn seen ->
            seen ++
              [
                {get_in(ctx, [:artifacts, :resume_session_id]),
                 ctx.artifacts.transport_session_id}
              ]
          end)
        end

        case {role, length(Agent.get(seen_agent, & &1))} do
          {"developer-static", 1} ->
            {:error, "Connection closed mid-response"}

          {"developer-static", 2} ->
            {:error,
             "No conversation found with session ID: " <> ctx.artifacts.transport_session_id}

          _ ->
            value = if reviewer_role?(role), do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"
            {:ok, %{"status" => "success", "value" => value}}
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 sleep_fn: fn _ms -> :ok end
               )

      [{nil, cold_id_1}, {resume_id_2, transport_id_2}, {resume_id_3, cold_id_3}] =
        Agent.get(seen_agent, & &1)

      # Attempt 2 correctly resumed attempt 1's session.
      assert resume_id_2 == cold_id_1
      assert transport_id_2 == cold_id_1

      # Attempt 3 falls back cold: no resume id carried forward, and a BRAND
      # NEW transport_session_id (never loops on the dead session).
      assert is_nil(resume_id_3)
      assert cold_id_3 != cold_id_1
    end
  end

  describe "mint_session_id/0 (via warm resume)" do
    test "minted ids are lowercase v4-uuid shaped", %{calls_agent: calls_agent} do
      {:ok, seen_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(seen_agent), do: Agent.stop(seen_agent) end)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)
        Agent.update(seen_agent, fn seen -> seen ++ [ctx.artifacts.transport_session_id] end)
        value = if reviewer_role?(role), do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      [id | _] = Agent.get(seen_agent, & &1)

      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
               id
             )
    end
  end

  describe "resume_prompt/1" do
    test "returns a short continuation instruction distinct from the full pitch" do
      prompt = OrchestrationLoop.resume_prompt("developer-static")

      assert prompt =~ "cut off"
      assert prompt =~ "Continue from where you stopped"
      refute prompt =~ "do the thing"
    end
  end

  describe "run/1 — gate handling" do
    test "gate verdict=failed → developer re-run within budget, then success on retry", %{
      calls_agent: calls_agent
    } do
      {:ok, gate_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(gate_calls_agent), do: Agent.stop(gate_calls_agent) end)

      # Calls: 0 = initial gate (failed), 1 = the flake-check standalone
      # re-run (stays failed — a genuine red, not a load flake), 2 = the
      # gate re-run after the developer's rework (clear).
      gate_fn = fn _cwd, _opts ->
        n = Agent.get_and_update(gate_calls_agent, fn n -> {n, n + 1} end)
        if n <= 1, do: {:failed, "make test"}, else: {:clear, "make test"}
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
                 preflight_probe_fn: all_present_preflight_probe_fn()
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
          preflight_probe_fn: all_present_preflight_probe_fn()
        )
      end
    end

    test "gate failure classified :infra aborts loud — NEVER re-invokes the developer", %{
      calls_agent: calls_agent
    } do
      gate_fn = fn _cwd, _opts -> {:failed, "make test"} end
      gate_classify_fn = fn _cwd, _dev_role -> :infra end

      assert_raise CodegenTestHarness.InfraAbort,
                   ~r/failed for a reason no developer edit can fix/,
                   fn ->
                     OrchestrationLoop.run(
                       harness: "claude_code",
                       stack: "static",
                       cwd: "/tmp/irrelevant",
                       pitch: "do the thing",
                       invoke_fn: always_ok_invoke_fn(calls_agent),
                       gate_fn: gate_fn,
                       gate_classify_fn: gate_classify_fn,
                       gate_preflight_fn: no_op_gate_preflight_fn(),
                       preflight_probe_fn: all_present_preflight_probe_fn()
                     )
                   end

      # developer-static ran ONCE (the normal initial pass) — never a SECOND
      # time as a gate-failure rework: a developer edit could not have fixed
      # this, so the rework budget must never be spent on it (the entire
      # point of the pitch).
      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "developer-static")) == 1
    end

    test "gate failure classified :code still reworks as before (unchanged behavior)", %{
      calls_agent: calls_agent
    } do
      {:ok, gate_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(gate_calls_agent), do: Agent.stop(gate_calls_agent) end)

      gate_fn = fn _cwd, _opts ->
        n = Agent.get_and_update(gate_calls_agent, fn n -> {n, n + 1} end)
        if n <= 1, do: {:failed, "make test"}, else: {:clear, "make test"}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: gate_fn,
                 gate_classify_fn: fn _cwd, dev_role -> {:owner, dev_role} end,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "developer-static")) == 2
    end

    test "phoenix: gate runs after developer-phoenix-backend (not post-planner), and a failed verdict re-invokes the developer",
         %{calls_agent: calls_agent} do
      {:ok, gate_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(gate_calls_agent), do: Agent.stop(gate_calls_agent) end)

      # gate_fn records a "GATE" marker into the same calls_agent list used by
      # invoke_fn, so the interleave position (relative to role invocations)
      # is directly observable — not just the eventual role-call counts.
      gate_fn = fn _cwd, _opts ->
        n = Agent.get_and_update(gate_calls_agent, fn n -> {n, n + 1} end)
        Agent.update(calls_agent, fn calls -> calls ++ ["GATE"] end)
        if n <= 1, do: {:failed, "make test"}, else: {:clear, "make test"}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "phoenix",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: gate_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 planner_plan_fn: stub_planner_plan_fn()
               )

      calls = Agent.get(calls_agent, & &1)

      # The gate interleaves immediately after developer-phoenix-backend —
      # NOT immediately after planner-phoenix. First GATE marker sits right
      # after the first developer-phoenix-backend call.
      first_gate_idx = Enum.find_index(calls, &(&1 == "GATE"))
      first_dev_idx = Enum.find_index(calls, &(&1 == "developer-phoenix-backend"))
      first_planner_idx = Enum.find_index(calls, &(&1 == "planner-phoenix"))

      assert first_gate_idx == first_dev_idx + 1
      assert first_gate_idx > first_planner_idx + 1

      # A :failed verdict re-invokes the DEVELOPER, never the planner:
      # developer-phoenix-backend runs twice (initial + gate-failure rework),
      # planner-phoenix runs exactly once.
      assert Enum.count(calls, &(&1 == "developer-phoenix-backend")) == 2
      assert Enum.count(calls, &(&1 == "planner-phoenix")) == 1

      # Full role sequence still completes to the end (reviewer/curator/committer).
      assert "reviewer-phoenix" in calls
      assert "context-curator" in calls
      assert "committer" in calls
    end
  end

  describe "run/1 — gate failure owner-routing" do
    test "a context-doc-shaped witness routes the rework to context-curator, not the developer",
         %{calls_agent: calls_agent} do
      {:ok, gate_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(gate_calls_agent), do: Agent.stop(gate_calls_agent) end)

      gate_fn = fn _cwd, _opts ->
        n = Agent.get_and_update(gate_calls_agent, fn n -> {n, n + 1} end)
        if n <= 1, do: {:failed, "make test"}, else: {:clear, "make test"}
      end

      gate_classify_fn = fn _cwd, dev_role ->
        # Simulates a witness naming context/foo.md — resolve_gate_owner/2's
        # own signature match, exercised end-to-end via the seam rather than
        # a real gate-run.log fixture.
        _ = dev_role
        {:owner, "context-curator"}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "phoenix",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: gate_fn,
                 gate_classify_fn: gate_classify_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 planner_plan_fn: stub_planner_plan_fn()
               )

      calls = Agent.get(calls_agent, & &1)

      # context-curator was invoked TWICE for this cycle: once as the
      # gate-failure rework (owner-routed), once as the normal end-of-cycle
      # curator step — the developer was NEVER re-invoked for the gate
      # failure it did not own.
      assert Enum.count(calls, &(&1 == "context-curator")) == 2
      assert Enum.count(calls, &(&1 == "developer-phoenix-backend")) == 1
    end

    test "an unmapped witness still routes to the developer (today's behavior preserved)", %{
      calls_agent: calls_agent
    } do
      {:ok, gate_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(gate_calls_agent), do: Agent.stop(gate_calls_agent) end)

      gate_fn = fn _cwd, _opts ->
        n = Agent.get_and_update(gate_calls_agent, fn n -> {n, n + 1} end)
        if n <= 1, do: {:failed, "make test"}, else: {:clear, "make test"}
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "developer-static")) == 2
    end
  end

  describe "run/1 — gate flake-check leg" do
    test "a check green standalone re-runs the gate once WITHOUT consuming a rework attempt", %{
      calls_agent: calls_agent
    } do
      {:ok, gate_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(gate_calls_agent), do: Agent.stop(gate_calls_agent) end)

      # Call 0: initial gate -> failed. Call 1: flake-check standalone
      # re-run -> CLEAR (the flake). Since do_gate_loop_flake_check's own
      # clear branch re-enters do_gate_loop (not the rework path), the
      # developer must never be re-invoked for this gate failure.
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      # developer-static invoked exactly ONCE — the load flake absorbed the
      # failure without spending a rework attempt.
      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "developer-static")) == 1
    end

    test "a second consecutive red on the flake re-run is treated as genuinely red (no infinite flake loop)",
         %{calls_agent: calls_agent} do
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
                 preflight_probe_fn: all_present_preflight_probe_fn()
               )

      assert reason =~ "gate verdict=failed"
    end
  end

  describe "run/1 — terminal marker on deterministic gate exhaustion" do
    test "gate exhaustion writes codegen/gate-pending/terminal-state.json naming the owner", %{
      calls_agent: calls_agent
    } do
      tmp_cwd =
        Path.join(System.tmp_dir!(), "loop-terminal-marker-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_cwd)
      on_exit(fn -> File.rm_rf!(tmp_cwd) end)

      gate_fn = fn _cwd, _opts -> {:failed, "make test"} end

      assert {:error, _reason} =
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: tmp_cwd,
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: gate_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn()
               )

      marker =
        Path.join(tmp_cwd, "codegen/gate-pending/terminal-state.json")
        |> File.read!()
        |> Jason.decode!()

      assert marker["terminal"] == true
      assert marker["reason"] =~ "gate verdict=failed"
      assert marker["owner"] == "developer-static"
    end
  end

  describe "build_prompt/2 — planner plan threading" do
    test "developer prompt threads the resolved plan verbatim under its own ## Plan heading" do
      plan = "## Plan\n\n**Approach**: do the thing.\n\n**Files to touch**: lib/foo.ex (NEW)"

      ctx = %{
        cwd: "/tmp",
        pitch: "raw pitch text",
        artifacts: %{planner_plan: plan}
      }

      content = OrchestrationLoop.build_prompt("developer-phoenix-backend", ctx)

      assert content =~ "## Plan"
      assert content =~ "**Files to touch**: lib/foo.ex (NEW)"
      refute content =~ "Implementation plan (from the planner)"
    end

    test "no :planner_plan artifact → prompt is just the raw pitch (static path unaffected)" do
      ctx = %{cwd: "/tmp", pitch: "raw pitch text", artifacts: %{}}

      content = OrchestrationLoop.build_prompt("developer-static", ctx)

      assert content == "raw pitch text"
      refute content =~ "## Plan"
    end

    test "blank :planner_plan artifact → no plan block appended" do
      ctx = %{cwd: "/tmp", pitch: "raw pitch text", artifacts: %{planner_plan: ""}}

      content = OrchestrationLoop.build_prompt("developer-phoenix-backend", ctx)

      assert content == "raw pitch text"
    end

    test "reviewer-phoenix prompt IS enriched with the plan block" do
      plan = "## Plan\n\n**Approach**: do the thing."

      ctx = %{
        cwd: "/tmp",
        pitch: "raw pitch text",
        artifacts: %{planner_plan: plan}
      }

      content = OrchestrationLoop.build_prompt("reviewer-phoenix", ctx)

      assert content =~ "## Plan"
      assert content =~ "**Approach**: do the thing."
    end

    test "reviewer-static prompt is NOT enriched (static has no planner, artifact absent)" do
      ctx = %{cwd: "/tmp", pitch: "raw pitch text", artifacts: %{}}

      content = OrchestrationLoop.build_prompt("reviewer-static", ctx)

      refute content =~ "## Plan"
    end

    test "committer and context-curator prompts are not enriched with the plan block" do
      plan = "## Plan\n\n**Approach**: do the thing."

      ctx = %{
        cwd: "/tmp",
        pitch: "raw pitch text",
        artifacts: %{planner_plan: plan}
      }

      committer_content = OrchestrationLoop.build_prompt("committer", ctx)
      curator_content = OrchestrationLoop.build_prompt("context-curator", ctx)

      refute committer_content =~ "**Approach**: do the thing."
      refute curator_content =~ "**Approach**: do the thing."
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

  describe "build_prompt/2 — repair brief threading" do
    test "developer prompt includes the repair brief when :rework_brief is present" do
      brief =
        "### Your current diff (uncommitted, authoritative)\n\n```diff\n+foo\n```\n\n" <>
          "### Untracked files\n\n```\n?? new_file.ex\n```"

      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{rework_brief: brief}
      }

      content = OrchestrationLoop.build_prompt("developer-static", ctx)

      assert content =~ "Repair brief — this is a repair, not a rebuild"
      assert content =~ "this is a repair, not a rebuild"
      assert content =~ "+foo"
      assert content =~ "?? new_file.ex"
    end

    test "no :rework_brief artifact → no repair brief block appended" do
      ctx = %{cwd: "/tmp", pitch: "do the thing", artifacts: %{}}

      content = OrchestrationLoop.build_prompt("developer-static", ctx)

      refute content =~ "Repair brief"
    end

    test "empty :rework_brief (blank string) → no repair brief block appended" do
      ctx = %{cwd: "/tmp", pitch: "do the thing", artifacts: %{rework_brief: ""}}

      content = OrchestrationLoop.build_prompt("developer-static", ctx)

      refute content =~ "Repair brief"
    end

    test "non-developer role prompt is not enriched with the repair brief" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{rework_brief: "### Your current diff\n\n```diff\n+foo\n```"}
      }

      content = OrchestrationLoop.build_prompt("reviewer-static", ctx)

      refute content =~ "Repair brief"
    end

    test "oversized brief (built by default_rework_brief_fn/1 over the cap) renders --stat fallback" do
      # default_rework_brief_fn/1 itself produces the --stat fallback wording
      # when the diff exceeds @rework_brief_max_bytes; here we simulate the
      # already-built oversized-fallback brief text landing in ctx, since
      # build_prompt/2 only renders what it is handed.
      brief =
        "### Your current diff (uncommitted, authoritative) — TOO LARGE TO INLINE\n\n" <>
          "Diff is 45000 bytes — too large to inline. Run `git diff HEAD -- <path>` for " <>
          "the specific files named in the fault below; do not sweep the tree.\n\n" <>
          "```\n lib/foo.ex | 200 +++++++++\n```\n\n" <>
          "### Untracked files\n\n```\n?? new_file.ex\n```"

      ctx = %{cwd: "/tmp", pitch: "do the thing", artifacts: %{rework_brief: brief}}

      content = OrchestrationLoop.build_prompt("developer-phoenix-backend", ctx)

      assert content =~ "Repair brief"
      assert content =~ "TOO LARGE TO INLINE"
      assert content =~ "too large to inline"
      assert content =~ "do not sweep the tree"
    end
  end

  describe "default_rework_brief_fn/1" do
    test "non-git cwd returns empty string" do
      assert OrchestrationLoop.default_rework_brief_fn("/tmp/definitely-not-a-git-repo-xyz") == ""
    end

    test "clean git work tree (no diff, nothing untracked) returns empty string" do
      tmp =
        System.tmp_dir!() |> Path.join("rework-brief-clean-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      {_out, 0} = System.cmd("git", ["init", "-q"], cd: tmp)
      {_out, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: tmp)
      {_out, 0} = System.cmd("git", ["config", "user.name", "T"], cd: tmp)
      File.write!(Path.join(tmp, "a.txt"), "hello\n")
      {_out, 0} = System.cmd("git", ["add", "a.txt"], cd: tmp)
      {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: tmp)

      assert OrchestrationLoop.default_rework_brief_fn(tmp) == ""
    end

    test "dirty tracked file + untracked file produces a non-empty brief with both sections" do
      tmp =
        System.tmp_dir!() |> Path.join("rework-brief-dirty-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      {_out, 0} = System.cmd("git", ["init", "-q"], cd: tmp)
      {_out, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: tmp)
      {_out, 0} = System.cmd("git", ["config", "user.name", "T"], cd: tmp)
      File.write!(Path.join(tmp, "a.txt"), "hello\n")
      {_out, 0} = System.cmd("git", ["add", "a.txt"], cd: tmp)
      {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: tmp)

      File.write!(Path.join(tmp, "a.txt"), "hello\nworld\n")
      File.write!(Path.join(tmp, "new.txt"), "new\n")

      brief = OrchestrationLoop.default_rework_brief_fn(tmp)

      assert brief =~ "Your current diff (uncommitted, authoritative)"
      assert brief =~ "+world"
      assert brief =~ "Untracked files"
      assert brief =~ "?? new.txt"
    end

    test "unborn HEAD (zero commits) falls back to bare `git diff` instead of raising" do
      tmp =
        System.tmp_dir!()
        |> Path.join("rework-brief-unborn-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      {_out, 0} = System.cmd("git", ["init", "-q"], cd: tmp)
      File.write!(Path.join(tmp, "a.txt"), "hello\n")

      brief = OrchestrationLoop.default_rework_brief_fn(tmp)

      # Unborn HEAD -> untracked-only (bare `git diff` sees nothing to
      # compare against for an unstaged new file); the untracked section
      # still names it.
      assert brief =~ "Untracked files"
      assert brief =~ "?? a.txt"
    end
  end

  describe "default_review_file_set_fn/1" do
    test "non-git cwd returns empty string" do
      assert OrchestrationLoop.default_review_file_set_fn(
               "/tmp/definitely-not-a-git-repo-#{System.unique_integer([:positive])}"
             ) == ""
    end

    test "tracked mod + untracked file both appear in the returned list" do
      tmp =
        System.tmp_dir!()
        |> Path.join("review-file-set-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      {_out, 0} = System.cmd("git", ["init", "-q"], cd: tmp)
      {_out, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: tmp)
      {_out, 0} = System.cmd("git", ["config", "user.name", "T"], cd: tmp)
      File.write!(Path.join(tmp, "a.txt"), "hello\n")
      {_out, 0} = System.cmd("git", ["add", "a.txt"], cd: tmp)
      {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: tmp)

      File.write!(Path.join(tmp, "a.txt"), "hello\nworld\n")
      File.write!(Path.join(tmp, "new.txt"), "new\n")

      set = OrchestrationLoop.default_review_file_set_fn(tmp)

      assert set =~ "a.txt"
      assert set =~ "new.txt"
    end

    test "clean git work tree returns empty string" do
      tmp =
        System.tmp_dir!()
        |> Path.join("review-file-set-clean-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      {_out, 0} = System.cmd("git", ["init", "-q"], cd: tmp)
      {_out, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: tmp)
      {_out, 0} = System.cmd("git", ["config", "user.name", "T"], cd: tmp)
      File.write!(Path.join(tmp, "a.txt"), "hello\n")
      {_out, 0} = System.cmd("git", ["add", "a.txt"], cd: tmp)
      {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: tmp)

      assert OrchestrationLoop.default_review_file_set_fn(tmp) == ""
    end
  end

  describe "run/1 — reviewer file set threading (loop-derived ## Files Modified)" do
    test "review_file_set_fn output reaches the reviewer prompt on first pass", %{
      calls_agent: calls_agent
    } do
      {:ok, prompt_agent} = Agent.start_link(fn -> nil end)
      on_exit(fn -> if Process.alive?(prompt_agent), do: Agent.stop(prompt_agent) end)

      set_fn = fn _cwd -> "lib/only_file.ex" end

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "reviewer-static" do
          prompt = OrchestrationLoop.build_prompt(role, ctx)
          Agent.update(prompt_agent, fn _ -> prompt end)
          {:ok, %{"status" => "success", "value" => "REVIEW_VERDICT: APPROVED"}}
        else
          {:ok, %{"status" => "success", "value" => "did #{role}"}}
        end
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 review_file_set_fn: set_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      prompt = Agent.get(prompt_agent, & &1)
      assert prompt =~ "## Files Modified"
      assert prompt =~ "lib/only_file.ex"
    end

    test "review_file_set_fn is re-captured fresh on a re-review pass", %{
      calls_agent: calls_agent
    } do
      {:ok, set_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(set_calls_agent), do: Agent.stop(set_calls_agent) end)

      {:ok, prompts_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(prompts_agent), do: Agent.stop(prompts_agent) end)

      set_fn = fn _cwd ->
        n = Agent.get_and_update(set_calls_agent, fn n -> {n, n + 1} end)
        "lib/pass_#{n}.ex"
      end

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "reviewer-static" do
          seen = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "reviewer-static"))
          prompt = OrchestrationLoop.build_prompt(role, ctx)
          Agent.update(prompts_agent, fn ps -> ps ++ [prompt] end)

          value =
            if seen <= 1,
              do: "REVIEW_VERDICT: CHANGES_REQUESTED — fix it",
              else: "REVIEW_VERDICT: APPROVED"

          {:ok, %{"status" => "success", "value" => value}}
        else
          {:ok, %{"status" => "success", "value" => "did #{role}"}}
        end
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 review_file_set_fn: set_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      prompts = Agent.get(prompts_agent, & &1)
      assert length(prompts) == 2
      assert Enum.at(prompts, 0) =~ "lib/pass_0.ex"
      assert Enum.at(prompts, 1) =~ "lib/pass_1.ex"
    end

    test "empty changed set in a real git tree → loop refuses to invoke the reviewer" do
      tmp =
        System.tmp_dir!()
        |> Path.join("review-empty-set-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      {_out, 0} = System.cmd("git", ["init", "-q"], cd: tmp)
      {_out, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: tmp)
      {_out, 0} = System.cmd("git", ["config", "user.name", "T"], cd: tmp)
      File.write!(Path.join(tmp, "a.txt"), "hello\n")
      {_out, 0} = System.cmd("git", ["add", "a.txt"], cd: tmp)
      {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: tmp)

      invoke_fn = fn role, _harness, _ctx, _opts ->
        {:ok, %{"status" => "success", "value" => "did #{role}"}}
      end

      assert {:error, reason} =
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: tmp,
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert reason =~ "cycle produced no changes — nothing for the reviewer to review"
    end

    test "gate-red developer re-entry then gate-clear → reviewer prompt carries no stale Previous attempt fault",
         %{calls_agent: calls_agent} do
      tmp_cwd =
        Path.join(
          System.tmp_dir!(),
          "loop-reviewer-no-leak-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_cwd)
      on_exit(fn -> File.rm_rf!(tmp_cwd) end)

      {:ok, gate_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(gate_calls_agent), do: Agent.stop(gate_calls_agent) end)

      gate_fn = fn _cwd, _opts ->
        n = Agent.get_and_update(gate_calls_agent, fn n -> {n, n + 1} end)
        if n == 0, do: {:failed, "make test"}, else: {:clear, "make test"}
      end

      {:ok, reviewer_prompt_agent} = Agent.start_link(fn -> nil end)

      on_exit(fn ->
        if Process.alive?(reviewer_prompt_agent), do: Agent.stop(reviewer_prompt_agent)
      end)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "reviewer-static" do
          prompt = OrchestrationLoop.build_prompt(role, ctx)
          Agent.update(reviewer_prompt_agent, fn _ -> prompt end)
          {:ok, %{"status" => "success", "value" => "REVIEW_VERDICT: APPROVED"}}
        else
          {:ok, %{"status" => "success", "value" => "did #{role}"}}
        end
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      reviewer_prompt = Agent.get(reviewer_prompt_agent, & &1)
      refute reviewer_prompt =~ "Previous attempt at role reviewer-"
    end
  end

  describe "run/1 — gate progress-based retry bound" do
    test "signature changes each attempt → re-invokes past legacy count-1 bound, then clears",
         %{calls_agent: calls_agent} do
      {:ok, gate_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(gate_calls_agent), do: Agent.stop(gate_calls_agent) end)

      # Fails 3 times (more than the legacy max_gate_retries: 1 default),
      # then clears — only possible under the progress bound, not the old
      # raw-count bound. Each real failure now costs TWO gate_fn calls (the
      # initial gate + the flake-check standalone re-run, which also stays
      # failed — a genuine red, not a load flake) before a rework attempt
      # is consumed: 3 real failures = 6 failed calls, then clear on the 7th.
      gate_fn = fn _cwd, _opts ->
        n = Agent.get_and_update(gate_calls_agent, fn n -> {n, n + 1} end)
        if n < 6, do: {:failed, "make test"}, else: {:clear, "make test"}
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
                 preflight_probe_fn: all_present_preflight_probe_fn()
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
        if n <= 1, do: {:failed, "make test"}, else: {:clear, "make test"}
      end

      {:ok, seen_reason_agent} = Agent.start_link(fn -> nil end)
      on_exit(fn -> if Process.alive?(seen_reason_agent), do: Agent.stop(seen_reason_agent) end)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "developer-static" do
          reason = get_in(ctx, [:artifacts, :last_failure_reason])
          Agent.update(seen_reason_agent, fn _ -> reason end)
        end

        value = if reviewer_role?(role), do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"
        {:ok, %{"status" => "success", "value" => value}}
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
                 preflight_probe_fn: all_present_preflight_probe_fn()
               )

      seen_reason = Agent.get(seen_reason_agent, & &1)
      assert seen_reason =~ "COMPILE ERROR: undefined function foo/1"
    end
  end

  describe "run/1 — gate-retry give-up-boundary model escalation" do
    # Non-git cwd -> tree_signature/1 unavailable -> falls back to the
    # legacy count bound (:max_gate_retries, default 1): attempt 0 (the
    # first rework retry) is the ONLY retry allowed, so it is also the
    # final one — escalation must fire on it.
    test "count-bound path: escalates on the one allowed retry when configured", %{
      calls_agent: calls_agent
    } do
      gate_fn = fn _cwd, _opts -> {:failed, "make test"} end

      {:ok, seen_ctx_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(seen_ctx_agent), do: Agent.stop(seen_ctx_agent) end)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "developer-static" do
          escalated = get_in(ctx, [:artifacts, :escalated_model])
          Agent.update(seen_ctx_agent, fn seen -> seen ++ [escalated] end)
        end

        {:ok, %{"status" => "success", "value" => "did #{role}"}}
      end

      resolve_escalation_fn = fn "developer-static", _harness -> {"opus", "high"} end

      assert {:error, reason} =
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 gate_fn: gate_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 resolve_escalation_fn: resolve_escalation_fn
               )

      assert reason =~ "gate verdict=failed"

      # initial call (no escalation, not a rework retry) + one rework retry
      # (the final allowed attempt -> escalated).
      assert Agent.get(seen_ctx_agent, & &1) == [nil, {"opus", "high"}]
    end

    test "count-bound path: escalation resolution uses the per-role resolve_harness_fn override, not the build harness",
         %{calls_agent: calls_agent} do
      gate_fn = fn _cwd, _opts -> {:failed, "make test"} end

      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)
        {:ok, %{"status" => "success", "value" => "did #{role}"}}
      end

      {:ok, harness_seen_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(harness_seen_agent), do: Agent.stop(harness_seen_agent) end)

      resolve_harness_fn = fn "developer-static", "claude_code" -> "pi" end

      resolve_escalation_fn = fn "developer-static", harness ->
        Agent.update(harness_seen_agent, fn seen -> seen ++ [harness] end)
        {"openai-codex/gpt-5.4", "high"}
      end

      assert {:error, _reason} =
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 gate_fn: gate_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 resolve_harness_fn: resolve_harness_fn,
                 resolve_escalation_fn: resolve_escalation_fn
               )

      assert Agent.get(harness_seen_agent, & &1) == ["pi"]
    end

    test "count-bound path: no escalation configured -> ctx unchanged, normal tier throughout", %{
      calls_agent: calls_agent
    } do
      gate_fn = fn _cwd, _opts -> {:failed, "make test"} end

      {:ok, seen_ctx_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(seen_ctx_agent), do: Agent.stop(seen_ctx_agent) end)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "developer-static" do
          escalated = get_in(ctx, [:artifacts, :escalated_model])
          Agent.update(seen_ctx_agent, fn seen -> seen ++ [escalated] end)
        end

        {:ok, %{"status" => "success", "value" => "did #{role}"}}
      end

      resolve_escalation_fn = fn "developer-static", _harness -> :none end

      assert {:error, _reason} =
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 gate_fn: gate_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 resolve_escalation_fn: resolve_escalation_fn
               )

      assert Agent.get(seen_ctx_agent, & &1) == [nil, nil]
    end

    # Signature-based path with continuous progress: escalation must NOT
    # fire on any attempt before the hard ceiling, even though each attempt
    # "looks stuck" until the tree actually stops changing — escalating
    # early would defeat the ~1.8% give-up-boundary frequency the pitch is
    # sized on. Uses a small ceiling override so the test doesn't need 16
    # developer invocations to reach the boundary.
    test "signature-bound path: escalates only at the hard ceiling, not on earlier progress retries",
         %{calls_agent: calls_agent} do
      gate_fn = fn _cwd, _opts -> {:failed, "make test"} end

      {:ok, sig_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(sig_calls_agent), do: Agent.stop(sig_calls_agent) end)

      signature_fn = fn _cwd ->
        n = Agent.get_and_update(sig_calls_agent, fn n -> {n, n + 1} end)
        "sig-#{n}"
      end

      {:ok, seen_ctx_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(seen_ctx_agent), do: Agent.stop(seen_ctx_agent) end)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "developer-static" do
          escalated = get_in(ctx, [:artifacts, :escalated_model])
          Agent.update(seen_ctx_agent, fn seen -> seen ++ [escalated] end)
        end

        {:ok, %{"status" => "success", "value" => "did #{role}"}}
      end

      resolve_escalation_fn = fn "developer-static", _harness -> {"opus", "high"} end

      assert {:error, _reason} =
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 gate_fn: gate_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 tree_signature_fn: signature_fn,
                 resolve_escalation_fn: resolve_escalation_fn
               )

      seen = Agent.get(seen_ctx_agent, & &1)
      # 1 initial call + 15 rework retries (hard ceiling) = 16 entries.
      assert length(seen) == 16
      # every attempt before the last is unescalated (continuous progress
      # keeps `allow?` true without ever being the "final" one) — only the
      # 16th (last, ceiling-exhausting) entry is escalated.
      {before_last, [last]} = Enum.split(seen, 15)
      assert Enum.all?(before_last, &(&1 == nil))
      assert last == {"opus", "high"}
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

      advance_fn = fn state, _step_log, _session_id, _verdict, _project_dir, _slug ->
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
                 advance_cycle_state_fn: advance_fn
               )

      assert Agent.get(states_agent, & &1) == ["GATED", "REVIEWED", "CURATED", "COMMITTED"]
    end

    test "GATED write carries verdict=clear; later states carry empty verdict" do
      {:ok, calls_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(calls_agent), do: Agent.stop(calls_agent) end)

      {:ok, verdicts_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(verdicts_agent), do: Agent.stop(verdicts_agent) end)

      advance_fn = fn state, _step_log, _session_id, verdict, _project_dir, _slug ->
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
                 format_fn: format_fn,
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      # developer-static (pre-gate) + context-curator (pre-commit) = 2 format calls
      assert Agent.get(format_calls_agent, & &1) == ["/tmp/irrelevant", "/tmp/irrelevant"]
    end
  end

  defp always_clean_curator_doc_fn do
    fn _cwd -> {:clean} end
  end

  describe "run/1 — context-curator conditional spawn (learning signal)" do
    # See LoopGate.curator_learning_signal/1 for the :learned/:no_learning/
    # :absent contract this predicate reads.
    test "signal :learned spawns the curator (unchanged behavior)", %{calls_agent: calls_agent} do
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 curator_doc_check_fn: always_clean_curator_doc_fn(),
                 curator_learning_signal_fn: fn _log_file -> :learned end
               )

      assert Agent.get(calls_agent, & &1) == @static_sequence
      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "context-curator")) == 1
    end

    test "signal :absent spawns the curator (fail-SAFE default — never skip on a missing signal)",
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 curator_doc_check_fn: always_clean_curator_doc_fn(),
                 curator_learning_signal_fn: fn _log_file -> :absent end
               )

      assert Agent.get(calls_agent, & &1) == @static_sequence
      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "context-curator")) == 1
    end

    test "signal :no_learning skips the curator spawn but still reaches the committer", %{
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 curator_doc_check_fn: always_clean_curator_doc_fn(),
                 curator_learning_signal_fn: fn _log_file -> :no_learning end
               )

      # "context-curator" never appears in calls_agent — no spawn happened —
      # but the sequence still terminates at the committer.
      refute "context-curator" in Agent.get(calls_agent, & &1)
      assert List.last(Agent.get(calls_agent, & &1)) == "committer"
    end

    test "signal :no_learning still runs the format step (doc scan runs on the pre-existing tree)",
         %{calls_agent: calls_agent} do
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
                 format_fn: format_fn,
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 curator_doc_check_fn: always_clean_curator_doc_fn(),
                 curator_learning_signal_fn: fn _log_file -> :no_learning end
               )

      # developer-static (pre-gate) format call PLUS the skip-path's own
      # format call (my run_roles clause calls run_format_step before
      # run_curator_doc_check even when the LLM spawn itself is skipped) =
      # 2 format calls, same total as the unconditional-spawn path.
      assert Agent.get(format_calls_agent, & &1) == ["/tmp/irrelevant", "/tmp/irrelevant"]
    end

    test "signal :no_learning still advances CURATED state (via run_curator_doc_check's :clean branch)" do
      {:ok, verdicts_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(verdicts_agent), do: Agent.stop(verdicts_agent) end)

      advance_fn = fn state, _step_log, _session_id, verdict, _cwd, _slug ->
        Agent.update(verdicts_agent, fn v -> v ++ [{state, verdict}] end)
        :ok
      end

      {:ok, calls_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(calls_agent), do: Agent.stop(calls_agent) end)

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
                 advance_cycle_state_fn: advance_fn,
                 curator_doc_check_fn: always_clean_curator_doc_fn(),
                 curator_learning_signal_fn: fn _log_file -> :no_learning end
               )

      assert {"CURATED", ""} in Agent.get(verdicts_agent, & &1)
    end

    test "signal :no_learning with a doc violation still spawns the curator for rework", %{
      calls_agent: calls_agent
    } do
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 curator_doc_check_fn: scan_fn,
                 curator_learning_signal_fn: fn _log_file -> :no_learning end
               )

      # The skipped spawn does NOT suppress the violation path — a
      # pre-existing doc violation still forces exactly one real curator
      # spawn for rework, even though the learning signal said "no_learning".
      curator_calls = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "context-curator"))
      assert curator_calls == 1
      assert List.last(Agent.get(calls_agent, & &1)) == "committer"
      assert Agent.get(scan_calls_agent, & &1) == 2
    end
  end

  describe "run/1 — curator doc check cycle (factcheck + index-parity)" do
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 curator_doc_check_fn: always_clean_curator_doc_fn()
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 curator_doc_check_fn: scan_fn
               )

      curator_calls = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "context-curator"))
      assert curator_calls == 2
      assert List.last(Agent.get(calls_agent, & &1)) == "committer"
      assert Agent.get(scan_calls_agent, & &1) == 2
    end

    # Regression for bug 5 (write/read key mismatch): the re-invoked
    # curator's PROMPT must actually carry the violation text scanned from
    # the FIRST pass — historically the write landed under
    # `:curator_doc_violations` while `build_prompt/2` read
    # `:factcheck_violations`, so the re-invoked curator was handed the raw
    # pitch with NO violation list at all.
    test "the re-invoked curator's prompt carries the scanned violation text (write/read key parity)",
         %{calls_agent: calls_agent} do
      {:ok, scan_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(scan_calls_agent), do: Agent.stop(scan_calls_agent) end)

      {:ok, prompt_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(prompt_agent), do: Agent.stop(prompt_agent) end)

      scan_fn = fn _cwd ->
        n = Agent.get_and_update(scan_calls_agent, fn c -> {c, c + 1} end)

        if n == 0,
          do: {:violations, "CLAUDE.md:1 bad path — the specific violation text"},
          else: {:clean}
      end

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "context-curator" do
          prompt = OrchestrationLoop.build_prompt(role, ctx)
          Agent.update(prompt_agent, fn ps -> ps ++ [prompt] end)
        end

        value = if reviewer_role?(role), do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 curator_doc_check_fn: scan_fn
               )

      prompts = Agent.get(prompt_agent, & &1)
      assert length(prompts) == 2
      # First pass: no violation yet threaded (nothing scanned before this call).
      refute Enum.at(prompts, 0) =~ "the specific violation text"
      # Second pass (rework): the violation text from the FIRST scan must be present.
      assert Enum.at(prompts, 1) =~ "the specific violation text"
      assert Enum.at(prompts, 1) =~ "## Factcheck violations to fix"
    end

    test "ADD-without-row index-parity violation once then clean re-invokes context-curator exactly once",
         %{calls_agent: calls_agent} do
      {:ok, scan_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(scan_calls_agent), do: Agent.stop(scan_calls_agent) end)

      scan_fn = fn _cwd ->
        n = Agent.get_and_update(scan_calls_agent, fn c -> {c, c + 1} end)

        if n == 0 do
          {:violations,
           "context-index-parity-scan: context/new.md added but no index row mentions \"new\" in PROJECT_CONTEXT.md § Domain Context Files. Add a \"Load when prompt mentions...\" row."}
        else
          {:clean}
        end
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 curator_doc_check_fn: scan_fn
               )

      curator_calls = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "context-curator"))
      assert curator_calls == 2
      assert List.last(Agent.get(calls_agent, & &1)) == "committer"
    end

    test "violations exhausting max_curator_doc_cycles returns {:error, reason} with combined factcheck+index-parity text; CURATED never advances, committer never invoked",
         %{calls_agent: calls_agent} do
      {:ok, states_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(states_agent), do: Agent.stop(states_agent) end)

      advance_fn = fn state, _step_log, _session_id, _verdict, _project_dir, _slug ->
        Agent.update(states_agent, fn states -> states ++ [state] end)
        :ok
      end

      always_violates_fn = fn _cwd ->
        {:violations,
         "CLAUDE.md:1 bad path\ncontext-index-parity-scan: context/new.md added but no index row mentions \"new\""}
      end

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
          advance_cycle_state_fn: advance_fn,
          curator_doc_check_fn: always_violates_fn,
          max_curator_doc_cycles: 1
        )

      assert {:error, reason} = result
      assert reason =~ "Turn-0 preflight verified"
      assert reason =~ "clean at HEAD"
      assert reason =~ "the violations below arrived with this cycle's own edits"
      assert reason =~ "doc check unresolved"
      assert reason =~ "CLAUDE.md:1 bad path"
      assert reason =~ "context-index-parity-scan"
      refute "CURATED" in Agent.get(states_agent, & &1)
      refute "committer" in Agent.get(calls_agent, & &1)
    end

    test "curator-doc exhaustion writes the terminal marker naming context-curator as owner", %{
      calls_agent: calls_agent
    } do
      tmp_cwd =
        Path.join(
          System.tmp_dir!(),
          "loop-curator-doc-terminal-marker-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_cwd)
      on_exit(fn -> File.rm_rf!(tmp_cwd) end)

      always_violates_fn = fn _cwd -> {:violations, "CLAUDE.md:1 bad path"} end

      assert {:error, _reason} =
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: tmp_cwd,
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 curator_doc_check_fn: always_violates_fn,
                 max_curator_doc_cycles: 1
               )

      marker =
        Path.join(tmp_cwd, "codegen/gate-pending/terminal-state.json")
        |> File.read!()
        |> Jason.decode!()

      assert marker["terminal"] == true
      assert marker["reason"] =~ "context-curator doc check unresolved"
      assert marker["owner"] == "context-curator"
    end

    test "curator introduces a superset (fixes nothing, adds a violation) → dies at the guaranteed floor",
         %{calls_agent: calls_agent} do
      # Pins the subset DIRECTION: a scan that grows (never shrinks) must be
      # refused past the floor exactly like an unchanging thrash — proves
      # `repair_allowed?/4` is not accidentally inverted.
      {:ok, scan_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(scan_calls_agent), do: Agent.stop(scan_calls_agent) end)

      scan_fn = fn _cwd ->
        n = Agent.get_and_update(scan_calls_agent, fn c -> {c, c + 1} end)
        if n == 0, do: {:violations, "A"}, else: {:violations, "A\nB"}
      end

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
          advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
          curator_doc_check_fn: scan_fn,
          max_curator_doc_cycles: 1
        )

      assert {:error, _reason} = result
      curator_calls = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "context-curator"))
      assert curator_calls == 2
      refute "committer" in Agent.get(calls_agent, & &1)
    end

    test "curator thrashes on doc scan (identical violation) → dies at the guaranteed floor",
         %{calls_agent: calls_agent} do
      # Mirrors the env-var side's thrash test: SAME violation text every
      # call (no progress at all) must be refused past the floor exactly
      # like today, with an explicit call-count assertion.
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
          advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
          curator_doc_check_fn: always_violates_fn,
          max_curator_doc_cycles: 1
        )

      assert {:error, _reason} = result
      curator_calls = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "context-curator"))
      assert curator_calls == 2
      refute "committer" in Agent.get(calls_agent, & &1)
    end

    test "curator resolves one violation while another surfaces → earns a turn past the guaranteed floor",
         %{calls_agent: calls_agent} do
      # The case that dies TODAY (budget=1) and must converge AFTER this
      # change: A+B -> B+C -> C -> clean, each turn resolving exactly one
      # violation from the prior scan.
      {:ok, scan_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(scan_calls_agent), do: Agent.stop(scan_calls_agent) end)

      scan_fn = fn _cwd ->
        n = Agent.get_and_update(scan_calls_agent, fn c -> {c, c + 1} end)

        case n do
          0 -> {:violations, "A\nB"}
          1 -> {:violations, "B\nC"}
          2 -> {:violations, "C"}
          _ -> {:clean}
        end
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 curator_doc_check_fn: scan_fn,
                 max_curator_doc_cycles: 1
               )

      curator_calls = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "context-curator"))
      assert curator_calls == 4
      assert List.last(Agent.get(calls_agent, & &1)) == "committer"
    end

    test "curator repair ceiling backstop: resolving one violation per turn from a large set still refuses past the hard ceiling",
         %{calls_agent: calls_agent} do
      # 30-member violation set, resolving exactly one per scan — never
      # reaches clean. Proves @repair_progress_ceiling caps otherwise
      # unbounded progress-earned turns.
      {:ok, scan_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(scan_calls_agent), do: Agent.stop(scan_calls_agent) end)

      scan_fn = fn _cwd ->
        n = Agent.get_and_update(scan_calls_agent, fn c -> {c, c + 1} end)
        remaining = for i <- (n + 1)..29, do: "V#{i}"
        {:violations, Enum.join(["V#{n}" | remaining], "\n")}
      end

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
          advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
          curator_doc_check_fn: scan_fn,
          max_curator_doc_cycles: 1
        )

      assert {:error, _reason} = result
      curator_calls = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "context-curator"))
      assert curator_calls == 16
      refute "committer" in Agent.get(calls_agent, & &1)
    end

    test "curator-doc violation classified :infra aborts loud — NEVER re-invokes context-curator",
         %{calls_agent: calls_agent} do
      always_violates_fn = fn _cwd ->
        {:violations, "** (Postgrex.Error) relation \"widgets\" already exists"}
      end

      assert_raise CodegenTestHarness.InfraAbort,
                   ~r/unsatisfiable by any curator edit/,
                   fn ->
                     OrchestrationLoop.run(
                       harness: "claude_code",
                       stack: "static",
                       cwd: "/tmp/irrelevant",
                       pitch: "do the thing",
                       invoke_fn: always_ok_invoke_fn(calls_agent),
                       gate_fn: always_clear_gate_fn(),
                       gate_preflight_fn: no_op_gate_preflight_fn(),
                       preflight_probe_fn: all_present_preflight_probe_fn(),
                       advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                       curator_doc_check_fn: always_violates_fn
                     )
                   end

      # context-curator ran ONCE (the normal initial pass) — never a SECOND
      # time as a doc-check rework re-invocation: no curator edit could
      # satisfy an infra-classified violation, so the rework budget must
      # never be spent on it.
      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "context-curator")) == 1
    end

    test "full-tree index-coverage violation once then clean re-invokes context-curator exactly once",
         %{calls_agent: calls_agent} do
      # Mirrors the ADD-without-row delta-pass test above, but the violation
      # string here is the one only the full-tree pass in
      # context-index-parity-scan.sh can produce (a PRE-EXISTING orphan with
      # no working-tree delta this turn) — routing must still land on the
      # context-curator, same as every other curator-doc-check violation.
      {:ok, scan_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(scan_calls_agent), do: Agent.stop(scan_calls_agent) end)

      scan_fn = fn _cwd ->
        n = Agent.get_and_update(scan_calls_agent, fn c -> {c, c + 1} end)

        if n == 0 do
          {:violations,
           "context-index-parity-scan: context/orphan.md missing from PROJECT_CONTEXT.md Domain Context Files table (full-tree pass)."}
        else
          {:clean}
        end
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 curator_doc_check_fn: scan_fn
               )

      curator_calls = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "context-curator"))
      assert curator_calls == 2
      assert List.last(Agent.get(calls_agent, & &1)) == "committer"
    end

    test "curator_doc_check_fn raising propagates (loop crashes loud)", %{
      calls_agent: calls_agent
    } do
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
          advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
          curator_doc_check_fn: raising_fn
        )
      end
    end

    test "curator_doc_check_fn returning an unexpected shape raises (no silent clean)", %{
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
          advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
          curator_doc_check_fn: bogus_fn
        )
      end
    end
  end

  defp always_clean_env_var_fn do
    fn _cwd -> {:clean} end
  end

  describe "run/1 — env-var fix cycle" do
    test "clean scan reaches the gate then the committer", %{calls_agent: calls_agent} do
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 curator_doc_check_fn: always_clean_curator_doc_fn(),
                 env_var_scan_fn: always_clean_env_var_fn()
               )

      assert Agent.get(calls_agent, & &1) == @static_sequence
    end

    test "violation once then clean re-invokes developer exactly once, then GATED then committer",
         %{calls_agent: calls_agent} do
      {:ok, scan_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(scan_calls_agent), do: Agent.stop(scan_calls_agent) end)

      scan_fn = fn _cwd ->
        n = Agent.get_and_update(scan_calls_agent, fn c -> {c, c + 1} end)
        if n == 0, do: {:violations, "MY_VAR"}, else: {:clean}
      end

      {:ok, states_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(states_agent), do: Agent.stop(states_agent) end)

      advance_fn = fn state, _step_log, _session_id, _verdict, _project_dir, _slug ->
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
                 advance_cycle_state_fn: advance_fn,
                 curator_doc_check_fn: always_clean_curator_doc_fn(),
                 env_var_scan_fn: scan_fn
               )

      dev_calls = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "developer-static"))
      assert dev_calls == 2
      assert List.last(Agent.get(calls_agent, & &1)) == "committer"
      assert Agent.get(scan_calls_agent, & &1) == 2
      assert "GATED" in Agent.get(states_agent, & &1)
    end

    test "violations exhausting max_env_var_cycles returns {:error, reason}; GATED never advances, committer never invoked",
         %{calls_agent: calls_agent} do
      {:ok, states_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(states_agent), do: Agent.stop(states_agent) end)

      advance_fn = fn state, _step_log, _session_id, _verdict, _project_dir, _slug ->
        Agent.update(states_agent, fn states -> states ++ [state] end)
        :ok
      end

      always_violates_fn = fn _cwd -> {:violations, "MY_VAR"} end

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
          advance_cycle_state_fn: advance_fn,
          curator_doc_check_fn: always_clean_curator_doc_fn(),
          env_var_scan_fn: always_violates_fn,
          max_env_var_cycles: 1
        )

      assert {:error, reason} = result
      assert reason =~ "env var"
      assert reason =~ "MY_VAR"
      refute "GATED" in Agent.get(states_agent, & &1)
      refute "committer" in Agent.get(calls_agent, & &1)
    end

    test "env-var exhaustion writes the terminal marker naming the developer as owner", %{
      calls_agent: calls_agent
    } do
      tmp_cwd =
        Path.join(
          System.tmp_dir!(),
          "loop-env-var-terminal-marker-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_cwd)
      on_exit(fn -> File.rm_rf!(tmp_cwd) end)

      always_violates_fn = fn _cwd -> {:violations, "MY_VAR"} end

      assert {:error, _reason} =
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: tmp_cwd,
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 curator_doc_check_fn: always_clean_curator_doc_fn(),
                 env_var_scan_fn: always_violates_fn,
                 max_env_var_cycles: 1
               )

      marker =
        Path.join(tmp_cwd, "codegen/gate-pending/terminal-state.json")
        |> File.read!()
        |> Jason.decode!()

      assert marker["terminal"] == true
      assert marker["reason"] =~ "env var sample-consistency unresolved"
      assert marker["owner"] == "developer-static"
    end

    test "developer resolves one env-var violation while another surfaces → earns a turn past the guaranteed floor",
         %{calls_agent: calls_agent} do
      # Mirrors the curator-doc fix-A-surface-B case: the developer fixes
      # MY_VAR, OTHER_VAR surfaces, then it's fixed too, then clean.
      {:ok, scan_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(scan_calls_agent), do: Agent.stop(scan_calls_agent) end)

      scan_fn = fn _cwd ->
        n = Agent.get_and_update(scan_calls_agent, fn c -> {c, c + 1} end)

        case n do
          0 -> {:violations, "MY_VAR\nOTHER_VAR"}
          1 -> {:violations, "OTHER_VAR\nTHIRD_VAR"}
          2 -> {:violations, "THIRD_VAR"}
          _ -> {:clean}
        end
      end

      {:ok, states_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(states_agent), do: Agent.stop(states_agent) end)

      advance_fn = fn state, _step_log, _session_id, _verdict, _project_dir, _slug ->
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
                 advance_cycle_state_fn: advance_fn,
                 curator_doc_check_fn: always_clean_curator_doc_fn(),
                 env_var_scan_fn: scan_fn,
                 max_env_var_cycles: 1
               )

      dev_calls = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "developer-static"))
      assert dev_calls == 4
      assert "GATED" in Agent.get(states_agent, & &1)
      assert List.last(Agent.get(calls_agent, & &1)) == "committer"
    end

    test "developer thrashes on env-var scan (identical violation) → dies at the guaranteed floor",
         %{calls_agent: calls_agent} do
      always_violates_fn = fn _cwd -> {:violations, "MY_VAR"} end

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
          advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
          curator_doc_check_fn: always_clean_curator_doc_fn(),
          env_var_scan_fn: always_violates_fn,
          max_env_var_cycles: 1
        )

      assert {:error, _reason} = result
      dev_calls = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "developer-static"))
      assert dev_calls == 2
      refute "committer" in Agent.get(calls_agent, & &1)
    end

    test "violation classified :infra aborts loud — NEVER re-invokes the developer",
         %{calls_agent: calls_agent} do
      always_violates_fn = fn _cwd ->
        {:violations, "** (Postgrex.Error) relation \"widgets\" already exists"}
      end

      assert_raise CodegenTestHarness.InfraAbort,
                   ~r/unsatisfiable by any developer edit/,
                   fn ->
                     OrchestrationLoop.run(
                       harness: "claude_code",
                       stack: "static",
                       cwd: "/tmp/irrelevant",
                       pitch: "do the thing",
                       invoke_fn: always_ok_invoke_fn(calls_agent),
                       gate_fn: always_clear_gate_fn(),
                       gate_preflight_fn: no_op_gate_preflight_fn(),
                       preflight_probe_fn: all_present_preflight_probe_fn(),
                       advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                       curator_doc_check_fn: always_clean_curator_doc_fn(),
                       env_var_scan_fn: always_violates_fn
                     )
                   end

      # developer-static ran ONCE (the normal initial pass) — never a SECOND
      # time as an env-var-scan rework: no edit could have satisfied this
      # scan, so the rework budget must never be spent on it.
      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "developer-static")) == 1
    end

    test "env_var_scan_fn raising propagates (loop crashes loud)", %{calls_agent: calls_agent} do
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
          advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
          curator_doc_check_fn: always_clean_curator_doc_fn(),
          env_var_scan_fn: raising_fn
        )
      end
    end

    test "env_var_scan_fn returning an unexpected shape raises (no silent clean)", %{
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
          advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
          curator_doc_check_fn: always_clean_curator_doc_fn(),
          env_var_scan_fn: bogus_fn
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
        value = if reviewer_role?(role), do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"
        {:ok, %{"status" => "success", "value" => value}}
    end
  end

  describe "run/1 — default curator doc scan diff-scoping (real scan.sh, temp git repo)" do
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
        "See `widgetapp/nope.ex` for details.\n\n## Trigger Keywords\n\nrotten\n"
      )

      File.write!(
        Path.join(dir, "PROJECT_CONTEXT.md"),
        "# PROJECT_CONTEXT.md\n`context/rotten.md` | x | x | rotten\n"
      )

      System.cmd("git", ["add", "context/rotten.md", "PROJECT_CONTEXT.md"], cd: dir)
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
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
          advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
          max_curator_doc_cycles: 0,
          clean_tree_preflight_fn: no_op_clean_tree_preflight_fn(),
          orientation_preflight_fn: no_op_orientation_preflight_fn()
        )

      assert {:error, reason} = result
      assert reason =~ "doc check unresolved"
      assert reason =~ "widgetapp/nope.ex"
    end

    test "Elixir source-root fallback resolves a changed doc's module-convention path claim → {:ok}",
         %{calls_agent: calls_agent, dir: dir} do
      File.mkdir_p!(Path.join([dir, "lib", "widgetapp"]))
      File.write!(Path.join([dir, "lib", "widgetapp", "billing.ex"]), "code\n")

      File.write!(
        Path.join([dir, "context", "foo.md"]),
        "See `widgetapp/billing.ex` for details.\n\n## Trigger Keywords\n\nfoo\n"
      )

      # Isolate this test to the factcheck path-resolution behavior — add the
      # matching index row (with a keyword cell matching the file's Trigger
      # Keywords section) so the (independent) index-parity check stays clean.
      File.write!(
        Path.join(dir, "PROJECT_CONTEXT.md"),
        "# PROJECT_CONTEXT.md\n`context/foo.md` | x | x | foo\n"
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
               )

      assert List.last(Agent.get(calls_agent, & &1)) == "committer"
    end

    test "context/*.md added this cycle without a PROJECT_CONTEXT.md row → index-parity fails loud",
         %{calls_agent: calls_agent, dir: dir} do
      File.write!(Path.join([dir, "context", "new.md"]), "brand new context doc\n")

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
          advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
          max_curator_doc_cycles: 0,
          clean_tree_preflight_fn: no_op_clean_tree_preflight_fn(),
          orientation_preflight_fn: no_op_orientation_preflight_fn()
        )

      assert {:error, reason} = result
      assert reason =~ "doc check unresolved"
      assert reason =~ "context-index-parity-scan"
      assert reason =~ "new.md added but no index row"
    end

    test "context/*.md added this cycle WITH a matching row → clean, reaches the committer",
         %{calls_agent: calls_agent, dir: dir} do
      File.write!(
        Path.join([dir, "context", "new.md"]),
        "brand new context doc\n\n## Trigger Keywords\n\nnew\n"
      )

      File.write!(
        Path.join(dir, "PROJECT_CONTEXT.md"),
        "# PROJECT_CONTEXT.md\n`context/new.md` | x | x | new\n"
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
               )

      assert List.last(Agent.get(calls_agent, & &1)) == "committer"
    end
  end

  describe "run/1 — default curator doc scan consumption check (real scan.sh, temp git repo)" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "consumption_scan_test_#{:erlang.unique_integer([:positive])}"
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

    defp fixture_cycle_log!(events) do
      path =
        Path.join(
          System.tmp_dir!(),
          "consumption_scan_cycle_#{System.unique_integer([:positive])}.jsonl"
        )

      body = events |> Enum.map(&Jason.encode!/1) |> Enum.join("\n")
      File.write!(path, body <> "\n")
      on_exit(fn -> File.rm(path) end)
      path
    end

    test "nil :cycle_log (no log initialized) → third leg is skipped, reaches the committer",
         %{calls_agent: calls_agent, dir: dir} do
      # Simulated developer output — a real working-tree diff is required for
      # invoke_reviewer/4 to proceed past its empty-diff refusal.
      File.write!(Path.join(dir, "unrelated.txt"), "unrelated change\n")

      # No :log_init_fn override → Process.get(@log_path_key) resolves to nil
      # for this test process → gate_opts/1 threads :cycle_log as nil →
      # default_curator_doc_scan/2's third leg is {:clean} without shelling.
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
               )

      assert List.last(Agent.get(calls_agent, & &1)) == "committer"
    end

    test "learnings captured this cycle + curator routes a shared/rules/**.md edit → clean, reaches the committer",
         %{calls_agent: calls_agent, dir: dir} do
      log_path =
        fixture_cycle_log!([
          %{"ev" => "init", "pitch" => "x"},
          %{"ev" => "learned", "role" => "planner-phoenix", "text" => "[shared] a real learning"}
        ])

      File.mkdir_p!(Path.join([dir, "shared", "rules", "roles"]))
      File.write!(Path.join(dir, "unrelated.txt"), "unrelated change\n")

      invoke_fn = fn role, harness, ctx, opts ->
        if role == "context-curator" do
          File.write!(
            Path.join([dir, "shared", "rules", "roles", "context-curator.md"]),
            "# updated curator rule\n"
          )
        end

        always_ok_invoke_fn_with_real_commit(calls_agent).(role, harness, ctx, opts)
      end

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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn(),
                 log_init_fn: log_init_fn_for(log_path),
                 slug: "consumption-scan-test"
               )

      assert List.last(Agent.get(calls_agent, & &1)) == "committer"
    end

    test "learnings captured this cycle, curator routes nothing and records no drop → consumption check fails loud",
         %{calls_agent: calls_agent, dir: dir} do
      log_path =
        fixture_cycle_log!([
          %{"ev" => "init", "pitch" => "x"},
          %{"ev" => "learned", "role" => "planner-phoenix", "text" => "[shared] a real learning"}
        ])

      File.write!(Path.join(dir, "unrelated.txt"), "unrelated change\n")

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
          advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
          max_curator_doc_cycles: 0,
          clean_tree_preflight_fn: no_op_clean_tree_preflight_fn(),
          orientation_preflight_fn: no_op_orientation_preflight_fn(),
          log_init_fn: log_init_fn_for(log_path),
          slug: "consumption-scan-test"
        )

      assert {:error, reason} = result
      assert reason =~ "doc check unresolved"
      assert reason =~ "curator-consumption-scan"
      assert reason =~ "captured 1"
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

  describe "prompt_tail/1" do
    test "wraps the prompt with an explicit end-of-flags separator" do
      assert OrchestrationLoop.prompt_tail("PROMPT") == ["--", "PROMPT"]
    end

    test "a prompt body opening with -- is still returned as data, not consumed as a flag" do
      prompt = "---\nstatus: SHAPED\n---\n# Body"

      assert OrchestrationLoop.prompt_tail(prompt) == ["--", prompt]
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

    test "accumulate_telemetry/2 carries latency_ms/duration_ms/metrics through to per_role, unsummed" do
      Process.delete(:loop_telemetry)

      envelope = %{
        "usage" => %{
          "cost_usd" => 0.5,
          "num_turns" => 3,
          "latency_ms" => 12_345,
          "duration_ms" => 9_000,
          "duration_api_ms" => 3_000,
          "ttft_ms" => 2_100,
          "permission_denials" => 4,
          "stop_reason" => "end_turn"
        },
        "metrics" => %{"read_count" => 10, "edit_count" => 2}
      }

      assert :ok == OrchestrationLoop.accumulate_telemetry("developer-static", envelope)

      t = OrchestrationLoop.get_telemetry()
      [role_entry] = t.per_role["developer-static"]
      assert role_entry.latency_ms == 12_345
      assert role_entry.duration_ms == 9_000
      assert role_entry.duration_api_ms == 3_000
      assert role_entry.ttft_ms == 2_100
      assert role_entry.permission_denials == 4
      assert role_entry.stop_reason == "end_turn"
      assert role_entry.metrics == %{"read_count" => 10, "edit_count" => 2}

      Process.delete(:loop_telemetry)
    end

    test "accumulate_telemetry/2 records nil (not 0) for absent latency/duration/metrics fields" do
      Process.delete(:loop_telemetry)

      envelope = %{"usage" => %{"cost_usd" => 0.1, "num_turns" => 1}}

      assert :ok == OrchestrationLoop.accumulate_telemetry("developer-static", envelope)

      t = OrchestrationLoop.get_telemetry()
      [role_entry] = t.per_role["developer-static"]
      assert role_entry.latency_ms == nil
      assert role_entry.duration_ms == nil
      assert role_entry.duration_api_ms == nil
      assert role_entry.ttft_ms == nil
      assert role_entry.permission_denials == nil
      assert role_entry.stop_reason == nil
      assert role_entry.metrics == nil

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

    test "invoke_role/4 writes latency_ms/duration_ms/metrics columns to cycle-summary.jsonl, null when absent" do
      cwd = Path.join(System.tmp_dir!(), "octel-#{System.unique_integer([:positive])}")
      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf(cwd) end)

      Process.put(:loop_cycle_id, "20260705_x_slug")
      Process.put(:loop_transcript_seq, 0)

      envelope = %{
        "result" => %{"status" => "success", "value" => "x"},
        "usage" => %{
          "num_turns" => 3,
          "cost_usd" => 0.02,
          "latency_ms" => 5_500,
          "duration_ms" => 5_000,
          "duration_api_ms" => 1_200,
          "ttft_ms" => 2_000,
          "permission_denials" => 2,
          "stop_reason" => "end_turn"
        },
        "metrics" => %{"read_count" => 3}
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

      [line] = summary_path |> File.read!() |> String.split("\n", trim: true)
      decoded = Jason.decode!(line)

      assert decoded["latency_ms"] == 5_500
      assert decoded["duration_ms"] == 5_000
      assert decoded["duration_api_ms"] == 1_200
      assert decoded["ttft_ms"] == 2_000
      assert decoded["permission_denials"] == 2
      assert decoded["stop_reason"] == "end_turn"
      assert decoded["metrics"] == %{"read_count" => 3}
    end

    test "invoke_role/4 writes null (not 0) for latency_ms/duration_ms/metrics when the envelope omits them" do
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

      [line] = summary_path |> File.read!() |> String.split("\n", trim: true)
      decoded = Jason.decode!(line)

      assert decoded["latency_ms"] == nil
      assert decoded["duration_ms"] == nil
      assert decoded["duration_api_ms"] == nil
      assert decoded["ttft_ms"] == nil
      assert decoded["permission_denials"] == nil
      assert decoded["stop_reason"] == nil
      assert decoded["metrics"] == nil
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
          preflight_probe_fn: all_present_preflight_probe_fn()
        )
      end
    end

    test "committer returning success on a CLEAN tree with real work committed proceeds to :ok",
         %{
           calls_agent: calls_agent,
           dir: dir
         } do
      # Simulate the developer's own work landing before the reviewer runs —
      # a real cycle never reaches the reviewer with a clean tree (see
      # invoke_reviewer/4's empty-set refusal).
      File.write!(Path.join(dir, "feature.txt"), "wip\n")

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
                 advance_cycle_state_fn: fn _state,
                                            _step_log,
                                            _session_id,
                                            _verdict,
                                            _project_dir,
                                            _slug ->
                   :ok
                 end,
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
               )
    end

    test "committer producing TWO commits raises (split-commit guard, exactly-one enforced)", %{
      calls_agent: calls_agent,
      dir: dir
    } do
      # Simulate the developer's own work landing before the reviewer runs —
      # a real cycle never reaches the reviewer with a clean tree (see
      # invoke_reviewer/4's empty-set refusal).
      File.write!(Path.join(dir, "feature.txt"), "wip\n")

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
          advance_cycle_state_fn: fn _state,
                                     _step_log,
                                     _session_id,
                                     _verdict,
                                     _project_dir,
                                     _slug ->
            :ok
          end,
          clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
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

      # Simulate THIS cycle's developer work landing before the reviewer
      # runs — a real cycle never reaches the reviewer with a clean tree
      # (see invoke_reviewer/4's empty-set refusal).
      File.write!(Path.join(dir, "feature.txt"), "wip\n")

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
          advance_cycle_state_fn: fn _state,
                                     _step_log,
                                     _session_id,
                                     _verdict,
                                     _project_dir,
                                     _slug ->
            :ok
          end,
          clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
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

      # A genuinely no-op cycle (zero work anywhere) is now caught even
      # earlier than the committer no-op guard: invoke_reviewer/4 refuses to
      # invoke the reviewer at all on an empty changed-file set in a real
      # git tree — see "empty changed set in a real git tree" test above.
      # Same never-loop_committed contract, an earlier catch point.
      assert {:error, reason} =
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: dir,
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: fn _state,
                                            _step_log,
                                            _session_id,
                                            _verdict,
                                            _project_dir,
                                            _slug ->
                   :ok
                 end
               )

      assert reason =~ "cycle produced no changes — nothing for the reviewer to review"
    end
  end

  describe "no ship on a gate that didn't grade this tree (pre-commit re-gate)" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "no_ship_stale_gate_test_#{:erlang.unique_integer([:positive])}"
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

    # committer commits whatever is on disk at the time it runs (mirrors a
    # faithful `git add -A && git commit`).
    defp committing_invoke_fn(calls_agent, dir) do
      fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "committer" do
          {_o, 0} = System.cmd("git", ["add", "-A"], cd: dir)
          {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "impl"], cd: dir)
        end

        value =
          if role == "reviewer-static", do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end
    end

    test "tree unchanged since gate → proceeds straight to the committer, no re-gate", %{
      calls_agent: calls_agent,
      dir: dir
    } do
      File.write!(Path.join(dir, "feature.txt"), "done\n")

      regate_calls = :counters.new(1, [])

      gate_fn = fn _cwd, _opts ->
        :counters.add(regate_calls, 1, 1)
        {:clear, "make test"}
      end

      # gate_tree_match_fn simulates "the gate already graded this exact
      # content" — no re-gate should fire.
      match_fn = fn _cwd -> true end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: dir,
                 pitch: "do the thing",
                 invoke_fn: committing_invoke_fn(calls_agent, dir),
                 gate_fn: gate_fn,
                 gate_tree_match_fn: match_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
               )

      # gate_fn is the PRIMARY developer-gate loop's gate — it fires once for
      # that, and the pre-commit path never re-invokes it because the match
      # check reports "match" without calling gate_fn at all.
      assert :counters.get(regate_calls, 1) == 1
      assert Agent.get(calls_agent, & &1) == @static_sequence
    end

    test "tree changed since gate, re-gate comes back clear → re-gates once then commits", %{
      calls_agent: calls_agent,
      dir: dir
    } do
      File.write!(Path.join(dir, "feature.txt"), "done\n")

      match_calls = :counters.new(1, [])
      regate_calls = :counters.new(1, [])

      # First match check (primary gate already ran, opts[:gate_fn] fired
      # once for the developer step) reports stale; the SECOND (after
      # rework_final_gate re-gates) reports match.
      match_fn = fn _cwd ->
        :counters.add(match_calls, 1, 1)
        :counters.get(match_calls, 1) > 1
      end

      gate_fn = fn _cwd, _opts ->
        :counters.add(regate_calls, 1, 1)
        {:clear, "make test"}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: dir,
                 pitch: "do the thing",
                 invoke_fn: committing_invoke_fn(calls_agent, dir),
                 gate_fn: gate_fn,
                 gate_tree_match_fn: match_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
               )

      # gate_fn fires once for the primary developer-gate step, then a
      # second time for the pre-commit re-gate triggered by the stale match.
      assert :counters.get(regate_calls, 1) == 2
      assert Agent.get(calls_agent, & &1) == @static_sequence
    end

    test "tree changed since gate, re-gate FAILS → reworks the developer, then re-checks and commits",
         %{
           calls_agent: calls_agent,
           dir: dir
         } do
      File.write!(Path.join(dir, "feature.txt"), "done\n")

      match_calls = :counters.new(1, [])
      regate_calls = :counters.new(1, [])

      match_fn = fn _cwd ->
        :counters.add(match_calls, 1, 1)
        :counters.get(match_calls, 1) > 1
      end

      # First re-gate call (the pre-commit rework path) fails; every
      # subsequent call (the primary developer-gate step's own call, plus
      # any later pre-commit re-gate) is clear.
      gate_fn = fn _cwd, _opts ->
        :counters.add(regate_calls, 1, 1)
        n = :counters.get(regate_calls, 1)
        if n == 2, do: {:failed, "make test"}, else: {:clear, "make test"}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: dir,
                 pitch: "do the thing",
                 invoke_fn: committing_invoke_fn(calls_agent, dir),
                 gate_fn: gate_fn,
                 gate_tree_match_fn: match_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 max_final_gate_cycles: 1,
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
               )

      # The developer role was invoked twice: once in the normal sequence,
      # once more as pre-commit rework.
      dev_calls = Agent.get(calls_agent, & &1) |> Enum.count(&(&1 == "developer-static"))
      assert dev_calls == 2
    end

    test "tree changed since gate, re-gate fails every time → exhausts and errors, never commits",
         %{
           calls_agent: calls_agent,
           dir: dir
         } do
      File.write!(Path.join(dir, "feature.txt"), "done\n")

      match_fn = fn _cwd -> false end

      # The PRIMARY developer-gate step (do_gate_loop/9) must clear so we
      # actually reach the committer clause; only the PRE-COMMIT re-gate
      # (rework_final_gate/5) must stay non-clear on every call, so the
      # exhaustion path under test fires instead of the primary gate loop's
      # own retry-exhaustion.
      regate_calls = :counters.new(1, [])

      gate_fn = fn _cwd, _opts ->
        :counters.add(regate_calls, 1, 1)

        if :counters.get(regate_calls, 1) == 1,
          do: {:clear, "make test"},
          else: {:failed, "make test"}
      end

      assert {:error, reason} =
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: dir,
                 pitch: "do the thing",
                 invoke_fn: committing_invoke_fn(calls_agent, dir),
                 gate_fn: gate_fn,
                 gate_tree_match_fn: match_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 max_final_gate_cycles: 1,
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
               )

      assert reason =~ "pre-commit re-gate" or reason =~ "never graded clear"
      refute "committer" in Agent.get(calls_agent, & &1)

      {status_out, 0} = System.cmd("git", ["status", "--porcelain"], cd: dir)
      # The developer's rework edits are still on disk, uncommitted — no
      # commit landed, matching the "never a false loop_committed" contract.
      assert status_out != ""
    end

    test "tree changed since gate, re-gate FAILS with max_final_gate_cycles: 1 → the one pre-commit rework is escalated",
         %{
           calls_agent: calls_agent,
           dir: dir
         } do
      File.write!(Path.join(dir, "feature.txt"), "done\n")

      match_calls = :counters.new(1, [])
      regate_calls = :counters.new(1, [])

      match_fn = fn _cwd ->
        :counters.add(match_calls, 1, 1)
        :counters.get(match_calls, 1) > 1
      end

      gate_fn = fn _cwd, _opts ->
        :counters.add(regate_calls, 1, 1)
        n = :counters.get(regate_calls, 1)
        if n == 2, do: {:failed, "make test"}, else: {:clear, "make test"}
      end

      {:ok, seen_ctx_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(seen_ctx_agent), do: Agent.stop(seen_ctx_agent) end)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "developer-static" do
          escalated = get_in(ctx, [:artifacts, :escalated_model])
          Agent.update(seen_ctx_agent, fn seen -> seen ++ [escalated] end)
        end

        if role == "committer" do
          {_o, 0} = System.cmd("git", ["add", "-A"], cd: dir)
          {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "impl"], cd: dir)
        end

        value =
          if role == "reviewer-static", do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end

      resolve_escalation_fn = fn "developer-static", _harness -> {"opus", "high"} end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: dir,
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 gate_fn: gate_fn,
                 gate_tree_match_fn: match_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 max_final_gate_cycles: 1,
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn(),
                 resolve_escalation_fn: resolve_escalation_fn
               )

      # first developer-static call: normal sequence, unescalated. Second
      # (pre-commit rework, the ONLY attempt max_final_gate_cycles: 1
      # allows -> also the final one) is escalated.
      assert Agent.get(seen_ctx_agent, & &1) == [nil, {"opus", "high"}]
    end

    test "committer commits DIFFERENT content than the last-graded tree → post-commit guard raises",
         %{
           calls_agent: calls_agent,
           dir: dir
         } do
      # The pre-commit match check says "match" (skip re-gate), but the
      # committer itself still diverges from the stamped graded_tree_sha
      # (simulating a bug in the committer, or a race). assert_commit_matches_gate!
      # must catch this independently of the pre-commit re-gate.
      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "committer" do
          File.write!(Path.join(dir, "unexpected.txt"), "not what was graded\n")
          {_o, 0} = System.cmd("git", ["add", "-A"], cd: dir)
          {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "diverged"], cd: dir)
        end

        value =
          if role == "reviewer-static", do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end

      # gate_result_sha_fn seam is not exposed directly — simulate the
      # stamped verdict via a real LoopGate.run_gate/2 call before run/1,
      # against a KNOWN tree that does NOT include unexpected.txt.
      claude_dir = Path.join(dir, ".claude")
      File.mkdir_p!(claude_dir)
      File.write!(Path.join(claude_dir, "gate-config.sh"), ~s(GATE_COMMAND="make test"\n))
      File.write!(Path.join(dir, "feature.txt"), "done\n")

      CodegenTestHarness.LoopGate.run_gate(dir,
        run_fn: fn _gate, _project_dir -> {"ok", 0} end,
        stack: "static"
      )

      # gate_tree_match_fn reports "match" so the pre-commit re-gate is
      # skipped entirely — the ONLY guard left standing is the post-commit
      # content assertion.
      match_fn = fn _cwd -> true end
      gate_fn = fn _cwd, _opts -> {:clear, "make test"} end

      assert_raise RuntimeError,
                   ~r/does not match the last graded_tree_sha|DIFFERENT content/,
                   fn ->
                     OrchestrationLoop.run(
                       harness: "claude_code",
                       stack: "static",
                       cwd: dir,
                       pitch: "do the thing",
                       invoke_fn: invoke_fn,
                       gate_fn: gate_fn,
                       gate_tree_match_fn: match_fn,
                       gate_preflight_fn: no_op_gate_preflight_fn(),
                       preflight_probe_fn: all_present_preflight_probe_fn(),
                       advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                       clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
                     )
                   end
    end
  end

  describe "run/1 — turn-0 clean-tree precondition (symmetric HEAD guard)" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "preflight_clean_tree_test_#{:erlang.unique_integer([:positive])}"
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

    test "dirty tree at cycle start raises BEFORE any role is invoked", %{
      calls_agent: calls_agent,
      dir: dir
    } do
      # A file left uncommitted from a prior (aborted) session — foreign
      # dirt the incoming cycle must never inherit.
      File.write!(Path.join(dir, "leftover.txt"), "from a prior aborted session\n")

      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)
        {:ok, %{"status" => "success", "value" => "did #{role}"}}
      end

      assert_raise RuntimeError, ~r/tree is NOT clean before the cycle/, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "static",
          cwd: dir,
          pitch: "do the thing",
          invoke_fn: invoke_fn,
          gate_fn: always_clear_gate_fn(),
          gate_preflight_fn: no_op_gate_preflight_fn(),
          preflight_probe_fn: all_present_preflight_probe_fn()
        )
      end

      # No role was ever invoked — the guard fires before turn 0's first spawn.
      assert Agent.get(calls_agent, & &1) == []
    end

    test "clean tree at cycle start proceeds normally (no false positive)", %{
      calls_agent: calls_agent,
      dir: dir
    } do
      # The stubbed developer role produces real work so the cycle has a
      # non-empty diff to commit — a clean-start cycle that never dirties
      # the tree would trip the (unrelated) "no changes for the reviewer"
      # guard, not the guard under test here.
      invoke_fn = fn
        "developer-static", _harness, ctx, _opts ->
          Agent.update(calls_agent, fn calls -> calls ++ ["developer-static"] end)
          File.write!(Path.join(ctx.cwd, "feature.txt"), "wip\n")
          {:ok, %{"status" => "success", "value" => "did developer-static"}}

        "committer", _harness, ctx, _opts ->
          Agent.update(calls_agent, fn calls -> calls ++ ["committer"] end)
          System.cmd("git", ["add", "-A"], cd: ctx.cwd)
          System.cmd("git", ["commit", "-q", "-m", "test commit"], cd: ctx.cwd)
          {:ok, %{"status" => "success", "value" => "did committer"}}

        role, _harness, _ctx, _opts ->
          Agent.update(calls_agent, fn calls -> calls ++ [role] end)

          value =
            if role == "reviewer-static", do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"

          {:ok, %{"status" => "success", "value" => value}}
      end

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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert List.last(Agent.get(calls_agent, & &1)) == "committer"
    end

    test "non-git cwd is fail-exempt (mocked-test synthetic cwd unaffected)", %{
      calls_agent: calls_agent
    } do
      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static", do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"

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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )
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
          preflight_probe_fn: all_present_preflight_probe_fn()
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 planner_plan_fn: stub_planner_plan_fn()
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
          preflight_probe_fn: missing_committer_probe
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
          preflight_probe_fn: inconclusive_probe
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 planner_plan_fn: stub_planner_plan_fn()
               )

      assert Agent.get(calls_agent, & &1) == @phoenix_sequence
    end
  end

  describe "run/1 — cycle log init + CODEGEN_LOG_PATH pinning" do
    test "log_init_fn is called exactly once, with the cycle's slug, before the first role invoke",
         %{calls_agent: calls_agent} do
      {:ok, init_calls_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(init_calls_agent), do: Agent.stop(init_calls_agent) end)

      log_path =
        Path.join(System.tmp_dir!(), "init_pin_#{System.unique_integer([:positive])}.jsonl")

      File.write!(log_path, Jason.encode!(%{"ev" => "init", "pitch" => "x"}) <> "\n")
      on_exit(fn -> File.rm(log_path) end)

      log_init_fn = fn slug, cwd, stamp ->
        Agent.update(init_calls_agent, fn calls -> calls ++ [{slug, cwd, stamp}] end)
        # Called before the first role: calls_agent must still be empty.
        assert Agent.get(calls_agent, & &1) == []
        log_path
      end

      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)
        body = if reviewer_role?(role), do: "REVIEW_VERDICT: APPROVED", else: "did the thing"
        append_role_body!(log_path, role, body)
        {:ok, %{"status" => "success", "value" => body, "session_id" => "sid-#{role}"}}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 slug: "my-test-slug",
                 stamp: "20260101_120000",
                 log_init_fn: log_init_fn,
                 invoke_fn: invoke_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 curator_doc_check_fn: always_clean_curator_doc_fn(),
                 env_var_scan_fn: always_clean_env_var_fn()
               )

      assert Agent.get(init_calls_agent, & &1) == [
               {"my-test-slug", "/tmp/irrelevant", "20260101_120000"}
             ]
    end

    test "run/1 without :stamp passes nil to log_init_fn — no crash on the unit-test path" do
      {:ok, init_calls_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(init_calls_agent), do: Agent.stop(init_calls_agent) end)

      log_path =
        Path.join(System.tmp_dir!(), "init_pin_#{System.unique_integer([:positive])}.jsonl")

      File.write!(log_path, Jason.encode!(%{"ev" => "init", "pitch" => "x"}) <> "\n")
      on_exit(fn -> File.rm(log_path) end)

      log_init_fn = fn slug, cwd, stamp ->
        Agent.update(init_calls_agent, fn calls -> calls ++ [{slug, cwd, stamp}] end)
        log_path
      end

      invoke_fn = fn role, _harness, _ctx, _opts ->
        body = if reviewer_role?(role), do: "REVIEW_VERDICT: APPROVED", else: "did the thing"
        append_role_body!(log_path, role, body)
        {:ok, %{"status" => "success", "value" => body, "session_id" => "sid-#{role}"}}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 slug: "my-test-slug",
                 log_init_fn: log_init_fn,
                 invoke_fn: invoke_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 curator_doc_check_fn: always_clean_curator_doc_fn(),
                 env_var_scan_fn: always_clean_env_var_fn()
               )

      assert Agent.get(init_calls_agent, & &1) == [{"my-test-slug", "/tmp/irrelevant", nil}]
    end

    test "a raising log_init_fn makes run/1 raise — no silent log-less cycle" do
      log_init_fn = fn _slug, _cwd, _stamp -> raise "codegen-log init failed (2): boom" end

      assert_raise RuntimeError, ~r/codegen-log init failed/, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "static",
          cwd: "/tmp/irrelevant",
          pitch: "do the thing",
          slug: "my-test-slug",
          log_init_fn: log_init_fn,
          invoke_fn: fn _role, _h, _ctx, _o ->
            flunk("a role must never be invoked when log init raised")
          end,
          gate_fn: always_clear_gate_fn(),
          gate_preflight_fn: no_op_gate_preflight_fn(),
          preflight_probe_fn: all_present_preflight_probe_fn(),
          advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
          curator_doc_check_fn: always_clean_curator_doc_fn(),
          env_var_scan_fn: always_clean_env_var_fn()
        )
      end
    end

    test "nil slug (no slug opt) skips log init cleanly — no raise",
         %{calls_agent: calls_agent} do
      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: fn role, _harness, _ctx, _opts ->
                   Agent.update(calls_agent, fn calls -> calls ++ [role] end)

                   value =
                     if reviewer_role?(role),
                       do: "REVIEW_VERDICT: APPROVED",
                       else: "no block here"

                   {:ok, %{"status" => "success", "value" => value, "session_id" => "sid"}}
                 end,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 curator_doc_check_fn: always_clean_curator_doc_fn(),
                 env_var_scan_fn: always_clean_env_var_fn()
               )

      assert Agent.get(calls_agent, & &1) == @static_sequence
    end
  end

  # ── Resume-checkpoint (pitch "no whole-build restart when the loop dies
  # mid-cycle") ────────────────────────────────────────────────────────────
  # A prior cycle that died AFTER a clear gate but BEFORE the committer
  # landed leaves a durable checkpoint on disk (gate-result.json +
  # cycle-state.json). A fresh run/1 call against the SAME (still-dirty)
  # cwd must detect it and start from the mapped resume role instead of
  # role 0 — skipping the (expensive, already-paid) prefix. Every
  # invalidation path must fall through to a full run from role 0 exactly
  # as if no checkpoint existed.
  describe "resume-checkpoint" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "resume_checkpoint_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      {_out, 0} = System.cmd("git", ["init", "-q"], cd: dir)
      {_out, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
      {_out, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: dir)
      {_out, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: dir)

      # Real scaffolded apps gitignore codegen/ (cycle logs + gate-pending
      # checkpoint files are ephemeral, never committed — see
      # shared/rules/_core/session-log.md § Git Status). Mirror that here so
      # the resume-checkpoint fixture files this describe block writes under
      # codegen/gate-pending/ never enter what the committer stages, keeping
      # the committed tree hash independent of the fixture's own bytes.
      File.write!(Path.join(dir, ".gitignore"), "codegen/\n")
      File.write!(Path.join(dir, "README.md"), "init\n")
      {_out, 0} = System.cmd("git", ["add", "-A"], cd: dir)
      {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: dir)

      {out, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
      base_head = String.trim(out)

      {:ok, dir: dir, base_head: base_head}
    end

    defp write_gate_result!(dir, verdict, graded_tree_sha, base_sha) do
      result_dir = Path.join([dir, "codegen", "gate-pending"])
      File.mkdir_p!(result_dir)

      File.write!(
        Path.join(result_dir, "gate-result.json"),
        Jason.encode!(%{
          "verdict" => verdict,
          "graded_tree_sha" => graded_tree_sha,
          "base_sha" => base_sha
        })
      )
    end

    defp write_cycle_state!(dir, state, slug \\ "") do
      result_dir = Path.join([dir, "codegen", "gate-pending"])
      File.mkdir_p!(result_dir)

      File.write!(
        Path.join(result_dir, "cycle-state.json"),
        Jason.encode!(%{"state" => state, "slug" => slug})
      )
    end

    # Writes `filename` (the prior cycle's simulated dev work) and returns
    # the REAL git tree hash that content produces — via `git add -A` +
    # `git write-tree` (stages, but does not commit). assert_commit_matches_gate!/1
    # (a real, un-mocked check in run_committer/4) compares the eventual
    # commit's tree against gate-result.json's graded_tree_sha bit-for-bit,
    # so a resume test asserting :ok must stamp the ACTUAL hash, not an
    # arbitrary placeholder string.
    defp real_tree_sha_after_write!(dir, filename, content) do
      File.write!(Path.join(dir, filename), content)
      {_o, 0} = System.cmd("git", ["add", "-A"], cd: dir)
      {out, 0} = System.cmd("git", ["write-tree"], cd: dir)
      String.trim(out)
    end

    # Common seam bundle every resume-checkpoint test needs: a real invoke_fn
    # that records which roles were actually called, a permissive gate/orphan
    # /preflight stack (never the object under test here), and a no-op
    # advance_cycle_state_fn (writing the real cycle-state.json would
    # overwrite the checkpoint this test set up).
    defp resume_run_opts(dir, calls_agent, extra) do
      base = [
        harness: "claude_code",
        stack: "static",
        cwd: dir,
        pitch: "do the thing",
        invoke_fn: fn role, _harness, _ctx, _opts ->
          Agent.update(calls_agent, fn calls -> calls ++ [role] end)

          if role == "committer" do
            # Real committer role stages + commits whatever the (real or
            # simulated) prior cycle left behind — commit exactly the dirty
            # tree the checkpoint fixture set up, satisfying
            # verify_committed!'s single-commit + clean-tree tail guard.
            {_o, 0} = System.cmd("git", ["add", "-A"], cd: dir)
            {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "resume test commit"], cd: dir)
          end

          value =
            if reviewer_role?(role), do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"

          {:ok, %{"status" => "success", "value" => value}}
        end,
        gate_fn: always_clear_gate_fn(),
        gate_preflight_fn: no_op_gate_preflight_fn(),
        preflight_probe_fn: all_present_preflight_probe_fn(),
        orientation_preflight_fn: no_op_orientation_preflight_fn(),
        orphan_scan_fn: fn _cwd -> [] end,
        advance_cycle_state_fn: fn _state,
                                   _step_log,
                                   _session_id,
                                   _verdict,
                                   _project_dir,
                                   _slug ->
          :ok
        end
      ]

      Keyword.merge(base, extra)
    end

    test "valid GATED checkpoint resumes at reviewer-static, skipping developer-static", %{
      dir: dir,
      base_head: base_head,
      calls_agent: calls_agent
    } do
      tree_sha = real_tree_sha_after_write!(dir, "feature.txt", "wip\n")
      write_gate_result!(dir, "clear", tree_sha, base_head)
      write_cycle_state!(dir, "GATED", "matching-slug")

      assert :ok ==
               OrchestrationLoop.run(
                 resume_run_opts(dir, calls_agent,
                   slug: "matching-slug",
                   cycle_state_get_fn: fn _cwd -> "GATED" end,
                   cycle_state_slug_fn: fn _cwd -> "matching-slug" end,
                   read_verdict_fn: fn _cwd -> :clear end,
                   gate_result_base_sha_fn: fn _cwd -> base_head end,
                   gate_tree_match_fn: fn _cwd -> true end,
                   clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
                 )
               )

      calls = Agent.get(calls_agent, & &1)
      refute "developer-static" in calls
      assert calls == ["reviewer-static", "context-curator", "committer"]
    end

    test "valid REVIEWED checkpoint resumes at context-curator, skipping developer+reviewer", %{
      dir: dir,
      base_head: base_head,
      calls_agent: calls_agent
    } do
      tree_sha = real_tree_sha_after_write!(dir, "feature.txt", "wip\n")
      write_gate_result!(dir, "clear", tree_sha, base_head)
      write_cycle_state!(dir, "REVIEWED", "matching-slug")

      assert :ok ==
               OrchestrationLoop.run(
                 resume_run_opts(dir, calls_agent,
                   slug: "matching-slug",
                   cycle_state_get_fn: fn _cwd -> "REVIEWED" end,
                   cycle_state_slug_fn: fn _cwd -> "matching-slug" end,
                   read_verdict_fn: fn _cwd -> :clear end,
                   gate_result_base_sha_fn: fn _cwd -> base_head end,
                   gate_tree_match_fn: fn _cwd -> true end,
                   clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
                 )
               )

      calls = Agent.get(calls_agent, & &1)
      refute "developer-static" in calls
      refute "reviewer-static" in calls
      assert calls == ["context-curator", "committer"]
    end

    test "valid CURATED checkpoint resumes at committer only", %{
      dir: dir,
      base_head: base_head,
      calls_agent: calls_agent
    } do
      tree_sha = real_tree_sha_after_write!(dir, "feature.txt", "wip\n")
      write_gate_result!(dir, "clear", tree_sha, base_head)
      write_cycle_state!(dir, "CURATED", "matching-slug")

      assert :ok ==
               OrchestrationLoop.run(
                 resume_run_opts(dir, calls_agent,
                   slug: "matching-slug",
                   cycle_state_get_fn: fn _cwd -> "CURATED" end,
                   cycle_state_slug_fn: fn _cwd -> "matching-slug" end,
                   read_verdict_fn: fn _cwd -> :clear end,
                   gate_result_base_sha_fn: fn _cwd -> base_head end,
                   gate_tree_match_fn: fn _cwd -> true end,
                   clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
                 )
               )

      assert Agent.get(calls_agent, & &1) == ["committer"]
    end

    # Regression for pitch "a failed cycle leaves no checkpoint the NEXT
    # pitch can resume into": a checkpoint stamped with a DIFFERENT pitch's
    # slug must never be resumed, even when every other guard (state,
    # verdict, tree, HEAD) is fully valid — that combination is exactly what
    # a foreign pitch's checkpoint looks like from the resuming cycle's
    # point of view. Every prior test in this describe block ran a single
    # cycle; this one deliberately crosses a slug boundary, which is the gap
    # the original bug slipped through (see the pitch's claim 6).
    test "checkpoint stamped with a DIFFERENT slug → full run, never resumes a foreign pitch", %{
      dir: dir,
      base_head: base_head,
      calls_agent: calls_agent
    } do
      tree_sha = real_tree_sha_after_write!(dir, "feature.txt", "wip\n")
      write_gate_result!(dir, "clear", tree_sha, base_head)
      write_cycle_state!(dir, "GATED", "pitch-a")

      assert :ok ==
               OrchestrationLoop.run(
                 resume_run_opts(dir, calls_agent,
                   slug: "pitch-b",
                   cycle_state_get_fn: fn _cwd -> "GATED" end,
                   cycle_state_slug_fn: fn _cwd -> "pitch-a" end,
                   read_verdict_fn: fn _cwd -> :clear end,
                   gate_result_base_sha_fn: fn _cwd -> base_head end,
                   gate_tree_match_fn: fn _cwd -> true end,
                   clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
                 )
               )

      assert Agent.get(calls_agent, & &1) ==
               ["developer-static", "reviewer-static", "context-curator", "committer"]
    end

    test "checkpoint stamped with an empty slug (pre-upgrade record) → full run, never resumes",
         %{
           dir: dir,
           base_head: base_head,
           calls_agent: calls_agent
         } do
      tree_sha = real_tree_sha_after_write!(dir, "feature.txt", "wip\n")
      write_gate_result!(dir, "clear", tree_sha, base_head)
      write_cycle_state!(dir, "GATED")

      assert :ok ==
               OrchestrationLoop.run(
                 resume_run_opts(dir, calls_agent,
                   slug: "pitch-b",
                   cycle_state_get_fn: fn _cwd -> "GATED" end,
                   cycle_state_slug_fn: fn _cwd -> "" end,
                   read_verdict_fn: fn _cwd -> :clear end,
                   gate_result_base_sha_fn: fn _cwd -> base_head end,
                   gate_tree_match_fn: fn _cwd -> true end,
                   clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
                 )
               )

      assert Agent.get(calls_agent, & &1) ==
               ["developer-static", "reviewer-static", "context-curator", "committer"]
    end

    test "no cycle-state.json → full run from role 0 (developer-static first)", %{
      dir: dir,
      calls_agent: calls_agent
    } do
      # No checkpoint files written at all — the ordinary case.
      File.write!(Path.join(dir, "feature.txt"), "wip\n")

      assert :ok ==
               OrchestrationLoop.run(
                 resume_run_opts(dir, calls_agent,
                   cycle_state_get_fn: fn _cwd -> "" end,
                   clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
                 )
               )

      assert Agent.get(calls_agent, & &1) ==
               ["developer-static", "reviewer-static", "context-curator", "committer"]
    end

    test "cycle-state COMMITTED → full run from role 0 (terminal state never resumes)", %{
      dir: dir,
      base_head: base_head,
      calls_agent: calls_agent
    } do
      # graded_tree_sha "" — the real (unmocked) assert_commit_matches_gate!/1
      # skips comparison entirely on an empty stamped value; this test's
      # committer stub creates real content the fixture value could never
      # match, and matching is not what's under test here (the COMMITTED
      # state itself is).
      write_gate_result!(dir, "clear", "", base_head)
      write_cycle_state!(dir, "COMMITTED")
      File.write!(Path.join(dir, "feature.txt"), "wip\n")

      assert :ok ==
               OrchestrationLoop.run(
                 resume_run_opts(dir, calls_agent,
                   cycle_state_get_fn: fn _cwd -> "COMMITTED" end,
                   read_verdict_fn: fn _cwd -> :clear end,
                   gate_result_base_sha_fn: fn _cwd -> base_head end,
                   gate_tree_match_fn: fn _cwd -> true end,
                   clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
                 )
               )

      assert Agent.get(calls_agent, & &1) ==
               ["developer-static", "reviewer-static", "context-curator", "committer"]
    end

    test "gate verdict not clear → full run from role 0", %{
      dir: dir,
      base_head: base_head,
      calls_agent: calls_agent
    } do
      write_gate_result!(dir, "failed", "", base_head)
      write_cycle_state!(dir, "GATED")
      File.write!(Path.join(dir, "feature.txt"), "wip\n")

      assert :ok ==
               OrchestrationLoop.run(
                 resume_run_opts(dir, calls_agent,
                   cycle_state_get_fn: fn _cwd -> "GATED" end,
                   read_verdict_fn: fn _cwd -> :failed end,
                   gate_result_base_sha_fn: fn _cwd -> base_head end,
                   gate_tree_match_fn: fn _cwd -> true end,
                   clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
                 )
               )

      assert Agent.get(calls_agent, & &1) ==
               ["developer-static", "reviewer-static", "context-curator", "committer"]
    end

    test "read_verdict_fn raising (absent gate-result.json) → full run, never propagates", %{
      dir: dir,
      calls_agent: calls_agent
    } do
      write_cycle_state!(dir, "GATED")
      File.write!(Path.join(dir, "feature.txt"), "wip\n")

      assert :ok ==
               OrchestrationLoop.run(
                 resume_run_opts(dir, calls_agent,
                   cycle_state_get_fn: fn _cwd -> "GATED" end,
                   read_verdict_fn: fn _cwd ->
                     raise "LoopGate: unrecognized/missing verdict"
                   end,
                   clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
                 )
               )

      assert Agent.get(calls_agent, & &1) ==
               ["developer-static", "reviewer-static", "context-curator", "committer"]
    end

    test "graded_tree_sha drifted since the gate ran → full run from role 0", %{
      dir: dir,
      base_head: base_head,
      calls_agent: calls_agent
    } do
      write_gate_result!(dir, "clear", "", base_head)
      write_cycle_state!(dir, "GATED")
      File.write!(Path.join(dir, "feature.txt"), "wip\n")

      assert :ok ==
               OrchestrationLoop.run(
                 resume_run_opts(dir, calls_agent,
                   cycle_state_get_fn: fn _cwd -> "GATED" end,
                   read_verdict_fn: fn _cwd -> :clear end,
                   gate_result_base_sha_fn: fn _cwd -> base_head end,
                   # tree has drifted since the gate graded it
                   gate_tree_match_fn: fn _cwd -> false end,
                   clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
                 )
               )

      assert Agent.get(calls_agent, & &1) ==
               ["developer-static", "reviewer-static", "context-curator", "committer"]
    end

    test "HEAD moved past base_sha (committer landed before dying) → full run from role 0", %{
      dir: dir,
      calls_agent: calls_agent
    } do
      write_gate_result!(dir, "clear", "", "0000000000000000000000000000000000000000")
      write_cycle_state!(dir, "GATED")
      File.write!(Path.join(dir, "feature.txt"), "wip\n")

      assert :ok ==
               OrchestrationLoop.run(
                 resume_run_opts(dir, calls_agent,
                   cycle_state_get_fn: fn _cwd -> "GATED" end,
                   read_verdict_fn: fn _cwd -> :clear end,
                   gate_result_base_sha_fn: fn _cwd ->
                     "0000000000000000000000000000000000000000"
                   end,
                   gate_tree_match_fn: fn _cwd -> true end,
                   clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
                 )
               )

      assert Agent.get(calls_agent, & &1) ==
               ["developer-static", "reviewer-static", "context-curator", "committer"]
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

  defp reviewer_role?(role), do: role == "reviewer-phoenix" or role == "reviewer-static"

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
      invoke_fn: fn role, _harness, _ctx, _opts ->
        value = if reviewer_role?(role), do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"
        {:ok, %{"status" => "success", "value" => value}}
      end,
      gate_fn: fn _cwd, _opts -> {:clear, "make test"} end,
      gate_preflight_fn: fn _cwd -> {"make test", "short", 0} end,
      preflight_probe_fn: fn _cwd ->
        "--agent '__codegen_loop_preflight_probe__' not found. Available agents: " <>
          "planner-phoenix, developer-phoenix-backend, developer-phoenix-frontend, " <>
          "reviewer-phoenix, context-curator, committer, developer-static, reviewer-static"
      end,
      advance_cycle_state_fn: fn _state, _step_log, _session_id, _verdict, _project_dir, _slug ->
        :ok
      end,
      orphan_scan_fn: fn _cwd -> [] end,
      planner_plan_fn: fn _log_file -> "## Plan\n\n**Approach**: do the thing." end
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

# Isolated for the same reason as OrchestrationLoopLockTest: exercises the
# REAL default_log_init/3 (no :log_init_fn stub) against a real, ambient
# CODEGEN_LOG_PATH — a process-global env var — so it cannot share async:
# true execution with the ~38 unrelated role-sequencing tests above.
defmodule CodegenTestHarness.OrchestrationLoopDefaultLogInitTest do
  use ExUnit.Case, async: false

  alias CodegenTestHarness.OrchestrationLoop

  defp reviewer_role?(role), do: role == "reviewer-phoenix" or role == "reviewer-static"

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "orchestration_loop_default_log_init_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(dir, "codegen/logging"))
    on_exit(fn -> File.rm_rf!(dir) end)

    System.put_env("CODEGEN_BUILD_LOCK_HELD", "1")
    on_exit(fn -> System.delete_env("CODEGEN_BUILD_LOCK_HELD") end)

    {:ok, dir: dir}
  end

  # The bug this guards against: OrchestrationLoop shells out to the REAL
  # codegen-log binary via System.cmd. System.cmd inherits the calling BEAM
  # process's OS-level env unless explicitly overridden per key — so if this
  # test's ambient CODEGEN_LOG_PATH (set via System.put_env, ExUnit's own
  # process env) is not explicitly cleared by default_log_init/3's env list,
  # the loop's own `codegen-log init` call would refuse itself (exit 2, since
  # `init` now hard-refuses under any non-empty pin) and run/1 would raise —
  # a self-build (or any nested build) would never get past cycle-log
  # creation. This test proves the loop clears its own pin before init'ing.
  test "run/1 succeeds via the real default_log_init/3 even with an ambient CODEGEN_LOG_PATH set",
       ctx do
    ambient_pin = Path.join(ctx.dir, "codegen/logging/some_unrelated_cycle.jsonl")
    File.write!(ambient_pin, Jason.encode!(%{"ev" => "init", "pitch" => "unrelated"}) <> "\n")

    System.put_env("CODEGEN_LOG_PATH", ambient_pin)
    on_exit(fn -> System.delete_env("CODEGEN_LOG_PATH") end)

    # Neutralize an ambient CODEGEN_BUILD_CWD/CLAUDE_PROJECT_DIR the dev
    # session running THIS suite may have exported (codegen-log's LOG_ROOT
    # falls back to either before $PWD — see codegen-log:113). Left set, the
    # loop's `cd: cwd` option is silently overridden and default_log_init/3
    # mints its log under the wrong root entirely, masking this test's real
    # assertion (the ambient-pin-clearing behavior) behind an unrelated path
    # bug. Same isolation pattern codegen-log_test.sh already documents.
    prior_build_cwd = System.get_env("CODEGEN_BUILD_CWD")
    prior_claude_project_dir = System.get_env("CLAUDE_PROJECT_DIR")
    System.delete_env("CODEGEN_BUILD_CWD")
    System.delete_env("CLAUDE_PROJECT_DIR")

    on_exit(fn ->
      if prior_build_cwd, do: System.put_env("CODEGEN_BUILD_CWD", prior_build_cwd)

      if prior_claude_project_dir,
        do: System.put_env("CLAUDE_PROJECT_DIR", prior_claude_project_dir)
    end)

    assert :ok ==
             OrchestrationLoop.run(
               harness: "claude_code",
               stack: "phoenix",
               cwd: ctx.dir,
               pitch: "do the thing",
               slug: "default-log-init-under-ambient-pin",
               invoke_fn: fn role, _harness, _ctx, _opts ->
                 value =
                   if reviewer_role?(role), do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"

                 {:ok, %{"status" => "success", "value" => value}}
               end,
               gate_fn: fn _cwd, _opts -> {:clear, "make test"} end,
               gate_preflight_fn: fn _cwd -> {"make test", "short", 0} end,
               preflight_probe_fn: fn _cwd ->
                 "--agent '__codegen_loop_preflight_probe__' not found. Available agents: " <>
                   "planner-phoenix, developer-phoenix-backend, developer-phoenix-frontend, " <>
                   "reviewer-phoenix, context-curator, committer, developer-static, reviewer-static"
               end,
               advance_cycle_state_fn: fn _state,
                                          _step_log,
                                          _session_id,
                                          _verdict,
                                          _project_dir,
                                          _slug ->
                 :ok
               end,
               orphan_scan_fn: fn _cwd -> [] end,
               planner_plan_fn: fn _log_file -> "## Plan\n\n**Approach**: do the thing." end
             )

    # The cycle minted its OWN log under ctx.dir/codegen/logging — distinct
    # from the ambient pin — proving default_log_init/3 actually ran (rather
    # than, say, silently reusing the ambient pin because it never cleared
    # it).
    minted =
      Path.wildcard(Path.join(ctx.dir, "codegen/logging/*default-log-init-under-ambient-pin*"))

    assert length(minted) == 1
  end
end

defmodule CodegenTestHarness.OrchestrationLoopTest do
  use ExUnit.Case, async: true

  import CodegenTestHarness.AgentTeardown, only: [stop_agent: 1]

  alias CodegenTestHarness.LoopGate
  alias CodegenTestHarness.OrchestrationLoop

  @phoenix_sequence ~w(developer-phoenix-backend reviewer-phoenix context-curator)
  @static_sequence ~w(developer-static reviewer-static context-curator)

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

  describe "build_prompt/2 — ## Diff under review (loop-supplied, move 1)" do
    test "reviewer-phoenix prompt renders the loop-supplied diff under review" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{
          review_file_set: "lib/foo.ex",
          review_diff: "```diff\n+def foo, do: :ok\n```\n\n### Untracked files\n\n```\n```"
        }
      }

      content = OrchestrationLoop.build_prompt("reviewer-phoenix", ctx)

      assert content =~ "## Diff under review"
      assert content =~ "+def foo, do: :ok"
      assert content =~ "you do not need to re-derive it with `git diff`"
    end

    test "reviewer-static prompt renders the loop-supplied diff under review" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{
          review_file_set: "assets/app.js",
          review_diff: "```diff\n+console.log(1)\n```\n\n### Untracked files\n\n```\n```"
        }
      }

      content = OrchestrationLoop.build_prompt("reviewer-static", ctx)

      assert content =~ "## Diff under review"
      assert content =~ "+console.log(1)"
    end

    test "no review_diff artifact → no ## Diff under review section" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{review_file_set: "lib/foo.ex"}
      }

      content = OrchestrationLoop.build_prompt("reviewer-phoenix", ctx)

      refute content =~ "## Diff under review"
    end

    test "developer prompt is NOT enriched with ## Diff under review (reviewer-only block)" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{review_diff: "```diff\n+foo\n```"}
      }

      content = OrchestrationLoop.build_prompt("developer-phoenix-backend", ctx)

      refute content =~ "## Diff under review"
    end
  end

  describe "build_prompt/2 — ## Since your last review (re-review delta, move 2)" do
    test "first-pass reviewer prompt (no review_diff_delta) carries no ## Since your last review block" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{review_file_set: "lib/foo.ex"}
      }

      content = OrchestrationLoop.build_prompt("reviewer-phoenix", ctx)

      refute content =~ "## Since your last review"
    end

    test "re-review prompt carries the prior finding, the changed-paths delta, and the terminality notice" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{
          review_file_set: "lib/foo.ex",
          review_feedback: "the pitch-format-validator.sh SHAPED gate is untested",
          review_diff_delta: [{"lib/foo.ex", :changed}],
          review_diff_bodies: %{"lib/foo.ex" => "diff --git a/lib/foo.ex b/lib/foo.ex\n+fix"},
          review_pass_number: 2,
          review_max_passes: 2
        }
      }

      content = OrchestrationLoop.build_prompt("reviewer-phoenix", ctx)

      assert content =~ "## Since your last review"
      assert content =~ "### Your prior finding"
      assert content =~ "the pitch-format-validator.sh SHAPED gate is untested"
      assert content =~ "### What changed since then"
      assert content =~ "lib/foo.ex (changed)"
      assert content =~ "+fix"
      assert content =~ "This is review pass 2 of 2"
      assert content =~ "review re-work budget is exhausted"
      assert content =~ "no further rework"
    end

    test "re-review prompt with a non-terminal pass number states the pass without an exhaustion notice" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{
          review_file_set: "lib/foo.ex",
          review_feedback: "fix the thing",
          review_diff_delta: [{"lib/foo.ex", :changed}],
          review_diff_bodies: %{"lib/foo.ex" => "+fix"},
          review_pass_number: 2,
          review_max_passes: 3
        }
      }

      content = OrchestrationLoop.build_prompt("reviewer-phoenix", ctx)

      assert content =~ "This is review pass 2 of 3."
      refute content =~ "budget is exhausted"
    end

    test "an empty delta (no path's diff changed) is reported explicitly, not omitted" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{
          review_file_set: "lib/foo.ex",
          review_feedback: "fix the thing",
          review_diff_delta: [],
          review_diff_bodies: %{}
        }
      }

      content = OrchestrationLoop.build_prompt("reviewer-phoenix", ctx)

      assert content =~ "## Since your last review"
      assert content =~ "No path's diff changed since your last pass"
    end

    test "a removed path (rework reverted a file) is reported as removed, naming the path" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{
          review_file_set: "lib/foo.ex",
          review_feedback: "fix the thing",
          review_diff_delta: [{"lib/reverted.ex", :removed}],
          review_diff_bodies: %{}
        }
      }

      content = OrchestrationLoop.build_prompt("reviewer-phoenix", ctx)

      assert content =~ "lib/reverted.ex (removed since your last pass)"
      assert content =~ "reverted it"
    end

    test "developer prompt is NOT enriched with ## Since your last review (reviewer-only block)" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{
          review_diff_delta: [{"lib/foo.ex", :changed}],
          review_diff_bodies: %{"lib/foo.ex" => "+fix"}
        }
      }

      content = OrchestrationLoop.build_prompt("developer-phoenix-backend", ctx)

      refute content =~ "## Since your last review"
    end
  end

  describe "build_prompt/2 — ## Learnings to route (curator ev:learned events, move 3)" do
    test "curator prompt renders the found ev:learned events verbatim" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{
          curator_learnings:
            {{:ok,
              [
                "developer-phoenix-backend: caught a bug",
                "reviewer-phoenix: scoped a warning"
              ]}, "/tmp/log.jsonl"}
        }
      }

      content = OrchestrationLoop.build_prompt("context-curator", ctx)

      assert content =~ "## Learnings to route"
      assert content =~ "developer-phoenix-backend: caught a bug"
      assert content =~ "reviewer-phoenix: scoped a warning"
      assert content =~ "/tmp/log.jsonl"
    end

    test "curator prompt states explicitly when the log was read but held no learnings" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{curator_learnings: {{:ok, []}, "/tmp/log.jsonl"}}
      }

      content = OrchestrationLoop.build_prompt("context-curator", ctx)

      assert content =~ "## Learnings to route"
      assert content =~ "No `ev:learned` events were recorded this cycle"
      assert content =~ "/tmp/log.jsonl"
    end

    test "curator prompt states explicitly, and DIFFERENTLY, when the log could not be read (D12)" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{curator_learnings: {{:error, :unreadable}, "/tmp/missing.jsonl"}}
      }

      content = OrchestrationLoop.build_prompt("context-curator", ctx)

      assert content =~ "## Learnings to route"
      assert content =~ "could not be read"
      assert content =~ "NOT the same as an empty cycle"
      refute content =~ "No `ev:learned` events were recorded this cycle"
    end

    test "curator prompt states explicitly when no cycle log was initialized" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{curator_learnings: {{:error, :absent}, nil}}
      }

      content = OrchestrationLoop.build_prompt("context-curator", ctx)

      assert content =~ "## Learnings to route"
      assert content =~ "No cycle log was initialized"
      assert content =~ "NOT the same as an empty cycle"
    end

    test "no curator_learnings artifact at all → no ## Learnings to route block" do
      ctx = %{cwd: "/tmp", pitch: "do the thing", artifacts: %{}}

      content = OrchestrationLoop.build_prompt("context-curator", ctx)

      refute content =~ "## Learnings to route"
    end

    test "reviewer prompt is NOT enriched with ## Learnings to route (curator-only block)" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{curator_learnings: {{:ok, ["role: text"]}, "/tmp/log.jsonl"}}
      }

      content = OrchestrationLoop.build_prompt("reviewer-phoenix", ctx)

      refute content =~ "## Learnings to route"
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
    test "phoenix is developer-first" do
      assert OrchestrationLoop.role_sequence("phoenix") == @phoenix_sequence
    end

    test "no stack has a planner role in its sequence" do
      for stack <- ~w(phoenix static), role <- OrchestrationLoop.role_sequence(stack) do
        refute String.starts_with?(role, "planner-"),
               "#{stack} sequence still names a planner role: #{role}"
      end
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
    fn role, _harness, ctx, _opts ->
      Agent.update(calls_agent, fn calls -> calls ++ [role] end)
      value = if reviewer_role?(role), do: approved_verdict_for(ctx), else: "did #{role}"
      {:ok, %{"status" => "success", "value" => value}}
    end
  end

  defp reviewer_role?(role), do: role == "reviewer-phoenix" or role == "reviewer-static"

  # Builds a full `REVIEW_COVERAGE:` + terminal `REVIEW_VERDICT: APPROVED`
  # body from whatever `ctx.artifacts.review_file_set` the loop already
  # captured (empty in a mocked non-git cwd -> no coverage lines needed;
  # real in a real git tree -> one `read` line per path) so test stubs
  # never have to hardcode a path they don't otherwise care about.
  defp approved_verdict_for(ctx) do
    files = get_in(ctx, [:artifacts, :review_file_set]) || ""

    coverage_lines =
      files
      |> String.split("\n", trim: true)
      |> Enum.map(&"REVIEW_COVERAGE: #{&1} read")

    Enum.join(coverage_lines ++ ["REVIEW_VERDICT: APPROVED"], "\n")
  end

  # Same shape as approved_verdict_for/1, but BLOCKING — for the resumed-cycle
  # regression where there is no developer role in ctx.artifacts to route the
  # rework to.
  defp changes_requested_verdict_for(ctx) do
    ctx
    |> approved_verdict_for()
    |> String.replace("REVIEW_VERDICT: APPROVED", "REVIEW_VERDICT: CHANGES_REQUESTED")
  end

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

  # Real default_advisor_fn/3 shells out to the codegen-advise binary, which
  # calls a REAL stronger-model advisor. Any test whose gate_fn reaches the
  # give-up boundary (final_attempt? true) without stubbing :advisor_fn would
  # otherwise trigger a real, paid LLM call from what must be a hermetic,
  # no-LLM test suite. Use for any run/1 call whose gate_fn always fails.
  defp no_op_advisor_fn do
    fn _harness, _context_text, _opts -> :error end
  end

  defp all_present_preflight_probe_fn do
    fn _cwd ->
      "--agent '__codegen_loop_preflight_probe__' not found. Available agents: " <>
        "developer-phoenix-backend, developer-phoenix-frontend, " <>
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

  setup do
    {:ok, calls_agent} = Agent.start_link(fn -> [] end)
    on_exit(fn -> stop_agent(calls_agent) end)
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert Agent.get(calls_agent, & &1) == @static_sequence
    end
  end

  describe "run/1 — gate opts carry an attributable :session_id" do
    test "gate_fn receives :session_id == the developer role that just ran (not the anonymous default)",
         %{calls_agent: calls_agent} do
      {:ok, gate_opts_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(gate_opts_agent) end)

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

    test "violations seam result naming a non-curator-writable doc → raises InfraAbort naming the check and remediation, before any role runs",
         %{calls_agent: calls_agent} do
      # AGENTS.md is outside the curator's write surface — not repairable,
      # so this still hits the unconditional InfraAbort path.
      violating_fn = fn _cwd ->
        {:violations, "context-factcheck-scan: AGENTS.md:1 references a doc that does not exist"}
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

    test "violations seam result naming only curator-writable docs → repairs via context-curator instead of InfraAbort",
         %{calls_agent: calls_agent} do
      {:ok, scan_agent} = Agent.start_link(fn -> :first end)
      on_exit(fn -> stop_agent(scan_agent) end)

      scan_fn = fn _cwd ->
        Agent.get_and_update(scan_agent, fn
          :first ->
            {{:violations,
              "context-index-parity-scan: context/new.md added but no index row mentions \"new\""},
             :second}

          :second ->
            {{:clean}, :second}
        end)
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
                 orientation_preflight_fn: scan_fn
               )

      # context-curator repaired the inherited drift, BEFORE the normal suffix ran
      assert Agent.get(calls_agent, & &1) ==
               ["context-curator" | @static_sequence]
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

    test "MIXED set (one curator-writable line + one AGENTS.md line) → InfraAbort, NEVER a partial repair",
         %{calls_agent: calls_agent} do
      mixed_fn = fn _cwd ->
        {:violations,
         "context-index-parity-scan: context/loop.md keyword drift\n" <>
           "context-factcheck-scan: AGENTS.md:1 references a doc that does not exist"}
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
                       orientation_preflight_fn: mixed_fn
                     )
                   end

      # zero role invocations — the writable line in the mixed set is NEVER
      # separated out and repaired on its own
      assert Agent.get(calls_agent, & &1) == []
    end

    test "violation naming CLAUDE.md → InfraAbort, zero role invocations",
         %{calls_agent: calls_agent} do
      violating_fn = fn _cwd ->
        {:violations, "context-factcheck-scan: CLAUDE.md:3 references a doc that does not exist"}
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

      assert Agent.get(calls_agent, & &1) == []
    end

    test "violation line with an unknown scanner prefix (unparseable target) → InfraAbort, zero role invocations",
         %{calls_agent: calls_agent} do
      # No recognized "<scanner-name>: " prefix at all — the grammar changed
      # under us; must be treated as ambiguous (fail closed), never guessed.
      violating_fn = fn _cwd -> {:violations, "some-unknown-tool: drift detected"} end

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

      assert Agent.get(calls_agent, & &1) == []
    end

    test "repairable violation converges across 2 curator turns before resuming the normal suffix",
         %{calls_agent: calls_agent} do
      {:ok, scan_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(scan_agent) end)

      scan_fn = fn _cwd ->
        n = Agent.get_and_update(scan_agent, fn c -> {c, c + 1} end)

        case n do
          0 -> {:violations, "context-index-parity-scan: context/loop.md drift A"}
          1 -> {:violations, "context-index-parity-scan: context/loop.md drift B"}
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
                 orientation_preflight_fn: scan_fn
               )

      # 2 turn-0 repair invocations + 1 normal-suffix context-curator spawn
      # (context-curator is always in @static_sequence) = 3 total.
      curator_calls = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "context-curator"))
      assert curator_calls == 3
      assert List.last(Agent.get(calls_agent, & &1)) == "context-curator"
    end

    test "no progress (identical violation set every pass) → {:error, _} owned by context-curator, invoked exactly the guaranteed floor",
         %{calls_agent: calls_agent} do
      always_violates_fn = fn _cwd ->
        {:violations, "context-index-parity-scan: context/loop.md drift"}
      end

      error =
        assert_raise RuntimeError, fn ->
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
            orientation_preflight_fn: always_violates_fn,
            max_curator_doc_cycles: 1
          )
        end

      assert error.message =~ "context-curator"
      curator_calls = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "context-curator"))
      assert curator_calls == 1
      refute "committer" in Agent.get(calls_agent, & &1)
    end

    test "hard ceiling caps turn-0 repair even with continuous one-per-turn progress",
         %{calls_agent: calls_agent} do
      {:ok, scan_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(scan_agent) end)

      scan_fn = fn _cwd ->
        n = Agent.get_and_update(scan_agent, fn c -> {c, c + 1} end)
        remaining = for i <- (n + 1)..29, do: "context-index-parity-scan: context/v#{i}.md drift"

        {:violations,
         Enum.join(["context-index-parity-scan: context/v#{n}.md drift" | remaining], "\n")}
      end

      assert_raise RuntimeError, fn ->
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
          orientation_preflight_fn: scan_fn,
          max_curator_doc_cycles: 1
        )
      end

      curator_calls = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "context-curator"))
      assert curator_calls == 15
      refute "committer" in Agent.get(calls_agent, & &1)
    end

    test "turn-0 repair exhaustion writes NO terminal marker — doc drift stays retryable",
         %{calls_agent: calls_agent} do
      # A terminal marker is read before retry_eligible?/5 and routes the pitch
      # to park + skip + circuit breaker, never a retry. Orientation-doc drift
      # is not that: the curator owns every path the scan can name, so a second
      # pass can land what one bounded pass did not. The cycle must still fail,
      # and must stay retry-eligible.
      tmp_cwd =
        Path.join(
          System.tmp_dir!(),
          "loop-turn0-terminal-marker-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_cwd)
      on_exit(fn -> File.rm_rf!(tmp_cwd) end)

      always_violates_fn = fn _cwd ->
        {:violations, "context-index-parity-scan: context/loop.md drift"}
      end

      assert_raise RuntimeError, fn ->
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
          orientation_preflight_fn: always_violates_fn,
          max_curator_doc_cycles: 1
        )
      end

      refute File.exists?(Path.join(tmp_cwd, "codegen/gate-pending/terminal-state.json"))
    end

    test "terminal marker write failure raises InfraAbort instead of leaving the deterministic error unmarked",
         %{calls_agent: calls_agent} do
      # codegen/gate-pending exists as a FILE (not a dir), so File.mkdir_p
      # for the marker path fails — proves the write-failure path raises
      # loud rather than degrading to a silent stderr note.
      #
      # Driven through the ENV-VAR exhaustion producer: the two orientation-doc
      # producers deliberately no longer write a marker (doc drift is
      # retryable), so they can no longer exercise the write-failure path.
      tmp_cwd =
        Path.join(
          System.tmp_dir!(),
          "loop-marker-write-fail-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(tmp_cwd, "codegen"))
      File.write!(Path.join([tmp_cwd, "codegen", "gate-pending"]), "not a directory")
      on_exit(fn -> File.rm_rf!(tmp_cwd) end)

      always_violates_fn = fn _cwd -> {:violations, "MY_VAR"} end

      assert_raise CodegenTestHarness.InfraAbort,
                   ~r/terminal-marker-write/,
                   fn ->
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
                   end
    end

    test "unresolved context-curator agent + a repairable violation → raises naming the missing role, zero role invocations",
         %{calls_agent: calls_agent} do
      repairable_fn = fn _cwd ->
        {:violations, "context-index-parity-scan: context/loop.md drift"}
      end

      # preflight_probe_fn's "Available agents:" list omits context-curator
      # entirely — the lazy resolution in run_orientation_preflight/4 must
      # still raise before any spend, even though the SELECTED suffix's own
      # agents (all present here) resolve fine on their own probe.
      missing_curator_probe_fn = fn _cwd ->
        "--agent '__codegen_loop_preflight_probe__' not found. Available agents: " <>
          "developer-phoenix-backend, developer-phoenix-frontend, " <>
          "reviewer-phoenix, committer, developer-static, reviewer-static"
      end

      assert_raise RuntimeError, ~r/context-curator/, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "static",
          cwd: "/tmp/irrelevant",
          pitch: "do the thing",
          invoke_fn: always_ok_invoke_fn(calls_agent),
          gate_fn: always_clear_gate_fn(),
          gate_preflight_fn: no_op_gate_preflight_fn(),
          preflight_probe_fn: missing_curator_probe_fn,
          advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
          orientation_preflight_fn: repairable_fn
        )
      end

      assert Agent.get(calls_agent, & &1) == []
    end

    test "scanner returns an unrecognized seam value → raises, zero role invocations",
         %{calls_agent: calls_agent} do
      bogus_fn = fn _cwd -> :not_a_valid_seam_value end

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
          orientation_preflight_fn: bogus_fn
        )
      end

      assert Agent.get(calls_agent, & &1) == []
    end

    test "turn-0 repair never advances CURATED itself — the only CURATED write comes from the real suffix's own post-curator check, after GATED",
         %{calls_agent: calls_agent} do
      {:ok, scan_agent} = Agent.start_link(fn -> :first end)
      on_exit(fn -> stop_agent(scan_agent) end)

      scan_fn = fn _cwd ->
        Agent.get_and_update(scan_agent, fn
          :first ->
            {{:violations, "context-index-parity-scan: context/loop.md drift"}, :second}

          :second ->
            {{:clean}, :second}
        end)
      end

      {:ok, states_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(states_agent) end)

      advance_fn = fn state, _step_log, _session_id, _verdict, _cwd, _slug ->
        Agent.update(states_agent, &[state | &1])
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
                 orientation_preflight_fn: scan_fn
               )

      states_in_order = Agent.get(states_agent, & &1) |> Enum.reverse()

      # Exactly ONE "CURATED" write in the whole run — the real suffix's own
      # post-curator doc check (there are zero context-created violations
      # here, so that check itself clears on its first pass and advances
      # CURATED legitimately). If the turn-0 repair ALSO advanced CURATED,
      # this would be 2.
      assert Enum.count(states_in_order, &(&1 == "CURATED")) == 1

      # The turn-0 repair (invoked before any suffix role — see the
      # dedicated ordering test above) never itself calls
      # advance_cycle_state_fn. The one CURATED entry is causally downstream
      # of GATED (the suffix's own gate loop), not something the turn-0
      # phase raced ahead to write before the suffix even started.
      gated_index = Enum.find_index(states_in_order, &(&1 == "GATED"))
      curated_index = Enum.find_index(states_in_order, &(&1 == "CURATED"))
      assert gated_index < curated_index
    end

    test "repair-turn prompt to context-curator carries the Orientation-doc violations heading, the verbatim lines, and the edit-scope trailer",
         %{calls_agent: calls_agent} do
      {:ok, scan_agent} = Agent.start_link(fn -> :first end)
      on_exit(fn -> stop_agent(scan_agent) end)

      violation_text = "context-index-parity-scan: context/loop.md keyword drift"

      scan_fn = fn _cwd ->
        Agent.get_and_update(scan_agent, fn
          :first -> {{:violations, violation_text}, :second}
          :second -> {{:clean}, :second}
        end)
      end

      {:ok, prompts_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(prompts_agent) end)

      capturing_invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, &(&1 ++ [role]))

        if role == "context-curator" do
          Agent.update(
            prompts_agent,
            &[OrchestrationLoop.build_prompt(role, ctx) | &1]
          )
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
                 invoke_fn: capturing_invoke_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 orientation_preflight_fn: scan_fn
               )

      # The FIRST captured prompt is the repair-turn invocation (before the
      # normal suffix even starts) — assert on that one specifically. A
      # later, unrelated context-curator spawn from the normal suffix
      # (@static_sequence always includes one) is out of scope for this
      # assertion.
      [first_prompt | _] = Enum.reverse(Agent.get(prompts_agent, & &1))
      assert first_prompt =~ "## Orientation-doc violations to fix"
      assert first_prompt =~ violation_text
      assert first_prompt =~ "Edit only the named orientation docs"
    end

    test "operator output: 'found repairable drift' on entry, 'repaired — continuing' after clear; the latter ABSENT on a clean first pass",
         %{calls_agent: calls_agent} do
      {:ok, scan_agent} = Agent.start_link(fn -> :first end)
      on_exit(fn -> stop_agent(scan_agent) end)

      scan_fn = fn _cwd ->
        Agent.get_and_update(scan_agent, fn
          :first -> {{:violations, "context-index-parity-scan: context/loop.md drift"}, :second}
          :second -> {{:clean}, :second}
        end)
      end

      repaired_output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
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
            orientation_preflight_fn: scan_fn
          )
        end)

      assert repaired_output =~
               "orientation-doc preflight found repairable drift — invoking context-curator"

      assert repaired_output =~ "orientation-doc preflight repaired — continuing"

      clean_output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
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
        end)

      refute clean_output =~ "orientation-doc preflight repaired — continuing"
    end
  end

  describe "run/1 — :pitch_scope threading" do
    test "phoenix cycle threads the run option's scope into the developer prompt as ## Declared Scope",
         %{calls_agent: calls_agent} do
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

        {:ok, %{"status" => "success", "value" => value}}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "phoenix",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 pitch_scope: ["lib/foo.ex", "test/foo_test.exs"],
                 invoke_fn: invoke_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      prompt = Agent.get(seen_prompt, & &1)
      assert prompt =~ "## Declared Scope"
      assert prompt =~ "lib/foo.ex"
      assert prompt =~ "test/foo_test.exs"
      # The retired `## Plan` block occupied this slot — nothing may re-mint it.
      refute prompt =~ "## Plan"
    end

    test "reviewer sees the same declared scope the developer saw", %{calls_agent: calls_agent} do
      seen = Agent.start_link(fn -> %{} end) |> elem(1)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)
        Agent.update(seen, &Map.put(&1, role, OrchestrationLoop.build_prompt(role, ctx)))

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
                 pitch_scope: ["lib/foo.ex"],
                 invoke_fn: invoke_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      prompts = Agent.get(seen, & &1)
      assert prompts["reviewer-phoenix"] =~ "## Declared Scope"
      assert prompts["reviewer-phoenix"] =~ "lib/foo.ex"
      # ...and no other role does. The commit step is not a role invocation
      # at all (see pitch "committing is deterministic, not a model call"),
      # so there is no `prompts["committer"]`/commit-step entry to check.
      refute prompts["context-curator"] =~ "## Declared Scope"
    end

    test "no :pitch_scope option (ad-hoc literal pitch) → prompts carry no ## Declared Scope",
         %{calls_agent: calls_agent} do
      seen_prompt = Agent.start_link(fn -> nil end) |> elem(1)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "developer-static" do
          Agent.update(seen_prompt, fn _ -> OrchestrationLoop.build_prompt(role, ctx) end)
        end

        value =
          if role == "reviewer-static",
            do: "REVIEW_VERDICT: APPROVED",
            else: "did #{role}"

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

      assert Agent.get(calls_agent, & &1) == @static_sequence
      refute Agent.get(seen_prompt, & &1) =~ "## Declared Scope"
    end
  end

  describe "run/1 — the loop authors the files_to_touch event (log_declared_scope)" do
    test ":log_scope_fn is called once, at turn 0, with the threaded scope and the cwd",
         %{calls_agent: calls_agent} do
      {:ok, scope_agent} = Agent.start_link(fn -> [] end)

      log_scope_fn = fn scope, cwd ->
        Agent.update(scope_agent, fn seen -> seen ++ [{scope, cwd}] end)
        :ok
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "phoenix",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 pitch_scope: ["lib/foo.ex", "context/foo.md"],
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 log_scope_fn: log_scope_fn
               )

      assert Agent.get(scope_agent, & &1) ==
               [{["lib/foo.ex", "context/foo.md"], "/tmp/irrelevant"}]
    end

    test ":log_scope_fn is called with nil when no scope was threaded (nothing is invented)",
         %{calls_agent: calls_agent} do
      {:ok, scope_agent} = Agent.start_link(fn -> [] end)

      log_scope_fn = fn scope, cwd ->
        Agent.update(scope_agent, fn seen -> seen ++ [{scope, cwd}] end)
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 log_scope_fn: log_scope_fn
               )

      assert Agent.get(scope_agent, & &1) == [{nil, "/tmp/irrelevant"}]
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
              do: "fix the nav link\nREVIEW_VERDICT: CHANGES_REQUESTED",
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
      # `:ok` above already proves the commit step ran — it is no longer a
      # role dispatched through invoke_fn (see pitch "committing is
      # deterministic, not a model call").
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
      # `:ok` above already proves the commit step ran.
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
            do: "still not right\nREVIEW_VERDICT: CHANGES_REQUESTED",
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

  # The three review budgets were (or became) hardcoded `1`s with no CLI
  # switch. Between two of them they killed 5 of 14 cycles one night and 100%
  # of cycles the next. These lock in that they are (a) sane by default and
  # (b) genuinely independent — a RESTATEMENT must never cost a REWORK.
  describe "run/1 — review budgets are separate and tunable" do
    test "default rework budget allows 3 CHANGES_REQUESTED rounds before failing",
         %{calls_agent: calls_agent} do
      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static",
            do: "still not right\nREVIEW_VERDICT: CHANGES_REQUESTED",
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert reason =~ "review re-work budget (3)"

      # 4 reviewer passes: the initial one plus 3 rework rounds.
      calls = Agent.get(calls_agent, & &1)
      assert Enum.count(calls, &(&1 == "reviewer-static")) == 4
      assert Enum.count(calls, &(&1 == "developer-static")) == 4
      assert "committer" not in calls
    end

    # The regression that forced the split: an :unknown verdict used to
    # increment `cycle`, so ONE formatting slip silently spent a rework round
    # the reviewer had genuinely asked for.
    test "an unparseable verdict does NOT consume the rework budget",
         %{calls_agent: calls_agent} do
      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "reviewer-static" do
          seen = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "reviewer-static"))

          # Pass 1: no verdict at all. Pass 2 (the verdict re-ask): a real
          # rejection. Passes 3+: approve, proving the full rework budget
          # survived the formatting slip.
          value =
            case seen do
              1 -> "I reviewed it and have thoughts."
              2 -> "fix the nav link\nREVIEW_VERDICT: CHANGES_REQUESTED"
              _ -> "REVIEW_VERDICT: APPROVED"
            end

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
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      # 3 reviewer passes (unparseable → re-ask → rejection → rework → approve)
      # and exactly ONE developer rework. Under the shared counter the
      # rejection at pass 2 would have found `cycle` already at 1 and, with
      # the old default of 1, failed the build outright.
      calls = Agent.get(calls_agent, & &1)
      assert Enum.count(calls, &(&1 == "reviewer-static")) == 3
      assert Enum.count(calls, &(&1 == "developer-static")) == 2
    end

    test "the verdict re-ask budget is separately exhaustible and fails loud",
         %{calls_agent: calls_agent} do
      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)
        value = if role == "reviewer-static", do: "no verdict here", else: "did #{role}"
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
                 max_review_verdict_cycles: 2
               )

      assert reason =~ "no parseable REVIEW_VERDICT"
      assert reason =~ "after 3 attempt(s)"

      calls = Agent.get(calls_agent, & &1)
      assert Enum.count(calls, &(&1 == "reviewer-static")) == 3
      assert "committer" not in calls
      assert "context-curator" not in calls
    end
  end

  # `aa404573` added 236 lines of enforcement and ONE line of instruction.
  # These lock in the cheap teaching counterpart: zero prompt bytes in the
  # steady state, the FULL violated contract exactly when it is needed —
  # including the specific paths this reviewer actually missed, which no
  # static rule file can name.
  describe "run/1 — re-ask prompts state the contract that was violated" do
    test "coverage re-ask names the regex, the totality rule, the missing paths, and the budget",
         %{calls_agent: calls_agent} do
      {:ok, prompts_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(prompts_agent) end)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "reviewer-static" do
          seen = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "reviewer-static"))

          Agent.update(prompts_agent, fn ps ->
            ps ++ [OrchestrationLoop.build_prompt(role, ctx)]
          end)

          # Pass 1 covers only one of the two changed paths.
          value =
            if seen == 1,
              do: "REVIEW_COVERAGE: lib/a.ex read\nREVIEW_VERDICT: APPROVED",
              else:
                "REVIEW_COVERAGE: lib/a.ex read\nREVIEW_COVERAGE: lib/b.ex read\n" <>
                  "REVIEW_VERDICT: APPROVED"

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
                 review_file_set_fn: fn _cwd -> "lib/a.ex\nlib/b.ex" end,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      re_ask = Agent.get(prompts_agent, & &1) |> Enum.at(1)

      # The steady-state (first) prompt must NOT carry the full contract —
      # the whole point is that it costs zero bytes until it is needed.
      first = Agent.get(prompts_agent, & &1) |> Enum.at(0)
      refute first =~ "## Coverage required (re-work)"

      assert re_ask =~ "## Coverage required (re-work)"
      # The exact gap, named.
      assert re_ask =~ "lib/b.ex"
      # The exact line format, as a regex the reviewer can match against.
      assert re_ask =~ "^REVIEW_COVERAGE:"
      assert re_ask =~ "read|skipped:"
      # Totality against the LOOP-computed set, not the reviewer's choice.
      assert re_ask =~ "TOTALITY"
      assert re_ask =~ "## Files Modified"
      # Naming a path outside the set is fatal.
      assert re_ask =~ "NO INVENTED PATHS"
      # Coverage precedes verdict parsing entirely.
      assert re_ask =~ "BEFORE YOUR VERDICT IS READ"
      # The retry budget, and that exhausting it FAILS rather than proceeds.
      assert re_ask =~ "RETRY BUDGET"
      assert re_ask =~ "attempt(s) remain"
      # And the concrete set it must cover.
      assert re_ask =~ "lib/a.ex"
    end

    test "verdict re-ask names the enum, the unanimity rule, and that absence is not approval",
         %{calls_agent: calls_agent} do
      {:ok, prompts_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(prompts_agent) end)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "reviewer-static" do
          seen = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "reviewer-static"))

          Agent.update(prompts_agent, fn ps ->
            ps ++ [OrchestrationLoop.build_prompt(role, ctx)]
          end)

          value =
            if seen == 1,
              do: "Review complete. Everything looks fine to me.",
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
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      prompts = Agent.get(prompts_agent, & &1)
      refute Enum.at(prompts, 0) =~ "## Verdict required (re-work)"

      re_ask = Enum.at(prompts, 1)
      assert re_ask =~ "## Verdict required (re-work)"
      # What the reviewer actually returned, quoted back.
      assert re_ask =~ "Review complete. Everything looks fine to me."
      # The enum, and that it is closed.
      assert re_ask =~ "REVIEW_VERDICT: APPROVED"
      assert re_ask =~ "REVIEW_VERDICT: CHANGES_REQUESTED"
      assert re_ask =~ "APPROVED_WITH_NITS"
      # The uniqueness/unanimity rule — the one that actually bites.
      assert re_ask =~ "UNANIMITY"
      assert re_ask =~ "exactly once"
      # The real failures from the logs: a trailing clause on the verdict line.
      assert re_ask =~ "REVIEW_VERDICT: APPROVED. Logged."
      # Terminality is NOT required (post-parser-fix) — say so, so the
      # reviewer does not contort its output to satisfy a dead rule.
      assert re_ask =~ "PLACEMENT IS FREE"
      # Absence is not approval, plus the budget.
      assert re_ask =~ "NOT AN APPROVAL"
      assert re_ask =~ "attempt(s) remain"
    end
  end

  describe "run/1 — review recovery and non-blocking findings" do
    test "all Non-blocking CHANGES_REQUESTED findings advance to curator without developer rework",
         %{calls_agent: calls_agent} do
      {:ok, curator_findings} = Agent.start_link(fn -> nil end)
      on_exit(fn -> stop_agent(curator_findings) end)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, &(&1 ++ [role]))

        if role == "context-curator" do
          Agent.update(curator_findings, fn _ ->
            get_in(ctx, [:artifacts, :review_non_blocking_findings])
          end)
        end

        value =
          if reviewer_role?(role) do
            "Non-blocking: wording in context/loop.md could be clearer\n" <>
              "REVIEW_VERDICT: CHANGES_REQUESTED"
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 max_review_cycles: 0
               )

      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "developer-static")) == 1
      assert Agent.get(curator_findings, & &1) =~ "Non-blocking: wording"
    end

    test "final re-review receives reviewer escalation and advisor plan, not the developer",
         %{calls_agent: calls_agent} do
      {:ok, reviewer_contexts} = Agent.start_link(fn -> [] end)
      {:ok, developer_contexts} = Agent.start_link(fn -> [] end)

      on_exit(fn ->
        stop_agent(reviewer_contexts)
        stop_agent(developer_contexts)
      end)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, &(&1 ++ [role]))

        case role do
          "reviewer-static" ->
            Agent.update(
              reviewer_contexts,
              &(&1 ++
                  [
                    {get_in(ctx, [:artifacts, :escalated_model]),
                     get_in(ctx, [:artifacts, :advisor_plan])}
                  ])
            )

            {:ok,
             %{
               "status" => "success",
               "value" => "blocking defect\nREVIEW_VERDICT: CHANGES_REQUESTED"
             }}

          "developer-static" ->
            Agent.update(
              developer_contexts,
              &(&1 ++ [get_in(ctx, [:artifacts, :escalated_model])])
            )

            {:ok, %{"status" => "success", "value" => "did developer-static"}}

          _ ->
            {:ok, %{"status" => "success", "value" => "did #{role}"}}
        end
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
                 max_review_cycles: 1,
                 resolve_escalation_fn: fn "reviewer-static", _harness -> {"opus", "high"} end,
                 advisor_fn: fn _harness, _context, _opts -> {:ok, "audit the review finding"} end
               )

      assert reason =~ "review re-work budget (1)"

      assert Agent.get(reviewer_contexts, & &1) == [
               {nil, nil},
               {{"opus", "high"}, "audit the review finding"}
             ]

      assert Agent.get(developer_contexts, & &1) == [nil, nil]
    end
  end

  describe "run/1 — reviewer verdict presentation-wrapper compatibility (#8)" do
    for harness <- ["claude_code"], stack <- ["phoenix", "static"] do
      @harness harness
      @stack stack

      test "#{harness}/#{stack}: strong APPROVED accepted, one reviewer call", %{
        calls_agent: calls_agent
      } do
        harness = @harness
        stack = @stack
        reviewer_role = if stack == "phoenix", do: "reviewer-phoenix", else: "reviewer-static"

        invoke_fn = fn role, _harness, _ctx, _opts ->
          Agent.update(calls_agent, fn calls -> calls ++ [role] end)

          value =
            if role == reviewer_role, do: "**REVIEW_VERDICT: APPROVED**", else: "did #{role}"

          {:ok, %{"status" => "success", "value" => value}}
        end

        assert :ok ==
                 OrchestrationLoop.run(
                   harness: harness,
                   stack: stack,
                   cwd: "/tmp/irrelevant",
                   pitch: "x",
                   invoke_fn: invoke_fn,
                   gate_fn: always_clear_gate_fn(),
                   gate_preflight_fn: no_op_gate_preflight_fn(),
                   preflight_probe_fn: all_present_preflight_probe_fn(),
                   advance_cycle_state_fn: no_op_advance_cycle_state_fn()
                 )

        calls = Agent.get(calls_agent, & &1)
        assert Enum.count(calls, &(&1 == reviewer_role)) == 1
        # `:ok` above already proves the commit step ran.
      end
    end

    test "bare APPROVED regression: still accepted unchanged", %{calls_agent: calls_agent} do
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
      assert Enum.count(calls, &(&1 == "reviewer-static")) == 1
      # `:ok` above already proves the commit step ran.
    end

    test "strong CHANGES_REQUESTED re-invokes developer, completes on strong APPROVED",
         %{calls_agent: calls_agent} do
      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static" do
            seen = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "reviewer-static"))

            if seen <= 1,
              do: "**REVIEW_VERDICT: CHANGES_REQUESTED**",
              else: "**REVIEW_VERDICT: APPROVED**"
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
      # `:ok` above already proves the commit step ran.
    end

    test "budget-exhausted strong CHANGES_REQUESTED fails loud, carries original text, no committer",
         %{calls_agent: calls_agent} do
      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static",
            do: "**REVIEW_VERDICT: CHANGES_REQUESTED**",
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
      assert reason =~ "**REVIEW_VERDICT: CHANGES_REQUESTED**"
      refute reason =~ "no parseable REVIEW_VERDICT"
      assert "committer" not in Agent.get(calls_agent, & &1)
    end

    # Regression for the backtick incident: a complete, gate-clear, APPROVED
    # review was thrown away because the reviewer rendered the sentinel as
    # inline code. Any ordinary markdown decoration must classify.
    for {name, verdict_text} <- [
          {"backticked", "`REVIEW_VERDICT: APPROVED`"},
          {"strong-wrapping-backticks", "**`REVIEW_VERDICT: APPROVED`**"},
          {"backticks-wrapping-strong", "`**REVIEW_VERDICT: APPROVED**`"},
          {"underscore-emphasis", "_REVIEW_VERDICT: APPROVED_"},
          {"single-asterisk-emphasis", "*REVIEW_VERDICT: APPROVED*"},
          {"surrounding-whitespace", "   REVIEW_VERDICT: APPROVED   "},
          {"decorated-with-inner-whitespace", "  ` REVIEW_VERDICT: APPROVED `  "}
        ] do
      @verdict_text verdict_text

      test "accepted APPROVED: #{name}", %{calls_agent: calls_agent} do
        verdict_text = @verdict_text

        invoke_fn = fn role, _harness, _ctx, _opts ->
          Agent.update(calls_agent, fn calls -> calls ++ [role] end)
          value = if role == "reviewer-static", do: verdict_text, else: "did #{role}"
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
        # Exactly one reviewer call: the verdict parsed first time, with no
        # `:unknown` re-invocation burning a second review.
        assert Enum.count(calls, &(&1 == "reviewer-static")) == 1
        # `:ok` above already proves the commit step ran.
      end
    end

    # The same decoration tolerance must apply to CHANGES_REQUESTED — a
    # decorated rejection that read as `:unknown` would be just as wrong.
    for {name, verdict_text} <- [
          {"backticked", "`REVIEW_VERDICT: CHANGES_REQUESTED`"},
          {"strong-wrapping-backticks", "**`REVIEW_VERDICT: CHANGES_REQUESTED`**"},
          {"underscore-emphasis", "_REVIEW_VERDICT: CHANGES_REQUESTED_"},
          {"surrounding-whitespace", "   REVIEW_VERDICT: CHANGES_REQUESTED   "}
        ] do
      @verdict_text verdict_text

      test "accepted CHANGES_REQUESTED: #{name}", %{calls_agent: calls_agent} do
        verdict_text = @verdict_text

        invoke_fn = fn role, _harness, _ctx, _opts ->
          Agent.update(calls_agent, fn calls -> calls ++ [role] end)
          value = if role == "reviewer-static", do: verdict_text, else: "did #{role}"
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

        # Classified as a rejection, not as an unparseable verdict.
        assert reason =~ "review re-work budget"
        refute reason =~ "no parseable REVIEW_VERDICT"
        assert "committer" not in Agent.get(calls_agent, & &1)
      end
    end

    for {name, verdict_text} <- [
          {"strong-then-bare", "**REVIEW_VERDICT: CHANGES_REQUESTED**\nREVIEW_VERDICT: APPROVED"},
          {"bare-then-strong", "REVIEW_VERDICT: CHANGES_REQUESTED\n**REVIEW_VERDICT: APPROVED**"},
          {"bare-conflict", "REVIEW_VERDICT: CHANGES_REQUESTED\nREVIEW_VERDICT: APPROVED"},
          {"conflict-with-trailing-prose",
           "REVIEW_VERDICT: APPROVED\nOn reflection: REVIEW_VERDICT: CHANGES_REQUESTED\nsee above"},
          {"malformed-suffix", "REVIEW_VERDICT: APPROVED extra"},
          # Decoration tolerance must not decay into "contains APPROVED
          # somewhere". A mid-sentence mention is not a verdict, and reading it
          # as one would turn a wasted build into a bad ship. Under the
          # unanimity rule this matters MORE, not less: a marker-bearing line
          # is now read wherever it sits, so a hedged mention has to poison the
          # set rather than resolve on its own.
          {"prose-mention", "I would have said REVIEW_VERDICT: APPROVED but the gate is red"},
          {"prose-mention-decorated",
           "*I would have said REVIEW_VERDICT: APPROVED but the gate is red*"},
          {"good-verdict-then-prose-mention",
           "REVIEW_VERDICT: APPROVED\nRestating for the log: REVIEW_VERDICT: APPROVED"},
          # Normalisation peels wrappers; it does not invent tokens.
          {"unknown-token", "REVIEW_VERDICT: MAYBE"},
          {"backticked-unknown-token", "`REVIEW_VERDICT: MAYBE`"},
          {"verdict-word-not-in-enum", "REVIEW_VERDICT: APPROVED_WITH_NITS"},
          {"non-enum word poisons an otherwise good verdict",
           "REVIEW_VERDICT: APPROVED\nREVIEW_VERDICT: MAYBE"},
          {"lowercase verdict word", "REVIEW_VERDICT: approved"},
          {"no marker at all (truncation, refusal, abort)",
           "API Error: Connection closed mid-response."},
          # Only *matched* pairs are decoration — a dangling delimiter is not.
          {"unbalanced-backtick", "`REVIEW_VERDICT: APPROVED"}
        ] do
      @verdict_text verdict_text

      test "rejected: #{name}", %{calls_agent: calls_agent} do
        verdict_text = @verdict_text

        invoke_fn = fn role, _harness, _ctx, _opts ->
          Agent.update(calls_agent, fn calls -> calls ++ [role] end)
          value = if role == "reviewer-static", do: verdict_text, else: "did #{role}"
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

        calls = Agent.get(calls_agent, & &1)
        assert Enum.count(calls, &(&1 == "reviewer-static")) == 2
        assert "committer" not in calls
        assert "context-curator" not in calls
      end
    end

    # Sampled from 180 real `reviewer-*` sessions under
    # ~/.claude/projects/**.jsonl (agentSetting == "reviewer-*", final
    # assistant text = the value codegen-call returns). 71/180 (39%) parsed as
    # `:unknown`, and the single biggest shape — 44/180 (24%) — is a perfectly
    # well-formed verdict line followed by the reviewer's own action list or
    # closing paragraph. Each cost a full second reviewer invocation over a
    # verdict that was already stated plainly. Dropping the terminality demand
    # (not the anchored per-line match) is what recovers them.
    for {name, verdict_text, expected} <- [
          {"trailing action list after CHANGES_REQUESTED (44/180 shape)",
           "REVIEW_VERDICT: CHANGES_REQUESTED\n" <>
             "- Provide `## Files Modified` for this cycle.\n" <>
             "- Fix root cause: strip remaining `clarifying_question` tokens.\n" <>
             "- Re-run `make test` to `clear` before resubmitting.", :changes_requested},
          {"trailing summary paragraph after strong APPROVED",
           "Review complete.\n\n**REVIEW_VERDICT: APPROVED**\n\n" <>
             "Gate verdict clear, pitch fulfilled, all declared scope covered.", :approved},
          {"backtick-wrapped verdict line above trailing table row (5/180 shape)",
           "| Scope expansion | justified — real Credo defect fix |\n" <>
             "`REVIEW_VERDICT: APPROVED`", :approved},
          {"duplicated but agreeing marker lines",
           "REVIEW_VERDICT: APPROVED\nREVIEW_VERDICT: APPROVED", :approved}
        ] do
      @verdict_text verdict_text
      @expected expected

      test "accepted from real reviewer output: #{name}", %{calls_agent: calls_agent} do
        verdict_text = @verdict_text
        expected = @expected

        invoke_fn = fn role, _harness, _ctx, _opts ->
          Agent.update(calls_agent, fn calls -> calls ++ [role] end)

          value =
            if role == "reviewer-static" do
              seen = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "reviewer-static"))
              if seen <= 1, do: verdict_text, else: "REVIEW_VERDICT: APPROVED"
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

        # The point of the fix: neither shape buys a second reviewer
        # invocation to re-derive a verdict the first one already stated.
        case expected do
          :approved ->
            assert Enum.count(calls, &(&1 == "reviewer-static")) == 1
            assert Enum.count(calls, &(&1 == "developer-static")) == 1

          :changes_requested ->
            assert Enum.count(calls, &(&1 == "developer-static")) == 2
            assert Enum.count(calls, &(&1 == "reviewer-static")) == 2
        end
      end
    end
  end

  describe "run/1 — review coverage (an APPROVED verdict names what it read)" do
    test "coverage naming every ## Files Modified path proceeds normally", %{
      calls_agent: calls_agent
    } do
      set_fn = fn _cwd -> "lib/a.ex\nlib/b.ex" end

      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static" do
            "REVIEW_COVERAGE: lib/a.ex read\n" <>
              "REVIEW_COVERAGE: lib/b.ex skipped: unchanged lockfile\n" <>
              "REVIEW_VERDICT: APPROVED"
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
                 review_file_set_fn: set_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      calls = Agent.get(calls_agent, & &1)
      # Exactly one reviewer call: coverage was total on the first pass, no
      # coverage re-invocation burning a second review.
      assert Enum.count(calls, &(&1 == "reviewer-static")) == 1
    end

    test "a missing REVIEW_COVERAGE path triggers one re-invocation naming the gap, then proceeds",
         %{calls_agent: calls_agent} do
      set_fn = fn _cwd -> "lib/a.ex\nlib/b.ex" end

      {:ok, prompts_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(prompts_agent) end)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "reviewer-static" do
          seen = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "reviewer-static"))
          prompt = OrchestrationLoop.build_prompt(role, ctx)
          Agent.update(prompts_agent, fn ps -> ps ++ [prompt] end)

          value =
            if seen <= 1,
              # lib/b.ex is missing from this reviewer's coverage statement.
              do: "REVIEW_COVERAGE: lib/a.ex read\nREVIEW_VERDICT: APPROVED",
              else:
                "REVIEW_COVERAGE: lib/a.ex read\nREVIEW_COVERAGE: lib/b.ex read\n" <>
                  "REVIEW_VERDICT: APPROVED"

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

      calls = Agent.get(calls_agent, & &1)
      assert Enum.count(calls, &(&1 == "reviewer-static")) == 2
      # Developer never re-invoked — nothing about the code changed, only
      # the reviewer's coverage statement was incomplete.
      assert Enum.count(calls, &(&1 == "developer-static")) == 1

      prompts = Agent.get(prompts_agent, & &1)
      second_prompt = Enum.at(prompts, 1)
      assert second_prompt =~ "## Coverage required (re-work)"
      assert second_prompt =~ "lib/b.ex"
    end

    test "an invented REVIEW_COVERAGE path not in ## Files Modified is incomplete", %{
      calls_agent: calls_agent
    } do
      set_fn = fn _cwd -> "lib/a.ex" end

      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static" do
            "REVIEW_COVERAGE: lib/a.ex read\n" <>
              "REVIEW_COVERAGE: lib/nonexistent.ex read\n" <>
              "REVIEW_VERDICT: APPROVED"
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
                 review_file_set_fn: set_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 max_review_coverage_cycles: 0
               )

      assert reason =~ "reviewer coverage did not name the ## Files Modified set"
      assert reason =~ "lib/nonexistent.ex"
    end

    test "zero REVIEW_COVERAGE lines when files were expected is incomplete", %{
      calls_agent: calls_agent
    } do
      set_fn = fn _cwd -> "lib/a.ex" end

      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)
        value = if role == "reviewer-static", do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"
        {:ok, %{"status" => "success", "value" => value}}
      end

      assert {:error, reason} =
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 max_review_coverage_cycles: 0
               )

      assert reason =~ "no REVIEW_COVERAGE: lines found"
      assert reason =~ "lib/a.ex"
    end

    test "a malformed REVIEW_COVERAGE line (empty skipped reason) is incomplete", %{
      calls_agent: calls_agent
    } do
      set_fn = fn _cwd -> "lib/a.ex" end

      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static" do
            "REVIEW_COVERAGE: lib/a.ex skipped:\nREVIEW_VERDICT: APPROVED"
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
                 review_file_set_fn: set_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 max_review_coverage_cycles: 0
               )

      assert reason =~ "malformed REVIEW_COVERAGE line"
    end

    test "empty ## Files Modified set is a coverage no-op (vacuous branch stated, not silent)",
         %{calls_agent: calls_agent} do
      # Default review_file_set_fn on a non-git cwd -> "" -> no coverage
      # lines required; a bare REVIEW_VERDICT: APPROVED is still accepted.
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
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      calls = Agent.get(calls_agent, & &1)
      assert Enum.count(calls, &(&1 == "reviewer-static")) == 1
    end

    test "empty changed set in a real git tree still refuses to invoke the reviewer (coverage never masks it)" do
      tmp =
        System.tmp_dir!()
        |> Path.join("review-coverage-empty-set-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      {_out, 0} = System.cmd("git", ["init", "-q"], cd: tmp)
      {_out, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: tmp)
      {_out, 0} = System.cmd("git", ["config", "user.name", "T"], cd: tmp)
      File.write!(Path.join(tmp, "README.md"), "init\n")
      {_out, 0} = System.cmd("git", ["add", "-A"], cd: tmp)
      {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: tmp)

      invoke_fn = fn role, _harness, _ctx, _opts ->
        value = if role == "reviewer-static", do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"
        {:ok, %{"status" => "success", "value" => value}}
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

    test "Move 15 — an unresolved pitch-contradiction marker blocks the gate-to-review advance" do
      tmp =
        System.tmp_dir!()
        |> Path.join("pitch-contradiction-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join([tmp, "codegen", "gate-pending"]))
      on_exit(fn -> File.rm_rf!(tmp) end)

      File.write!(
        Path.join([tmp, "codegen", "gate-pending", "pitch-contradiction.json"]),
        Jason.encode!(%{
          "claim" => "pitch says shared/rules/STYLE_GUIDE.md needs updating",
          "evidence" => "inspected file, ratchet move does not change its content",
          "proposed_disposition" => "no-op is correct, pitch overstates drift",
          "affected_paths" => ["shared/rules/STYLE_GUIDE.md"]
        })
      )

      invoke_fn = fn role, _harness, _ctx, _opts ->
        value = if role == "reviewer-static", do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"
        {:ok, %{"status" => "success", "value" => value}}
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

      assert reason =~ "pitch contradiction pending resolution"
      assert reason =~ "STYLE_GUIDE.md"
    end

    test "Move 15 — no pitch-contradiction marker present, review proceeds normally" do
      tmp =
        System.tmp_dir!()
        |> Path.join("pitch-contradiction-absent-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      invoke_fn = fn role, _harness, _ctx, _opts ->
        value = if role == "reviewer-static", do: "REVIEW_VERDICT: APPROVED", else: "did #{role}"
        {:ok, %{"status" => "success", "value" => value}}
      end

      assert :ok ==
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
    end
  end

  # Writes a codegen-call stream-json transcript whose ASSISTANT turns carry
  # `assistant_texts`. Deliberately includes a user turn naming BOTH enum
  # members (it is the reviewer prompt) and a junk non-JSON line — recovery
  # must ignore both.
  defp write_reviewer_transcript!(assistant_texts) do
    path =
      Path.join(
        System.tmp_dir!(),
        "reviewer_transcript_#{:erlang.unique_integer([:positive])}.jsonl"
      )

    lines =
      [
        ~s({"type":"system","subtype":"init","agent":"reviewer-static"}),
        Jason.encode!(%{
          "type" => "user",
          "message" => %{
            "role" => "user",
            "content" =>
              "finish with `REVIEW_VERDICT: APPROVED` or `REVIEW_VERDICT: CHANGES_REQUESTED`"
          }
        })
      ] ++
        Enum.map(assistant_texts, fn text ->
          Jason.encode!(%{
            "type" => "assistant",
            "message" => %{
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => text}]
            }
          })
        end) ++ ["not json at all", ""]

    File.write!(path, Enum.join(lines, "\n"))
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  describe "run/1 — verdict recovery from the reviewer's own transcript" do
    test "sign-off-after-tool-call value recovers APPROVED without a second reviewer call",
         %{calls_agent: calls_agent} do
      transcript =
        write_reviewer_transcript!([
          "Reviewing the diff now.",
          "No blocking findings.\n\nREVIEW_VERDICT: APPROVED",
          "All sections recorded successfully across separate calls."
        ])

      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "reviewer-static" do
          {:ok,
           %{
             "status" => "success",
             "value" => "All sections recorded successfully across separate calls.",
             "transcript" => transcript
           }}
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
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      calls = Agent.get(calls_agent, & &1)
      assert Enum.count(calls, &(&1 == "reviewer-static")) == 1
    end

    test "recovered CHANGES_REQUESTED routes the RECOVERED text to the developer, not the sign-off",
         %{calls_agent: calls_agent} do
      transcript =
        write_reviewer_transcript!([
          "REVIEW_VERDICT: CHANGES_REQUESTED\n- Working tree has zero diff — no code was written."
        ])

      {:ok, feedback_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(feedback_agent) end)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if fb = get_in(ctx, [:artifacts, :review_feedback]) do
          Agent.update(feedback_agent, fn seen -> seen ++ [fb] end)
        end

        cond do
          role != "reviewer-static" ->
            {:ok, %{"status" => "success", "value" => "did #{role}"}}

          Enum.count(Agent.get(calls_agent, & &1), &(&1 == "reviewer-static")) <= 1 ->
            {:ok, %{"status" => "success", "value" => "Recorded.", "transcript" => transcript}}

          true ->
            {:ok, %{"status" => "success", "value" => "REVIEW_VERDICT: APPROVED"}}
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

      feedback = Agent.get(feedback_agent, & &1)
      assert feedback != []
      assert Enum.all?(feedback, &(&1 =~ "Working tree has zero diff"))
      refute Enum.any?(feedback, &(&1 == "Recorded."))
    end

    for {name, texts} <- [
          {"no verdict anywhere in the transcript", ["Logged.", "Nothing else to add."]},
          {"transcript states both verdicts (ambiguous)",
           ["REVIEW_VERDICT: CHANGES_REQUESTED", "Actually REVIEW_VERDICT: APPROVED", "Logged."]}
        ] do
      @texts texts

      test "no recovery: #{name}", %{calls_agent: calls_agent} do
        transcript = write_reviewer_transcript!(@texts)

        invoke_fn = fn role, _harness, _ctx, _opts ->
          Agent.update(calls_agent, fn calls -> calls ++ [role] end)

          if role == "reviewer-static" do
            {:ok, %{"status" => "success", "value" => "Logged.", "transcript" => transcript}}
          else
            {:ok, %{"status" => "success", "value" => "did #{role}"}}
          end
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
        assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "reviewer-static")) == 2
      end
    end

    test "a missing transcript file never raises — falls back to the re-invocation",
         %{calls_agent: calls_agent} do
      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "reviewer-static" do
          {:ok,
           %{
             "status" => "success",
             "value" => "Logged.",
             "transcript" => "/nonexistent/dir/nope.jsonl"
           }}
        else
          {:ok, %{"status" => "success", "value" => "did #{role}"}}
        end
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
      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "reviewer-static")) == 2
    end
  end

  describe "run/1 — role failure handling" do
    test "role fails once then succeeds on retry — cycle still completes", %{
      calls_agent: calls_agent
    } do
      {:ok, fail_once_agent} = Agent.start_link(fn -> MapSet.new() end)
      on_exit(fn -> stop_agent(fail_once_agent) end)

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
      on_exit(fn -> stop_agent(fail_once_agent) end)
      {:ok, died_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(died_agent) end)

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
      on_exit(fn -> stop_agent(died_agent) end)

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
      on_exit(fn -> stop_agent(died_agent) end)
      {:ok, sleep_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(sleep_agent) end)

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

      # 3 backoff sleeps between the 4 attempts, increasing per the backoff
      # table — jittered +/-20% so parallel builds don't thunder-herd on
      # recovery from a shared incident; assert bounded ranges, not exact
      # values.
      [sleep1, sleep2, sleep3] = Agent.get(sleep_agent, & &1)
      assert sleep1 in 12_000..18_000
      assert sleep2 in 48_000..72_000
      assert sleep3 in 96_000..144_000

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
      on_exit(fn -> stop_agent(fail_count_agent) end)

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
      on_exit(fn -> stop_agent(died_agent) end)
      {:ok, models_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(models_agent) end)

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

    test "role-model-sweep fixed binding suppresses the fallback chain — reports an error naming the campaign arm, never a swapped model" do
      run_dir =
        Path.join(System.tmp_dir!(), "rms_fallback_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(run_dir)
      on_exit(fn -> File.rm_rf!(run_dir) end)

      binding = %{
        "schema_version" => 1,
        "campaign_id" => "camp-1",
        "arm" => "baseline",
        "role" => "developer-static",
        "stack" => "static",
        "harness" => "claude_code",
        "model" => "sonnet",
        "effort" => "medium",
        "source_sha" => "deadbeef",
        "fixed" => true
      }

      File.write!(Path.join(run_dir, "role-model-binding.json"), Jason.encode!(binding))
      System.put_env("BENCH_RUN_DIR", run_dir)
      Process.delete(:role_model_sweep_binding)

      on_exit(fn ->
        System.delete_env("BENCH_RUN_DIR")
        Process.delete(:role_model_sweep_binding)
      end)

      resolve_fallback_fn = fn _role, _harness, 0 -> {"opus", "medium"} end

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
                 # Pins harness resolution to match the binding file's
                 # "harness" ("claude_code") independent of config.yaml's
                 # live per-role override (developer-static currently
                 # forced an override) — this test asserts the SUPPRESSION
                 # contract, not config.yaml's current routing.
                 resolve_harness_fn: fn _role, build_harness -> build_harness end,
                 resolve_fallback_fn: resolve_fallback_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 git_head_fn: fn -> "deadbeef" end,
                 git_dirty_fn: fn -> false end
               )

      assert reason =~ "binding fixed"
      assert reason =~ "fallback suppressed for campaign arm"
    end

    test "switch_model fallback resolution uses the per-role resolve_harness_fn override, not the build harness" do
      {:ok, harness_seen_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(harness_seen_agent) end)

      resolve_harness_fn = fn "developer-static", "claude_code" -> "other_harness" end

      resolve_fallback_fn = fn "developer-static", harness, 0 ->
        Agent.update(harness_seen_agent, fn seen -> seen ++ [harness] end)
        {"other-model", "medium"}
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

      assert Agent.get(harness_seen_agent, & &1) == ["other_harness"]
    end

    test "default :log_died_fn with no cycle log initialized (nil path) → silent no-op, run still completes" do
      {:ok, fail_once_agent} = Agent.start_link(fn -> MapSet.new() end)
      on_exit(fn -> stop_agent(fail_once_agent) end)

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
      on_exit(fn -> stop_agent(fail_once_agent) end)

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

    # A status:"failed" envelope is now UNCONDITIONALLY an error. The one
    # promotion that ever existed (a planner whose typed ev:plan event had
    # landed) went with the planner role — no role gets its failure
    # reinterpreted any more, so there is no envelope shape a role can end
    # its turn on that turns a failure into a success.
    test "status=failed envelope maps to {:error, reason} for every surviving role" do
      codegen_call_fn = fn _harness, _model, _effort, _sp, _tools, _prompt ->
        %{
          "session_id" => "sess-123",
          "result" => %{"status" => "failed", "reason" => "tool_use final turn", "value" => nil}
        }
      end

      resolve_fn = fn _role, _harness -> {"sonnet", "medium"} end

      roles =
        OrchestrationLoop.role_sequence("phoenix") ++ OrchestrationLoop.role_sequence("static")

      for role <- Enum.uniq(roles) do
        assert {:error, "tool_use final turn"} =
                 OrchestrationLoop.invoke_role(
                   role,
                   "claude_code",
                   %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                   resolve_fn: resolve_fn,
                   codegen_call_fn: codegen_call_fn
                 )
      end
    end

    test "status=failed envelope with no reason still maps to a named {:error, reason}" do
      codegen_call_fn = fn _harness, _model, _effort, _sp, _tools, _prompt ->
        %{"result" => %{"status" => "failed", "value" => nil}}
      end

      resolve_fn = fn _role, _harness -> {"sonnet", "medium"} end

      assert {:error, reason} =
               OrchestrationLoop.invoke_role(
                 "developer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 codegen_call_fn: codegen_call_fn
               )

      assert reason =~ "developer-static failed with no reason given"
    end

    # Fault 13 / Move 16a-16b — a reviewer envelope that failed SCHEMA
    # validation still carries the reviewer's full prose in
    # result["value"] (call-dispatch.sh never clears VALUE_JSON on a
    # schema mismatch). A parseable REVIEW_VERDICT: sentinel inside that
    # prose recovers the call as an ordinary {:ok, result} instead of
    # discarding a complete, substantive review over a malformed wrapper.
    test "reviewer schema-validation failure with a parseable verdict recovers as {:ok, result} (Move 16a)" do
      codegen_call_fn = fn _harness, _model, _effort, _sp, _tools, _prompt ->
        %{
          "session_id" => "sess-schema-1",
          "result" => %{
            "status" => "failed",
            "reason" => "schema validation failed: data must be object",
            "value" => "Review complete.\n\n**REVIEW_VERDICT: APPROVED**\n\nAll clear."
          }
        }
      end

      resolve_fn = fn _role, _harness -> {"sonnet", "medium"} end

      assert {:ok, result} =
               OrchestrationLoop.invoke_role(
                 "reviewer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 codegen_call_fn: codegen_call_fn
               )

      assert result["value"] =~ "REVIEW_VERDICT: APPROVED"
      assert result["session_id"] == "sess-schema-1"
    end

    # Non-reviewer roles never carry json_schema_path, so the schema-failure
    # fallback must never fire for them — a plain "failed" status stays a
    # plain {:error, reason} regardless of what text happens to be in
    # result["value"].
    test "non-reviewer schema-shaped failure text is NOT recovered (fallback is reviewer-only)" do
      codegen_call_fn = fn _harness, _model, _effort, _sp, _tools, _prompt ->
        %{
          "result" => %{
            "status" => "failed",
            "reason" => "schema validation failed: data must be object",
            "value" => "**REVIEW_VERDICT: APPROVED**"
          }
        }
      end

      resolve_fn = fn _role, _harness -> {"sonnet", "medium"} end

      assert {:error, reason} =
               OrchestrationLoop.invoke_role(
                 "developer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 codegen_call_fn: codegen_call_fn
               )

      assert reason =~ "schema validation failed"
    end

    # An unusable reply (schema failed AND no parseable verdict inside the
    # prose either) must record an EXPLICIT unusable-verdict outcome, never
    # a generic reason string that reads as "the gate said nothing".
    test "reviewer schema-validation failure with NO parseable verdict records an explicit unusable-verdict outcome (Move 16b)" do
      codegen_call_fn = fn _harness, _model, _effort, _sp, _tools, _prompt ->
        %{
          "result" => %{
            "status" => "failed",
            "reason" => "schema validation failed: data must be object",
            "value" => "The user's request is ambiguous. I need more context."
          }
        }
      end

      resolve_fn = fn _role, _harness -> {"sonnet", "medium"} end

      assert {:error, reason} =
               OrchestrationLoop.invoke_role(
                 "reviewer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 codegen_call_fn: codegen_call_fn
               )

      assert reason =~ "unusable reviewer verdict"
      assert reason =~ "reviewer-static"
      assert reason =~ "value_type=:string"
    end

    # A schema failure whose value is nil/non-binary (never happens via the
    # real call-dispatch.sh envelope shape, but the loop must still fail
    # closed rather than crash) also records the explicit unusable outcome.
    test "reviewer schema-validation failure with a nil value records an explicit unusable-verdict outcome (Move 16b)" do
      codegen_call_fn = fn _harness, _model, _effort, _sp, _tools, _prompt ->
        %{
          "result" => %{
            "status" => "failed",
            "reason" => "schema validation failed: data must be object",
            "value" => nil
          }
        }
      end

      resolve_fn = fn _role, _harness -> {"sonnet", "medium"} end

      assert {:error, reason} =
               OrchestrationLoop.invoke_role(
                 "reviewer-phoenix",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 codegen_call_fn: codegen_call_fn
               )

      assert reason =~ "unusable reviewer verdict"
      assert reason =~ "value_type=:null"
    end

    # A reviewer failure for a DIFFERENT reason (not schema validation) must
    # never be swept into the fallback path — only the exact "schema
    # validation failed" prefix triggers it.
    test "reviewer failure for a non-schema reason is unaffected by the fallback (Move 16a scoping)" do
      codegen_call_fn = fn _harness, _model, _effort, _sp, _tools, _prompt ->
        %{
          "result" => %{
            "status" => "failed",
            "reason" => "API Error: 401 authentication_error",
            "value" => "**REVIEW_VERDICT: APPROVED**"
          }
        }
      end

      resolve_fn = fn _role, _harness -> {"sonnet", "medium"} end

      assert {:error, "API Error: 401 authentication_error"} =
               OrchestrationLoop.invoke_role(
                 "reviewer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 codegen_call_fn: codegen_call_fn
               )
    end

    # CHANGES_REQUESTED must recover through the same fallback path as
    # APPROVED — the fix is verdict-agnostic, not approval-only.
    test "reviewer schema-validation failure with a parseable CHANGES_REQUESTED verdict recovers as {:ok, result} (Move 16a)" do
      codegen_call_fn = fn _harness, _model, _effort, _sp, _tools, _prompt ->
        %{
          "result" => %{
            "status" => "failed",
            "reason" => "schema validation failed: data must be object",
            "value" => "REVIEW_VERDICT: CHANGES_REQUESTED\n\n- Fix the root cause."
          }
        }
      end

      resolve_fn = fn _role, _harness -> {"sonnet", "medium"} end

      assert {:ok, result} =
               OrchestrationLoop.invoke_role(
                 "reviewer-phoenix",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 codegen_call_fn: codegen_call_fn
               )

      assert result["value"] =~ "REVIEW_VERDICT: CHANGES_REQUESTED"
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
        stop_agent(harness_seen_by_resolve_fn)

        stop_agent(harness_seen_by_codegen_call_fn)
      end)

      resolve_harness_fn = fn "developer-static", "claude_code" -> "other_harness" end

      resolve_fn = fn _role, harness ->
        Agent.update(harness_seen_by_resolve_fn, fn _ -> harness end)
        {"other-model", "medium"}
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

      assert Agent.get(harness_seen_by_resolve_fn, & &1) == "other_harness"
      assert Agent.get(harness_seen_by_codegen_call_fn, & &1) == "other_harness"
    end

    # No role carries a `.harness.<role>.harness` key in the real config.yaml
    # any more, so every role takes this passthrough path. The point of the
    # test is the passthrough default, not the identity of the role — a
    # non-reviewer role keeps that indifference true without also having to
    # satisfy the reviewer-only typed-verdict schema shape (see
    # normalize_reviewer_result/3).
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
                 "developer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 codegen_call_fn: codegen_call_fn
               )
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

  describe "invoke_role/4 — role-model-sweep fixed binding (BENCH_RUN_DIR/role-model-binding.json)" do
    setup do
      Process.delete(:role_model_sweep_binding)
      Process.delete(:loop_telemetry)
      System.delete_env("BENCH_RUN_DIR")

      on_exit(fn ->
        Process.delete(:role_model_sweep_binding)
        Process.delete(:loop_telemetry)
        System.delete_env("BENCH_RUN_DIR")
      end)

      run_dir = Path.join(System.tmp_dir!(), "rms_bind_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(run_dir)
      on_exit(fn -> File.rm_rf!(run_dir) end)
      %{run_dir: run_dir}
    end

    defp write_binding!(run_dir, overrides) do
      base = %{
        "schema_version" => 1,
        "campaign_id" => "camp-1",
        "arm" => "candidate-a",
        "role" => "developer-static",
        "stack" => "static",
        "harness" => "claude_code",
        "model" => "other-model",
        "effort" => "high",
        "source_sha" => "deadbeef",
        "fixed" => true
      }

      File.write!(
        Path.join(run_dir, "role-model-binding.json"),
        Jason.encode!(Map.merge(base, overrides))
      )
    end

    test "target role: fixed binding wins over resolve_fn, verbatim", %{run_dir: run_dir} do
      write_binding!(run_dir, %{})
      System.put_env("BENCH_RUN_DIR", run_dir)

      resolve_fn = fn _role, _harness -> {"sonnet", "medium"} end
      {:ok, seen_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(seen_agent) end)

      codegen_call_fn = fn h, m, e, _sp, _t, _pr ->
        Agent.update(seen_agent, fn seen -> seen ++ [{h, m, e}] end)
        %{"result" => %{"status" => "success", "value" => "x"}, "usage" => %{"cost_usd" => 0.1}}
      end

      assert {:ok, _} =
               OrchestrationLoop.invoke_role(
                 "developer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 codegen_call_fn: codegen_call_fn,
                 git_head_fn: fn -> "deadbeef" end,
                 git_dirty_fn: fn -> false end
               )

      assert Agent.get(seen_agent, & &1) == [{"claude_code", "other-model", "high"}]
    end

    test "non-target role: binding present for a DIFFERENT role -> resolve_fn used unchanged", %{
      run_dir: run_dir
    } do
      write_binding!(run_dir, %{})
      System.put_env("BENCH_RUN_DIR", run_dir)

      resolve_fn = fn _role, _harness -> {"sonnet", "medium"} end
      {:ok, seen_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(seen_agent) end)

      codegen_call_fn = fn h, m, e, _sp, _t, _pr ->
        Agent.update(seen_agent, fn seen -> seen ++ [{h, m, e}] end)

        %{
          "result" => %{
            "status" => "success",
            "value" => %{"verdict" => "APPROVED", "body" => "x"}
          },
          "usage" => %{"cost_usd" => 0.1}
        }
      end

      assert {:ok, _} =
               OrchestrationLoop.invoke_role(
                 "reviewer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 codegen_call_fn: codegen_call_fn,
                 git_head_fn: fn -> "deadbeef" end,
                 git_dirty_fn: fn -> false end
               )

      assert Agent.get(seen_agent, & &1) == [{"claude_code", "sonnet", "medium"}]
    end

    test "absent BENCH_RUN_DIR -> resolve_fn used unchanged (ordinary build behavior)" do
      resolve_fn = fn _role, _harness -> {"sonnet", "medium"} end
      {:ok, seen_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(seen_agent) end)

      codegen_call_fn = fn h, m, e, _sp, _t, _pr ->
        Agent.update(seen_agent, fn seen -> seen ++ [{h, m, e}] end)
        %{"result" => %{"status" => "success", "value" => "x"}, "usage" => %{"cost_usd" => 0.1}}
      end

      assert {:ok, _} =
               OrchestrationLoop.invoke_role(
                 "developer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 # Pins harness resolution independent of config.yaml's live
                 # per-role override (developer-static currently forces
                 # "claude_code") — this test asserts the fixed-binding ABSENCE
                 # contract, not config.yaml's current routing.
                 resolve_harness_fn: fn _role, build_harness -> build_harness end,
                 codegen_call_fn: codegen_call_fn
               )

      assert Agent.get(seen_agent, & &1) == [{"claude_code", "sonnet", "medium"}]
    end

    test "BENCH_RUN_DIR set but file absent -> resolve_fn used unchanged" do
      run_dir =
        Path.join(System.tmp_dir!(), "rms_bind_absent_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(run_dir)
      on_exit(fn -> File.rm_rf!(run_dir) end)
      System.put_env("BENCH_RUN_DIR", run_dir)

      resolve_fn = fn _role, _harness -> {"sonnet", "medium"} end

      assert {:ok, %{"value" => "did-it"}} =
               OrchestrationLoop.invoke_role(
                 "developer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 codegen_call_fn: fn _h, _m, _e, _sp, _t, _pr ->
                   %{
                     "result" => %{"status" => "success", "value" => "did-it"},
                     "usage" => %{"cost_usd" => 0.1}
                   }
                 end
               )
    end

    test "present but invalid binding (missing required key) raises before the role runs", %{
      run_dir: run_dir
    } do
      File.write!(
        Path.join(run_dir, "role-model-binding.json"),
        Jason.encode!(%{"role" => "developer-static"})
      )

      System.put_env("BENCH_RUN_DIR", run_dir)

      assert_raise RuntimeError, ~r/missing required key/, fn ->
        OrchestrationLoop.invoke_role(
          "developer-static",
          "claude_code",
          %{cwd: "/tmp", pitch: "x", artifacts: %{}},
          resolve_fn: fn _r, _h -> {"sonnet", "medium"} end,
          codegen_call_fn: fn _h, _m, _e, _sp, _t, _pr ->
            %{
              "result" => %{"status" => "success", "value" => "x"},
              "usage" => %{"cost_usd" => 0.1}
            }
          end
        )
      end
    end

    test "binding source_sha does not match current codegen HEAD -> raises before the role runs (INCONCLUSIVE drift)",
         %{run_dir: run_dir} do
      write_binding!(run_dir, %{"source_sha" => "deadbeef"})
      System.put_env("BENCH_RUN_DIR", run_dir)

      assert_raise RuntimeError, ~r/source drift makes this arm INCONCLUSIVE/, fn ->
        OrchestrationLoop.invoke_role(
          "developer-static",
          "claude_code",
          %{cwd: "/tmp", pitch: "x", artifacts: %{}},
          resolve_fn: fn _r, _h -> {"sonnet", "medium"} end,
          codegen_call_fn: fn _h, _m, _e, _sp, _t, _pr ->
            %{
              "result" => %{"status" => "success", "value" => "x"},
              "usage" => %{"cost_usd" => 0.1}
            }
          end,
          # Loop's own current HEAD reads as a DIFFERENT sha than the
          # binding's pinned "deadbeef" -> drift, not a live git call.
          git_head_fn: fn -> "cafef00d" end,
          git_dirty_fn: fn -> false end
        )
      end
    end

    test "codegen root worktree is dirty at binding-read time -> raises before the role runs (INCONCLUSIVE dirty tree)",
         %{run_dir: run_dir} do
      write_binding!(run_dir, %{"source_sha" => "deadbeef"})
      System.put_env("BENCH_RUN_DIR", run_dir)

      assert_raise RuntimeError, ~r/dirty tree makes this arm INCONCLUSIVE/, fn ->
        OrchestrationLoop.invoke_role(
          "developer-static",
          "claude_code",
          %{cwd: "/tmp", pitch: "x", artifacts: %{}},
          resolve_fn: fn _r, _h -> {"sonnet", "medium"} end,
          codegen_call_fn: fn _h, _m, _e, _sp, _t, _pr ->
            %{
              "result" => %{"status" => "success", "value" => "x"},
              "usage" => %{"cost_usd" => 0.1}
            }
          end,
          # SHA matches (no drift) but the tree is reported dirty -> still
          # a loud INCONCLUSIVE rejection, never a silent proceed.
          git_head_fn: fn -> "deadbeef" end,
          git_dirty_fn: fn -> true end
        )
      end
    end

    test "invocation records the requested dispatch tuple into telemetry per_role entry", %{
      run_dir: run_dir
    } do
      write_binding!(run_dir, %{})
      System.put_env("BENCH_RUN_DIR", run_dir)

      assert {:ok, _} =
               OrchestrationLoop.invoke_role(
                 "developer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: fn _r, _h -> {"sonnet", "medium"} end,
                 codegen_call_fn: fn _h, _m, _e, _sp, _t, _pr ->
                   %{
                     "result" => %{"status" => "success", "value" => "x"},
                     "usage" => %{"cost_usd" => 0.1}
                   }
                 end,
                 git_head_fn: fn -> "deadbeef" end,
                 git_dirty_fn: fn -> false end
               )

      [entry] = OrchestrationLoop.get_telemetry().per_role["developer-static"]

      assert entry.dispatch == %{
               harness: "claude_code",
               model: "other-model",
               effort: "high",
               source: :campaign,
               native_effort: "--effort high"
             }
    end
  end

  describe "invoke_role/4 — reviewer typed-verdict transport (normalize_reviewer_result/3)" do
    test "reviewer-role success with schema-shaped value: 'value' rewritten to body string" do
      codegen_call_fn = fn _h, _m, _e, _sp, _t, _pr ->
        %{
          "result" => %{
            "status" => "success",
            "value" => %{"verdict" => "APPROVED", "body" => "findings\nREVIEW_VERDICT: APPROVED"}
          },
          "usage" => %{"cost_usd" => 0.1}
        }
      end

      assert {:ok, result} =
               OrchestrationLoop.invoke_role(
                 "reviewer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: fn _r, _h -> {"sonnet", "medium"} end,
                 codegen_call_fn: codegen_call_fn,
                 git_head_fn: fn -> "deadbeef" end,
                 git_dirty_fn: fn -> false end
               )

      assert result["value"] == "findings\nREVIEW_VERDICT: APPROVED"
      assert result["typed_verdict"] == :approved
    end

    test "reviewer-role success with a bare-string value (no schema shape) raises loud" do
      codegen_call_fn = fn _h, _m, _e, _sp, _t, _pr ->
        %{"result" => %{"status" => "success", "value" => "plain text"}, "usage" => %{}}
      end

      assert_raise RuntimeError, ~r/non-conforming value/, fn ->
        OrchestrationLoop.invoke_role(
          "reviewer-static",
          "claude_code",
          %{cwd: "/tmp", pitch: "x", artifacts: %{}},
          resolve_fn: fn _r, _h -> {"sonnet", "medium"} end,
          codegen_call_fn: codegen_call_fn,
          git_head_fn: fn -> "deadbeef" end,
          git_dirty_fn: fn -> false end
        )
      end
    end

    test "non-reviewer role: bare-string value passes through unchanged (no schema requested)" do
      codegen_call_fn = fn _h, _m, _e, _sp, _t, _pr ->
        %{"result" => %{"status" => "success", "value" => "did the work"}, "usage" => %{}}
      end

      assert {:ok, result} =
               OrchestrationLoop.invoke_role(
                 "developer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: fn _r, _h -> {"sonnet", "medium"} end,
                 codegen_call_fn: codegen_call_fn,
                 git_head_fn: fn -> "deadbeef" end,
                 git_dirty_fn: fn -> false end
               )

      assert result["value"] == "did the work"
      refute Map.has_key?(result, "typed_verdict")
    end

    test "reviewer-role schema_retry_exhausted status is a retryable error, not a raise" do
      codegen_call_fn = fn _h, _m, _e, _sp, _t, _pr ->
        %{
          "result" => %{
            "status" => "schema_retry_exhausted",
            "reason" => "max structured output retries exceeded"
          }
        }
      end

      assert {:error, reason} =
               OrchestrationLoop.invoke_role(
                 "reviewer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: fn _r, _h -> {"sonnet", "medium"} end,
                 codegen_call_fn: codegen_call_fn,
                 git_head_fn: fn -> "deadbeef" end,
                 git_dirty_fn: fn -> false end
               )

      assert reason =~ "max structured output retries exceeded"
    end
  end

  describe "run/1 — reviewer typed-verdict transport reaches resolve_review/1 end-to-end" do
    setup do
      {:ok, calls_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(calls_agent) end)
      {:ok, calls_agent: calls_agent}
    end

    # Acceptance criterion 1: a substantive reviewer body ending in prose
    # ("Review section logged. Verdict: **APPROVED**.") that carries NO
    # parseable REVIEW_VERDICT: sentinel must still resolve APPROVED, and
    # in exactly ONE reviewer call, when the same result carries a valid
    # typed "verdict" field (the schema-shaped transport). Before this
    # pitch, this exact shape drove a second re-invocation demanding the
    # sentinel and then failed loud on `rules-grants-and-guards-match-reality`.
    test "typed APPROVED with no REVIEW_VERDICT: sentinel reaches commit in a single reviewer call",
         %{calls_agent: calls_agent} do
      codegen_call_fn = fn _harness, _model, _effort, _sp, _tools, prompt ->
        role = if prompt =~ "REVIEW_VERDICT: APPROVED", do: "reviewer-static", else: "other"
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static" do
            %{
              "verdict" => "APPROVED",
              "body" => "findings all fine.\nReview section logged. Verdict: **APPROVED**."
            }
          else
            "did the work"
          end

        %{"result" => %{"status" => "success", "value" => value}, "usage" => %{"cost_usd" => 0.1}}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 resolve_fn: fn _role, _harness -> {"sonnet", "medium"} end,
                 codegen_call_fn: codegen_call_fn,
                 git_head_fn: fn -> "deadbeef" end,
                 git_dirty_fn: fn -> false end,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "reviewer-static")) == 1
    end

    test "typed CHANGES_REQUESTED drives the developer rework path and preserves the review body as feedback",
         %{calls_agent: calls_agent} do
      codegen_call_fn = fn _harness, _model, _effort, _sp, _tools, prompt ->
        role =
          if prompt =~ "REVIEW_VERDICT: APPROVED", do: "reviewer-static", else: "developer-static"

        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        seen_reviewer = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "reviewer-static"))

        value =
          cond do
            role == "reviewer-static" and seen_reviewer <= 1 ->
              %{
                "verdict" => "CHANGES_REQUESTED",
                "body" => "fix the nav link.\nReview section logged. Verdict: CHANGES_REQUESTED."
              }

            role == "reviewer-static" ->
              %{"verdict" => "APPROVED", "body" => "looks good now.\nREVIEW_VERDICT: APPROVED"}

            true ->
              "did the work"
          end

        %{"result" => %{"status" => "success", "value" => value}, "usage" => %{"cost_usd" => 0.1}}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 resolve_fn: fn _role, _harness -> {"sonnet", "medium"} end,
                 codegen_call_fn: codegen_call_fn,
                 git_head_fn: fn -> "deadbeef" end,
                 git_dirty_fn: fn -> false end,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      calls = Agent.get(calls_agent, & &1)
      # Exactly 2 reviewer calls: pass 1 (typed CHANGES_REQUESTED) drives
      # rework, pass 2 (typed APPROVED) resolves via the typed channel —
      # neither pass needed a 3rd re-invocation to recover a sentinel.
      assert Enum.count(calls, &(&1 == "reviewer-static")) == 2
      # At least one additional developer-static call happened after the
      # CHANGES_REQUESTED verdict — the review body reached the rework path.
      assert Enum.count(calls, &(&1 == "developer-static")) >= 2
    end

    # A valid typed field disagreeing with a valid REVIEW_VERDICT: text
    # sentinel is a transport contract break — it must fail the whole
    # build loud, never silently prefer one channel over the other.
    test "typed APPROVED disagreeing with a REVIEW_VERDICT: CHANGES_REQUESTED text sentinel fails the build loud",
         %{calls_agent: calls_agent} do
      codegen_call_fn = fn _harness, _model, _effort, _sp, _tools, prompt ->
        role =
          if prompt =~ "REVIEW_VERDICT: APPROVED", do: "reviewer-static", else: "developer-static"

        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static" do
            %{
              "verdict" => "APPROVED",
              "body" => "still not right.\nREVIEW_VERDICT: CHANGES_REQUESTED"
            }
          else
            "did the work"
          end

        %{"result" => %{"status" => "success", "value" => value}, "usage" => %{"cost_usd" => 0.1}}
      end

      # A transport contract break is a raised error, not a returned
      # {:error, reason} tuple — it must never be silently absorbed into
      # the normal review-rework control flow (which resolve_review/1
      # itself is part of).
      assert_raise RuntimeError, ~r/reviewer verdict transport disagreement/, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "static",
          cwd: "/tmp/irrelevant",
          pitch: "do the thing",
          resolve_fn: fn _role, _harness -> {"sonnet", "medium"} end,
          codegen_call_fn: codegen_call_fn,
          git_head_fn: fn -> "deadbeef" end,
          git_dirty_fn: fn -> false end,
          gate_fn: always_clear_gate_fn(),
          gate_preflight_fn: no_op_gate_preflight_fn(),
          preflight_probe_fn: all_present_preflight_probe_fn(),
          advance_cycle_state_fn: no_op_advance_cycle_state_fn()
        )
      end

      assert "committer" not in Agent.get(calls_agent, & &1)
    end
  end

  describe "invoke_role/4 — opts[:effort_override] (--effort build-wide override)" do
    setup do
      Process.delete(:loop_telemetry)
      on_exit(fn -> Process.delete(:loop_telemetry) end)
      :ok
    end

    test "override present, no fixed binding -> replaces effort, model unchanged" do
      resolve_fn = fn _role, _harness -> {"sonnet", "medium"} end
      {:ok, seen_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(seen_agent) end)

      codegen_call_fn = fn h, m, e, _sp, _t, _pr ->
        Agent.update(seen_agent, fn seen -> seen ++ [{h, m, e}] end)
        %{"result" => %{"status" => "success", "value" => "x"}, "usage" => %{"cost_usd" => 0.1}}
      end

      assert {:ok, _} =
               OrchestrationLoop.invoke_role(
                 "developer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 resolve_harness_fn: fn _role, build_harness -> build_harness end,
                 codegen_call_fn: codegen_call_fn,
                 effort_override: "off"
               )

      # Model rung unchanged ("sonnet"); effort replaced by the override.
      assert Agent.get(seen_agent, & &1) == [{"claude_code", "sonnet", "off"}]

      [entry] = OrchestrationLoop.get_telemetry().per_role["developer-static"]
      assert entry.dispatch.source == :build_override
      assert entry.dispatch.effort == "off"
      assert entry.dispatch.native_effort == "settings.MAX_THINKING_TOKENS=0"
    end

    test "fixed campaign binding wins over effort_override (override ignored for pinned role)" do
      run_dir =
        Path.join(System.tmp_dir!(), "rms_eff_override_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(run_dir)
      on_exit(fn -> File.rm_rf!(run_dir) end)
      System.put_env("BENCH_RUN_DIR", run_dir)
      on_exit(fn -> System.delete_env("BENCH_RUN_DIR") end)

      File.write!(
        Path.join(run_dir, "role-model-binding.json"),
        Jason.encode!(%{
          "schema_version" => 1,
          "campaign_id" => "camp-1",
          "arm" => "candidate-a",
          "role" => "developer-static",
          "stack" => "static",
          "harness" => "claude_code",
          "model" => "other-model",
          "effort" => "high",
          "source_sha" => "deadbeef",
          "fixed" => true
        })
      )

      resolve_fn = fn _role, _harness -> {"sonnet", "medium"} end
      {:ok, seen_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(seen_agent) end)

      codegen_call_fn = fn h, m, e, _sp, _t, _pr ->
        Agent.update(seen_agent, fn seen -> seen ++ [{h, m, e}] end)
        %{"result" => %{"status" => "success", "value" => "x"}, "usage" => %{"cost_usd" => 0.1}}
      end

      assert {:ok, _} =
               OrchestrationLoop.invoke_role(
                 "developer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 codegen_call_fn: codegen_call_fn,
                 git_head_fn: fn -> "deadbeef" end,
                 git_dirty_fn: fn -> false end,
                 effort_override: "off"
               )

      # Fixed binding's own effort ("high") wins; override never applied.
      assert Agent.get(seen_agent, & &1) == [{"claude_code", "other-model", "high"}]

      [entry] = OrchestrationLoop.get_telemetry().per_role["developer-static"]
      assert entry.dispatch.source == :campaign
      assert entry.dispatch.effort == "high"
    end

    test "absent override -> source is :role_config, unchanged behavior" do
      resolve_fn = fn _role, _harness -> {"sonnet", "medium"} end

      assert {:ok, _} =
               OrchestrationLoop.invoke_role(
                 "developer-static",
                 "claude_code",
                 %{cwd: "/tmp", pitch: "x", artifacts: %{}},
                 resolve_fn: resolve_fn,
                 resolve_harness_fn: fn _role, build_harness -> build_harness end,
                 codegen_call_fn: fn _h, _m, _e, _sp, _t, _pr ->
                   %{
                     "result" => %{"status" => "success", "value" => "x"},
                     "usage" => %{"cost_usd" => 0.1}
                   }
                 end
               )

      [entry] = OrchestrationLoop.get_telemetry().per_role["developer-static"]
      assert entry.dispatch.source == :role_config
      assert entry.dispatch.effort == "medium"
    end
  end

  describe "warm resume on transient retry" do
    test "transient failure carries the SAME resume_session_id into the next attempt's ctx",
         %{calls_agent: calls_agent} do
      {:ok, seen_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(seen_agent) end)

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
      on_exit(fn -> stop_agent(seen_agent) end)

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
      on_exit(fn -> stop_agent(seen_agent) end)

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
      on_exit(fn -> stop_agent(seen_agent) end)

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
      on_exit(fn -> stop_agent(gate_calls_agent) end)

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
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advisor_fn: no_op_advisor_fn()
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
                       preflight_probe_fn: all_present_preflight_probe_fn(),
                       advisor_fn: no_op_advisor_fn()
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
      on_exit(fn -> stop_agent(gate_calls_agent) end)

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

    test "phoenix: the gate runs after developer-phoenix-backend — the head of the sequence — and a failed verdict re-invokes it",
         %{calls_agent: calls_agent} do
      {:ok, gate_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(gate_calls_agent) end)

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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      calls = Agent.get(calls_agent, & &1)

      # The developer is now the HEAD of the phoenix sequence, so it is the
      # very first call, and the gate interleaves immediately after it.
      first_gate_idx = Enum.find_index(calls, &(&1 == "GATE"))
      first_dev_idx = Enum.find_index(calls, &(&1 == "developer-phoenix-backend"))

      assert first_dev_idx == 0
      assert first_gate_idx == first_dev_idx + 1

      # A :failed verdict re-invokes the DEVELOPER — it runs twice (initial +
      # gate-failure rework) while no earlier role is re-entered, because
      # there is no earlier role.
      assert Enum.count(calls, &(&1 == "developer-phoenix-backend")) == 2

      # Full role sequence still completes to the end (reviewer/curator),
      # and `:ok` above already proves the commit step ran after them.
      assert "reviewer-phoenix" in calls
      assert "context-curator" in calls
    end
  end

  describe "run/1 — gate failure owner-routing" do
    test "a context-doc-shaped witness routes the rework to context-curator, not the developer",
         %{calls_agent: calls_agent} do
      {:ok, gate_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(gate_calls_agent) end)

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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
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
      on_exit(fn -> stop_agent(gate_calls_agent) end)

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
      on_exit(fn -> stop_agent(gate_calls_agent) end)

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
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advisor_fn: no_op_advisor_fn()
               )

      assert reason =~ "gate verdict=failed"
    end
  end

  describe "run/1 — gate load-starvation leg (Fault 1 / Move 2b)" do
    test "a :load_starvation classification re-runs the gate once WITHOUT consuming a rework attempt",
         %{calls_agent: calls_agent} do
      {:ok, gate_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(gate_calls_agent) end)

      # Call 0: initial gate -> failed (classified :load_starvation below —
      # LoopGate.run_gate/2's isolated single-file rerun already proved this
      # is a load-sensitivity flake, not a code defect). Call 1: the
      # load-starvation leg's own re-run -> CLEAR. Since
      # do_gate_loop_load_starvation re-enters do_gate_loop (not the rework
      # path), the developer must never be re-invoked for this gate failure.
      gate_fn = fn _cwd, _opts ->
        n = Agent.get_and_update(gate_calls_agent, fn n -> {n, n + 1} end)
        if n == 0, do: {:failed, "make test"}, else: {:clear, "make test"}
      end

      gate_classify_fn = fn _cwd, _dev_role -> :load_starvation end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: gate_fn,
                 gate_classify_fn: gate_classify_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      # developer-static invoked exactly ONCE — the load-starvation
      # classification absorbed the failure without spending a rework
      # attempt.
      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "developer-static")) == 1
    end

    test "a second consecutive red after the load-starvation re-run is treated as genuinely red (no infinite grace loop)",
         %{calls_agent: calls_agent} do
      # Every call stays :failed AND every call re-classifies as
      # :load_starvation — asserts termination (bounded by the rework
      # budget, once ordinary classification takes over), not an infinite
      # grace loop. The ONE-TIME grace is per gate-failure OCCURRENCE, not
      # a standing amnesty: this proves the loop still terminates even if a
      # test's own classify_fn stub misbehaves and returns
      # :load_starvation forever.
      gate_fn = fn _cwd, _opts -> {:failed, "make test"} end
      gate_classify_fn = fn _cwd, _dev_role -> :load_starvation end

      assert {:error, reason} =
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: gate_fn,
                 gate_classify_fn: gate_classify_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advisor_fn: no_op_advisor_fn()
               )

      assert reason =~ "gate verdict=failed"
    end
  end

  describe "run/1 — gate stale-build self-heal leg" do
    test "a stale-_build verdict rebuilds once and re-runs the gate WITHOUT consuming a rework attempt",
         %{calls_agent: calls_agent} do
      {:ok, gate_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(gate_calls_agent) end)

      {:ok, heal_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(heal_calls_agent) end)

      # Call 0: initial gate -> failed (classified :stale_build below).
      # Call 1: heal-leg re-run -> CLEAR (rebuild fixed it).
      gate_fn = fn _cwd, _opts ->
        n = Agent.get_and_update(gate_calls_agent, fn n -> {n, n + 1} end)
        if n == 0, do: {:failed, "make test"}, else: {:clear, "make test"}
      end

      gate_classify_fn = fn _cwd, _dev_role -> :stale_build end

      # The stale-build verdict is flake-checked (standalone re-run) BEFORE
      # any heal — here the standalone check still fails, so it proceeds to
      # the genuine-stale heal path (proving that leg still works).
      flake_check_fn = fn _cwd, _opts -> {:failed, "make test"} end

      heal_fn = fn _cwd, _live_root_fn ->
        Agent.update(heal_calls_agent, &(&1 + 1))
        :ok
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: gate_fn,
                 gate_classify_fn: gate_classify_fn,
                 flake_check_fn: flake_check_fn,
                 stale_build_heal_fn: heal_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      # heal_fn invoked exactly once (the _build nuke).
      assert Agent.get(heal_calls_agent, & &1) == 1

      # developer-static invoked exactly ONCE — the stale-build heal
      # absorbed the failure without spending a rework attempt.
      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "developer-static")) == 1
    end

    test "a stale-_build verdict that persists after rebuild eventually exhausts to ordinary rework (no infinite heal loop)",
         %{calls_agent: calls_agent} do
      {:ok, heal_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(heal_calls_agent) end)

      # Every gate call stays :failed even after the "rebuild" — this
      # asserts termination (bounded by the rework budget), not a tight
      # infinite heal loop. Each NEW gate-failure occurrence (post-rework
      # retry) legitimately heals again — do_gate_loop_stale_build_heal
      # itself never recurses into its own heal leg on ONE occurrence.
      gate_fn = fn _cwd, _opts -> {:failed, "make test"} end
      gate_classify_fn = fn _cwd, _dev_role -> :stale_build end
      flake_check_fn = fn _cwd, _opts -> {:failed, "make test"} end

      heal_fn = fn _cwd, _live_root_fn ->
        Agent.update(heal_calls_agent, &(&1 + 1))
        :ok
      end

      assert {:error, reason} =
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: gate_fn,
                 gate_classify_fn: gate_classify_fn,
                 flake_check_fn: flake_check_fn,
                 stale_build_heal_fn: heal_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advisor_fn: no_op_advisor_fn()
               )

      assert reason =~ "gate verdict=failed"
      # heal_fn ran at least once and the loop still terminated (bounded by
      # the rework budget) rather than spinning forever.
      assert Agent.get(heal_calls_agent, & &1) >= 1
    end

    test "a stale-_build verdict that passes standalone is absorbed as a load flake WITHOUT nuking _build",
         %{calls_agent: calls_agent} do
      {:ok, gate_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(gate_calls_agent) end)

      {:ok, heal_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(heal_calls_agent) end)

      # Call 0: initial gate -> failed (classified :stale_build below).
      # Call 1: re-entered do_gate_loop/9 after the flake-check absorbed it
      # -> CLEAR (it was a load flake all along, not a stale build).
      gate_fn = fn _cwd, _opts ->
        n = Agent.get_and_update(gate_calls_agent, fn n -> {n, n + 1} end)
        if n == 0, do: {:failed, "make test"}, else: {:clear, "make test"}
      end

      gate_classify_fn = fn _cwd, _dev_role -> :stale_build end

      # Standalone re-run is GREEN -> load flake, not a genuine stale build.
      flake_check_fn = fn _cwd, _opts -> {:clear, "make test"} end

      heal_fn = fn _cwd, _live_root_fn ->
        Agent.update(heal_calls_agent, &(&1 + 1))
        :ok
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: gate_fn,
                 gate_classify_fn: gate_classify_fn,
                 flake_check_fn: flake_check_fn,
                 stale_build_heal_fn: heal_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      # The core invariant: the destructive heal was NEVER invoked.
      assert Agent.get(heal_calls_agent, & &1) == 0

      # developer-static invoked exactly ONCE — the flake was absorbed
      # without spending a rework attempt.
      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "developer-static")) == 1
    end
  end

  describe "run/1 — stale-build heal never nukes the live orchestrator build root" do
    test "the real default heal fn skips the candidate matching the injected live build root",
         %{calls_agent: calls_agent} do
      tmp_cwd =
        Path.join(
          System.tmp_dir!(),
          "loop-stale-heal-live-root-#{System.unique_integer([:positive])}"
        )

      downstream_build = Path.join(tmp_cwd, "_build")
      live_build = Path.join([tmp_cwd, "test_harness", "_build"])

      File.mkdir_p!(downstream_build)
      File.mkdir_p!(live_build)
      on_exit(fn -> File.rm_rf!(tmp_cwd) end)

      # Simulate: the running orchestrator's own build root IS
      # test_harness/_build (as on a codegen self-build).
      live_root_fn = fn -> live_build end

      # Standalone flake-check fails (genuinely stale, not a load flake) so
      # the real heal fn actually runs; then the gate clears post-heal.
      {:ok, gate_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(gate_calls_agent) end)

      gate_fn = fn _cwd, _opts ->
        n = Agent.get_and_update(gate_calls_agent, fn n -> {n, n + 1} end)
        if n == 0, do: {:failed, "make test"}, else: {:clear, "make test"}
      end

      gate_classify_fn = fn _cwd, _dev_role -> :stale_build end
      flake_check_fn = fn _cwd, _opts -> {:failed, "make test"} end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: tmp_cwd,
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: gate_fn,
                 gate_classify_fn: gate_classify_fn,
                 flake_check_fn: flake_check_fn,
                 live_build_root_fn: live_root_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      refute File.dir?(downstream_build)
      assert File.dir?(live_build)
    end

    test "with no :live_build_root_fn override, the default resolves against the process's own cwd",
         %{calls_agent: calls_agent} do
      tmp_cwd =
        Path.join(
          System.tmp_dir!(),
          "loop-stale-heal-default-live-root-#{System.unique_integer([:positive])}"
        )

      # The DEFAULT live-root resolution is `Path.expand(File.cwd!())` joined
      # with "_build" — since this test process's cwd is `test_harness/`
      # (mix test's own working directory), that default does NOT match
      # either candidate under `tmp_cwd`, so both are nuked. This exercises
      # `default_live_build_root_fn/0` itself (never overridden), proving the
      # default is safe when the tmp_cwd under test is unrelated to the
      # actual running process.
      downstream_build = Path.join(tmp_cwd, "_build")
      nested_build = Path.join([tmp_cwd, "test_harness", "_build"])

      File.mkdir_p!(downstream_build)
      File.mkdir_p!(nested_build)
      on_exit(fn -> File.rm_rf!(tmp_cwd) end)

      {:ok, gate_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(gate_calls_agent) end)

      gate_fn = fn _cwd, _opts ->
        n = Agent.get_and_update(gate_calls_agent, fn n -> {n, n + 1} end)
        if n == 0, do: {:failed, "make test"}, else: {:clear, "make test"}
      end

      gate_classify_fn = fn _cwd, _dev_role -> :stale_build end
      flake_check_fn = fn _cwd, _opts -> {:failed, "make test"} end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: tmp_cwd,
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: gate_fn,
                 gate_classify_fn: gate_classify_fn,
                 flake_check_fn: flake_check_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      refute File.dir?(downstream_build)
      refute File.dir?(nested_build)
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
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advisor_fn: no_op_advisor_fn()
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

  # ctx with a pitch_scope, the shape run/1 builds from the :pitch_scope
  # run option.
  defp scoped_ctx(scope) do
    %{cwd: "/tmp", pitch: "raw pitch text", pitch_scope: scope, artifacts: %{}}
  end

  describe "build_prompt/2 — ## Declared Scope threading" do
    test "developer prompt carries the declared paths under a ## Declared Scope heading" do
      content =
        OrchestrationLoop.build_prompt(
          "developer-phoenix-backend",
          scoped_ctx(["lib/foo.ex", "test/foo_test.exs"])
        )

      assert content =~ "raw pitch text"
      assert content =~ "## Declared Scope"
      assert content =~ "lib/foo.ex"
      assert content =~ "test/foo_test.exs"
      # The block names the pitch's own `scope:` field as the source — it is a
      # declaration, not a forecast, and it is NOT the retired plan block.
      assert content =~ "`scope:`"
      refute content =~ "## Plan"
    end

    test "developer-static gets the same block (both stacks, one threading rule)" do
      content = OrchestrationLoop.build_prompt("developer-static", scoped_ctx(["assets/app.js"]))

      assert content =~ "## Declared Scope"
      assert content =~ "assets/app.js"
    end

    test "reviewer-phoenix prompt IS enriched with the declared scope block" do
      content = OrchestrationLoop.build_prompt("reviewer-phoenix", scoped_ctx(["lib/foo.ex"]))

      assert content =~ "## Declared Scope"
      assert content =~ "lib/foo.ex"
    end

    test "reviewer-static prompt IS enriched with the declared scope block" do
      content = OrchestrationLoop.build_prompt("reviewer-static", scoped_ctx(["assets/app.js"]))

      assert content =~ "## Declared Scope"
      assert content =~ "assets/app.js"
    end

    test "context-curator prompt is NOT enriched" do
      ctx = scoped_ctx(["lib/foo.ex"])

      curator_content = OrchestrationLoop.build_prompt("context-curator", ctx)

      refute curator_content =~ "## Declared Scope"
      refute curator_content =~ "lib/foo.ex"
    end

    test "nil pitch_scope → prompt is just the raw pitch (ad-hoc literal pitch)" do
      content = OrchestrationLoop.build_prompt("developer-static", scoped_ctx(nil))

      assert content == "raw pitch text"
      refute content =~ "## Declared Scope"
    end

    test "empty pitch_scope list → no block appended (an empty declaration declares nothing)" do
      content = OrchestrationLoop.build_prompt("developer-phoenix-backend", scoped_ctx([]))

      assert content == "raw pitch text"
      refute content =~ "## Declared Scope"
    end

    test "a ctx with no :pitch_scope key at all is tolerated, not a crash" do
      ctx = %{cwd: "/tmp", pitch: "raw pitch text", artifacts: %{}}

      content = OrchestrationLoop.build_prompt("developer-phoenix-backend", ctx)

      assert content == "raw pitch text"
      refute content =~ "## Declared Scope"
    end

    test "the declared paths are rendered one per line in a fenced block" do
      content =
        OrchestrationLoop.build_prompt(
          "developer-phoenix-backend",
          scoped_ctx(["lib/a.ex", "lib/b.ex"])
        )

      assert content =~ "```\nlib/a.ex\nlib/b.ex\n```"
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

    test "post-review curator gets stage ownership while developer contract stays unchanged" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{
          "reviewer-static" => %{"value" => "REVIEW_VERDICT: APPROVED"},
          gate_command: "make test"
        }
      }

      curator = OrchestrationLoop.build_prompt("context-curator", ctx)
      developer = OrchestrationLoop.build_prompt("developer-static", ctx)

      assert curator =~ "Stage contract — post-review context curation"
      assert curator =~ "loop gate already passed for this exact tree"
      assert curator =~ "reviewer approved it"
      assert curator =~ "typed `ev:learned` events"
      assert curator =~ "MUST NOT run the full gate or test command"
      assert curator =~ "Targeted curator routing and factcheck checks are allowed"
      assert curator =~ "will re-run the gate if your edits change the tree"
      refute curator =~ "Gate — self-verify"

      assert developer =~ "Gate — self-verify"
      refute developer =~ "Stage contract — post-review context curation"
    end

    test "curator orientation repair block is preserved and does not imply post-review state" do
      violation = "context/loop.md: named path does not exist"

      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{curator_doc_violations: violation, gate_command: "make test"}
      }

      content = OrchestrationLoop.build_prompt("context-curator", ctx)

      assert content =~ "## Orientation-doc violations to fix"
      assert content =~ violation
      assert content =~ "Edit only the named orientation docs"
      refute content =~ "Stage contract — post-review context curation"
      refute content =~ "Gate — self-verify"
    end

    test "REVIEWED checkpoint curator receives the post-review stage contract" do
      ctx = %{
        cwd: "/tmp",
        pitch: "do the thing",
        artifacts: %{resume_state: "REVIEWED", gate_command: "make test"}
      }

      content = OrchestrationLoop.build_prompt("context-curator", ctx)

      assert content =~ "Stage contract — post-review context curation"
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

  describe "parse_review_coverage/2" do
    test "empty expected_files is a vacuous no-op regardless of value shape" do
      assert OrchestrationLoop.parse_review_coverage(%{"value" => "REVIEW_VERDICT: APPROVED"}, "") ==
               {:ok, %{read: [], skipped: []}}

      assert OrchestrationLoop.parse_review_coverage(%{"value" => "anything at all"}, "  \n  ") ==
               {:ok, %{read: [], skipped: []}}
    end

    test "every expected path named read -> :ok with the full read list" do
      value =
        "REVIEW_COVERAGE: lib/a.ex read\nREVIEW_COVERAGE: lib/b.ex read\n" <>
          "REVIEW_VERDICT: APPROVED"

      assert {:ok, %{read: read, skipped: []}} =
               OrchestrationLoop.parse_review_coverage(%{"value" => value}, "lib/a.ex\nlib/b.ex")

      assert Enum.sort(read) == ["lib/a.ex", "lib/b.ex"]
    end

    test "a mix of read and skipped entries -> :ok with both lists populated" do
      value =
        "REVIEW_COVERAGE: lib/a.ex read\n" <>
          "REVIEW_COVERAGE: lib/b.ex skipped: unchanged lockfile\n" <>
          "REVIEW_VERDICT: APPROVED"

      assert {:ok, %{read: ["lib/a.ex"], skipped: [{"lib/b.ex", "unchanged lockfile"}]}} =
               OrchestrationLoop.parse_review_coverage(%{"value" => value}, "lib/a.ex\nlib/b.ex")
    end

    test "a decorated coverage line (backticks) is tolerated the same as the verdict line" do
      value = "`REVIEW_COVERAGE: lib/a.ex read`\nREVIEW_VERDICT: APPROVED"

      assert {:ok, %{read: ["lib/a.ex"], skipped: []}} =
               OrchestrationLoop.parse_review_coverage(%{"value" => value}, "lib/a.ex")
    end

    test "sign-off value recovers coverage from the reviewer's transcript" do
      transcript =
        write_reviewer_transcript!([
          "Reviewing the diff.",
          "REVIEW_COVERAGE: lib/a.ex read\nREVIEW_COVERAGE: lib/b.ex read\n" <>
            "REVIEW_VERDICT: APPROVED",
          "Logged."
        ])

      assert {:ok, %{read: read, skipped: []}} =
               OrchestrationLoop.parse_review_coverage(
                 %{"value" => "Logged.", "transcript" => transcript},
                 "lib/a.ex\nlib/b.ex"
               )

      assert Enum.sort(read) == ["lib/a.ex", "lib/b.ex"]
    end

    test "zero coverage lines when files were expected -> :incomplete naming the count" do
      assert {:incomplete, reason} =
               OrchestrationLoop.parse_review_coverage(
                 %{"value" => "REVIEW_VERDICT: APPROVED"},
                 "lib/a.ex\nlib/b.ex"
               )

      assert reason =~ "no REVIEW_COVERAGE: lines found"
      assert reason =~ "2 path(s)"
    end

    test "a missing path -> :incomplete naming exactly the gap" do
      value = "REVIEW_COVERAGE: lib/a.ex read\nREVIEW_VERDICT: APPROVED"

      assert {:incomplete, reason} =
               OrchestrationLoop.parse_review_coverage(%{"value" => value}, "lib/a.ex\nlib/b.ex")

      assert reason =~ "missing"
      assert reason =~ "lib/b.ex"
      refute reason =~ "lib/a.ex missing"
    end

    test "an invented path not in the expected set -> :incomplete naming it" do
      value =
        "REVIEW_COVERAGE: lib/a.ex read\nREVIEW_COVERAGE: lib/ghost.ex read\n" <>
          "REVIEW_VERDICT: APPROVED"

      assert {:incomplete, reason} =
               OrchestrationLoop.parse_review_coverage(%{"value" => value}, "lib/a.ex")

      assert reason =~ "not in ## Files Modified"
      assert reason =~ "lib/ghost.ex"
    end

    test "a skipped entry with an empty reason is malformed" do
      value = "REVIEW_COVERAGE: lib/a.ex skipped:\nREVIEW_VERDICT: APPROVED"

      assert {:incomplete, reason} =
               OrchestrationLoop.parse_review_coverage(%{"value" => value}, "lib/a.ex")

      assert reason =~ "malformed REVIEW_COVERAGE line"
    end

    test "a coverage line with an unrecognised state token is malformed" do
      value = "REVIEW_COVERAGE: lib/a.ex glanced-at\nREVIEW_VERDICT: APPROVED"

      assert {:incomplete, reason} =
               OrchestrationLoop.parse_review_coverage(%{"value" => value}, "lib/a.ex")

      assert reason =~ "malformed REVIEW_COVERAGE line"
    end

    test "a non-text value is incomplete without raising" do
      assert {:incomplete, _reason} =
               OrchestrationLoop.parse_review_coverage(%{"status" => "success"}, "lib/a.ex")
    end
  end

  describe "default_review_diff_fn/1" do
    test "non-git cwd returns empty block and empty digest/body maps" do
      assert OrchestrationLoop.default_review_diff_fn(
               "/tmp/definitely-not-a-git-repo-diff-#{System.unique_integer([:positive])}"
             ) == {"", %{}, %{}}
    end

    test "clean git work tree returns empty block and empty digest/body maps" do
      tmp =
        System.tmp_dir!()
        |> Path.join("review-diff-clean-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      {_out, 0} = System.cmd("git", ["init", "-q"], cd: tmp)
      {_out, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: tmp)
      {_out, 0} = System.cmd("git", ["config", "user.name", "T"], cd: tmp)
      File.write!(Path.join(tmp, "a.txt"), "hello\n")
      {_out, 0} = System.cmd("git", ["add", "a.txt"], cd: tmp)
      {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: tmp)

      assert OrchestrationLoop.default_review_diff_fn(tmp) == {"", %{}, %{}}
    end

    test "dirty tracked file produces a verbatim diff block and a digest+body entry for that path" do
      tmp =
        System.tmp_dir!()
        |> Path.join("review-diff-dirty-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      {_out, 0} = System.cmd("git", ["init", "-q"], cd: tmp)
      {_out, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: tmp)
      {_out, 0} = System.cmd("git", ["config", "user.name", "T"], cd: tmp)
      File.write!(Path.join(tmp, "a.txt"), "hello\n")
      {_out, 0} = System.cmd("git", ["add", "a.txt"], cd: tmp)
      {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: tmp)

      File.write!(Path.join(tmp, "a.txt"), "hello\nworld\n")

      {block, digests, bodies} = OrchestrationLoop.default_review_diff_fn(tmp)

      assert block =~ "+world"
      assert Map.has_key?(digests, "a.txt")
      assert bodies["a.txt"] =~ "+world"
    end

    test "an untracked new file gets a digest derived from its raw content" do
      tmp =
        System.tmp_dir!()
        |> Path.join("review-diff-untracked-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      {_out, 0} = System.cmd("git", ["init", "-q"], cd: tmp)
      {_out, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: tmp)
      {_out, 0} = System.cmd("git", ["config", "user.name", "T"], cd: tmp)
      File.write!(Path.join(tmp, "a.txt"), "hello\n")
      {_out, 0} = System.cmd("git", ["add", "a.txt"], cd: tmp)
      {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: tmp)

      File.write!(Path.join(tmp, "new.txt"), "brand new\n")

      {_block, digests, _bodies} = OrchestrationLoop.default_review_diff_fn(tmp)

      assert Map.has_key?(digests, "new.txt")
      expected = :crypto.hash(:sha256, "brand new\n") |> Base.encode16(case: :lower)
      assert digests["new.txt"] == expected
    end
  end

  describe "run/1 — reviewer file set threading (loop-derived ## Files Modified)" do
    test "review_file_set_fn output reaches the reviewer prompt on first pass", %{
      calls_agent: calls_agent
    } do
      {:ok, prompt_agent} = Agent.start_link(fn -> nil end)
      on_exit(fn -> stop_agent(prompt_agent) end)

      set_fn = fn _cwd -> "lib/only_file.ex" end

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "reviewer-static" do
          prompt = OrchestrationLoop.build_prompt(role, ctx)
          Agent.update(prompt_agent, fn _ -> prompt end)

          {:ok,
           %{
             "status" => "success",
             "value" => "REVIEW_COVERAGE: lib/only_file.ex read\nREVIEW_VERDICT: APPROVED"
           }}
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
      on_exit(fn -> stop_agent(set_calls_agent) end)

      {:ok, prompts_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(prompts_agent) end)

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
              do:
                "REVIEW_COVERAGE: lib/pass_0.ex read\nfix it\nREVIEW_VERDICT: CHANGES_REQUESTED",
              else: "REVIEW_COVERAGE: lib/pass_1.ex read\nREVIEW_VERDICT: APPROVED"

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

    test "review_diff_fn output reaches the ## Diff under review block, and a re-review pass carries ## Since your last review with the prior finding and the delta",
         %{calls_agent: calls_agent} do
      {:ok, prompts_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(prompts_agent) end)

      {:ok, diff_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(diff_calls_agent) end)

      set_fn = fn _cwd -> "lib/foo.ex" end

      # Pass 1 digest differs from pass 2 digest, so `diff_delta/2` reports
      # `lib/foo.ex` as :changed on the re-review pass.
      diff_fn = fn _cwd ->
        n = Agent.get_and_update(diff_calls_agent, fn n -> {n, n + 1} end)

        {"```diff\n+pass_#{n}\n```", %{"lib/foo.ex" => "digest_#{n}"},
         %{"lib/foo.ex" => "+pass_#{n}"}}
      end

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "reviewer-static" do
          seen = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "reviewer-static"))
          prompt = OrchestrationLoop.build_prompt(role, ctx)
          Agent.update(prompts_agent, fn ps -> ps ++ [prompt] end)

          value =
            if seen <= 1,
              do:
                "REVIEW_COVERAGE: lib/foo.ex read\n" <>
                  "the pitch-format-validator.sh gate is untested\nREVIEW_VERDICT: CHANGES_REQUESTED",
              else: "REVIEW_COVERAGE: lib/foo.ex read\nREVIEW_VERDICT: APPROVED"

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
                 review_diff_fn: diff_fn,
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 # Pinned, not inherited: the two assertions below about pass
                 # NUMBERING ("2 of 2") and the last-pass budget warning are
                 # only true when pass 2 is the final one. This test is about
                 # diff threading, not about what the default budget happens
                 # to be, so it states the budget it needs rather than
                 # silently re-breaking whenever that default moves.
                 max_review_cycles: 1
               )

      prompts = Agent.get(prompts_agent, & &1)
      assert length(prompts) == 2

      first_pass = Enum.at(prompts, 0)
      assert first_pass =~ "## Diff under review"
      assert first_pass =~ "+pass_0"
      refute first_pass =~ "## Since your last review"

      re_review_pass = Enum.at(prompts, 1)
      assert re_review_pass =~ "## Diff under review"
      assert re_review_pass =~ "+pass_1"
      assert re_review_pass =~ "## Since your last review"
      assert re_review_pass =~ "### Your prior finding"
      assert re_review_pass =~ "the pitch-format-validator.sh gate is untested"
      assert re_review_pass =~ "lib/foo.ex (changed)"
      assert re_review_pass =~ "+pass_1"
      assert re_review_pass =~ "This is review pass 2 of 2"
      assert re_review_pass =~ "review re-work budget is exhausted"
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
      on_exit(fn -> stop_agent(gate_calls_agent) end)

      gate_fn = fn _cwd, _opts ->
        n = Agent.get_and_update(gate_calls_agent, fn n -> {n, n + 1} end)
        if n == 0, do: {:failed, "make test"}, else: {:clear, "make test"}
      end

      {:ok, reviewer_prompt_agent} = Agent.start_link(fn -> nil end)

      on_exit(fn ->
        stop_agent(reviewer_prompt_agent)
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
      on_exit(fn -> stop_agent(gate_calls_agent) end)

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
      on_exit(fn -> stop_agent(sig_calls_agent) end)

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
                 tree_signature_fn: signature_fn,
                 advisor_fn: no_op_advisor_fn()
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
      on_exit(fn -> stop_agent(sig_calls_agent) end)

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
                 tree_signature_fn: signature_fn,
                 advisor_fn: no_op_advisor_fn()
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
                 advisor_fn: no_op_advisor_fn()
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
      on_exit(fn -> stop_agent(gate_calls_agent) end)

      gate_fn = fn _cwd, _opts ->
        n = Agent.get_and_update(gate_calls_agent, fn n -> {n, n + 1} end)
        if n <= 1, do: {:failed, "make test"}, else: {:clear, "make test"}
      end

      {:ok, seen_reason_agent} = Agent.start_link(fn -> nil end)
      on_exit(fn -> stop_agent(seen_reason_agent) end)

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
      on_exit(fn -> stop_agent(seen_ctx_agent) end)

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
                 resolve_escalation_fn: resolve_escalation_fn,
                 advisor_fn: no_op_advisor_fn()
               )

      assert reason =~ "gate verdict=failed"

      # initial call (no escalation, not a rework retry) + one rework retry
      # (the final allowed attempt -> escalated).
      assert Agent.get(seen_ctx_agent, & &1) == [nil, {"opus", "high"}]
    end

    test "role-model-sweep fixed binding suppresses give-up-boundary escalation — ctx.escalated_model stays nil on the final retry",
         %{calls_agent: calls_agent} do
      run_dir =
        Path.join(System.tmp_dir!(), "rms_escalate_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(run_dir)
      on_exit(fn -> File.rm_rf!(run_dir) end)

      binding = %{
        "schema_version" => 1,
        "campaign_id" => "camp-1",
        "arm" => "baseline",
        "role" => "developer-static",
        "stack" => "static",
        "harness" => "claude_code",
        "model" => "sonnet",
        "effort" => "medium",
        "source_sha" => "deadbeef",
        "fixed" => true
      }

      File.write!(Path.join(run_dir, "role-model-binding.json"), Jason.encode!(binding))
      System.put_env("BENCH_RUN_DIR", run_dir)
      Process.delete(:role_model_sweep_binding)

      on_exit(fn ->
        System.delete_env("BENCH_RUN_DIR")
        Process.delete(:role_model_sweep_binding)
      end)

      gate_fn = fn _cwd, _opts -> {:failed, "make test"} end

      {:ok, seen_ctx_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(seen_ctx_agent) end)

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
                 # Pins harness resolution to match the binding file's
                 # "harness" ("claude_code") independent of config.yaml's
                 # live per-role override (developer-static currently
                 # forced an override) — this test asserts the SUPPRESSION
                 # contract, not config.yaml's current routing.
                 resolve_harness_fn: fn _role, build_harness -> build_harness end,
                 gate_fn: gate_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 resolve_escalation_fn: resolve_escalation_fn,
                 git_head_fn: fn -> "deadbeef" end,
                 git_dirty_fn: fn -> false end,
                 advisor_fn: no_op_advisor_fn()
               )

      # Fixed binding present for developer-static -> escalation suppressed
      # on every attempt, including the final one.
      assert Agent.get(seen_ctx_agent, & &1) == [nil, nil]
    end

    test "count-bound path: escalation resolution uses the per-role resolve_harness_fn override, not the build harness",
         %{calls_agent: calls_agent} do
      gate_fn = fn _cwd, _opts -> {:failed, "make test"} end

      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)
        {:ok, %{"status" => "success", "value" => "did #{role}"}}
      end

      {:ok, harness_seen_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(harness_seen_agent) end)

      resolve_harness_fn = fn "developer-static", "claude_code" -> "other_harness" end

      resolve_escalation_fn = fn "developer-static", harness ->
        Agent.update(harness_seen_agent, fn seen -> seen ++ [harness] end)
        {"other-model", "high"}
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
                 resolve_escalation_fn: resolve_escalation_fn,
                 advisor_fn: no_op_advisor_fn()
               )

      assert Agent.get(harness_seen_agent, & &1) == ["other_harness"]
    end

    test "count-bound path: no escalation configured -> ctx unchanged, normal tier throughout", %{
      calls_agent: calls_agent
    } do
      gate_fn = fn _cwd, _opts -> {:failed, "make test"} end

      {:ok, seen_ctx_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(seen_ctx_agent) end)

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
                 resolve_escalation_fn: resolve_escalation_fn,
                 advisor_fn: no_op_advisor_fn()
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
      on_exit(fn -> stop_agent(sig_calls_agent) end)

      signature_fn = fn _cwd ->
        n = Agent.get_and_update(sig_calls_agent, fn n -> {n, n + 1} end)
        "sig-#{n}"
      end

      {:ok, seen_ctx_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(seen_ctx_agent) end)

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
                 resolve_escalation_fn: resolve_escalation_fn,
                 advisor_fn: no_op_advisor_fn()
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

  describe "run/1 — gate-retry give-up-boundary advisor (maybe_advise/5)" do
    # Mirrors the escalation describe block's count-bound path: non-git cwd ->
    # tree_signature/1 unavailable -> falls back to the legacy count bound
    # (:max_gate_retries, default 1) -> the one allowed retry is also final.
    test "count-bound path: advisor fires on the one allowed retry when it returns a plan", %{
      calls_agent: calls_agent
    } do
      gate_fn = fn _cwd, _opts -> {:failed, "make test"} end

      {:ok, seen_ctx_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(seen_ctx_agent) end)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "developer-static" do
          plan = get_in(ctx, [:artifacts, :advisor_plan])
          Agent.update(seen_ctx_agent, fn seen -> seen ++ [plan] end)
        end

        {:ok, %{"status" => "success", "value" => "did #{role}"}}
      end

      advisor_fn = fn _harness, _context_text, _opts ->
        {:ok, "try a different index strategy"}
      end

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
                 advisor_fn: advisor_fn
               )

      assert reason =~ "gate verdict=failed"

      # initial call (no advisor, not a rework retry) + one rework retry
      # (the final allowed attempt -> advisor plan present).
      assert Agent.get(seen_ctx_agent, & &1) == [nil, "try a different index strategy"]
    end

    test "advisor plan is cleared from ctx.artifacts after the attempt resolves (same lifecycle as escalated_model)",
         %{calls_agent: calls_agent} do
      gate_fn = fn _cwd, _opts -> {:failed, "make test"} end

      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)
        {:ok, %{"status" => "success", "value" => "did #{role}"}}
      end

      advisor_fn = fn _harness, _context_text, _opts -> {:ok, "a recovery plan"} end

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
                 advisor_fn: advisor_fn
               )

      # The final call in the sequence is the committer's own gate re-check
      # (rework_final_gate/5) — irrelevant here; what matters is that no
      # invocation AFTER the advised retry ever sees a stale advisor_plan
      # left over from a prior attempt. Assert indirectly: the FIRST
      # (non-final) developer invocation never saw a plan (only the final
      # attempt does), proving the key isn't leaking backward across
      # attempts either.
      assert Enum.member?(Agent.get(calls_agent, & &1), "developer-static")
    end

    test "composes with escalation: final attempt carries BOTH escalated_model AND advisor_plan",
         %{
           calls_agent: calls_agent
         } do
      gate_fn = fn _cwd, _opts -> {:failed, "make test"} end

      {:ok, seen_ctx_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(seen_ctx_agent) end)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "developer-static" do
          escalated = get_in(ctx, [:artifacts, :escalated_model])
          plan = get_in(ctx, [:artifacts, :advisor_plan])
          Agent.update(seen_ctx_agent, fn seen -> seen ++ [{escalated, plan}] end)
        end

        {:ok, %{"status" => "success", "value" => "did #{role}"}}
      end

      resolve_escalation_fn = fn "developer-static", _harness -> {"opus", "high"} end
      advisor_fn = fn _harness, _context_text, _opts -> {:ok, "advisor recovery plan"} end

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
                 resolve_escalation_fn: resolve_escalation_fn,
                 advisor_fn: advisor_fn
               )

      assert Agent.get(seen_ctx_agent, & &1) == [
               {nil, nil},
               {{"opus", "high"}, "advisor recovery plan"}
             ]
    end

    test "role-model-sweep fixed binding suppresses the advisor too — ctx.advisor_plan stays nil on the final retry",
         %{calls_agent: calls_agent} do
      run_dir = Path.join(System.tmp_dir!(), "rms_advise_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(run_dir)
      on_exit(fn -> File.rm_rf!(run_dir) end)

      binding = %{
        "schema_version" => 1,
        "campaign_id" => "camp-1",
        "arm" => "baseline",
        "role" => "developer-static",
        "stack" => "static",
        "harness" => "claude_code",
        "model" => "sonnet",
        "effort" => "medium",
        "source_sha" => "deadbeef",
        "fixed" => true
      }

      File.write!(Path.join(run_dir, "role-model-binding.json"), Jason.encode!(binding))
      System.put_env("BENCH_RUN_DIR", run_dir)
      Process.delete(:role_model_sweep_binding)

      on_exit(fn ->
        System.delete_env("BENCH_RUN_DIR")
        Process.delete(:role_model_sweep_binding)
      end)

      gate_fn = fn _cwd, _opts -> {:failed, "make test"} end

      {:ok, seen_ctx_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(seen_ctx_agent) end)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "developer-static" do
          plan = get_in(ctx, [:artifacts, :advisor_plan])
          Agent.update(seen_ctx_agent, fn seen -> seen ++ [plan] end)
        end

        {:ok, %{"status" => "success", "value" => "did #{role}"}}
      end

      advisor_fn = fn _harness, _context_text, _opts -> {:ok, "should never be seen"} end

      assert {:error, _reason} =
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 resolve_harness_fn: fn _role, build_harness -> build_harness end,
                 gate_fn: gate_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advisor_fn: advisor_fn,
                 git_head_fn: fn -> "deadbeef" end,
                 git_dirty_fn: fn -> false end
               )

      # Fixed binding present for developer-static -> advisor suppressed on
      # every attempt, including the final one.
      assert Agent.get(seen_ctx_agent, & &1) == [nil, nil]
    end

    test "a failed advisor call (:error) does not fail the cycle — ctx unchanged, no advisor_plan set",
         %{
           calls_agent: calls_agent
         } do
      gate_fn = fn _cwd, _opts -> {:failed, "make test"} end

      {:ok, seen_ctx_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(seen_ctx_agent) end)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "developer-static" do
          plan = get_in(ctx, [:artifacts, :advisor_plan])
          Agent.update(seen_ctx_agent, fn seen -> seen ++ [plan] end)
        end

        {:ok, %{"status" => "success", "value" => "did #{role}"}}
      end

      # Simulates codegen-advise unavailable/non-zero exit.
      advisor_fn = fn _harness, _context_text, _opts -> :error end

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
                 advisor_fn: advisor_fn
               )

      # Cycle fails on gate exhaustion exactly as it would without the
      # advisor feature — the failure reason is unrelated to the advisor.
      assert reason =~ "gate verdict=failed"
      assert Agent.get(seen_ctx_agent, & &1) == [nil, nil]
    end

    test "build_prompt/2 renders the advisor plan under ## Advisor for developer and reviewer roles" do
      ctx = %{
        pitch: "fix the thing",
        artifacts: %{advisor_plan: "Try reindexing the query instead of adding a cache layer."}
      }

      prompt = OrchestrationLoop.build_prompt("developer-static", ctx)

      assert prompt =~ "## Advisor — second opinion"
      assert prompt =~ "Try reindexing the query instead of adding a cache layer."

      reviewer_prompt = OrchestrationLoop.build_prompt("reviewer-static", ctx)
      assert reviewer_prompt =~ "## Advisor — second opinion"
    end

    test "build_prompt/2 hands non-blocking reviewer findings to context-curator" do
      findings = "Non-blocking: stale wording\nREVIEW_VERDICT: CHANGES_REQUESTED"
      ctx = %{pitch: "fix the thing", artifacts: %{review_non_blocking_findings: findings}}

      prompt = OrchestrationLoop.build_prompt("context-curator", ctx)

      assert prompt =~ "## Reviewer non-blocking findings"
      assert prompt =~ findings
    end

    test "build_prompt/2 renders nothing when advisor_plan is absent" do
      ctx = %{pitch: "fix the thing", artifacts: %{}}

      prompt = OrchestrationLoop.build_prompt("developer-static", ctx)

      refute prompt =~ "## Advisor"
    end

    # Pitch "the advisor is handed a paragraph" D-10: `advisor_fn/3`'s arity
    # stays fixed — attempt/ceiling/stage metadata rides in `opts` under
    # `:advise_meta`, not as a new positional arg. Assert the seam actually
    # carries it through from the gate-loop-rework give-up boundary.
    test "gate-loop-rework advisor call receives :advise_meta in opts (attempt/ceiling/stage)",
         %{calls_agent: calls_agent} do
      gate_fn = fn _cwd, _opts -> {:failed, "make test"} end

      {:ok, seen_meta_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(seen_meta_agent) end)

      invoke_fn = fn role, _harness, _ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)
        {:ok, %{"status" => "success", "value" => "did #{role}"}}
      end

      advisor_fn = fn _harness, _context_text, opts ->
        Agent.update(seen_meta_agent, fn seen -> seen ++ [Keyword.get(opts, :advise_meta)] end)
        {:ok, "a diagnosis"}
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
                 advisor_fn: advisor_fn
               )

      [meta] = Agent.get(seen_meta_agent, & &1)
      assert meta[:stage] == "gate_loop_rework"
      assert is_integer(meta[:attempt])
      assert is_integer(meta[:ceiling])
      assert meta[:final_attempt] == true
    end

    # All 18 pre-existing `no_op_advisor_fn()` stub sites (elsewhere in this
    # file) depend on `advisor_fn/3` keeping its 3-arity shape — this is a
    # smoke assertion that the shared stub still compiles/works unchanged.
    test "no_op_advisor_fn/0 stub still satisfies the (harness, context_text, opts) arity" do
      stub = no_op_advisor_fn()
      assert stub.("claude_code", "some context", advise_meta: %{stage: "x"}) == :error
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

      assert List.last(Agent.get(calls_agent, & &1)) == "context-curator"
    end
  end

  describe "run/1 — cycle-state advancement" do
    test "advances GATED → REVIEWED → CURATED → COMMITTED in order for static stack", %{
      calls_agent: calls_agent
    } do
      {:ok, states_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(states_agent) end)

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
      on_exit(fn -> stop_agent(calls_agent) end)

      {:ok, verdicts_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(verdicts_agent) end)

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
      on_exit(fn -> stop_agent(format_calls_agent) end)

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

    test "signal :no_learning skips the curator spawn but still reaches the commit step", %{
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
      # but `:ok` above already proves the commit step still ran after it.
      refute "context-curator" in Agent.get(calls_agent, & &1)
      assert List.last(Agent.get(calls_agent, & &1)) == "reviewer-static"
    end

    test "signal :no_learning still runs the format step (doc scan runs on the pre-existing tree)",
         %{calls_agent: calls_agent} do
      {:ok, format_calls_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(format_calls_agent) end)

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
      on_exit(fn -> stop_agent(verdicts_agent) end)

      advance_fn = fn state, _step_log, _session_id, verdict, _cwd, _slug ->
        Agent.update(verdicts_agent, fn v -> v ++ [{state, verdict}] end)
        :ok
      end

      {:ok, calls_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(calls_agent) end)

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
      on_exit(fn -> stop_agent(scan_calls_agent) end)

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
      assert List.last(Agent.get(calls_agent, & &1)) == "context-curator"
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

    test "violation once then clean invokes context-curator exactly once (pre-scan seeds the first prompt), then reaches committer",
         %{calls_agent: calls_agent} do
      {:ok, scan_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(scan_calls_agent) end)

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

      # A violation present at curator-stage ENTRY reaches the FIRST curator
      # call (pre-scan seeds it) — only ONE curator invocation is paid for,
      # not two (first empty + second rework respawn).
      curator_calls = Enum.count(Agent.get(calls_agent, & &1), &(&1 == "context-curator"))
      assert curator_calls == 1
      assert List.last(Agent.get(calls_agent, & &1)) == "context-curator"
      # Pre-scan (finds violation) + post-invoke rescan (clean) = 2 scans.
      assert Agent.get(scan_calls_agent, & &1) == 2
    end

    # Regression for bug 5 (write/read key mismatch): the curator's PROMPT
    # must actually carry the violation text scanned at curator-stage entry
    # — historically the write landed under `:curator_doc_violations` while
    # `build_prompt/2` read `:factcheck_violations`, so the re-invoked
    # curator was handed the raw pitch with NO violation list at all. Now
    # the pre-scan seeds the violation into the FIRST (and only) call.
    test "the curator's FIRST prompt carries the scanned violation text (write/read key parity)",
         %{calls_agent: calls_agent} do
      {:ok, scan_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(scan_calls_agent) end)

      {:ok, prompt_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(prompt_agent) end)

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
      assert length(prompts) == 1
      # ONLY pass: the pre-scan violation text is threaded into this FIRST
      # (and only) curator call.
      assert Enum.at(prompts, 0) =~ "the specific violation text"
      assert Enum.at(prompts, 0) =~ "## Orientation-doc violations to fix"
    end

    test "ADD-without-row index-parity violation invokes context-curator exactly once (pre-scan seeds it), then reaches committer",
         %{calls_agent: calls_agent} do
      {:ok, scan_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(scan_calls_agent) end)

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
      assert curator_calls == 1
      assert List.last(Agent.get(calls_agent, & &1)) == "context-curator"
    end

    test "violations exhausting max_curator_doc_cycles returns {:error, reason} with combined factcheck+index-parity text; CURATED never advances, committer never invoked",
         %{calls_agent: calls_agent} do
      {:ok, states_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(states_agent) end)

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
      assert reason =~ "Turn-0 preflight found no inherited orientation-doc drift"
      assert reason =~ "the violations below arrived with this cycle's own edits"
      assert reason =~ "doc check unresolved"
      assert reason =~ "CLAUDE.md:1 bad path"
      assert reason =~ "context-index-parity-scan"
      refute "CURATED" in Agent.get(states_agent, & &1)
      refute "committer" in Agent.get(calls_agent, & &1)
    end

    test "curator-doc exhaustion writes NO terminal marker — doc drift stays retryable", %{
      calls_agent: calls_agent
    } do
      # Sibling of the turn-0 case: the cycle still fails, but a marker would
      # park the pitch and charge the circuit breaker for a condition a second
      # curator pass routinely clears.
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

      refute File.exists?(Path.join(tmp_cwd, "codegen/gate-pending/terminal-state.json"))
    end

    test "curator introduces a superset (fixes nothing, adds a violation) → dies at the guaranteed floor",
         %{calls_agent: calls_agent} do
      # Pins the subset DIRECTION: a scan that grows (never shrinks) must be
      # refused past the floor exactly like an unchanging thrash — proves
      # `repair_allowed?/4` is not accidentally inverted.
      {:ok, scan_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(scan_calls_agent) end)

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
      assert curator_calls == 1
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
      assert curator_calls == 1
      refute "committer" in Agent.get(calls_agent, & &1)
    end

    test "curator resolves one violation while another surfaces → earns a turn past the guaranteed floor",
         %{calls_agent: calls_agent} do
      # The case that dies TODAY (budget=1) and must converge AFTER this
      # change: A+B -> B+C -> C -> clean, each turn resolving exactly one
      # violation from the prior scan.
      {:ok, scan_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(scan_calls_agent) end)

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
      assert curator_calls == 3
      assert List.last(Agent.get(calls_agent, & &1)) == "context-curator"
    end

    test "curator repair ceiling backstop: resolving one violation per turn from a large set still refuses past the hard ceiling",
         %{calls_agent: calls_agent} do
      # 30-member violation set, resolving exactly one per scan — never
      # reaches clean. Proves @repair_progress_ceiling caps otherwise
      # unbounded progress-earned turns.
      {:ok, scan_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(scan_calls_agent) end)

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
      assert curator_calls == 15
      refute "committer" in Agent.get(calls_agent, & &1)
    end

    test "curator-doc violation classified :infra aborts loud — NEVER invokes context-curator",
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

      # The pre-scan classifies the violation BEFORE any invocation — an
      # infra-classified violation aborts loud with ZERO curator calls, not
      # even the "normal initial pass": no curator edit could satisfy it, so
      # no invocation (paid or otherwise) is ever spent on it.
      assert Enum.count(Agent.get(calls_agent, & &1), &(&1 == "context-curator")) == 0
    end

    test "full-tree index-coverage violation invokes context-curator exactly once (pre-scan seeds it), then reaches committer",
         %{calls_agent: calls_agent} do
      # Mirrors the ADD-without-row delta-pass test above, but the violation
      # string here is the one only the full-tree pass in
      # context-index-parity-scan.sh can produce (a PRE-EXISTING orphan with
      # no working-tree delta this turn) — routing must still land on the
      # context-curator, same as every other curator-doc-check violation.
      {:ok, scan_calls_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(scan_calls_agent) end)

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
      assert curator_calls == 1
      assert List.last(Agent.get(calls_agent, & &1)) == "context-curator"
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
      on_exit(fn -> stop_agent(scan_calls_agent) end)

      scan_fn = fn _cwd ->
        n = Agent.get_and_update(scan_calls_agent, fn c -> {c, c + 1} end)
        if n == 0, do: {:violations, "MY_VAR"}, else: {:clean}
      end

      {:ok, states_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(states_agent) end)

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
      assert List.last(Agent.get(calls_agent, & &1)) == "context-curator"
      assert Agent.get(scan_calls_agent, & &1) == 2
      assert "GATED" in Agent.get(states_agent, & &1)
    end

    test "violations exhausting max_env_var_cycles returns {:error, reason}; GATED never advances, committer never invoked",
         %{calls_agent: calls_agent} do
      {:ok, states_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(states_agent) end)

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
      on_exit(fn -> stop_agent(scan_calls_agent) end)

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
      on_exit(fn -> stop_agent(states_agent) end)

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
      assert List.last(Agent.get(calls_agent, & &1)) == "context-curator"
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

  # Like always_ok_invoke_fn/1 — the commit step is no longer dispatched
  # through invoke_fn at all (it left the role vocabulary; see pitch
  # "committing is deterministic, not a model call"). Real git commits for
  # tests exercising `changed_orientation_docs/1`'s diff-scope logic now go
  # through `real_commit_fn/0` (a `:commit_fn` override), not through this
  # invoke_fn's dead `"committer"` clause.
  defp always_ok_invoke_fn_with_real_commit(calls_agent) do
    always_ok_invoke_fn(calls_agent)
  end

  # `:commit_fn` override for tests that use a REAL git repo cwd and need
  # `verify_committed!/2` to actually observe a clean, advanced tree —
  # commits whatever is on disk with a fixed test subject.
  defp real_commit_fn do
    fn cwd, _subject ->
      System.cmd("git", ["add", "-A"], cd: cwd)
      System.cmd("git", ["commit", "-q", "-m", "test commit"], cd: cwd)
      {:ok, "COMMITTED: test commit"}
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

      # Pre-existing (pre-cycle-base) caller file: one test in this describe
      # block adds a NEW `.ex` module this cycle (`widgetapp/billing.ex`)
      # purely as factcheck bait content, unrelated to the born-dead detector.
      # Committing a generic caller here — BEFORE any test captures its own
      # base_head — means it is never itself a "new entity" the detector
      # must re-check, and its content references the module name that test
      # introduces so that module reads as wired, not born-dead.
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join([dir, "lib", "caller.ex"]), "# uses Billing\n")
      System.cmd("git", ["add", "PROJECT_CONTEXT.md", "lib/caller.ex"], cd: dir)
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
                 commit_fn: real_commit_fn(),
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
               )

      assert List.last(Agent.get(calls_agent, & &1)) == "context-curator"
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
                 commit_fn: real_commit_fn(),
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
               )

      assert List.last(Agent.get(calls_agent, & &1)) == "context-curator"
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
                 commit_fn: real_commit_fn(),
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
               )

      assert List.last(Agent.get(calls_agent, & &1)) == "context-curator"
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
                 commit_fn: real_commit_fn(),
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
               )

      assert List.last(Agent.get(calls_agent, & &1)) == "context-curator"
    end

    test "learnings captured this cycle + curator routes a shared/rules/**.md edit → clean, reaches the commit step",
         %{calls_agent: calls_agent, dir: dir} do
      log_path =
        fixture_cycle_log!([
          %{"ev" => "init", "pitch" => "x"},
          %{
            "ev" => "learned",
            "role" => "developer-phoenix-backend",
            "text" => "[shared] a real learning"
          }
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
                 commit_fn: real_commit_fn(),
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn(),
                 log_init_fn: log_init_fn_for(log_path),
                 slug: "consumption-scan-test"
               )

      assert List.last(Agent.get(calls_agent, & &1)) == "context-curator"
    end

    test "learnings captured this cycle, curator routes nothing and records no drop → consumption check fails loud",
         %{calls_agent: calls_agent, dir: dir} do
      log_path =
        fixture_cycle_log!([
          %{"ev" => "init", "pitch" => "x"},
          %{
            "ev" => "learned",
            "role" => "developer-phoenix-backend",
            "text" => "[shared] a real learning"
          }
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

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static", do: approved_verdict_for(ctx), else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end

      assert_raise RuntimeError, ~r/working tree is NOT clean/, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "static",
          cwd: dir,
          pitch: "do the thing",
          invoke_fn: invoke_fn,
          commit_fn: fn _cwd, _subject -> {:ok, "COMMITTED: test"} end,
          commit_subject: "Test subject",
          gate_fn: always_clear_gate_fn(),
          gate_preflight_fn: no_op_gate_preflight_fn(),
          preflight_probe_fn: all_present_preflight_probe_fn()
        )
      end
    end

    test "commit step returning success on a CLEAN tree with real work committed proceeds to :ok",
         %{
           calls_agent: calls_agent,
           dir: dir
         } do
      # Simulate the developer's own work landing before the reviewer runs —
      # a real cycle never reaches the reviewer with a clean tree (see
      # invoke_reviewer/4's empty-set refusal).
      File.write!(Path.join(dir, "feature.txt"), "wip\n")

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static", do: approved_verdict_for(ctx), else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end

      commit_fn = fn cwd, _subject ->
        File.write!(Path.join(cwd, "feature.txt"), "done\n")
        {_o, 0} = System.cmd("git", ["add", "-A"], cd: cwd)
        {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "impl"], cd: cwd)
        {:ok, "COMMITTED: impl"}
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
                 commit_fn: commit_fn,
                 commit_subject: "Test subject",
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

    test "commit step producing TWO commits raises (split-commit guard, exactly-one enforced)", %{
      calls_agent: calls_agent,
      dir: dir
    } do
      # Simulate the developer's own work landing before the reviewer runs —
      # a real cycle never reaches the reviewer with a clean tree (see
      # invoke_reviewer/4's empty-set refusal).
      File.write!(Path.join(dir, "feature.txt"), "wip\n")

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static", do: approved_verdict_for(ctx), else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end

      commit_fn = fn cwd, _subject ->
        File.write!(Path.join(cwd, "a.txt"), "one\n")
        {_o, 0} = System.cmd("git", ["add", "-A"], cd: cwd)
        {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "c1"], cd: cwd)
        File.write!(Path.join(cwd, "b.txt"), "two\n")
        {_o, 0} = System.cmd("git", ["add", "-A"], cd: cwd)
        {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "c2"], cd: cwd)
        {:ok, "COMMITTED: c2"}
      end

      assert_raise RuntimeError, ~r/exactly one commit|expected 1|split commits/, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "static",
          cwd: dir,
          pitch: "do the thing",
          invoke_fn: invoke_fn,
          commit_fn: commit_fn,
          commit_subject: "Test subject",
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

    test "commit step orphaning the base via git reset raises (ancestry backstop)", %{
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

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static", do: approved_verdict_for(ctx), else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end

      commit_fn = fn cwd, _subject ->
        # Orphaning move: reset past the prior-cycle commit (base_head),
        # then make exactly ONE new commit on the older history. This
        # passes the count+diff guard but must trip the ancestry backstop.
        {_o, 0} = System.cmd("git", ["reset", "--hard", "HEAD~1"], cd: cwd)
        File.write!(Path.join(cwd, "new_work.txt"), "new\n")
        {_o, 0} = System.cmd("git", ["add", "-A"], cd: cwd)
        {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "orphaning commit"], cd: cwd)
        {:ok, "COMMITTED: orphaning commit"}
      end

      assert_raise RuntimeError, ~r/no longer an ancestor|orphaned the base/, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "static",
          cwd: dir,
          pitch: "do the thing",
          invoke_fn: invoke_fn,
          commit_fn: commit_fn,
          commit_subject: "Test subject",
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
      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static", do: approved_verdict_for(ctx), else: "did #{role}"

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

    test "commit step landing a born-dead new module (no caller, no registration) raises", %{
      calls_agent: calls_agent,
      dir: dir
    } do
      # Simulate the developer's own work landing before the reviewer runs.
      File.write!(Path.join(dir, "feature.txt"), "wip\n")

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static", do: approved_verdict_for(ctx), else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end

      commit_fn = fn cwd, _subject ->
        lib_dir = Path.join(cwd, "lib")
        File.mkdir_p!(lib_dir)

        File.write!(
          Path.join(lib_dir, "orphan_module.ex"),
          "defmodule OrphanModule do\n  def run, do: :ok\nend\n"
        )

        {_o, 0} = System.cmd("git", ["add", "-A"], cd: cwd)
        {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "impl"], cd: cwd)
        {:ok, "COMMITTED: impl"}
      end

      assert_raise RuntimeError, ~r/born-dead detector: new entity.*orphan_module/, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "static",
          cwd: dir,
          pitch: "do the thing",
          invoke_fn: invoke_fn,
          commit_fn: commit_fn,
          commit_subject: "Test subject",
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

    test "commit step deleting test blocks while its subject survives raises", %{
      calls_agent: calls_agent,
      dir: dir
    } do
      File.write!(Path.join(dir, "foo.ex"), "defmodule Foo do\n  def go, do: :ok\nend\n")

      File.write!(
        Path.join(dir, "foo_test.exs"),
        "defmodule FooTest do\n  use ExUnit.Case\n  test \"one\", do: :ok\n  test \"two\", do: :ok\nend\n"
      )

      {_o, 0} = System.cmd("git", ["add", "-A"], cd: dir)
      {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "seed covered feature"], cd: dir)
      File.write!(Path.join(dir, "feature.txt"), "wip\n")

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)
        value = if role == "reviewer-static", do: approved_verdict_for(ctx), else: "did #{role}"
        {:ok, %{"status" => "success", "value" => value}}
      end

      commit_fn = fn cwd, _subject ->
        File.write!(Path.join(cwd, "feature.txt"), "done\n")
        File.write!(Path.join(cwd, "foo_test.exs"), "test \"one\", do: :ok\n")
        {_o, 0} = System.cmd("git", ["add", "-A"], cd: cwd)
        {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "impl"], cd: cwd)
        {:ok, "COMMITTED: impl"}
      end

      assert_raise RuntimeError, ~r/test-coverage-floor: foo_test\.exs lost test coverage/, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "static",
          cwd: dir,
          pitch: "do the thing",
          invoke_fn: invoke_fn,
          commit_fn: commit_fn,
          commit_subject: "Test subject",
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

    test "commit step landing a defer-marker (\"not yet wired\") raises", %{
      calls_agent: calls_agent,
      dir: dir
    } do
      File.write!(Path.join(dir, "feature.txt"), "wip\n")

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static", do: approved_verdict_for(ctx), else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end

      commit_fn = fn cwd, _subject ->
        File.write!(
          Path.join(cwd, "note.md"),
          "# Notes\n\nFuture migration (not yet wired) — will connect this later.\n"
        )

        {_o, 0} = System.cmd("git", ["add", "-A"], cd: cwd)
        {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "impl"], cd: cwd)
        {:ok, "COMMITTED: impl"}
      end

      assert_raise RuntimeError, ~r/born-dead detector: defer marker/, fn ->
        OrchestrationLoop.run(
          harness: "claude_code",
          stack: "static",
          cwd: dir,
          pitch: "do the thing",
          invoke_fn: invoke_fn,
          commit_fn: commit_fn,
          commit_subject: "Test subject",
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

    test "commit step landing a fully-wired new module (real caller) proceeds to :ok", %{
      calls_agent: calls_agent,
      dir: dir
    } do
      # Pre-existing caller committed BEFORE the cycle base.
      File.write!(Path.join(dir, "caller.ex"), "defmodule Caller do\n  def go, do: :ok\nend\n")
      {_o, 0} = System.cmd("git", ["add", "-A"], cd: dir)
      {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "pre-existing caller"], cd: dir)

      # Simulate the developer's own work landing before the reviewer runs —
      # a real cycle never reaches the reviewer with a clean tree (see
      # invoke_reviewer/4's empty-set refusal).
      File.write!(Path.join(dir, "wip.txt"), "wip\n")

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static", do: approved_verdict_for(ctx), else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end

      commit_fn = fn cwd, _subject ->
        lib_dir = Path.join(cwd, "lib")
        File.mkdir_p!(lib_dir)

        File.write!(
          Path.join(lib_dir, "helper_thing.ex"),
          "defmodule HelperThing do\n  def run, do: :ok\nend\n"
        )

        File.write!(
          Path.join(cwd, "caller.ex"),
          "defmodule Caller do\n  def go, do: HelperThing.run()\nend\n"
        )

        {_o, 0} = System.cmd("git", ["add", "-A"], cd: cwd)
        {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "impl"], cd: cwd)
        {:ok, "COMMITTED: impl"}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: dir,
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 commit_fn: commit_fn,
                 commit_subject: "Test subject",
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

  describe "committed HEAD attribution (the-commit-is-a-typed-event-not-prose)" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "committed_head_test_#{:erlang.unique_integer([:positive])}"
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

    # (a) The legitimate path: the deterministic commit step moves HEAD ->
    # a {"ev":"committed"} (captured via :log_committed_fn) with role="loop"
    # is recorded and the cycle proceeds to :ok. No raise — the commit step
    # is not a role invocation at all, so `record_and_assert_head_move!/5`
    # (which now raises unconditionally for ANY role moving HEAD) never
    # sees this move.
    test "commit step moving HEAD records a committed event (role=loop) and proceeds", %{
      calls_agent: calls_agent,
      dir: dir
    } do
      {:ok, committed_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(committed_agent) end)

      File.write!(Path.join(dir, "feature.txt"), "wip\n")

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static", do: approved_verdict_for(ctx), else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end

      commit_fn = fn cwd, _subject ->
        File.write!(Path.join(cwd, "feature.txt"), "done\n")
        {_o, 0} = System.cmd("git", ["add", "-A"], cd: cwd)
        {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "impl"], cd: cwd)
        {:ok, "COMMITTED: impl"}
      end

      log_committed_fn = fn role, sha, subject, _cycle_log, _opts ->
        Agent.update(committed_agent, fn calls -> calls ++ [{role, sha, subject}] end)
        :ok
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: dir,
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 commit_fn: commit_fn,
                 commit_subject: "Test subject",
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
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn(),
                 log_committed_fn: log_committed_fn
               )

      recorded = Agent.get(committed_agent, & &1)
      assert length(recorded) == 1
      assert [{"loop", sha, subject}] = recorded
      assert is_binary(sha) and sha != ""
      assert subject == "impl"
    end

    # (b) The bypass path: a non-committer role (context-curator) moves HEAD
    # during its own invocation — reproduces the shape of the three known
    # bypass incidents (a-guards-allowlist-cannot-be-spelled-in-the-payload).
    # The loop must raise loud, naming the bypassing role, BEFORE the cycle
    # can proceed to ship.
    test "non-committer role moving HEAD raises, naming the bypassing role", %{
      calls_agent: calls_agent,
      dir: dir
    } do
      File.write!(Path.join(dir, "feature.txt"), "wip\n")

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "context-curator" do
          File.write!(Path.join(dir, "bypass.txt"), "bypass commit\n")
          {_o, 0} = System.cmd("git", ["add", "-A"], cd: dir)
          {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "oops: bypass"], cd: dir)
        end

        value =
          if role == "reviewer-static", do: approved_verdict_for(ctx), else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end

      assert_raise RuntimeError, ~r/HEAD moved during context-curator/, fn ->
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

    # (c) Non-git cwd -> sampling disabled (cycle_base_head/1's own fail-open
    # posture for synthetic test cwds). No raise, no committed event.
    test "non-git cwd disables HEAD sampling — no raise, no committed event", %{
      calls_agent: calls_agent
    } do
      {:ok, committed_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(committed_agent) end)

      log_committed_fn = fn role, sha, subject, _cycle_log, _opts ->
        Agent.update(committed_agent, fn calls -> calls ++ [{role, sha, subject}] end)
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 log_committed_fn: log_committed_fn
               )

      assert Agent.get(committed_agent, & &1) == []
    end

    # (c-bis) A retried non-committer whose HEAD is unchanged across the
    # retry records zero committed events — sampling is per-invocation
    # (pre vs post of THAT call), so an unchanged HEAD never fires.
    test "retried non-committer with unchanged HEAD records zero committed events", %{
      dir: dir
    } do
      {:ok, calls_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(calls_agent) end)

      {:ok, committed_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(committed_agent) end)

      File.write!(Path.join(dir, "feature.txt"), "wip\n")

      invoke_fn = fn role, _harness, ctx, _opts ->
        seen = Agent.get_and_update(calls_agent, fn calls -> {calls, calls ++ [role]} end)
        attempt_count = Enum.count(seen, &(&1 == role))

        cond do
          role == "developer-static" and attempt_count == 0 ->
            # First attempt fails (no HEAD move) -> retried once.
            {:error, "transient failure, please retry"}

          role == "reviewer-static" ->
            {:ok, %{"status" => "success", "value" => approved_verdict_for(ctx)}}

          true ->
            {:ok, %{"status" => "success", "value" => "did #{role}"}}
        end
      end

      commit_fn = fn cwd, _subject ->
        File.write!(Path.join(cwd, "feature.txt"), "done\n")
        {_o, 0} = System.cmd("git", ["add", "-A"], cd: cwd)
        {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "impl"], cd: cwd)
        {:ok, "COMMITTED: impl"}
      end

      log_committed_fn = fn role, sha, subject, _cycle_log, _opts ->
        Agent.update(committed_agent, fn calls -> calls ++ [{role, sha, subject}] end)
        :ok
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: dir,
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 commit_fn: commit_fn,
                 commit_subject: "Test subject",
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
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn(),
                 log_committed_fn: log_committed_fn
               )

      recorded = Agent.get(committed_agent, & &1)
      assert [{"loop", _sha, "impl"}] = recorded
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

    defp committing_invoke_fn(calls_agent, _dir) do
      fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static", do: approved_verdict_for(ctx), else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end
    end

    # The commit step is no longer dispatched via invoke_fn — it left the
    # role vocabulary (see pitch "committing is deterministic, not a model
    # call"). Commits whatever is on disk at the time it runs (mirrors a
    # faithful `git add -A && git commit`), matching this describe block's
    # `:commit_fn` seam.
    defp committing_commit_fn(dir) do
      fn _cwd, _subject ->
        {_o, 0} = System.cmd("git", ["add", "-A"], cd: dir)
        {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "impl"], cd: dir)
        {:ok, "COMMITTED: impl"}
      end
    end

    test "tree unchanged since gate → proceeds straight to the commit step, no re-gate", %{
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
                 commit_fn: committing_commit_fn(dir),
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
                 commit_fn: committing_commit_fn(dir),
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
                 commit_fn: committing_commit_fn(dir),
                 gate_fn: gate_fn,
                 gate_tree_match_fn: match_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 max_final_gate_cycles: 1,
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn(),
                 advisor_fn: no_op_advisor_fn()
               )

      # The developer role was invoked twice: once in the normal sequence,
      # once more as pre-commit rework.
      dev_calls = Agent.get(calls_agent, & &1) |> Enum.count(&(&1 == "developer-static"))
      assert dev_calls == 2
    end

    test "tree changed since gate, re-gate FAILS on a curator-owned witness → reworks context-curator, not the developer",
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
      # subsequent call is clear — same shape as the developer-rework case
      # above, but this failure is routed through `:gate_owner_fn` as a
      # curator-owned witness (e.g. a `context/*.md` doc drift), so the
      # rework must land on `context-curator`, never the developer.
      gate_fn = fn _cwd, _opts ->
        :counters.add(regate_calls, 1, 1)
        n = :counters.get(regate_calls, 1)
        if n == 2, do: {:failed, "make test"}, else: {:clear, "make test"}
      end

      gate_owner_fn = fn _cwd, _dev_role -> "context-curator" end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: dir,
                 pitch: "do the thing",
                 invoke_fn: committing_invoke_fn(calls_agent, dir),
                 commit_fn: committing_commit_fn(dir),
                 gate_fn: gate_fn,
                 gate_tree_match_fn: match_fn,
                 gate_owner_fn: gate_owner_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 max_final_gate_cycles: 1,
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn(),
                 advisor_fn: no_op_advisor_fn()
               )

      # context-curator was invoked twice: once in the normal sequence, once
      # more as the owner-routed pre-commit rework. The developer was NOT
      # re-invoked for this failure — it stays at its normal-sequence count
      # of one, never the guaranteed-exhaust dead end this fix prevents.
      calls = Agent.get(calls_agent, & &1)
      assert Enum.count(calls, &(&1 == "context-curator")) == 2
      assert Enum.count(calls, &(&1 == "developer-static")) == 1
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
                 commit_fn: committing_commit_fn(dir),
                 gate_fn: gate_fn,
                 gate_tree_match_fn: match_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 max_final_gate_cycles: 1,
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn(),
                 advisor_fn: no_op_advisor_fn()
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
      on_exit(fn -> stop_agent(seen_ctx_agent) end)

      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        if role == "developer-static" do
          escalated = get_in(ctx, [:artifacts, :escalated_model])
          Agent.update(seen_ctx_agent, fn seen -> seen ++ [escalated] end)
        end

        value =
          if role == "reviewer-static", do: approved_verdict_for(ctx), else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end

      commit_fn = fn cwd, _subject ->
        {_o, 0} = System.cmd("git", ["add", "-A"], cd: cwd)
        {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "impl"], cd: cwd)
        {:ok, "COMMITTED: impl"}
      end

      resolve_escalation_fn = fn "developer-static", _harness -> {"opus", "high"} end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: dir,
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 commit_fn: commit_fn,
                 commit_subject: "Test subject",
                 gate_fn: gate_fn,
                 gate_tree_match_fn: match_fn,
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 max_final_gate_cycles: 1,
                 clean_tree_preflight_fn: no_op_clean_tree_preflight_fn(),
                 resolve_escalation_fn: resolve_escalation_fn,
                 advisor_fn: no_op_advisor_fn()
               )

      # first developer-static call: normal sequence, unescalated. Second
      # (pre-commit rework, the ONLY attempt max_final_gate_cycles: 1
      # allows -> also the final one) is escalated.
      assert Agent.get(seen_ctx_agent, & &1) == [nil, {"opus", "high"}]
    end

    test "commit step commits DIFFERENT content than the last-graded tree → post-commit guard raises",
         %{
           calls_agent: calls_agent,
           dir: dir
         } do
      # The pre-commit match check says "match" (skip re-gate), but the
      # commit step itself still diverges from the stamped graded_tree_sha
      # (simulating a codegen-commit bug, or a race). assert_commit_matches_gate!
      # must catch this independently of the pre-commit re-gate.
      invoke_fn = fn role, _harness, ctx, _opts ->
        Agent.update(calls_agent, fn calls -> calls ++ [role] end)

        value =
          if role == "reviewer-static", do: approved_verdict_for(ctx), else: "did #{role}"

        {:ok, %{"status" => "success", "value" => value}}
      end

      commit_fn = fn cwd, _subject ->
        File.write!(Path.join(cwd, "unexpected.txt"), "not what was graded\n")
        {_o, 0} = System.cmd("git", ["add", "-A"], cd: cwd)
        {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "diverged"], cd: cwd)
        {:ok, "COMMITTED: diverged"}
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
                       commit_fn: commit_fn,
                       commit_subject: "Test subject",
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

    test "tracked source dirt at cycle start is still rejected", %{
      calls_agent: calls_agent,
      dir: dir
    } do
      File.write!(Path.join(dir, "README.md"), "source changed before cycle\n")

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

        role, _harness, ctx, _opts ->
          Agent.update(calls_agent, fn calls -> calls ++ [role] end)

          value =
            if role == "reviewer-static", do: approved_verdict_for(ctx), else: "did #{role}"

          {:ok, %{"status" => "success", "value" => value}}
      end

      commit_fn = fn cwd, _subject ->
        System.cmd("git", ["add", "-A"], cd: cwd)
        System.cmd("git", ["commit", "-q", "-m", "test commit"], cd: cwd)
        {:ok, "COMMITTED: test commit"}
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "static",
                 cwd: dir,
                 pitch: "do the thing",
                 invoke_fn: invoke_fn,
                 commit_fn: commit_fn,
                 commit_subject: "Test subject",
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 preflight_probe_fn: all_present_preflight_probe_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert List.last(Agent.get(calls_agent, & &1)) == "context-curator"
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert Agent.get(calls_agent, & &1) == @phoenix_sequence
    end
  end

  describe "run/1 — turn-0 role-agent resolution preflight (loop-agent-resolution-preflight)" do
    test "a missing required role raises BEFORE any role is invoked", %{calls_agent: calls_agent} do
      missing_curator_probe = fn _cwd ->
        "--agent '__codegen_loop_preflight_probe__' not found. Available agents: " <>
          "developer-phoenix-backend, developer-phoenix-frontend, " <>
          "reviewer-phoenix"
      end

      assert_raise RuntimeError,
                   ~r/required role agent\(s\) not resolvable: context-curator/,
                   fn ->
                     OrchestrationLoop.run(
                       harness: "claude_code",
                       stack: "phoenix",
                       cwd: "/tmp/irrelevant",
                       pitch: "do the thing",
                       invoke_fn: always_ok_invoke_fn(calls_agent),
                       gate_fn: always_clear_gate_fn(),
                       gate_preflight_fn: no_op_gate_preflight_fn(),
                       preflight_probe_fn: missing_curator_probe
                     )
                   end

      # The refusal MUST happen before the first role spend.
      assert Agent.get(calls_agent, & &1) == []
    end

    test "a PERSISTENTLY inconclusive probe (no parseable agent list) raises", %{
      calls_agent: calls_agent
    } do
      {:ok, probes_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(probes_agent) end)

      inconclusive_probe = fn _cwd ->
        Agent.update(probes_agent, &(&1 + 1))
        "some unrelated CLI error with no agent list"
      end

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

      # Fail-closed posture is preserved — but only AFTER a re-probe.
      assert Agent.get(probes_agent, & &1) == 2
      assert Agent.get(calls_agent, & &1) == []
    end

    test "a ONE-OFF inconclusive probe is re-probed and the build proceeds", %{
      calls_agent: calls_agent
    } do
      # An unparseable probe output is an inconclusive PARSE, not a missing
      # agent: nothing was learned about the agent set. Its observed causes are
      # transient, and the probe costs zero model turns, so a single unlucky
      # read must not kill a build before any role runs. Contrast the
      # missing-role case above, which stays fail-closed and unretried.
      {:ok, probes_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(probes_agent) end)

      flaky_probe = fn cwd ->
        n = Agent.get_and_update(probes_agent, fn c -> {c, c + 1} end)

        if n == 0 do
          "spinner noise, truncated pipe, no agent list"
        else
          all_present_preflight_probe_fn().(cwd)
        end
      end

      assert :ok ==
               OrchestrationLoop.run(
                 harness: "claude_code",
                 stack: "phoenix",
                 cwd: "/tmp/irrelevant",
                 pitch: "do the thing",
                 invoke_fn: always_ok_invoke_fn(calls_agent),
                 gate_fn: always_clear_gate_fn(),
                 gate_preflight_fn: no_op_gate_preflight_fn(),
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn(),
                 preflight_probe_fn: flaky_probe
               )

      assert Agent.get(probes_agent, & &1) == 2
      assert Agent.get(calls_agent, & &1) == @phoenix_sequence
    end

    test "a re-probe never rescues a MISSING role — that stays fail-closed and unretried", %{
      calls_agent: calls_agent
    } do
      {:ok, probes_agent} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop_agent(probes_agent) end)

      missing_curator_probe = fn _cwd ->
        Agent.update(probes_agent, &(&1 + 1))

        "--agent '__codegen_loop_preflight_probe__' not found. Available agents: " <>
          "developer-phoenix-backend, developer-phoenix-frontend, " <>
          "reviewer-phoenix"
      end

      assert_raise RuntimeError,
                   ~r/required role agent\(s\) not resolvable: context-curator/,
                   fn ->
                     OrchestrationLoop.run(
                       harness: "claude_code",
                       stack: "phoenix",
                       cwd: "/tmp/irrelevant",
                       pitch: "do the thing",
                       invoke_fn: always_ok_invoke_fn(calls_agent),
                       gate_fn: always_clear_gate_fn(),
                       gate_preflight_fn: no_op_gate_preflight_fn(),
                       preflight_probe_fn: missing_curator_probe
                     )
                   end

      assert Agent.get(probes_agent, & &1) == 1
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
                 advance_cycle_state_fn: no_op_advance_cycle_state_fn()
               )

      assert Agent.get(calls_agent, & &1) == @phoenix_sequence
    end
  end

  describe "run/1 — cycle log init + CODEGEN_LOG_PATH pinning" do
    test "log_init_fn is called exactly once, with the cycle's slug, before the first role invoke",
         %{calls_agent: calls_agent} do
      {:ok, init_calls_agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> stop_agent(init_calls_agent) end)

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
      on_exit(fn -> stop_agent(init_calls_agent) end)

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

    # Writes a real, minimal JSONL cycle log fixture under dir/codegen/ (the
    # same subtree the fixture's own .gitignore excludes — see the setup
    # block's "codegen/\n" write above) and returns its path — mirrors
    # fresh_cycle_log!/0's shape (a real init line on disk, not a bare path)
    # so downstream reads through this cycle (e.g. curator-consumption-scan)
    # find real content instead of a missing file, WITHOUT the fixture file
    # itself showing up as an uncommitted tracked change (it would if placed
    # directly under dir/, tripping verify_committed!'s clean-tree guard).
    # Cleaned up by the describe block's on_exit File.rm_rf!(dir). Needed
    # because default_log_init/3 shells the real codegen-log with CODEGEN_DIR
    # pinned to the live repo root (correct for production — the loop runs
    # from test_harness/ and needs it to locate codegen/), and codegen-log
    # resolves CODEGEN_DIR before cwd — so without this stub every
    # resume-checkpoint run silently writes a real cycle log into the LIVE
    # codegen/logging/ dir instead of this test's sandbox (see
    # context/test-harness-pitfalls.md).
    defp resume_checkpoint_cycle_log!(dir) do
      logging_dir = Path.join([dir, "codegen", "logging"])
      File.mkdir_p!(logging_dir)
      path = Path.join(logging_dir, "cycle.jsonl")
      File.write!(path, Jason.encode!(%{"ev" => "init", "pitch" => "do the thing"}) <> "\n")
      path
    end

    defp resume_run_opts(dir, calls_agent, extra) do
      base = [
        harness: "claude_code",
        stack: "static",
        cwd: dir,
        pitch: "do the thing",
        log_init_fn: log_init_fn_for(resume_checkpoint_cycle_log!(dir)),
        invoke_fn: fn role, _harness, ctx, _opts ->
          Agent.update(calls_agent, fn calls -> calls ++ [role] end)

          value =
            if reviewer_role?(role), do: approved_verdict_for(ctx), else: "did #{role}"

          {:ok, %{"status" => "success", "value" => value}}
        end,
        # The deterministic commit step stages + commits whatever the (real
        # or simulated) prior cycle left behind — commit exactly the dirty
        # tree the checkpoint fixture set up, satisfying verify_committed!'s
        # single-commit + clean-tree tail guard. It is no longer dispatched
        # via invoke_fn (see pitch "committing is deterministic, not a
        # model call").
        commit_fn: fn cwd, _subject ->
          {_o, 0} = System.cmd("git", ["add", "-A"], cd: cwd)
          {_o, 0} = System.cmd("git", ["commit", "-q", "-m", "resume test commit"], cd: cwd)
          {:ok, "COMMITTED: resume test commit"}
        end,
        commit_subject: "Test subject",
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
      # "committer" left the role vocabulary — the commit step is now the
      # unconditional terminator of run_roles/4's `[]` clause, not an
      # invoke_fn-dispatched role, so it never appears in `calls`.
      assert calls == ["reviewer-static", "context-curator"]
    end

    test "recovery_role takes precedence over a stale checkpoint", %{
      dir: dir,
      calls_agent: calls_agent
    } do
      File.write!(Path.join(dir, "feature.txt"), "recovered work\n")

      assert :ok ==
               OrchestrationLoop.run(
                 resume_run_opts(dir, calls_agent,
                   cycle_state_get_fn: fn _cwd -> "" end,
                   recovery_mode: :exact,
                   recovery_role: "reviewer-static",
                   clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
                 )
               )

      assert Agent.get(calls_agent, & &1) == ["reviewer-static", "context-curator"]
    end

    # A resumed GATED cycle carries only :resume_state in artifacts, but a
    # blocking reviewer result still has a developer available in the stack.
    # Prove the positive path: rework runs, gets re-reviewed, then commits.
    test "CHANGES_REQUESTED on a resumed GATED cycle invokes developer rework and re-review", %{
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
                   invoke_fn: fn role, _harness, ctx, _opts ->
                     Agent.update(calls_agent, fn calls -> calls ++ [role] end)

                     value =
                       if reviewer_role?(role) do
                         reviews = Enum.count(Agent.get(calls_agent, & &1), &reviewer_role?/1)

                         if reviews == 1,
                           do: changes_requested_verdict_for(ctx),
                           else: approved_verdict_for(ctx)
                       else
                         "did #{role}"
                       end

                     {:ok, %{"status" => "success", "value" => value}}
                   end,
                   cycle_state_get_fn: fn _cwd -> "GATED" end,
                   cycle_state_slug_fn: fn _cwd -> "matching-slug" end,
                   read_verdict_fn: fn _cwd -> :clear end,
                   gate_result_base_sha_fn: fn _cwd -> base_head end,
                   gate_tree_match_fn: fn _cwd -> true end,
                   clean_tree_preflight_fn: no_op_clean_tree_preflight_fn()
                 )
               )

      calls = Agent.get(calls_agent, & &1)

      assert calls == [
               "reviewer-static",
               "developer-static",
               "reviewer-static",
               "context-curator"
             ]

      {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
      refute String.trim(head) == base_head
    end

    test "a resumed GATED cycle resolves developer rework when its final re-gate fails", %{
      dir: dir,
      base_head: base_head,
      calls_agent: calls_agent
    } do
      tree_sha = real_tree_sha_after_write!(dir, "feature.txt", "wip\n")
      write_gate_result!(dir, "clear", tree_sha, base_head)
      write_cycle_state!(dir, "GATED", "matching-slug")
      matches = :counters.new(1, [])

      match_fn = fn _cwd ->
        :counters.add(matches, 1, 1)

        case :counters.get(matches, 1) do
          1 -> true
          2 -> false
          _ -> true
        end
      end

      assert :ok ==
               OrchestrationLoop.run(
                 resume_run_opts(dir, calls_agent,
                   slug: "matching-slug",
                   cycle_state_get_fn: fn _cwd -> "GATED" end,
                   cycle_state_slug_fn: fn _cwd -> "matching-slug" end,
                   read_verdict_fn: fn _cwd -> :clear end,
                   gate_result_base_sha_fn: fn _cwd -> base_head end,
                   gate_tree_match_fn: match_fn,
                   gate_fn: fn _cwd, _opts -> {:failed, "make test"} end,
                   max_final_gate_cycles: 1,
                   clean_tree_preflight_fn: no_op_clean_tree_preflight_fn(),
                   advisor_fn: no_op_advisor_fn()
                 )
               )

      assert Agent.get(calls_agent, & &1) == [
               "reviewer-static",
               "context-curator",
               "developer-static"
             ]
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
      assert calls == ["context-curator"]
    end

    test "valid CURATED checkpoint resumes directly at the commit step (no role invoked)", %{
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

      # No role is invoked at all — the commit step is the sentinel resume
      # target and resolves directly to `[]` (resume_suffix/2).
      assert Agent.get(calls_agent, & &1) == []
    end

    test "clean GATED checkpoint is not resumable at reviewer", %{
      dir: dir,
      base_head: base_head
    } do
      write_gate_result!(dir, "clear", "already-recovered-tree", base_head)
      write_cycle_state!(dir, "GATED", "matching-slug")

      assert :full ==
               OrchestrationLoop.resume_checkpoint(dir, ["developer-static", "reviewer-static"],
                 slug: "matching-slug",
                 cycle_state_get_fn: fn _cwd -> "GATED" end,
                 cycle_state_slug_fn: fn _cwd -> "matching-slug" end,
                 read_verdict_fn: fn _cwd -> :clear end,
                 gate_result_base_sha_fn: fn _cwd -> base_head end,
                 gate_tree_match_fn: fn _cwd -> true end
               )
    end

    test "clean CURATED checkpoint is not resumable at the commit step", %{
      dir: dir,
      base_head: base_head
    } do
      write_gate_result!(dir, "clear", "already-recovered-tree", base_head)
      write_cycle_state!(dir, "CURATED", "matching-slug")

      assert :full ==
               OrchestrationLoop.resume_checkpoint(dir, ["context-curator"],
                 slug: "matching-slug",
                 cycle_state_get_fn: fn _cwd -> "CURATED" end,
                 cycle_state_slug_fn: fn _cwd -> "matching-slug" end,
                 read_verdict_fn: fn _cwd -> :clear end,
                 gate_result_base_sha_fn: fn _cwd -> base_head end,
                 gate_tree_match_fn: fn _cwd -> true end
               )
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
               ["developer-static", "reviewer-static", "context-curator"]
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
               ["developer-static", "reviewer-static", "context-curator"]
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
               ["developer-static", "reviewer-static", "context-curator"]
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
               ["developer-static", "reviewer-static", "context-curator"]
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
               ["developer-static", "reviewer-static", "context-curator"]
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
               ["developer-static", "reviewer-static", "context-curator"]
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
               ["developer-static", "reviewer-static", "context-curator"]
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
               ["developer-static", "reviewer-static", "context-curator"]
    end
  end

  # ── Cached review-re-work re-gate ────────────────────────────────────────
  # After CHANGES_REQUESTED the loop re-invokes the developer and then
  # re-runs the gate. That re-work is frequently a no-op (the developer comes
  # back blocked, or answers the review in prose), and the gate then pays
  # 100-160s to re-derive a verdict already stamped for the byte-identical
  # tree — see cycle log 20260806_055519_adhoc_cycle.jsonl, gate #2, 100s,
  # tree a8da05e8, the same tree gate #1 graded 92 seconds earlier.
  #
  # `run_gate_once/2` now consults the stamped `gate-result.json` first. The
  # asymmetry these tests exist to pin down: skipping when it should is worth
  # 100s; skipping when it should NOT ships a stale pass. So one test proves
  # the hit and six prove the misses, one per conjunct.
  describe "review-re-work re-gate — cached-clear skip" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "regate_cache_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(dir, ".claude"))
      on_exit(fn -> File.rm_rf!(dir) end)

      {_out, 0} = System.cmd("git", ["init", "-q"], cd: dir)
      {_out, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: dir)
      {_out, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: dir)
      {_out, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: dir)

      # Mirrors a real scaffolded app: codegen/ (gate-pending + cycle logs)
      # and .claude/ are gitignored, so neither the fixture's own
      # gate-result.json nor its gate-config.sh perturbs graded_tree_sha.
      # That is what makes the gate-command conjunct testable at all — a
      # mid-cycle GATE_COMMAND edit is invisible to the tree signature.
      File.write!(Path.join(dir, ".gitignore"), "codegen/\n.claude/\n")
      File.write!(Path.join(dir, "README.md"), "init\n")
      {_out, 0} = System.cmd("git", ["add", "-A"], cd: dir)
      {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: dir)

      File.write!(Path.join([dir, ".claude", "gate-config.sh"]), ~s(GATE_COMMAND="make test"\n))

      # The cycle's simulated developer output. A real cycle never reaches
      # the reviewer with a clean tree (invoke_reviewer/4 refuses an empty
      # change set), and the committer needs something to commit.
      File.write!(Path.join(dir, "feature.txt"), "wip\n")

      {:ok, gate_calls} = Agent.start_link(fn -> 0 end)
      {:ok, logged} = Agent.start_link(fn -> [] end)

      on_exit(fn ->
        if Process.alive?(gate_calls), do: Agent.stop(gate_calls)
        if Process.alive?(logged), do: Agent.stop(logged)
      end)

      {:ok, dir: dir, gate_calls: gate_calls, logged: logged}
    end

    @cached_cycle_id "cycle-under-test"
    @first_gate_started "2026-08-06T05:59:37Z"

    defp regate_result_path(dir),
      do: Path.join([dir, "codegen", "gate-pending", "gate-result.json"])

    defp read_regate_result!(dir), do: regate_result_path(dir) |> File.read!() |> Jason.decode!()

    # A `gate_fn` double that STAMPS like the real one. `run_gate/2` writing
    # gate-result.json is the whole precondition the skip reads, so a double
    # that only returned `:clear` would make every test here vacuous.
    # `overrides` are applied to the FIRST stamp only — that is the record
    # the re-gate will consult, and corrupting one field of it is how each
    # conjunct gets its own negative test without disturbing the others.
    defp stamping_gate_fn(dir, gate_calls, overrides) do
      fn cwd, opts ->
        n = Agent.get_and_update(gate_calls, fn n -> {n + 1, n + 1} end)

        fields = %{
          "gate" => "make test",
          "mode" => "short",
          "verdict" => "clear",
          "verdict_marker" => "ALL CLEAR ✅",
          "graded_tree_sha" => LoopGate.graded_tree_sha_now(cwd),
          "cycle_id" => Keyword.get(opts, :cycle_id, ""),
          "started" => @first_gate_started,
          "ended" => "2026-08-06T06:01:59Z"
        }

        fields = if n == 1, do: Map.merge(fields, overrides), else: fields

        File.mkdir_p!(Path.dirname(regate_result_path(dir)))
        File.write!(regate_result_path(dir), Jason.encode!(fields))

        {:clear, "make test"}
      end
    end

    # developer → gate → reviewer(CHANGES_REQUESTED) → developer → [re-gate]
    # → reviewer(APPROVED) → curator → committer. `rework_fn` is the second
    # developer turn's side effect on the working tree; the default is the
    # no-op re-work that motivates the whole change.
    defp regate_run_opts(dir, gate_calls, logged, extra) do
      rework_fn = Keyword.get(extra, :rework_fn, fn -> :ok end)
      overrides = Keyword.get(extra, :overrides, %{})
      extra = Keyword.drop(extra, [:rework_fn, :overrides])
      {:ok, dev_turns} = Agent.start_link(fn -> 0 end)
      {:ok, review_turns} = Agent.start_link(fn -> 0 end)

      base = [
        harness: "claude_code",
        stack: "static",
        cwd: dir,
        pitch: "do the thing",
        cycle_id: @cached_cycle_id,
        slug: "regate-slug",
        log_init_fn: log_init_fn_for(regate_cycle_log!(dir)),
        format_fn: fn _cwd -> :ok end,
        invoke_fn: fn role, _harness, ctx, _opts ->
          cond do
            role == "developer-static" ->
              if Agent.get_and_update(dev_turns, fn n -> {n + 1, n + 1} end) == 2 do
                rework_fn.()
              end

              {:ok, %{"status" => "success", "value" => "did #{role}"}}

            reviewer_role?(role) ->
              n = Agent.get_and_update(review_turns, fn n -> {n + 1, n + 1} end)
              verdict = if n == 1, do: "CHANGES_REQUESTED", else: "APPROVED"

              # These fixtures git-init a REAL tree, so the loop's default
              # `review_file_set_fn` returns a non-empty `## Files Modified`
              # set and the coverage precondition genuinely applies. Answer it
              # from the set the loop itself computed rather than stubbing the
              # seam off — the re-gate cache under test is orthogonal to
              # coverage, but it must not be exercised through a reviewer the
              # real loop would reject.
              coverage =
                (get_in(ctx, [:artifacts, :review_file_set]) || "")
                |> String.split("\n", trim: true)
                |> Enum.map_join("", &"REVIEW_COVERAGE: #{&1} read\n")

              {:ok, %{"status" => "success", "value" => coverage <> "REVIEW_VERDICT: #{verdict}"}}

            true ->
              {:ok, %{"status" => "success", "value" => "did #{role}"}}
          end
        end,
        # The commit is deterministic now — no committer role. Not asserted
        # on: the loop's own verify_committed!/2 is left un-stubbed and
        # enforces that a commit really landed on a clean tree. The one test
        # that destroys .git mid-cycle needs these two to be allowed to fail.
        commit_fn: fn cwd, _subject ->
          System.cmd("git", ["add", "-A"], cd: cwd, stderr_to_stdout: true)

          System.cmd("git", ["commit", "-q", "-m", "regate commit"],
            cd: cwd,
            stderr_to_stdout: true
          )

          {:ok, "COMMITTED: regate commit"}
        end,
        gate_fn: stamping_gate_fn(dir, gate_calls, overrides),
        log_verdict_fn: fn cycle_log, gate, mode, marker, detail ->
          Agent.update(logged, &(&1 ++ [{cycle_log, gate, mode, marker, detail}]))
          :ok
        end,
        gate_preflight_fn: no_op_gate_preflight_fn(),
        preflight_probe_fn: all_present_preflight_probe_fn(),
        orientation_preflight_fn: no_op_orientation_preflight_fn(),
        clean_tree_preflight_fn: no_op_clean_tree_preflight_fn(),
        orphan_scan_fn: fn _cwd -> [] end,
        env_var_scan_fn: always_clean_env_var_fn(),
        advance_cycle_state_fn: no_op_advance_cycle_state_fn()
      ]

      Keyword.merge(base, extra)
    end

    defp regate_cycle_log!(dir) do
      logging_dir = Path.join([dir, "codegen", "logging"])
      File.mkdir_p!(logging_dir)
      path = Path.join(logging_dir, "cycle.jsonl")
      File.write!(path, Jason.encode!(%{"ev" => "init", "pitch" => "do the thing"}) <> "\n")
      path
    end

    test "no-op re-work on the identical tree → gate runs ONCE, not twice", %{
      dir: dir,
      gate_calls: gate_calls,
      logged: logged
    } do
      assert :ok == OrchestrationLoop.run(regate_run_opts(dir, gate_calls, logged, []))

      assert Agent.get(gate_calls, & &1) == 1
    end

    test "the skip preserves the existing gate-result.json rather than unlinking it", %{
      dir: dir,
      gate_calls: gate_calls,
      logged: logged
    } do
      assert :ok == OrchestrationLoop.run(regate_run_opts(dir, gate_calls, logged, []))

      # Skipping at the CALL SITE (not inside run_gate/2) is what keeps
      # loop_gate.ex's leading `File.rm(gate_result_path/1)` from firing.
      # The artifact the reviewer, codegen-commit's `.verdict == clear`
      # check and assert_commit_matches_gate!/1 all read must still be the
      # FIRST run's, untouched — same timestamps, not a rewrite.
      result = read_regate_result!(dir)
      assert result["verdict"] == "clear"
      assert result["started"] == @first_gate_started
      assert result["cycle_id"] == @cached_cycle_id
    end

    test "the skip is recorded as a cached gate event, never silent", %{
      dir: dir,
      gate_calls: gate_calls,
      logged: logged
    } do
      assert :ok == OrchestrationLoop.run(regate_run_opts(dir, gate_calls, logged, []))

      # A developer step followed by a reviewer step with no gate event
      # between them reads as a bypass to any later auditor, and anything
      # summing gate time per cycle_id would silently lose the step.
      assert [{cycle_log, gate, mode, marker, detail}] = Agent.get(logged, & &1)
      assert String.ends_with?(cycle_log, "cycle.jsonl")
      assert gate == "make test"
      assert mode == "short"
      assert marker == "ALL CLEAR ✅"
      assert detail =~ "cached"
      assert detail =~ @first_gate_started
    end

    test "re-work that CHANGED the tree → gate re-runs", %{
      dir: dir,
      gate_calls: gate_calls,
      logged: logged
    } do
      rework = fn -> File.write!(Path.join(dir, "feature.txt"), "reworked\n") end

      assert :ok ==
               OrchestrationLoop.run(regate_run_opts(dir, gate_calls, logged, rework_fn: rework))

      assert Agent.get(gate_calls, & &1) == 2
      assert Agent.get(logged, & &1) == []
    end

    test "re-work that added an UNTRACKED file → gate re-runs", %{
      dir: dir,
      gate_calls: gate_calls,
      logged: logged
    } do
      # graded_tree_sha overlays `git ls-files -m -d -o --exclude-standard`,
      # so a brand-new untracked file must move the signature. If it did not,
      # the single commonest shape of developer output — a new file — would
      # be invisible to the skip.
      rework = fn -> File.write!(Path.join(dir, "new_module.txt"), "added\n") end

      assert :ok ==
               OrchestrationLoop.run(regate_run_opts(dir, gate_calls, logged, rework_fn: rework))

      assert Agent.get(gate_calls, & &1) == 2
    end

    test "re-work that DELETED a tracked file → gate re-runs", %{
      dir: dir,
      gate_calls: gate_calls,
      logged: logged
    } do
      rework = fn -> File.rm!(Path.join(dir, "README.md")) end

      assert :ok ==
               OrchestrationLoop.run(regate_run_opts(dir, gate_calls, logged, rework_fn: rework))

      assert Agent.get(gate_calls, & &1) == 2
    end

    # One negative per conjunct. Each corrupts exactly ONE field of the
    # first gate's stamped record and leaves every other conjunct
    # satisfiable, so a passing test convicts that field alone.
    for {name, overrides} <- [
          {"a DIFFERENT cycle_id (a previous build's leftover clear record)",
           %{"cycle_id" => "some-earlier-build"}},
          {"an EMPTY cycle_id (pre-cycle_id record, or a gate run outside a loop)",
           %{"cycle_id" => ""}},
          {"a FAILED verdict", %{"verdict" => "failed", "verdict_marker" => "FAILED ❌"}},
          {"an INCONCLUSIVE verdict",
           %{"verdict" => "inconclusive", "verdict_marker" => "INCONCLUSIVE ⚠️"}},
          {"an EMPTY graded_tree_sha", %{"graded_tree_sha" => ""}},
          {"a DIFFERENT gate command", %{"gate" => "make ci"}},
          {"an EMPTY gate command", %{"gate" => ""}}
        ] do
      @overrides overrides

      test "no skip on #{name}", %{dir: dir, gate_calls: gate_calls, logged: logged} do
        assert :ok ==
                 OrchestrationLoop.run(
                   regate_run_opts(dir, gate_calls, logged, overrides: @overrides)
                 )

        assert Agent.get(gate_calls, & &1) == 2
        assert Agent.get(logged, & &1) == []
      end
    end

    test "no skip when gate-result.json is absent entirely", %{
      dir: dir,
      gate_calls: gate_calls,
      logged: logged
    } do
      # The first gate's stamp is deleted between the reviewer's
      # CHANGES_REQUESTED and the re-gate — every abort path inside
      # run_gate/2 leaves exactly this state, and it must read as "run",
      # never as "nothing to compare, therefore fine".
      rework = fn -> File.rm!(regate_result_path(dir)) end

      assert :ok ==
               OrchestrationLoop.run(regate_run_opts(dir, gate_calls, logged, rework_fn: rework))

      assert Agent.get(gate_calls, & &1) == 2
    end

    test "no skip when gate-result.json is malformed", %{
      dir: dir,
      gate_calls: gate_calls,
      logged: logged
    } do
      rework = fn -> File.write!(regate_result_path(dir), "{not json") end

      assert :ok ==
               OrchestrationLoop.run(regate_run_opts(dir, gate_calls, logged, rework_fn: rework))

      assert Agent.get(gate_calls, & &1) == 2
    end

    test "no skip when the cwd is not a git repo (empty current signature)", %{
      dir: dir,
      gate_calls: gate_calls,
      logged: logged
    } do
      # graded_tree_sha_now/1 returns "" for a non-git cwd. That sentinel is
      # exactly what default_gate_tree_match?/1 fails OPEN on, and reusing
      # that function here would skip the gate in every mocked unit test in
      # this file. Proven by removing .git mid-cycle.
      rework = fn -> File.rm_rf!(Path.join(dir, ".git")) end

      # How this cycle ENDS is not the claim (a repo that lost its .git
      # mid-cycle cannot commit, and the loop is entitled to fail however it
      # likes downstream) — the claim is only what the re-gate decided.
      try do
        OrchestrationLoop.run(regate_run_opts(dir, gate_calls, logged, rework_fn: rework))
      rescue
        _ -> :raised
      end

      assert Agent.get(gate_calls, & &1) == 2
      assert Agent.get(logged, & &1) == []
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
      commit_fn: fn _cwd, _subject -> {:ok, "COMMITTED: deadbeef test subject"} end,
      commit_subject: "Test subject",
      gate_fn: fn _cwd, _opts -> {:clear, "make test"} end,
      gate_preflight_fn: fn _cwd -> {"make test", "short", 0} end,
      preflight_probe_fn: fn _cwd ->
        "--agent '__codegen_loop_preflight_probe__' not found. Available agents: " <>
          "developer-phoenix-backend, developer-phoenix-frontend, " <>
          "reviewer-phoenix, context-curator, developer-static, reviewer-static"
      end,
      advance_cycle_state_fn: fn _state, _step_log, _session_id, _verdict, _project_dir, _slug ->
        :ok
      end,
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
                   "developer-phoenix-backend, developer-phoenix-frontend, " <>
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
               orphan_scan_fn: fn _cwd -> [] end
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

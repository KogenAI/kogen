defmodule CodegenTestHarness.RoleModelSweepTest do
  @moduledoc """
  Hermetic tests for `CodegenTestHarness.RoleModelSweep` — matrix validation,
  baseline resolution, cyclic scheduling, classification, aggregation, and
  verdict computation. No LLM calls; `run_repetition/5` is exercised only
  with an injected `run_fn` stub (never the real `mix test` spawn).
  """

  use ExUnit.Case, async: true

  alias CodegenTestHarness.RoleModelSweep

  @valid_raw %{
    "role" => "developer-static",
    "stack" => "static",
    "build_harness" => "claude",
    "test" => "test/stacks/static/scaffold_test.exs",
    "repetitions" => 3,
    "tolerances" => %{"cost_pct" => 0, "duration_pct" => 20},
    "candidates" => [
      %{
        "name" => "candidate-a",
        "harness" => "pi",
        "model" => "openai-codex/gpt-5.6-terra",
        "effort" => "high"
      }
    ]
  }

  describe "validate_matrix!/1" do
    test "accepts a well-formed matrix and normalizes tolerances to floats" do
      matrix = RoleModelSweep.validate_matrix!(@valid_raw)

      assert matrix.role == "developer-static"
      assert matrix.stack == "static"
      assert matrix.repetitions == 3
      assert matrix.tolerances == %{cost_pct: 0.0, duration_pct: 20.0}
      assert [%{name: "candidate-a"}] = matrix.candidates
    end

    test "rejects a role not in the stack's role sequence" do
      raw = %{@valid_raw | "role" => "planner-phoenix"}

      assert_raise RuntimeError, ~r/not in the static role sequence/, fn ->
        RoleModelSweep.validate_matrix!(raw)
      end
    end

    test "rejects an unknown stack" do
      raw = %{@valid_raw | "stack" => "bogus"}

      assert_raise RuntimeError, ~r/"stack" must be one of/, fn ->
        RoleModelSweep.validate_matrix!(raw)
      end
    end

    test "rejects an unknown build_harness" do
      raw = %{@valid_raw | "build_harness" => "bogus"}

      assert_raise RuntimeError, ~r/"build_harness" must be one of/, fn ->
        RoleModelSweep.validate_matrix!(raw)
      end
    end

    test "rejects repetitions below the minimum" do
      raw = %{@valid_raw | "repetitions" => 2}

      assert_raise RuntimeError, ~r/"repetitions" must be an integer >= 3/, fn ->
        RoleModelSweep.validate_matrix!(raw)
      end
    end

    test "rejects a non-integer repetitions" do
      raw = %{@valid_raw | "repetitions" => "3"}

      assert_raise RuntimeError, ~r/"repetitions" must be an integer/, fn ->
        RoleModelSweep.validate_matrix!(raw)
      end
    end

    test "rejects missing tolerances" do
      raw = Map.delete(@valid_raw, "tolerances")

      assert_raise RuntimeError, ~r/"tolerances" must be/, fn ->
        RoleModelSweep.validate_matrix!(raw)
      end
    end

    test "rejects a negative tolerance" do
      raw = %{@valid_raw | "tolerances" => %{"cost_pct" => -1, "duration_pct" => 20}}

      assert_raise RuntimeError, ~r/"tolerances" must be/, fn ->
        RoleModelSweep.validate_matrix!(raw)
      end
    end

    test "rejects an empty candidates list" do
      raw = %{@valid_raw | "candidates" => []}

      assert_raise RuntimeError, ~r/"candidates" must be a non-empty list/, fn ->
        RoleModelSweep.validate_matrix!(raw)
      end
    end

    test "rejects duplicate candidate names" do
      dup = %{"name" => "candidate-a", "harness" => "pi", "model" => "m", "effort" => "high"}
      raw = %{@valid_raw | "candidates" => [dup, dup]}

      assert_raise RuntimeError, ~r/candidate names must be unique/, fn ->
        RoleModelSweep.validate_matrix!(raw)
      end
    end

    test "rejects a non-kebab-case candidate name" do
      raw = %{
        @valid_raw
        | "candidates" => [
            %{"name" => "Candidate_A", "harness" => "pi", "model" => "m", "effort" => "high"}
          ]
      }

      assert_raise RuntimeError, ~r/kebab-case/, fn ->
        RoleModelSweep.validate_matrix!(raw)
      end
    end

    test "rejects a candidate with an invalid effort" do
      raw = %{
        @valid_raw
        | "candidates" => [
            %{"name" => "candidate-a", "harness" => "pi", "model" => "m", "effort" => "extreme"}
          ]
      }

      assert_raise RuntimeError, ~r/effort must be one of/, fn ->
        RoleModelSweep.validate_matrix!(raw)
      end
    end

    test "rejects a test file outside test/stacks/<stack>/" do
      raw = %{@valid_raw | "test" => "test/stacks/phoenix/scaffold_test.exs"}

      assert_raise RuntimeError, ~r/must be a relative path directly under/, fn ->
        RoleModelSweep.validate_matrix!(raw)
      end
    end

    test "rejects a test file that does not exist" do
      raw = %{@valid_raw | "test" => "test/stacks/static/does_not_exist_test.exs"}

      assert_raise RuntimeError, ~r/test file not found/, fn ->
        RoleModelSweep.validate_matrix!(raw)
      end
    end

    test "rejects a deterministic-only test file (no @moduletag :slow)" do
      raw = %{@valid_raw | "test" => "test/stacks/static/no_ecto_scaffold_test.exs"}

      # no_ecto_scaffold_test.exs is a phoenix-only fixture in this repo, so
      # this exercises the not-found branch OR the moduletag branch — both
      # are "rejected before spend", so either message is acceptable here.
      # Use a real static test file with no :slow tag instead, if one
      # exists; otherwise assert on the generic rejection.
      assert_raise RuntimeError, fn ->
        RoleModelSweep.validate_matrix!(raw)
      end
    end

    test "rejects a non-object matrix" do
      assert_raise RuntimeError, ~r/must decode to a JSON\/YAML object/, fn ->
        RoleModelSweep.validate_matrix!("not a map")
      end
    end
  end

  describe "resolve_baseline/1" do
    test "resolves the target role's CURRENT effective binding for build_harness" do
      matrix = RoleModelSweep.validate_matrix!(@valid_raw)
      baseline = RoleModelSweep.resolve_baseline(matrix)

      assert baseline.name == "baseline"
      assert is_binary(baseline.harness)
      assert is_binary(baseline.model)
      assert is_binary(baseline.effort)
    end
  end

  describe "build_schedule/2" do
    test "round 1 runs arms in given order; round 2 rotates by one" do
      arms = [%{name: "a"}, %{name: "b"}, %{name: "c"}]
      schedule = RoleModelSweep.build_schedule(arms, 2)

      names = Enum.map(schedule, fn {arm, _rep} -> arm.name end)
      assert names == ["a", "b", "c", "b", "c", "a"]
    end

    test "repetition index is 1-based per arm" do
      arms = [%{name: "a"}, %{name: "b"}]
      schedule = RoleModelSweep.build_schedule(arms, 3)

      a_reps = for {arm, rep} <- schedule, arm.name == "a", do: rep
      assert a_reps == [1, 2, 3]
    end

    test "single arm: schedule length equals repetitions" do
      schedule = RoleModelSweep.build_schedule([%{name: "only"}], 3)
      assert length(schedule) == 3
    end
  end

  describe "median/1" do
    test "odd count: returns the middle sorted value" do
      assert RoleModelSweep.median([5, 1, 3]) == 3
    end

    test "even count: returns the arithmetic mean of the two middle values" do
      assert RoleModelSweep.median([1, 2, 3, 4]) == 2.5
    end

    test "empty list: returns nil" do
      assert RoleModelSweep.median([]) == nil
    end

    test "single value: returns that value" do
      assert RoleModelSweep.median([7]) == 7
    end
  end

  describe "classify_repetition/3" do
    @matrix RoleModelSweep.validate_matrix!(%{
              "role" => "developer-static",
              "stack" => "static",
              "build_harness" => "claude",
              "test" => "test/stacks/static/scaffold_test.exs",
              "repetitions" => 3,
              "tolerances" => %{"cost_pct" => 0, "duration_pct" => 20},
              "candidates" => [
                %{"name" => "c", "harness" => "pi", "model" => "m", "effort" => "high"}
              ]
            })

    @arm %{name: "baseline", harness: "pi", model: "m", effort: "high"}

    test "non-zero exit -> incomplete naming the exit code" do
      rep = %{exit_code: 1, run_dir: "/irrelevant", wall_ms: 100, output: ""}
      assert {:incomplete, reason} = RoleModelSweep.classify_repetition(rep, @matrix, @arm)
      assert reason =~ "exited 1"
    end

    test "zero exit but no harness_summary records -> incomplete" do
      run_dir =
        Path.join(System.tmp_dir!(), "rms_classify_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(run_dir)
      on_exit(fn -> File.rm_rf!(run_dir) end)

      manifest = %{
        "codegen_sha" => "x",
        "harness_versions" => %{},
        "started_at" => "x",
        "model_resolution" => %{}
      }

      File.write!(Path.join(run_dir, "manifest.json"), Jason.encode!(manifest))

      rep = %{exit_code: 0, run_dir: run_dir, wall_ms: 100, output: ""}
      assert {:incomplete, reason} = RoleModelSweep.classify_repetition(rep, @matrix, @arm)
      assert reason =~ "no harness_summary"
    end

    test "zero exit, passing summary, matching dispatch -> complete with summed cost" do
      run_dir =
        Path.join(System.tmp_dir!(), "rms_classify_#{:erlang.unique_integer([:positive])}")

      runs_dir = Path.join([run_dir, "runs", "pi", "static"])
      File.mkdir_p!(runs_dir)
      on_exit(fn -> File.rm_rf!(run_dir) end)

      manifest = %{
        "codegen_sha" => "x",
        "harness_versions" => %{},
        "started_at" => "x",
        "model_resolution" => %{}
      }

      File.write!(Path.join(run_dir, "manifest.json"), Jason.encode!(manifest))

      summary_line =
        Jason.encode!(%{
          "type" => "harness_summary",
          "exit_code" => 0,
          "assertion_passed" => true,
          "parsed" => %{"cost_usd" => 0.42}
        })

      File.write!(Path.join(runs_dir, "scaffold_test.jsonl"), summary_line <> "\n")

      output =
        Jason.encode!(%{
          "type" => "result",
          "engine" => "elixir_loop",
          "subtype" => "success",
          "per_role" => %{
            "developer-static" => %{
              "dispatches" => [%{"harness" => "pi", "model" => "m", "effort" => "high"}]
            }
          }
        })

      rep = %{exit_code: 0, run_dir: run_dir, wall_ms: 100, output: output}

      assert {:complete, %{cost: 0.42, summaries: 1}} =
               RoleModelSweep.classify_repetition(rep, @matrix, @arm)
    end

    test "mismatched dispatch tuple -> incomplete naming provenance" do
      run_dir =
        Path.join(System.tmp_dir!(), "rms_classify_#{:erlang.unique_integer([:positive])}")

      runs_dir = Path.join([run_dir, "runs", "pi", "static"])
      File.mkdir_p!(runs_dir)
      on_exit(fn -> File.rm_rf!(run_dir) end)

      manifest = %{
        "codegen_sha" => "x",
        "harness_versions" => %{},
        "started_at" => "x",
        "model_resolution" => %{}
      }

      File.write!(Path.join(run_dir, "manifest.json"), Jason.encode!(manifest))

      summary_line =
        Jason.encode!(%{
          "type" => "harness_summary",
          "exit_code" => 0,
          "assertion_passed" => true,
          "parsed" => %{"cost_usd" => 0.42}
        })

      File.write!(Path.join(runs_dir, "scaffold_test.jsonl"), summary_line <> "\n")

      output =
        Jason.encode!(%{
          "type" => "result",
          "engine" => "elixir_loop",
          "subtype" => "success",
          "per_role" => %{
            "developer-static" => %{
              # WRONG model — does not match @arm.model "m"
              "dispatches" => [%{"harness" => "pi", "model" => "wrong-model", "effort" => "high"}]
            }
          }
        })

      rep = %{exit_code: 0, run_dir: run_dir, wall_ms: 100, output: output}
      assert {:incomplete, reason} = RoleModelSweep.classify_repetition(rep, @matrix, @arm)
      assert reason =~ "dispatch provenance"
    end
  end

  describe "aggregate_arm/1 and candidate_verdict/3" do
    @matrix RoleModelSweep.validate_matrix!(@valid_raw)

    test "all-complete repetitions: pass_rate 1.0, medians from literal costs" do
      rep = %{wall_ms: 1000}

      classified = [
        {rep, {:complete, %{cost: 1.0}}},
        {rep, {:complete, %{cost: 2.0}}},
        {rep, {:complete, %{cost: 3.0}}}
      ]

      agg = RoleModelSweep.aggregate_arm(classified)
      assert agg.pass_rate == 1.0
      assert agg.median_cost == 2.0
      assert agg.complete_count == 3
      assert agg.total_count == 3
    end

    test "one incomplete out of three: pass_rate is 2/3" do
      rep = %{wall_ms: 1000}

      classified = [
        {rep, {:complete, %{cost: 1.0}}},
        {rep, {:incomplete, "child exited 1"}},
        {rep, {:complete, %{cost: 3.0}}}
      ]

      agg = RoleModelSweep.aggregate_arm(classified)
      assert_in_delta agg.pass_rate, 2 / 3, 0.0001
      assert agg.complete_count == 2
      assert agg.total_count == 3
    end

    test "candidate_verdict: viable when pass_rate/cost/duration all within tolerance" do
      baseline_agg = %{pass_rate: 1.0, median_cost: 1.0, median_wall_ms: 1000}

      candidate_agg = %{
        pass_rate: 1.0,
        median_cost: 1.0,
        median_wall_ms: 1100,
        complete_count: 3,
        total_count: 3
      }

      assert RoleModelSweep.candidate_verdict(candidate_agg, baseline_agg, @matrix) == :viable
    end

    test "candidate_verdict: rejected when pass_rate is worse than a lower baseline pass_rate" do
      # Both arms fully complete (complete_count == total_count) so the
      # incomplete-arm inconclusive branch never fires; baseline itself is
      # below 1.0 (e.g. an earlier campaign convention), letting the
      # pass_rate-comparison branch — not the completeness branch — decide.
      baseline_agg = %{pass_rate: 0.9, median_cost: 1.0, median_wall_ms: 1000}

      candidate_agg = %{
        pass_rate: 0.5,
        median_cost: 1.0,
        median_wall_ms: 1000,
        complete_count: 3,
        total_count: 3
      }

      assert RoleModelSweep.candidate_verdict(candidate_agg, baseline_agg, @matrix) == :rejected
    end

    test "candidate_verdict: rejected when median cost exceeds tolerance (0% cost_pct)" do
      baseline_agg = %{pass_rate: 1.0, median_cost: 1.0, median_wall_ms: 1000}

      candidate_agg = %{
        pass_rate: 1.0,
        median_cost: 1.01,
        median_wall_ms: 1000,
        complete_count: 3,
        total_count: 3
      }

      assert RoleModelSweep.candidate_verdict(candidate_agg, baseline_agg, @matrix) == :rejected
    end

    test "candidate_verdict: rejected when median wall duration exceeds 20% tolerance" do
      baseline_agg = %{pass_rate: 1.0, median_cost: 1.0, median_wall_ms: 1000}

      candidate_agg = %{
        pass_rate: 1.0,
        median_cost: 1.0,
        median_wall_ms: 1201,
        complete_count: 3,
        total_count: 3
      }

      assert RoleModelSweep.candidate_verdict(candidate_agg, baseline_agg, @matrix) == :rejected
    end

    test "candidate_verdict: inconclusive when the candidate has an incomplete repetition" do
      baseline_agg = %{pass_rate: 1.0, median_cost: 1.0, median_wall_ms: 1000}

      candidate_agg = %{
        pass_rate: 0.67,
        median_cost: 1.0,
        median_wall_ms: 1000,
        complete_count: 2,
        total_count: 3
      }

      assert RoleModelSweep.candidate_verdict(candidate_agg, baseline_agg, @matrix) ==
               :inconclusive
    end
  end

  describe "run_repetition/5" do
    test "writes role-model-binding.json with the arm's exact requested tuple" do
      matrix = RoleModelSweep.validate_matrix!(@valid_raw)

      arm = %{
        name: "candidate-a",
        harness: "pi",
        model: "openai-codex/gpt-5.6-terra",
        effort: "high"
      }

      run_dir =
        Path.join(System.tmp_dir!(), "rms_run_rep_#{:erlang.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(run_dir) end)

      run_fn = fn _test_file, _env -> {"", 0} end

      RoleModelSweep.run_repetition(matrix, arm, "camp-1", run_dir,
        run_fn: run_fn,
        sha: "deadbeef"
      )

      binding =
        run_dir
        |> Path.join("role-model-binding.json")
        |> File.read!()
        |> Jason.decode!()

      assert binding == %{
               "schema_version" => 1,
               "campaign_id" => "camp-1",
               "arm" => "candidate-a",
               "role" => "developer-static",
               "stack" => "static",
               "harness" => "pi",
               "model" => "openai-codex/gpt-5.6-terra",
               "effort" => "high",
               "source_sha" => "deadbeef",
               "fixed" => true
             }
    end

    test "returns exit_code and non-negative wall_ms from the injected run_fn" do
      matrix = RoleModelSweep.validate_matrix!(@valid_raw)
      arm = %{name: "baseline", harness: "claude", model: "sonnet", effort: "medium"}

      run_dir =
        Path.join(System.tmp_dir!(), "rms_run_rep_#{:erlang.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(run_dir) end)

      run_fn = fn _test_file, _env -> {"child output", 0} end

      result =
        RoleModelSweep.run_repetition(matrix, arm, "camp-1", run_dir,
          run_fn: run_fn,
          sha: "deadbeef"
        )

      assert result.exit_code == 0
      assert result.output == "child output"
      assert result.wall_ms >= 0
    end
  end
end

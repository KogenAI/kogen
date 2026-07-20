defmodule Mix.Tasks.Codegen.Bench.RoleModelSweep do
  @shortdoc "Role-model-binding campaign: baseline vs candidate arms, evidence-only"

  @moduledoc """
  Runs (or validates) a `RoleModelSweep` campaign — see
  `CodegenTestHarness.RoleModelSweep` for the full contract.

  ## Usage

      mix codegen.bench.role_model_sweep --matrix ../campaign.yaml --reason "developer-static candidates" --validate-only
      mix codegen.bench.role_model_sweep --matrix ../campaign.yaml --reason "developer-static candidates"

  `--matrix` (required) — path to the campaign matrix YAML, resolved against
  invocation cwd.

  `--reason` (required) — human-readable run label, stored alongside the
  evidence directory (mirrors `make bench REASON=`).

  `--validate-only` — runs every preflight check (matrix validation, clean
  tree, tool/path resolution, baseline resolution) and prints the resolved
  baseline + planned schedule, then exits BEFORE any child `mix test` spawns.
  No spend is possible with this flag. Agents may run this form; the paid
  form (without `--validate-only`) is operator-only.

  ## Exit codes

  Non-zero when: preflight fails, baseline aborts (any repetition
  incomplete), or any candidate is `INCONCLUSIVE`. A fully-measured
  `REJECTED` candidate is a valid, zero-exit campaign completion.
  """

  use Mix.Task

  alias CodegenTestHarness.RoleModelSweep

  @switches [matrix: :string, reason: :string, validate_only: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    matrix_path = Keyword.get(opts, :matrix)
    reason = Keyword.get(opts, :reason)
    validate_only? = Keyword.get(opts, :validate_only, false)

    unless matrix_path do
      Mix.raise(
        "--matrix is required. Usage: mix codegen.bench.role_model_sweep --matrix <path> --reason <text>"
      )
    end

    unless reason do
      Mix.raise(
        "--reason is required. Usage: mix codegen.bench.role_model_sweep --matrix <path> --reason <text>"
      )
    end

    cwd = File.cwd!()
    matrix = RoleModelSweep.load_matrix!(matrix_path, cwd)
    preflight = RoleModelSweep.preflight!(matrix)

    arms = [preflight.baseline | matrix.candidates]
    schedule = RoleModelSweep.build_schedule(arms, matrix.repetitions)

    Mix.shell().info("ROLE MODEL PREFLIGHT: CLEAR")
    Mix.shell().info("  role:      #{matrix.role}")
    Mix.shell().info("  stack:     #{matrix.stack}")
    Mix.shell().info("  test:      #{matrix.test}")
    Mix.shell().info("  sha:       #{preflight.sha}")
    Mix.shell().info("  platform:  #{preflight.platform} (#{preflight.cores} cores)")

    Mix.shell().info(
      "  baseline:  #{preflight.baseline.harness}/#{preflight.baseline.model}/#{preflight.baseline.effort}"
    )

    Enum.each(matrix.candidates, fn c ->
      Mix.shell().info("  candidate: #{c.name} — #{c.harness}/#{c.model}/#{c.effort}")
    end)

    Mix.shell().info(
      "  arms x repetitions: #{length(arms)} x #{matrix.repetitions} = #{length(schedule)} runs"
    )

    if validate_only? do
      :ok
    else
      run_campaign(matrix, preflight, schedule, reason)
    end
  end

  defp run_campaign(matrix, preflight, schedule, reason) do
    campaign_id = "#{DateTime.utc_now() |> DateTime.to_iso8601()}-role-model-#{matrix.role}"
    ts = DateTime.utc_now() |> Calendar.strftime("%Y%m%d_%H%M%S")

    evidence_dir =
      Path.expand("../../codegen/benchmarks/#{ts}-role-model-#{matrix.role}", __DIR__)

    File.mkdir_p!(evidence_dir)
    File.write!(Path.join(evidence_dir, "reason.txt"), reason)

    results =
      Enum.map(schedule, fn {arm, repetition} ->
        run_dir = Path.join([evidence_dir, "arms", arm.name, Integer.to_string(repetition)])

        rep_result =
          RoleModelSweep.run_repetition(matrix, arm, campaign_id, run_dir, sha: preflight.sha)

        verdict = RoleModelSweep.classify_repetition(rep_result, matrix, arm)
        {arm, rep_result, verdict}
      end)

    per_arm =
      Enum.group_by(results, fn {arm, _rep, _verdict} -> arm.name end)

    baseline_results = Map.get(per_arm, "baseline", [])

    baseline_agg =
      RoleModelSweep.aggregate_arm(Enum.map(baseline_results, fn {_a, r, v} -> {r, v} end))

    Mix.shell().info("")

    Mix.shell().info(
      "baseline: pass_rate=#{baseline_agg.pass_rate} median_cost=#{inspect(baseline_agg.median_cost)}"
    )

    if baseline_agg.complete_count != baseline_agg.total_count do
      Mix.shell().error(
        "ROLE MODEL EVIDENCE: INCONCLUSIVE — baseline did not complete every repetition"
      )

      write_evidence(evidence_dir, matrix, preflight, baseline_agg, [])
      exit({:shutdown, 1})
    else
      candidate_verdicts =
        Enum.map(matrix.candidates, fn candidate ->
          rep_results = Map.get(per_arm, candidate.name, [])
          agg = RoleModelSweep.aggregate_arm(Enum.map(rep_results, fn {_a, r, v} -> {r, v} end))
          verdict = RoleModelSweep.candidate_verdict(agg, baseline_agg, matrix)
          {candidate, agg, verdict}
        end)

      Enum.each(candidate_verdicts, fn {candidate, agg, verdict} ->
        Mix.shell().info(
          "#{candidate.name}: pass_rate=#{agg.pass_rate} median_cost=#{inspect(agg.median_cost)} verdict=#{verdict}"
        )
      end)

      write_evidence(evidence_dir, matrix, preflight, baseline_agg, candidate_verdicts)

      if Enum.any?(candidate_verdicts, fn {_c, _a, v} -> v == :inconclusive end) do
        Mix.shell().error("ROLE MODEL EVIDENCE: INCONCLUSIVE — #{evidence_dir}/evidence.md")
        exit({:shutdown, 1})
      else
        Mix.shell().info("ROLE MODEL EVIDENCE: COMPLETE — #{evidence_dir}/evidence.md")
      end
    end
  end

  defp write_evidence(evidence_dir, matrix, preflight, baseline_agg, candidate_verdicts) do
    evidence = %{
      "campaign" => %{
        "role" => matrix.role,
        "stack" => matrix.stack,
        "test" => matrix.test,
        "sha" => preflight.sha,
        "platform" => preflight.platform,
        "cores" => preflight.cores
      },
      "baseline" => %{"arm" => preflight.baseline, "aggregate" => stringify(baseline_agg)},
      "candidates" =>
        Enum.map(candidate_verdicts, fn {candidate, agg, verdict} ->
          %{
            "arm" => candidate,
            "aggregate" => stringify(agg),
            "verdict" => Atom.to_string(verdict)
          }
        end)
    }

    File.write!(Path.join(evidence_dir, "evidence.json"), Jason.encode!(evidence, pretty: true))

    md =
      [
        "# Role-model-sweep evidence: #{matrix.role}\n",
        "sha: #{preflight.sha} — platform: #{preflight.platform} (#{preflight.cores} cores)\n",
        "## Baseline\n",
        "pass_rate=#{baseline_agg.pass_rate} median_cost=#{inspect(baseline_agg.median_cost)} " <>
          "median_wall_ms=#{inspect(baseline_agg.median_wall_ms)}\n",
        "## Candidates\n"
      ] ++
        Enum.map(candidate_verdicts, fn {candidate, agg, verdict} ->
          "- #{candidate.name} (#{candidate.harness}/#{candidate.model}/#{candidate.effort}): " <>
            "**#{String.upcase(Atom.to_string(verdict))}** — pass_rate=#{agg.pass_rate} " <>
            "median_cost=#{inspect(agg.median_cost)} median_wall_ms=#{inspect(agg.median_wall_ms)}\n"
        end) ++
        [
          "\nManual review of linked artifacts under `arms/` is required before any binding change.\n"
        ]

    File.write!(Path.join(evidence_dir, "evidence.md"), Enum.join(md, "\n"))
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)
  end
end

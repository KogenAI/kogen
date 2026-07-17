defmodule Mix.Tasks.Codegen.Bench.CheckRegression do
  @shortdoc "Soft perf-regression check against perf_baseline.json"

  @moduledoc """
  Loads `perf_baseline.json` and computes per-harness averages from JSONL
  harness_summary records in the given benchmark run directory.

  ## Usage

      mix codegen.bench.check_regression --run path/to/run
      mix codegen.bench.check_regression --run path/to/run --strict

  NOTE: the task name is `check_regression` (UNDERSCORE). Mix derives it from
  this module's name and does NOT alias a dashed spelling — `mix
  codegen.bench.check-regression` exits "task could not be found". The
  Makefile `bench` target invoked the dashed name for its whole life, so the
  final step of every `make bench` run died after the tokens were already
  spent. The hermetic tests never caught it because they call
  `CheckRegression.run/1` directly, bypassing CLI name resolution.

  ## Behaviour

  - Metrics with `baseline == 0` (not yet populated) are skipped entirely —
    never evaluated, never reported. Populate `perf_baseline.json` from a
    green `make bench` run to activate a metric.
  - `min_abs` metrics (currently only `pass_rate`) are HARD regressions
    regardless of `--strict`: `pass_rate` sits at a ceiling (1.0) in normal
    operation, so any drop below `min_abs` is an unambiguous break, not
    noise. A `min_abs` violation always fails the task, `--strict` or not.
  - `max_regression_pct` metrics (turns/cost/duration/tokens) are
    INFORMATIONAL by default — printed as a warning table, task still
    exits 0. Pass `--strict` to make these hard regressions too (fail the
    task) once you trust the baseline enough to gate on it.
  - Without `--strict`: only `min_abs` (pass_rate) violations fail the task.
  - With `--strict`: any regression (min_abs or max_regression_pct) fails.

  ## Metric naming convention

  Baseline keys use `<harness>.<metric>` (e.g. `claude.avg_cost_usd`). The
  harness prefix maps to JSONL `harness_summary` records' `parsed` fields:
  `build_duration_ms`, `cost_usd`, `num_turns`, `input_tokens`, `output_tokens`.
  `pass_rate` = fraction of summaries where `assertion_passed == true`.
  """

  use Mix.Task

  @switches [run: :string, strict: :boolean]

  @baseline_path Path.expand("../../../perf_baseline.json", __DIR__)

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    run_dir = Keyword.get(opts, :run)
    strict? = Keyword.get(opts, :strict, false)

    unless run_dir do
      Mix.raise("--run is required. Usage: mix codegen.bench.check_regression --run <path>")
    end

    unless File.dir?(run_dir) do
      Mix.raise("Run directory does not exist: #{run_dir}")
    end

    unless File.exists?(@baseline_path) do
      Mix.shell().info(
        "perf_baseline.json not found at #{@baseline_path} — skipping regression check"
      )

      exit(:normal)
    end

    baseline = load_baseline(@baseline_path)
    actuals = compute_actuals(run_dir)

    regressions = check_regressions(baseline, actuals)

    {hard, informational} = Enum.split_with(regressions, &hard_regression?(&1, strict?))

    if regressions == [] do
      Mix.shell().info("perf-regression: no regressions detected")
    else
      if informational != [] do
        Mix.shell().info("")

        Mix.shell().info(
          "⚠️  perf-regression warnings (informational — not failing the build):"
        )

        Mix.shell().info("")
        Mix.shell().info(format_table(informational))
        Mix.shell().info("")
      end

      if hard != [] do
        Mix.shell().info("")
        Mix.shell().info("❌ perf-regression FAILURES:")
        Mix.shell().info("")
        Mix.shell().info(format_table(hard))
        Mix.shell().info("")
      end
    end

    if hard == [] do
      :ok
    else
      exit({:shutdown, 1})
    end
  end

  # `min_abs` (pass_rate) is always a hard failure — it sits at a ceiling in
  # normal operation, so any drop is unambiguous. `max_regression_pct`
  # metrics are hard failures only under `--strict`.
  @spec hard_regression?(regression(), boolean()) :: boolean()
  defp hard_regression?(%{kind: :min_abs}, _strict?), do: true
  defp hard_regression?(%{kind: :max_regression}, strict?), do: strict?

  # ── Baseline loading ──────────────────────────────────────────────────────────

  @spec load_baseline(String.t()) :: map()
  defp load_baseline(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.get("metrics", %{})
  end

  # ── Actual computation ────────────────────────────────────────────────────────

  @spec compute_actuals(String.t()) :: %{String.t() => float()}
  defp compute_actuals(run_dir) do
    harness_names = ["claude", "pi"]

    Enum.reduce(harness_names, %{}, fn harness, acc ->
      records = load_harness_summaries(run_dir, harness)

      if records == [] do
        acc
      else
        metrics = aggregate_records(harness, records)
        Map.merge(acc, metrics)
      end
    end)
  end

  @spec load_harness_summaries(String.t(), String.t()) :: [map()]
  defp load_harness_summaries(run_dir, harness) do
    pattern = Path.join([run_dir, "runs", harness, "**", "*.jsonl"])

    pattern
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, %{"type" => "harness_summary"} = record} -> [record]
          _ -> []
        end
      end)
    end)
  end

  @spec aggregate_records(String.t(), [map()]) :: %{String.t() => float()}
  defp aggregate_records(harness, records) do
    count = length(records)

    if count == 0 do
      %{}
    else
      passed_count = Enum.count(records, fn r -> r["assertion_passed"] == true end)
      pass_rate = passed_count / count

      metric_keys = [
        "build_duration_ms",
        "cost_usd",
        "num_turns",
        "input_tokens",
        "output_tokens"
      ]

      averages =
        Enum.reduce(metric_keys, %{}, fn key, acc ->
          values =
            Enum.flat_map(records, fn r ->
              case get_in(r, ["parsed", key]) do
                nil -> []
                v when is_number(v) -> [v]
                _ -> []
              end
            end)

          if values == [] do
            acc
          else
            avg = Enum.sum(values) / length(values)
            Map.put(acc, "#{harness}.avg_#{key}", avg)
          end
        end)

      Map.put(averages, "#{harness}.pass_rate", pass_rate)
    end
  end

  # ── Regression check ──────────────────────────────────────────────────────────

  @type regression() :: %{
          metric: String.t(),
          baseline: float(),
          actual: float(),
          threshold: float(),
          kind: :max_regression | :min_abs
        }

  @spec check_regressions(map(), map()) :: [regression()]
  defp check_regressions(baseline, actuals) do
    Enum.flat_map(baseline, fn {metric_key, spec} ->
      baseline_val = spec["baseline"]

      # Skip zero-baseline metrics (not yet populated)
      if is_number(baseline_val) and baseline_val == 0 and not Map.has_key?(spec, "min_abs") do
        []
      else
        actual = Map.get(actuals, metric_key)

        if is_nil(actual) do
          # No data for this metric in this run — skip
          []
        else
          check_metric_regression(metric_key, spec, baseline_val, actual)
        end
      end
    end)
  end

  @spec check_metric_regression(String.t(), map(), number(), float()) :: [regression()]
  defp check_metric_regression(metric_key, spec, baseline_val, actual) do
    regressions = []

    regressions =
      if max_pct = spec["max_regression_pct"] do
        if is_number(baseline_val) and baseline_val > 0 do
          threshold = baseline_val * (1 + max_pct / 100)

          if actual > threshold do
            [
              %{
                metric: metric_key,
                baseline: baseline_val,
                actual: actual,
                threshold: threshold,
                kind: :max_regression
              }
              | regressions
            ]
          else
            regressions
          end
        else
          regressions
        end
      else
        regressions
      end

    if min_abs = spec["min_abs"] do
      if actual < min_abs do
        [
          %{
            metric: metric_key,
            baseline: baseline_val,
            actual: actual,
            threshold: min_abs,
            kind: :min_abs
          }
          | regressions
        ]
      else
        regressions
      end
    else
      regressions
    end
  end

  # ── Formatting ────────────────────────────────────────────────────────────────

  @spec format_table([regression()]) :: String.t()
  defp format_table(regressions) do
    header =
      "  Metric                              | Baseline    | Actual      | Threshold   | Kind"

    divider = "  " <> String.duplicate("-", 90)

    rows =
      Enum.map(regressions, fn r ->
        kind_str = if r.kind == :max_regression, do: "max_regression", else: "min_abs"

        "  #{pad(r.metric, 36)} | #{pad_float(r.baseline)} | #{pad_float(r.actual)} | #{pad_float(r.threshold)} | #{kind_str}"
      end)

    Enum.join([header, divider] ++ rows, "\n")
  end

  @spec pad(String.t(), non_neg_integer()) :: String.t()
  defp pad(str, width) do
    String.pad_trailing(str, width)
  end

  @spec pad_float(number()) :: String.t()
  defp pad_float(val) do
    val
    |> Float.round(4)
    |> to_string()
    |> String.pad_trailing(11)
  end
end

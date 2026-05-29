defmodule Mix.Tasks.Codegen.Bench.View do
  @shortdoc "View metrics table for a benchmark run"

  @moduledoc """
  Renders a metrics table for a specific benchmark run directory.

  ## Usage

      mix codegen.bench.view --run path/to/run
      mix codegen.bench.view --run path/to/run --compare path/to/prev
      mix codegen.bench.view --run path/to/run --no-compare
      mix codegen.bench.view --run path/to/run --test scaffold
      mix codegen.bench.view --run path/to/run --metric cost_usd

  ## Options

  - `--run` (required) — path to the run directory to view
  - `--compare` — path to a previous run directory to compute deltas against
  - `--no-compare` — suppress automatic previous-run detection
  - `--test` — substring filter on test name
  - `--metric` — substring filter on metric id (e.g. "cost" matches "cost_usd");
    note this is a substring match against the metric id string, not an exact
    atom lookup

  ## Auto-compare

  When neither `--compare` nor `--no-compare` is given, the task automatically
  finds the most recent previous run under the same benchmark root (the parent
  directory of `--run`) and computes deltas if one exists.
  """

  use Mix.Task

  alias CodegenTestHarness.BenchView

  @switches [
    run: :string,
    compare: :string,
    no_compare: :boolean,
    test: :string,
    metric: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    run_dir = Keyword.get(opts, :run)

    unless run_dir do
      Mix.raise("--run is required. Usage: mix codegen.bench.view --run <path>")
    end

    unless File.dir?(run_dir) do
      Mix.raise("Run directory does not exist: #{run_dir}")
    end

    loaded = BenchView.load_run(run_dir)

    loaded =
      case Keyword.get(opts, :test) do
        nil ->
          loaded

        filter ->
          %{
            loaded
            | tests: Enum.filter(loaded.tests, fn t -> String.contains?(t.test_name, filter) end)
          }
      end

    deltas =
      cond do
        Keyword.get(opts, :no_compare) ->
          nil

        compare_dir = Keyword.get(opts, :compare) ->
          if File.dir?(compare_dir) do
            prev = BenchView.load_run(compare_dir)
            BenchView.compare(loaded, prev)
          else
            Mix.shell().error("--compare path not found: #{compare_dir}")
            nil
          end

        true ->
          benchmark_root = Path.dirname(run_dir)
          prev_path = BenchView.previous_run_path(benchmark_root, run_dir)

          if prev_path && File.dir?(prev_path) do
            prev = BenchView.load_run(prev_path)
            BenchView.compare(loaded, prev)
          else
            nil
          end
      end

    metric_filter = Keyword.get(opts, :metric)

    table = BenchView.render_table(loaded, deltas)

    lines = String.split(table, "\n")

    filtered_lines =
      if metric_filter do
        Enum.filter(lines, fn line ->
          String.starts_with?(line, "+") or String.contains?(line, metric_filter)
        end)
      else
        lines
      end

    IO.puts(Enum.join(filtered_lines, "\n"))
  end
end

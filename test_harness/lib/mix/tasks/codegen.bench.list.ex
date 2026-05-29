defmodule Mix.Tasks.Codegen.Bench.List do
  @shortdoc "List benchmark runs under codegen/benchmarks/"

  @moduledoc """
  Lists benchmark runs recorded under `codegen/benchmarks/` (or a custom root
  passed as the first argument), newest-first.

  ## Usage

      mix codegen.bench.list
      mix codegen.bench.list path/to/benchmarks

  Each run shows: path, started_at, reason, pass rate per (harness × stack).
  """

  use Mix.Task

  alias CodegenTestHarness.BenchView

  @impl Mix.Task
  def run(args) do
    root_dir =
      case args do
        [dir | _] -> dir
        [] -> default_bench_dir()
      end

    unless File.dir?(root_dir) do
      Mix.shell().info("No benchmark runs found at #{root_dir}")
      exit(:normal)
    end

    runs = BenchView.list_runs(root_dir)

    if runs == [] do
      Mix.shell().info("No benchmark runs found under #{root_dir}")
    else
      IO.puts(IO.ANSI.bright() <> "Benchmark runs under #{root_dir}" <> IO.ANSI.reset())
      IO.puts("")
      Enum.each(runs, fn run -> print_run_summary(run) end)
    end
  end

  defp print_run_summary(run) do
    IO.puts(IO.ANSI.cyan() <> run.path <> IO.ANSI.reset())
    IO.puts("  started_at : #{run.started_at}")
    IO.puts("  reason     : #{run.reason}")

    if run.pass_rate_per_shape == %{} do
      IO.puts("  (no test records)")
    else
      Enum.each(run.pass_rate_per_shape, fn {{harness, stack}, rate} ->
        pct = Float.round(rate * 100, 1)
        IO.puts("  #{harness}/#{stack} pass rate: #{pct}%")
      end)
    end

    IO.puts("")
  end

  defp default_bench_dir do
    Path.join([
      File.cwd!(),
      "..",
      "codegen",
      "benchmarks"
    ])
    |> Path.expand()
  end
end

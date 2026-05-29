defmodule CodegenTestHarness.BenchView do
  @moduledoc """
  Pure read-only view layer for benchmark run directories. No IO.puts.

  ## Public API

  - `list_runs/1` — lists all runs under a root dir, newest-first
  - `load_run/1` — loads a single run dir into a structured map
  - `compare/2` — computes per-metric deltas between two loaded runs
  - `render_table/1` — renders an ASCII table (iodata) from a loaded run
  """

  alias CodegenTestHarness.BenchManifest
  alias CodegenTestHarness.BenchMetrics

  @type run_summary :: %{
          path: String.t(),
          started_at: String.t(),
          reason: String.t(),
          pass_rate_per_shape: %{{String.t(), String.t()} => float()}
        }

  @type test_record :: %{
          harness: String.t(),
          stack: String.t(),
          test_name: String.t(),
          parsed: map(),
          exit_code: integer(),
          assertion_passed: boolean(),
          screenshot_path: String.t() | nil
        }

  @type loaded_run :: %{
          manifest: map(),
          tests: [test_record()]
        }

  @type delta :: %{
          metric_id: atom(),
          current: term(),
          previous: term(),
          diff: term() | :not_comparable
        }

  @doc """
  Lists all run directories under `root_dir`, newest-first (lexicographic
  descending). Returns a list of `t:run_summary/0` maps.
  """
  @spec list_runs(String.t()) :: [run_summary()]
  def list_runs(root_dir) do
    case File.ls(root_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn entry ->
          dir = Path.join(root_dir, entry)
          File.dir?(dir) and File.exists?(Path.join(dir, "manifest.json"))
        end)
        |> Enum.sort(:desc)
        |> Enum.map(fn entry ->
          run_dir = Path.join(root_dir, entry)
          build_run_summary(run_dir)
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Loads a single run directory into a `t:loaded_run/0` map.
  """
  @spec load_run(String.t()) :: loaded_run()
  def load_run(run_dir) do
    manifest = BenchManifest.load(run_dir)
    tests = load_test_records(run_dir)
    %{manifest: manifest, tests: tests}
  end

  @doc """
  Finds the previous run directory under `benchmark_root` that is strictly
  older than `current_run_dir` (lexicographic comparison on basename).

  Returns the absolute path of the previous run dir, or `nil` when none exists.
  """
  @spec previous_run_path(String.t(), String.t()) :: String.t() | nil
  def previous_run_path(benchmark_root, current_run_dir) do
    current_key = Path.basename(current_run_dir)

    case File.ls(benchmark_root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn entry ->
          dir = Path.join(benchmark_root, entry)

          File.dir?(dir) and File.exists?(Path.join(dir, "manifest.json")) and
            entry < current_key
        end)
        |> Enum.sort(:desc)
        |> case do
          [] -> nil
          [latest | _] -> Path.join(benchmark_root, latest)
        end

      _ ->
        nil
    end
  end

  @doc """
  Computes per-metric deltas between `current_run` and `previous_run`.
  Both are `t:loaded_run/0` maps. Returns a list of `t:delta/0` maps for
  measurable metrics where the values are not `:unknown`.
  """
  @spec compare(loaded_run(), loaded_run()) :: [delta()]
  def compare(current_run, previous_run) do
    current_agg = aggregate_metrics(current_run.tests)
    previous_agg = aggregate_metrics(previous_run.tests)

    BenchMetrics.measurable()
    |> Enum.map(fn metric ->
      curr = Map.get(current_agg, metric.id, :unknown)
      prev = Map.get(previous_agg, metric.id, :unknown)

      diff =
        if curr == :unknown or prev == :unknown do
          :not_comparable
        else
          compute_diff(curr, prev, metric.aggregator)
        end

      %{metric_id: metric.id, current: curr, previous: prev, diff: diff}
    end)
  end

  @doc """
  Renders an ASCII table of metrics for the loaded run. Accepts an optional
  list of deltas from `compare/2` as a second argument; when provided, a delta
  column is added.

  Returns iodata suitable for `IO.puts/1`.
  """
  @spec render_table(loaded_run()) :: iodata()
  @spec render_table(loaded_run(), [delta()] | nil) :: iodata()
  def render_table(loaded_run, deltas \\ nil) do
    agg = aggregate_metrics(loaded_run.tests)
    rows = build_rows(agg, deltas)
    format_table(rows, deltas != nil)
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp build_run_summary(run_dir) do
    manifest =
      try do
        BenchManifest.load(run_dir)
      rescue
        _ -> %{}
      end

    reason =
      case File.read(Path.join(run_dir, "reason.txt")) do
        {:ok, content} -> String.trim(content)
        _ -> "(no reason)"
      end

    tests = load_test_records(run_dir)
    pass_rate = compute_pass_rate_per_shape(tests)

    %{
      path: run_dir,
      started_at: Map.get(manifest, "started_at", "(unknown)"),
      reason: reason,
      pass_rate_per_shape: pass_rate
    }
  end

  defp load_test_records(run_dir) do
    runs_dir = Path.join(run_dir, "runs")

    case File.ls(runs_dir) do
      {:ok, harnesses} ->
        Enum.flat_map(harnesses, fn harness ->
          harness_dir = Path.join(runs_dir, harness)

          case File.ls(harness_dir) do
            {:ok, stacks} ->
              Enum.flat_map(stacks, fn stack ->
                stack_dir = Path.join(harness_dir, stack)

                case File.ls(stack_dir) do
                  {:ok, files} ->
                    files
                    |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
                    |> Enum.map(fn file ->
                      test_name = String.replace_suffix(file, ".jsonl", "")
                      path = Path.join(stack_dir, file)
                      parse_test_record(path, harness, stack, test_name)
                    end)

                  _ ->
                    []
                end
              end)

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  defp parse_test_record(path, harness, stack, test_name) do
    stack_dir = Path.dirname(path)
    png_path = Path.join(stack_dir, "#{test_name}.png")
    screenshot_path = if File.exists?(png_path), do: png_path, else: nil

    lines =
      case File.read(path) do
        {:ok, content} ->
          content
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            case Jason.decode(line) do
              {:ok, map} -> map
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        _ ->
          []
      end

    summary =
      Enum.find(lines, fn
        %{"type" => "harness_summary"} -> true
        _ -> false
      end)

    case summary do
      %{
        "exit_code" => exit_code,
        "assertion_passed" => assertion_passed,
        "parsed" => parsed_raw
      } ->
        parsed = atomize_parsed(parsed_raw)

        %{
          harness: harness,
          stack: stack,
          test_name: test_name,
          parsed: parsed,
          exit_code: exit_code,
          assertion_passed: assertion_passed,
          screenshot_path: screenshot_path
        }

      _ ->
        %{
          harness: harness,
          stack: stack,
          test_name: test_name,
          parsed: %{},
          exit_code: -1,
          assertion_passed: false,
          screenshot_path: screenshot_path
        }
    end
  end

  defp atomize_parsed(raw) when is_map(raw) do
    Map.new(raw, fn
      {k, ":unknown"} -> {String.to_atom(k), :unknown}
      {k, v} -> {String.to_atom(k), v}
    end)
  end

  defp atomize_parsed(_), do: %{}

  defp compute_pass_rate_per_shape(tests) do
    tests
    |> Enum.group_by(fn t -> {t.harness, t.stack} end)
    |> Map.new(fn {{harness, stack}, group} ->
      passed = Enum.count(group, & &1.assertion_passed)
      total = length(group)
      rate = if total > 0, do: passed / total, else: 0.0
      {{harness, stack}, rate}
    end)
  end

  defp aggregate_metrics(tests) do
    BenchMetrics.measurable()
    |> Enum.map(fn metric ->
      values =
        Enum.map(tests, fn test ->
          case metric.id do
            :exit_code -> test.exit_code
            :assertion_passed -> test.assertion_passed
            id -> Map.get(test.parsed, id, :unknown)
          end
        end)

      agg_value = aggregate(values, metric.aggregator)
      {metric.id, agg_value}
    end)
    |> Map.new()
  end

  defp aggregate(values, :sum) do
    clean = Enum.reject(values, &(&1 == :unknown))
    if clean == [], do: :unknown, else: Enum.sum(clean)
  end

  defp aggregate(values, :max) do
    clean = Enum.reject(values, &(&1 == :unknown))
    if clean == [], do: :unknown, else: Enum.max(clean)
  end

  defp aggregate(values, :all) do
    if Enum.all?(values, &(&1 == true)), do: true, else: false
  end

  defp aggregate(values, :mode) do
    clean = Enum.reject(values, &(&1 == :unknown))

    if clean == [] do
      :unknown
    else
      clean
      |> Enum.frequencies()
      |> Enum.max_by(fn {_, count} -> count end)
      |> elem(0)
    end
  end

  defp compute_diff(curr, prev, _aggregator) when is_number(curr) and is_number(prev) do
    curr - prev
  end

  defp compute_diff(curr, prev, _aggregator) when is_boolean(curr) and is_boolean(prev) do
    if curr == prev, do: :no_change, else: :changed
  end

  defp compute_diff(curr, prev, _aggregator) do
    if curr == prev, do: :no_change, else: :changed
  end

  defp build_rows(agg, deltas) do
    delta_map =
      if deltas do
        Map.new(deltas, fn d -> {d.metric_id, d} end)
      else
        %{}
      end

    all_entries =
      BenchMetrics.measurable() ++
        BenchMetrics.gaps()

    Enum.map(all_entries, fn metric ->
      value_str =
        cond do
          not is_nil(metric.gap) ->
            metric.gap

          true ->
            val = Map.get(agg, metric.id, :unknown)
            format_value(val, metric.unit)
        end

      delta_str =
        if deltas != nil and is_nil(metric.gap) do
          case Map.get(delta_map, metric.id) do
            %{diff: :not_comparable} -> "(n/a)"
            %{diff: :no_change} -> "~"
            %{diff: :changed} -> "changed"
            %{diff: diff} when is_number(diff) -> format_diff(diff, metric.unit)
            _ -> "(n/a)"
          end
        else
          nil
        end

      %{id: metric.id, unit: metric.unit, value: value_str, delta: delta_str}
    end)
  end

  defp format_value(:unknown, _unit), do: "(n/a)"

  defp format_value(v, "USD") when is_float(v),
    do: "$#{:erlang.float_to_binary(v, decimals: 6)}"

  defp format_value(v, "USD") when is_integer(v), do: "$#{v}.000000"

  defp format_value(v, "ms") when is_number(v), do: "#{v}ms"

  defp format_value(v, "bool") when is_boolean(v), do: inspect(v)

  defp format_value(v, _unit), do: inspect(v)

  defp format_diff(diff, "USD") when is_float(diff) do
    sign = if diff >= 0, do: "+", else: ""
    "#{sign}$#{:erlang.float_to_binary(diff, decimals: 6)}"
  end

  defp format_diff(diff, _unit) when is_number(diff) do
    sign = if diff >= 0, do: "+", else: ""
    "#{sign}#{diff}"
  end

  defp format_table(rows, has_delta) do
    headers = ["Metric", "Unit", "Value"] ++ if(has_delta, do: ["Delta"], else: [])

    data_rows =
      Enum.map(rows, fn row ->
        base = [to_string(row.id), row.unit, row.value]
        if has_delta, do: base ++ [row.delta || ""], else: base
      end)

    all_rows = [headers | data_rows]
    col_widths = compute_col_widths(all_rows)
    render_rows(all_rows, col_widths)
  end

  defp compute_col_widths(rows) do
    num_cols = rows |> List.first() |> length()

    Enum.map(0..(num_cols - 1), fn col ->
      rows
      |> Enum.map(fn row -> row |> Enum.at(col, "") |> String.length() end)
      |> Enum.max()
    end)
  end

  defp render_rows([header | data], col_widths) do
    separator = col_widths |> Enum.map(fn w -> String.duplicate("-", w + 2) end) |> Enum.join("+")
    separator_line = "+" <> separator <> "+"

    header_line = format_row(header, col_widths)

    data_lines = Enum.map(data, fn row -> format_row(row, col_widths) end)

    ([
       separator_line,
       header_line,
       separator_line
       | data_lines
     ] ++ [separator_line])
    |> Enum.join("\n")
  end

  defp format_row(cells, col_widths) do
    padded =
      cells
      |> Enum.zip(col_widths)
      |> Enum.map(fn {cell, width} -> " " <> String.pad_trailing(cell, width) <> " " end)
      |> Enum.join("|")

    "|" <> padded <> "|"
  end
end

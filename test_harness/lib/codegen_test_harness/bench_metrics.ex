defmodule CodegenTestHarness.BenchMetrics do
  @moduledoc """
  Single source of truth for the benchmarking metric catalog.

  Each entry is a map with:
  - `id` — atom identifier (matches `UsageParser.parse/2` map keys where measurable)
  - `unit` — display unit string
  - `source` — where the value originates
  - `aggregator` — `:sum`, `:max`, `:all` (boolean), or `:mode` (most frequent)
  - `gap` — `nil` for measurable metrics; reason string for stub metrics

  `measurable/0` returns entries where `gap: nil`.
  `gaps/0` returns entries where `gap` is a string.
  """

  @type metric :: %{
          id: atom(),
          unit: String.t(),
          source: String.t(),
          aggregator: :sum | :max | :all | :mode,
          gap: nil | String.t()
        }

  @catalog [
    %{
      id: :cost_usd,
      unit: "USD",
      source: "UsageParser total_cost_usd sum",
      aggregator: :sum,
      gap: nil
    },
    %{
      id: :input_tokens,
      unit: "count",
      source: "UsageParser usage.input_tokens",
      aggregator: :sum,
      gap: nil
    },
    %{
      id: :output_tokens,
      unit: "count",
      source: "UsageParser usage.output_tokens",
      aggregator: :sum,
      gap: nil
    },
    %{
      id: :cache_read_tokens,
      unit: "count",
      source: "UsageParser usage.cache_read_input_tokens",
      aggregator: :sum,
      gap: nil
    },
    %{
      id: :cache_creation_tokens,
      unit: "count",
      source: "UsageParser usage.cache_creation_input_tokens",
      aggregator: :sum,
      gap: nil
    },
    %{
      id: :duration_ms,
      unit: "ms",
      source: "UsageParser result envelope duration_ms",
      aggregator: :sum,
      gap: nil
    },
    %{
      id: :duration_api_ms,
      unit: "ms",
      source: "UsageParser result envelope duration_api_ms",
      aggregator: :sum,
      gap: nil
    },
    %{
      id: :build_duration_ms,
      unit: "ms",
      source: "Fixtures monotonic wall-clock around codegen-build Port (spawn to exit)",
      aggregator: :sum,
      gap: nil
    },
    %{
      id: :num_turns,
      unit: "count",
      source: "UsageParser result envelope num_turns",
      aggregator: :sum,
      gap: nil
    },
    %{
      id: :terminal_reason,
      unit: "string",
      source: "UsageParser result envelope terminal_reason",
      aggregator: :mode,
      gap: nil
    },
    %{
      id: :exit_code,
      unit: "int",
      source: "codegen-build process exit code",
      aggregator: :max,
      gap: nil
    },
    %{
      id: :assertion_passed,
      unit: "bool",
      source: "ExUnit test assertion result",
      aggregator: :all,
      gap: nil
    },
    %{
      id: :judge_pass_rate,
      unit: "float",
      source: "LLM judge",
      aggregator: :sum,
      gap: "not measured — separate design"
    },
    %{
      id: :lighthouse_score,
      unit: "float",
      source: "Lighthouse CI",
      aggregator: :sum,
      gap: "not measured — separate design"
    },
    %{
      id: :judge_coherence_score,
      unit: "float",
      source: "LLM judge",
      aggregator: :sum,
      gap: "not measured — separate design"
    },
    %{
      id: :cache_read_tokens_by_role,
      unit: "count",
      source:
        "UsageParser.parse_per_role/3 — per-subagent transcript sums",
      aggregator: :sum,
      gap: "separate shape — %{role => %{...}}, not a flat scalar"
    }
  ]

  @doc "Returns the full catalog of all metrics (measurable + stub)."
  @spec all_metrics() :: [metric()]
  def all_metrics, do: @catalog

  @doc "Returns only measurable metrics (gap: nil)."
  @spec measurable() :: [metric()]
  def measurable, do: Enum.filter(@catalog, fn m -> is_nil(m.gap) end)

  @doc "Returns only stub metrics (gap is a non-nil string)."
  @spec gaps() :: [metric()]
  def gaps, do: Enum.filter(@catalog, fn m -> not is_nil(m.gap) end)

  @doc "Returns the metric map for a given id, or nil if not found."
  @spec metric_for(atom()) :: metric() | nil
  def metric_for(id), do: Enum.find(@catalog, fn m -> m.id == id end)
end

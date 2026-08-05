defmodule CodegenTestHarness.UsageParser do
  @moduledoc """
  Parses stream-json envelope output from codegen-build invocations to extract
  LLM usage metrics.

  ## Claude envelope shape

  Line-by-line JSONL. First `{"type":"system","subtype":"init"}` line carries
  `model`. Last `{"type":"result","subtype":"success"}` line carries `usage`,
  `total_cost_usd`, `modelUsage`, `duration_ms`, `duration_api_ms`,
  `num_turns`, `terminal_reason`.

  All missing fields return `:unknown`.

  ## Per-role attribution (`parse_per_role/3`)

  Claude reads per-subagent transcript files from
  `~/.claude/projects/<proj>/<session_id>/subagents/agent-*.jsonl` and adds
  the main transcript as an `"orchestrator"` bucket.
  """

  @type parsed :: %{
          model: String.t() | :unknown,
          input_tokens: non_neg_integer() | :unknown,
          output_tokens: non_neg_integer() | :unknown,
          cache_read_tokens: non_neg_integer() | :unknown,
          cache_creation_tokens: non_neg_integer() | :unknown,
          cost_usd: float() | :unknown,
          duration_ms: non_neg_integer() | :unknown,
          duration_api_ms: non_neg_integer() | :unknown,
          num_turns: non_neg_integer() | :unknown,
          terminal_reason: String.t() | :unknown
        }

  @doc """
  Parses `raw_stdout` captured from a `codegen-build` invocation.

  `harness` is `:claude`. Returns a `t:parsed/0` map; all fields
  default to `:unknown` on missing or unparseable input.
  """
  @spec parse(String.t(), :claude) :: parsed()
  def parse(raw_stdout, :claude) do
    lines = decode_lines(raw_stdout)

    model = extract_claude_model(lines)
    result = extract_claude_result(lines)

    usage = Map.get(result, "usage", %{})
    model_usage = resolve_model_usage(result, model)

    %{
      model: model,
      input_tokens: int_field(usage, "input_tokens", model_usage, "inputTokens"),
      output_tokens: int_field(usage, "output_tokens", model_usage, "outputTokens"),
      cache_read_tokens:
        int_field(usage, "cache_read_input_tokens", model_usage, "cacheReadInputTokens"),
      cache_creation_tokens:
        int_field(
          usage,
          "cache_creation_input_tokens",
          model_usage,
          "cacheCreationInputTokens"
        ),
      cost_usd: float_or_unknown(result, "total_cost_usd"),
      duration_ms: int_or_unknown(result, "duration_ms"),
      duration_api_ms: int_or_unknown(result, "duration_api_ms"),
      num_turns: int_or_unknown(result, "num_turns"),
      terminal_reason: string_or_unknown(result, "terminal_reason")
    }
  end

  # The loop's terminal result line. Unlike extract_claude_result/1 this accepts
  # ANY subtype: a failed build ("subtype":"error") still reports real
  # total_cost_usd and per_role spend, and a bench run that discards the cost of
  # failed attempts under-reports what the run actually billed.
  defp extract_loop_result(lines) do
    lines
    |> Enum.filter(&match?(%{"type" => "result", "engine" => "elixir_loop"}, &1))
    |> List.last()
    |> case do
      nil -> %{}
      result -> result
    end
  end

  @type per_role_usage :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          cache_creation_tokens: non_neg_integer()
        }

  @type dispatch :: %{
          harness: String.t() | nil,
          model: String.t() | nil,
          effort: String.t() | nil
        }

  @doc """
  Parses per-role, per-invocation dispatch provenance (the ACTUAL requested
  harness/model/effort tuple for every codegen-call the loop made) from raw
  `codegen-build` stdout — the loop's own terminal `{"type":"result",
  "engine":"elixir_loop",...}` line. Harness-agnostic: this is loop-internal
  bookkeeping, not per-harness envelope shape.

  Returns `%{role => [dispatch(), ...]}`, one entry per invocation IN CALL
  ORDER (gate retries and rework re-invocations of the same role each add
  their own entry). Returns `%{}` when the loop terminal line is absent
  (e.g. a raw non-loop-driven capture).
  """
  @spec parse_dispatches(String.t()) :: %{optional(String.t()) => [dispatch()]}
  def parse_dispatches(output) do
    output
    |> decode_lines()
    |> extract_loop_result()
    |> dispatches_from_loop_result()
  end

  defp dispatches_from_loop_result(%{} = result) when map_size(result) > 0 do
    result
    |> Map.get("per_role", %{})
    |> Map.new(fn {role, entry} ->
      raw = Map.get(entry, "dispatches", [])

      normalized =
        Enum.map(raw, fn d ->
          %{
            harness: Map.get(d, "harness"),
            model: Map.get(d, "model"),
            effort: Map.get(d, "effort")
          }
        end)

      {role, normalized}
    end)
  end

  defp dispatches_from_loop_result(_), do: %{}

  @doc """
  Parses per-role token usage from Claude's per-subagent transcript files.

  For `:claude`, returns `%{role => per_role_usage}` keyed by subagent
  `agentType` plus an `"orchestrator"` bucket from the main transcript.
  Returns `%{}` on any failure (no session_id, dir not found) — graceful,
  never raises.

  `opts[:projects_root]` overrides the default `~/.claude/projects` base
  (used for hermetic tests).
  """
  @spec parse_per_role(String.t(), :claude, keyword()) :: %{
          optional(String.t()) => per_role_usage()
        }
  def parse_per_role(output, harness, opts \\ [])

  def parse_per_role(output, :claude, opts) do
    projects_root = Keyword.get(opts, :projects_root, Path.expand("~/.claude/projects"))

    with sid when is_binary(sid) <- extract_session_id(output),
         [subagents_dir | _] <- locate_subagents_dir(projects_root, sid) do
      subagents_dir
      |> per_role_from_subagents()
      |> Map.merge(orchestrator_bucket(projects_root, sid))
    else
      _ -> %{}
    end
  end

  # ── Shared helpers ─────────────────────────────────────────────────────────

  defp decode_lines(raw_stdout) do
    raw_stdout
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case Jason.decode(line) do
        {:ok, map} -> map
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # ── Per-role helpers ───────────────────────────────────────────────────────

  defp extract_session_id(output) do
    output
    |> decode_lines()
    |> Enum.find_value(fn
      %{"session_id" => sid} when is_binary(sid) -> sid
      _ -> nil
    end)
  end

  defp locate_subagents_dir(projects_root, sid) do
    Path.wildcard(Path.join([projects_root, "*", sid, "subagents"]))
    |> Enum.filter(&File.dir?/1)
  end

  defp per_role_from_subagents(subagents_dir) do
    subagents_dir
    |> Path.join("agent-*.jsonl")
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn jsonl_path, acc ->
      role = role_for_agent_file(jsonl_path)
      usage = sum_assistant_usage(File.read(jsonl_path))
      Map.update(acc, role, usage, &merge_usage(&1, usage))
    end)
  end

  defp orchestrator_bucket(projects_root, sid) do
    case Path.wildcard(Path.join([projects_root, "*", "#{sid}.jsonl"])) do
      [main | _] -> %{"orchestrator" => sum_assistant_usage(File.read(main))}
      [] -> %{}
    end
  end

  defp role_for_agent_file(jsonl_path) do
    meta_path = String.replace_suffix(jsonl_path, ".jsonl", ".meta.json")

    with {:ok, content} <- File.read(meta_path),
         {:ok, %{"agentType" => type}} when is_binary(type) <- Jason.decode(content) do
      type
    else
      _ -> "unattributed"
    end
  end

  defp sum_assistant_usage({:error, _}), do: zero_usage()

  defp sum_assistant_usage({:ok, content}) do
    content
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case Jason.decode(line) do
        {:ok, map} -> map
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn
      %{"type" => "assistant"} -> true
      _ -> false
    end)
    |> Enum.reduce(zero_usage(), fn turn, acc ->
      usage = get_in(turn, ["message", "usage"]) || %{}

      turn_usage = %{
        input_tokens: int_usage(usage, "input_tokens"),
        output_tokens: int_usage(usage, "output_tokens"),
        cache_read_tokens: int_usage(usage, "cache_read_input_tokens"),
        cache_creation_tokens: int_usage(usage, "cache_creation_input_tokens")
      }

      merge_usage(acc, turn_usage)
    end)
  end

  defp zero_usage do
    %{
      input_tokens: 0,
      output_tokens: 0,
      cache_read_tokens: 0,
      cache_creation_tokens: 0
    }
  end

  defp int_usage(map, key) do
    case Map.get(map, key) do
      v when is_integer(v) -> v
      v when is_float(v) -> round(v)
      _ -> 0
    end
  end

  defp merge_usage(a, b) do
    %{
      input_tokens: a.input_tokens + b.input_tokens,
      output_tokens: a.output_tokens + b.output_tokens,
      cache_read_tokens: a.cache_read_tokens + b.cache_read_tokens,
      cache_creation_tokens: a.cache_creation_tokens + b.cache_creation_tokens
    }
  end

  # ── Claude helpers ─────────────────────────────────────────────────────────

  defp extract_claude_model(lines) do
    init_line =
      Enum.find(lines, fn
        %{"type" => "system", "subtype" => "init"} -> true
        _ -> false
      end)

    case init_line do
      %{"model" => model} when is_binary(model) -> model
      _ -> :unknown
    end
  end

  # Accepts ANY subtype, not just "success".
  #
  # Filtering to subtype == "success" meant a FAILED build reported no cost at
  # all: the loop still emits `{"type":"result","subtype":"error",...}` carrying
  # a real total_cost_usd (a failed static build was observed billing $2.2094
  # across 94 turns), but the bench record stored `cost_usd: :unknown` and the
  # summary printed "—". Benchmarks therefore under-reported spend precisely on
  # the runs that burned money without shipping anything — the case you most
  # need costed. Pass/fail is carried separately by `assertion_passed` +
  # `terminal_reason`, so admitting error results here cannot make a red run
  # look green.
  defp extract_claude_result(lines) do
    result_line =
      lines
      |> Enum.filter(&match?(%{"type" => "result"}, &1))
      |> List.last()

    result_line || %{}
  end

  defp resolve_model_usage(result, model) do
    case Map.get(result, "modelUsage") do
      map when is_map(map) and map_size(map) > 0 ->
        key =
          cond do
            is_binary(model) and Map.has_key?(map, model) -> model
            true -> map |> Map.keys() |> List.first()
          end

        Map.get(map, key, %{})

      _ ->
        %{}
    end
  end

  defp int_field(primary_map, primary_key, fallback_map, fallback_key) do
    case Map.get(primary_map, primary_key) do
      v when is_integer(v) ->
        v

      v when is_float(v) ->
        round(v)

      _ ->
        case Map.get(fallback_map, fallback_key) do
          v when is_integer(v) -> v
          v when is_float(v) -> round(v)
          _ -> :unknown
        end
    end
  end

  defp int_or_unknown(map, key) do
    case Map.get(map, key) do
      v when is_integer(v) -> v
      v when is_float(v) -> round(v)
      _ -> :unknown
    end
  end

  defp float_or_unknown(map, key) do
    case Map.get(map, key) do
      v when is_float(v) -> v
      v when is_integer(v) -> v * 1.0
      _ -> :unknown
    end
  end

  defp string_or_unknown(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) -> v
      _ -> :unknown
    end
  end

end

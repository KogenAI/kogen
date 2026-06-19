defmodule CodegenTestHarness.UsageParser do
  @moduledoc """
  Parses stream-json envelope output from codegen-build invocations to extract
  LLM usage metrics.

  ## Claude envelope shape

  Line-by-line JSONL. First `{"type":"system","subtype":"init"}` line carries
  `model`. Last `{"type":"result","subtype":"success"}` line carries `usage`,
  `total_cost_usd`, `modelUsage`, `duration_ms`, `duration_api_ms`,
  `num_turns`, `terminal_reason`.

  ## Pi envelope shape (from live probe)

  `{"type":"agent_end","messages":[...]}` — each message has `model` and
  `usage.{input,output,cacheRead,cacheWrite,totalTokens,cost.total}`. No
  top-level `duration_ms`, `duration_api_ms`, `num_turns`, `terminal_reason`,
  or `total_cost_usd` fields.

  All missing fields return `:unknown`.

  ## Per-role attribution (`parse_per_role/3`)

  Claude only — reads per-subagent transcript files from
  `~/.claude/projects/<proj>/<session_id>/subagents/agent-*.jsonl` and adds
  the main transcript as an `"orchestrator"` bucket.

  Pi returns `%{}` — Pi has no `~/.claude` subagent transcripts.
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

  `harness` is `:claude` or `:pi`. Returns a `t:parsed/0` map; all fields
  default to `:unknown` on missing or unparseable input.
  """
  @spec parse(String.t(), :claude | :pi) :: parsed()
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

  def parse(raw_stdout, :pi) do
    lines = decode_lines(raw_stdout)

    agent_end =
      Enum.find(lines, fn
        %{"type" => "agent_end"} -> true
        _ -> false
      end)

    case agent_end do
      nil ->
        %{
          model: :unknown,
          input_tokens: :unknown,
          output_tokens: :unknown,
          cache_read_tokens: :unknown,
          cache_creation_tokens: :unknown,
          cost_usd: :unknown,
          duration_ms: :unknown,
          duration_api_ms: :unknown,
          num_turns: :unknown,
          terminal_reason: :unknown
        }

      %{"messages" => messages} when is_list(messages) ->
        extract_pi_metrics(messages)

      _ ->
        unknown_pi_map()
    end
  end

  @type per_role_usage :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          cache_creation_tokens: non_neg_integer()
        }

  @doc """
  Parses per-role token usage from Claude's per-subagent transcript files.

  Returns `%{role => per_role_usage}` keyed by subagent `agentType` plus an
  `"orchestrator"` bucket from the main transcript. Returns `%{}` on any
  failure (no session_id, dir not found, Pi harness) — graceful, never raises.

  `opts[:projects_root]` overrides the default `~/.claude/projects` base
  (used for hermetic tests).

  Pi returns `%{}` — Pi has no `~/.claude` subagent transcripts.
  """
  @spec parse_per_role(String.t(), :claude | :pi, keyword()) :: %{
          optional(String.t()) => per_role_usage()
        }
  def parse_per_role(output, harness, opts \\ [])
  def parse_per_role(_output, :pi, _opts), do: %{}

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

  defp extract_claude_result(lines) do
    result_line =
      lines
      |> Enum.filter(fn
        %{"type" => "result", "subtype" => "success"} -> true
        _ -> false
      end)
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

  # ── Pi helpers ─────────────────────────────────────────────────────────────

  defp extract_pi_metrics(messages) do
    acc =
      Enum.reduce(
        messages,
        %{
          in: :unknown,
          out: :unknown,
          read: :unknown,
          write: :unknown,
          cost: :unknown,
          model: nil
        },
        fn msg, acc ->
          usage = Map.get(msg, "usage") || %{}
          cost_map = Map.get(usage, "cost") || %{}
          model = Map.get(msg, "model") || acc.model

          %{
            in: add_unknown(acc.in, pi_int(usage, "input")),
            out: add_unknown(acc.out, pi_int(usage, "output")),
            read: add_unknown(acc.read, pi_int(usage, "cacheRead")),
            write: add_unknown(acc.write, pi_int(usage, "cacheWrite")),
            cost: add_unknown_float(acc.cost, pi_float(cost_map, "total")),
            model: model
          }
        end
      )

    %{
      model: acc.model || :unknown,
      input_tokens: acc.in,
      output_tokens: acc.out,
      cache_read_tokens: acc.read,
      cache_creation_tokens: acc.write,
      cost_usd: acc.cost,
      duration_ms: :unknown,
      duration_api_ms: :unknown,
      num_turns: :unknown,
      terminal_reason: :unknown
    }
  end

  defp unknown_pi_map do
    %{
      model: :unknown,
      input_tokens: :unknown,
      output_tokens: :unknown,
      cache_read_tokens: :unknown,
      cache_creation_tokens: :unknown,
      cost_usd: :unknown,
      duration_ms: :unknown,
      duration_api_ms: :unknown,
      num_turns: :unknown,
      terminal_reason: :unknown
    }
  end

  defp pi_int(map, key) do
    case Map.get(map, key) do
      v when is_integer(v) -> v
      v when is_float(v) -> round(v)
      _ -> :unknown
    end
  end

  defp pi_float(map, key) do
    case Map.get(map, key) do
      v when is_float(v) -> v
      v when is_integer(v) -> v * 1.0
      _ -> :unknown
    end
  end

  # Adds two values where either may be :unknown.
  # :unknown + N = N (treat missing as not-yet-seen, not as zero)
  # N + :unknown = N
  # :unknown + :unknown = :unknown
  defp add_unknown(:unknown, :unknown), do: :unknown
  defp add_unknown(:unknown, v) when is_number(v), do: v
  defp add_unknown(acc, :unknown) when is_number(acc), do: acc
  defp add_unknown(acc, v) when is_number(acc) and is_number(v), do: acc + v

  defp add_unknown_float(:unknown, :unknown), do: :unknown
  defp add_unknown_float(:unknown, v) when is_number(v), do: v * 1.0
  defp add_unknown_float(acc, :unknown) when is_number(acc), do: acc
  defp add_unknown_float(acc, v) when is_number(acc) and is_number(v), do: acc + v * 1.0
end

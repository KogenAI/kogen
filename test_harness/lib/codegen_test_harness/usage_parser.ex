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

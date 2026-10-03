defmodule Kogen.Harness.Shaping.State do
  @moduledoc false

  @enforce_keys [:opts, :slug, :transcript_path, :items, :calls, :turns, :turn_offset, :deadline]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          opts: Kogen.Harness.Opts.t(),
          slug: String.t(),
          transcript_path: Path.t(),
          items: [map()],
          calls: [Kogen.Harness.ShapeCall.t()],
          turns: non_neg_integer(),
          turn_offset: non_neg_integer(),
          deadline: integer()
        }
end

defmodule Kogen.Harness.Shaping do
  @moduledoc false

  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ToolCall
  alias Kogen.Harness.Codec
  alias Kogen.Harness.Error
  alias Kogen.Harness.Exchange
  alias Kogen.Harness.Exchange.Request, as: ExchangeRequest
  alias Kogen.Harness.Opts
  alias Kogen.Harness.Recording
  alias Kogen.Harness.ShapeCall
  alias Kogen.Harness.ShapePass
  alias Kogen.Harness.ShaperTools
  alias Kogen.Harness.Shaping.State
  alias Kogen.Harness.ToolResult
  alias Kogen.Harness.Usage

  @instructions """
  You are Kogen Intent shaper. The Intent uses YAML frontmatter with title, domains, and size, a prose Brief, `## Acceptance` items `A1` through `An`, and `## Verify` lines `- A1: test domain=<domain>` or `- A1: test keep domain=<domain>`. Each test has `@tag intent: \"<slug>/A<n>\"`. A `test` item must fail on the unchanged checkout; use `test keep` for existing behaviour that must pass. Test through public functions. Do not implement the task.
  """

  @spec run(Opts.t(), String.t(), String.t(), [map()], String.t() | nil, non_neg_integer()) ::
          {:ok, ShapePass.t()} | {:error, term()}
  def run(%Opts{} = opts, slug, task, history, failure_text, turn_offset) do
    with :ok <- valid_request(slug, task, history, failure_text, turn_offset, opts),
         {:ok, transcript_path} <- Recording.path(opts),
         {:ok, items} <- input_items(slug, task, history, failure_text) do
      started_at = System.monotonic_time(:millisecond)

      state = %State{
        opts: opts,
        slug: slug,
        transcript_path: transcript_path,
        items: items,
        calls: [],
        turns: turn_offset,
        turn_offset: turn_offset,
        deadline: started_at + opts.limits.wall_ms
      }

      shape_loop(state)
    end
  end

  defp shape_loop(%State{} = state) do
    local_turns = state.turns - state.turn_offset
    remaining_ms = max(state.deadline - System.monotonic_time(:millisecond), 0)

    cond do
      local_turns >= state.opts.limits.max_turns ->
        error(:shape_turn_limit, "Shaper exhausted its turn limit.")

      remaining_ms == 0 ->
        error(:shape_wall_limit, "Shaper exhausted its wall time limit.")

      true ->
        shape_turn(state, remaining_ms)
    end
  end

  defp shape_turn(%State{} = state, remaining_ms) do
    {model, effort} = state.opts.models.builder

    request = %ExchangeRequest{
      stage: :shape,
      turn: state.turns + 1,
      model: model,
      effort: effort,
      instructions: @instructions,
      items: state.items,
      tool_names: Codec.tool_names(:shaper),
      remaining_ms: remaining_ms
    }

    call_started = System.monotonic_time(:millisecond)

    case Exchange.respond(state.opts, request) do
      {:ok, %ModelResponse{} = response} ->
        accept_response(state, response, model, effort, call_started)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp accept_response(state, response, model, effort, call_started) do
    call = %ShapeCall{
      stage: :shape,
      model: model,
      effort: effort,
      tokens: Usage.zero() |> Codec.usage(response.usage) |> Usage.to_map(),
      wall_ms: elapsed(call_started)
    }

    case record_model_usage(state, call) do
      :ok ->
        state = %{
          state
          | turns: state.turns + 1,
            items: state.items ++ response.raw_items,
            calls: [call | state.calls]
        }

        if response.tool_calls == [],
          do: complete(state, response),
          else: run_tools(state, response.tool_calls)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete(%State{} = state, %ModelResponse{text: text}) do
    {:ok,
     %ShapePass{
       items: state.items,
       text: text,
       calls: Enum.reverse(state.calls),
       turns: state.turns - state.turn_offset
     }}
  end

  defp run_tools(%State{} = state, calls) do
    calls
    |> Enum.reduce_while({:ok, state}, fn %ToolCall{} = call, {:ok, current} ->
      case run_tool(current, call) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> continue_loop()
  end

  defp run_tool(%State{} = state, %ToolCall{} = call) do
    with :ok <- record(state, :tool_call, call),
         %ToolResult{} = result <- ShaperTools.run(state.opts, call, output_paths(state.slug)),
         :ok <- record(state, :tool_result, %{call: call, result: result}) do
      output = Codec.function_output(call.id, result.output)
      {:ok, %{state | items: state.items ++ [output]}}
    end
  end

  defp continue_loop({:ok, %State{} = state}), do: shape_loop(state)
  defp continue_loop({:error, reason}), do: {:error, reason}

  defp input_items(slug, task, [], nil) do
    text =
      "Slug: #{slug}\n\nTask statement:\n#{task}\n\nWrite the Intent and acceptance test at the two paths named by the Kogen format."

    {:ok, [Codec.user_item(text)]}
  end

  defp input_items(_slug, _task, history, failure_text)
       when is_list(history) and is_binary(failure_text) do
    repair =
      "Validation failed. Repair the generated files. Exact failure output follows:\n\n" <>
        failure_text

    {:ok, history ++ [Codec.user_item(repair)]}
  end

  defp input_items(_slug, _task, _history, _failure_text),
    do: error(:invalid_shape_history, "Shaper repair history is invalid.")

  defp valid_request(slug, task, history, failure_text, turn_offset, opts) do
    with :ok <- valid_slug(slug),
         :ok <- valid_task(task),
         :ok <- valid_history(history, failure_text),
         :ok <- valid_turn_offset(turn_offset) do
      valid_limits(opts)
    end
  end

  defp valid_slug(slug) do
    if is_binary(slug) and Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug),
      do: :ok,
      else: error(:invalid_slug, "Slug must use lowercase letters, digits, and dashes.")
  end

  defp valid_task(task) do
    if is_binary(task) and String.trim(task) != "",
      do: :ok,
      else: error(:empty_task, "Task statement must not be empty.")
  end

  defp valid_history([], nil), do: :ok
  defp valid_history(history, failure) when is_list(history) and is_binary(failure), do: :ok

  defp valid_history(_history, _failure),
    do: error(:invalid_shape_history, "Shaper history or failure text is invalid.")

  defp valid_turn_offset(value) when is_integer(value) and value >= 0, do: :ok

  defp valid_turn_offset(_value),
    do: error(:invalid_turn_offset, "Shaper turn offset must be non-negative.")

  defp valid_limits(opts) do
    cond do
      not is_integer(opts.limits.max_turns) or opts.limits.max_turns < 1 ->
        error(:invalid_turn_limit, "max_turns must be positive.")

      not is_integer(opts.limits.wall_ms) or opts.limits.wall_ms < 1 ->
        error(:invalid_wall_limit, "wall_ms must be positive.")

      true ->
        :ok
    end
  end

  defp record(state, event, payload),
    do: Recording.append(state.opts, event, :shape, state.turns, payload)

  defp record_model_usage(state, %ShapeCall{} = call),
    do: Recording.append(state.opts, :model_usage, :shape, state.turns + 1, call)

  defp output_paths(slug),
    do: [".kogen/intents/#{slug}/intent.md", ".kogen/acceptance/#{slug}_test.exs"]

  defp elapsed(started), do: max(System.monotonic_time(:millisecond) - started, 0)
  defp error(reason, detail), do: {:error, %Error{reason: reason, detail: detail}}
end

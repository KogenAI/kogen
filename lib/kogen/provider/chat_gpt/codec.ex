defmodule Kogen.Provider.ChatGPT.Codec do
  @moduledoc "Encodes ChatGPT Responses requests and decodes JSON/SSE streams."

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ProviderError
  alias Kogen.Contracts.ToolCall

  defmodule Stream do
    @moduledoc false
    defstruct buffer: "",
              event_lines: [],
              items: [],
              completed: nil,
              failure: nil,
              malformed?: false

    @type t :: %__MODULE__{
            buffer: binary(),
            event_lines: [binary()],
            items: [map()],
            completed: map() | nil,
            failure: ProviderError.t() | nil,
            malformed?: boolean()
          }
  end

  @spec encode_request(ModelRequest.t()) :: {:ok, binary()} | {:error, ProviderError.t()}
  def encode_request(%ModelRequest{} = request) do
    if valid_request?(request) do
      request
      |> request_body()
      |> encode_json()
    else
      malformed_error()
    end
  end

  @spec request_fingerprint(ModelRequest.t()) :: {:ok, String.t()} | {:error, ProviderError.t()}
  def request_fingerprint(%ModelRequest{} = request) do
    with true <- valid_request?(request),
         {:ok, encoded} <- request |> request_body() |> encode_json() do
      digest = :sha256 |> :crypto.hash(encoded) |> Base.encode16(case: :lower)
      {:ok, digest}
    else
      _ -> malformed_error()
    end
  end

  @spec new_stream() :: Stream.t()
  def new_stream, do: %Stream{}

  @spec feed(Stream.t(), binary()) :: Stream.t()
  def feed(%Stream{} = stream, chunk) when is_binary(chunk) do
    combined = normalize_newlines(stream.buffer <> chunk)
    parts = :binary.split(combined, "\n\n", [:global])
    {frames, [buffer]} = Enum.split(parts, length(parts) - 1)
    Enum.reduce(frames, %{stream | buffer: buffer}, &read_frame/2)
  end

  @spec finish(Stream.t()) :: {:ok, ModelResponse.t()} | {:error, ProviderError.t()}
  def finish(%Stream{} = stream) do
    stream = flush_buffer(stream)

    cond do
      not is_nil(stream.failure) -> {:error, stream.failure}
      stream.malformed? -> malformed_error()
      is_nil(stream.completed) -> malformed_error()
      true -> response(stream)
    end
  end

  @spec sse_lines(binary()) :: {:ok, [binary()]} | {:error, ProviderError.t()}
  def sse_lines(body) when is_binary(body) do
    stream = new_stream() |> feed(body) |> flush_buffer()
    if stream.malformed?, do: malformed_error(), else: {:ok, Enum.reverse(stream.event_lines)}
  end

  def sse_lines(_body), do: malformed_error()

  defp valid_request?(request) do
    is_binary(request.model) and request.model != "" and is_binary(request.effort) and
      request.effort != "" and is_binary(request.instructions) and is_list(request.input) and
      is_list(request.tools) and
      (is_nil(request.previous_response_id) or is_binary(request.previous_response_id))
  end

  defp request_body(request) do
    body = %{
      "model" => request.model,
      "instructions" => request.instructions,
      "input" => request.input,
      "tools" => request.tools,
      "reasoning" => %{"effort" => request.effort},
      "store" => false,
      "stream" => true,
      "include" => ["reasoning.encrypted_content"]
    }

    case request.previous_response_id do
      nil -> body
      response_id -> Map.put(body, "previous_response_id", response_id)
    end
  end

  defp encode_json(value) do
    {:ok, value |> :json.encode() |> IO.iodata_to_binary()}
  rescue
    ErlangError -> malformed_error()
  end

  defp normalize_newlines(binary) do
    binary |> :binary.replace("\r\n", "\n", [:global]) |> :binary.replace("\r", "\n", [:global])
  end

  defp flush_buffer(%Stream{buffer: ""} = stream), do: stream

  defp flush_buffer(%Stream{buffer: buffer} = stream) do
    read_frame(<<buffer::binary, "\n\n">>, %{stream | buffer: ""})
  end

  defp read_frame(frame, stream) do
    data = frame |> :binary.split("\n", [:global]) |> frame_data()

    if data in ["", "[DONE]"] do
      stream
    else
      decode_event(data, %{stream | event_lines: [data | stream.event_lines]})
    end
  end

  defp frame_data(lines) do
    lines
    |> Enum.flat_map(fn
      <<"data:", value::binary>> -> [trim_one_space(value)]
      _line -> []
    end)
    |> Enum.join("\n")
  end

  defp trim_one_space(<<32, rest::binary>>), do: rest
  defp trim_one_space(value), do: value

  defp decode_event(data, stream) do
    case decode_json(data) do
      {:ok, %{"type" => "response.output_item.done", "item" => item}} when is_map(item) ->
        %{stream | items: [item | stream.items]}

      {:ok, %{"type" => "response.completed", "response" => response}} when is_map(response) ->
        put_completion(stream, response)

      {:ok, %{"type" => type} = event} when type in ["error", "response.failed"] ->
        put_failure(stream, classify_event_error(event))

      {:ok, %{"type" => "response.incomplete"} = event} ->
        put_failure(stream, classify_event_error(event))

      {:ok, %{"error" => error} = event} when not is_nil(error) ->
        put_failure(stream, classify_event_error(event))

      {:ok, event} when is_map(event) ->
        stream

      _ ->
        %{stream | malformed?: true}
    end
  end

  defp decode_json(data) do
    {:ok, :json.decode(data)}
  rescue
    ErlangError -> {:error, :invalid_json}
  end

  defp put_completion(%Stream{completed: nil} = stream, response),
    do: %{stream | completed: response}

  defp put_completion(stream, _response), do: %{stream | malformed?: true}

  defp put_failure(%Stream{failure: nil} = stream, failure), do: %{stream | failure: failure}
  defp put_failure(stream, _failure), do: stream

  defp classify_event_error(event) do
    encoded = event |> :json.encode() |> IO.iodata_to_binary() |> String.downcase()

    cond do
      contains_any?(encoded, ["usage_limit", "usage limit", "rate_limit", "rate limit"]) ->
        error(:usage_limit)

      contains_any?(encoded, ["server_is_overloaded", "overloaded", "overload"]) ->
        error(:overload)

      true ->
        error(:transport)
    end
  rescue
    ErlangError -> error(:transport)
  end

  defp contains_any?(text, values), do: Enum.any?(values, &String.contains?(text, &1))

  defp response(stream) do
    with %{"status" => "completed", "id" => id} = completed <- stream.completed,
         true <- is_binary(id) and id != "",
         {:ok, items} <- output_items(completed, stream.items),
         {:ok, calls} <- tool_calls(items),
         {:ok, usage} <- usage(completed["usage"]) do
      {:ok,
       %ModelResponse{
         id: id,
         text: output_text(items),
         tool_calls: calls,
         usage: usage,
         raw_items: items
       }}
    else
      _ -> malformed_error()
    end
  end

  defp output_items(%{"output" => []}, streamed) when streamed != [],
    do: streamed |> Enum.reverse() |> valid_items()

  defp output_items(%{"output" => items}, _streamed) when is_list(items), do: valid_items(items)

  defp output_items(_completed, streamed) when streamed != [],
    do: streamed |> Enum.reverse() |> valid_items()

  defp output_items(_completed, _streamed), do: malformed_error()

  defp valid_items(items) do
    if Enum.all?(items, &is_map/1), do: {:ok, items}, else: malformed_error()
  end

  defp output_text(items) do
    items
    |> Enum.filter(&(&1["type"] == "message"))
    |> Enum.flat_map(fn item -> if is_list(item["content"]), do: item["content"], else: [] end)
    |> Enum.filter(&(&1["type"] == "output_text" and is_binary(&1["text"])))
    |> Enum.map_join(& &1["text"])
  end

  defp tool_calls(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, calls} ->
      case tool_call(item) do
        :skip -> {:cont, {:ok, calls}}
        {:ok, call} -> {:cont, {:ok, [call | calls]}}
        :error -> {:halt, malformed_error()}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      error -> error
    end
  end

  defp tool_call(%{"type" => "function_call", "call_id" => id, "name" => name} = item)
       when is_binary(id) and id != "" and is_binary(name) and name != "" do
    case arguments(item["arguments"]) do
      {:ok, arguments} -> {:ok, %ToolCall{id: id, name: name, arguments: arguments}}
      _ -> :error
    end
  end

  defp tool_call(%{"type" => "function_call"}), do: :error
  defp tool_call(_item), do: :skip

  defp arguments(arguments) when is_map(arguments), do: {:ok, arguments}

  defp arguments(arguments) when is_binary(arguments) do
    case decode_json(arguments) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, :invalid_arguments}
    end
  end

  defp arguments(_arguments), do: {:error, :invalid_arguments}

  defp usage(%{"input_tokens" => input, "output_tokens" => output} = usage)
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0 do
    with {:ok, cached} <- optional_count(usage, "input_tokens_details", "cached_tokens"),
         {:ok, reasoning} <- optional_count(usage, "output_tokens_details", "reasoning_tokens"),
         true <- cached <= input do
      {:ok, %{input: input - cached, cached_input: cached, output: output, reasoning: reasoning}}
    else
      _ -> {:error, :invalid_usage}
    end
  end

  defp usage(_usage), do: {:error, :invalid_usage}

  defp optional_count(usage, details_key, count_key) do
    case usage[details_key] do
      nil -> {:ok, 0}
      %{^count_key => count} when is_integer(count) and count >= 0 -> {:ok, count}
      _ -> {:error, :invalid_usage}
    end
  end

  defp malformed_error do
    {:error, error(:malformed)}
  end

  defp error(:usage_limit),
    do: %ProviderError{class: :usage_limit, message: "ChatGPT subscription usage limit reached."}

  defp error(:overload),
    do: %ProviderError{class: :overload, message: "ChatGPT service is temporarily overloaded."}

  defp error(:transport),
    do: %ProviderError{class: :transport, message: "ChatGPT stream reported a provider error."}

  defp error(:malformed),
    do: %ProviderError{
      class: :malformed,
      message: "ChatGPT returned a malformed response stream."
    }
end

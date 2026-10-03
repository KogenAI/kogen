defmodule Kogen.Provider.ChatGPT.Codec.Recording do
  @moduledoc false

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ProviderError
  alias Kogen.Provider.ChatGPT.Codec.Errors

  @tool_call_recording """
  {
    "instructions": "Call the echo_phrase function exactly once with phrase set to recorded.",
    "input": [{"role": "user", "content": [{"type": "input_text", "text": "Use the function tool now."}]}],
    "tools": [
      {
        "type": "function",
        "name": "echo_phrase",
        "description": "Echo a phrase supplied by the user.",
        "parameters": {
          "type": "object",
          "properties": {"phrase": {"type": "string"}},
          "required": ["phrase"],
          "additionalProperties": false
        },
        "strict": false
      }
    ]
  }
  """
  @text_recording ~s({"instructions":"Answer exactly with the word recorded.","input":[{"role":"user","content":[{"type":"input_text","text":"Reply now."}]}],"tools":[]})

  @spec recording_request(String.t(), String.t(), String.t()) :: ModelRequest.t()
  def recording_request(scenario, model, effort) do
    template = if scenario == "tool_call", do: @tool_call_recording, else: @text_recording
    {:ok, fields} = decode_json(template)

    %ModelRequest{
      model: model,
      effort: effort,
      instructions: fields["instructions"],
      input: fields["input"],
      tools: fields["tools"],
      previous_response_id: nil
    }
  end

  @spec decode_recording(binary()) ::
          {:ok, {String.t(), String.t(), [binary()]}} | {:error, ProviderError.t()}
  def decode_recording(contents) when is_binary(contents) do
    case String.split(contents, "\n", trim: true) do
      [metadata | rows] -> decode_recording(metadata, rows)
      [] -> Errors.recording("Provider fixture is missing or malformed.")
    end
  end

  @spec encode_recording(String.t(), String.t(), [binary()]) ::
          {:ok, binary()} | {:error, ProviderError.t()}
  def encode_recording(model, fingerprint, event_lines)
      when is_binary(model) and is_binary(fingerprint) and is_list(event_lines) do
    if Enum.all?(event_lines, &is_binary/1) do
      encode_rows(model, fingerprint, event_lines)
    else
      {:error, Errors.provider(:malformed)}
    end
  end

  defp decode_recording(metadata, rows) do
    case decode_json(metadata) do
      {:ok, %{"kind" => "recording", "model" => model, "request_sha256" => fingerprint}}
      when is_binary(model) and is_binary(fingerprint) ->
        case decode_events(rows) do
          {:ok, event_lines} -> {:ok, {model, fingerprint, event_lines}}
          {:error, %ProviderError{} = provider_error} -> {:error, provider_error}
        end

      _ ->
        Errors.recording("Provider fixture is missing or malformed.")
    end
  end

  defp decode_events(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, event_lines} ->
      case decode_json(row) do
        {:ok, %{"kind" => "sse", "data" => data}} when is_binary(data) ->
          {:cont, {:ok, [data | event_lines]}}

        _ ->
          {:halt, Errors.recording("Provider fixture contains an invalid SSE event.")}
      end
    end)
    |> case do
      {:ok, []} -> Errors.recording("Provider fixture contains no SSE events.")
      {:ok, event_lines} -> {:ok, Enum.reverse(event_lines)}
      {:error, %ProviderError{} = provider_error} -> {:error, provider_error}
    end
  end

  defp encode_rows(model, fingerprint, event_lines) do
    rows =
      [%{"kind" => "recording", "model" => model, "request_sha256" => fingerprint}] ++
        Enum.map(event_lines, &%{"kind" => "sse", "data" => &1})

    encoded = Enum.map_join(rows, "\n", &(&1 |> :json.encode() |> IO.iodata_to_binary()))
    {:ok, encoded <> "\n"}
  rescue
    ErlangError -> Errors.malformed()
  end

  defp decode_json(data) do
    {:ok, :json.decode(data)}
  rescue
    ErlangError -> {:error, :invalid_json}
  end
end

defmodule Kogen.Provider.Fake do
  @moduledoc "Replays exact ModelRequest fingerprints from JSONL SSE fixtures."
  @behaviour Kogen.Contracts.ProviderPort

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ProviderError
  alias Kogen.Provider.ChatGPT.Codec

  defmodule Recording do
    @moduledoc false
    @enforce_keys [:model, :request_sha256, :event_lines]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            model: String.t(),
            request_sha256: String.t(),
            event_lines: [binary()]
          }
  end

  defmodule Config do
    @moduledoc false
    @enforce_keys [:recordings]
    defstruct @enforce_keys

    @type t :: %__MODULE__{recordings: [Recording.t()]}
  end

  @spec config([Path.t()]) :: {:ok, Config.t()} | {:error, ProviderError.t()}
  def config(fixture_paths) when is_list(fixture_paths) do
    fixture_paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, recordings} ->
      case load_recording(path) do
        {:ok, recording} -> {:cont, {:ok, [recording | recordings]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, recordings} -> {:ok, %Config{recordings: Enum.reverse(recordings)}}
      error -> error
    end
  end

  @spec config(term()) :: {:error, ProviderError.t()}
  def config(_fixture_paths), do: malformed_error("Provider fixture list is invalid.")

  @impl true
  @spec respond(term(), ModelRequest.t()) ::
          {:ok, ModelResponse.t()} | {:error, ProviderError.t()}
  def respond(%Config{recordings: recordings}, %ModelRequest{} = request) do
    with {:ok, fingerprint} <- Codec.request_fingerprint(request),
         %Recording{} = recording <- find_recording(recordings, request.model, fingerprint) do
      replay(recording.event_lines)
    else
      nil -> malformed_error("No recorded provider response matches the request.")
      {:error, %ProviderError{} = error} -> {:error, error}
    end
  end

  def respond(_config, _request),
    do: malformed_error("Provider fixture configuration or request is invalid.")

  defp load_recording(path) when is_binary(path) do
    with {:ok, contents} <- File.read(path),
         [metadata | event_rows] <- String.split(contents, "\n", trim: true),
         {:ok, %{"kind" => "recording", "model" => model, "request_sha256" => fingerprint}} <-
           decode_row(metadata),
         true <- is_binary(model) and is_binary(fingerprint),
         {:ok, event_lines} <- event_lines(event_rows) do
      {:ok, %Recording{model: model, request_sha256: fingerprint, event_lines: event_lines}}
    else
      _ -> malformed_error("Provider fixture is missing or malformed.")
    end
  end

  defp load_recording(_path), do: malformed_error("Provider fixture path is invalid.")

  defp event_lines(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, lines} ->
      case decode_row(row) do
        {:ok, %{"kind" => "sse", "data" => data}} when is_binary(data) ->
          {:cont, {:ok, [data | lines]}}

        _ ->
          {:halt, malformed_error("Provider fixture contains an invalid SSE event.")}
      end
    end)
    |> case do
      {:ok, []} -> malformed_error("Provider fixture contains no SSE events.")
      {:ok, lines} -> {:ok, Enum.reverse(lines)}
      error -> error
    end
  end

  defp decode_row(row) do
    {:ok, :json.decode(row)}
  rescue
    ErlangError -> {:error, :invalid_json}
  end

  defp find_recording(recordings, model, fingerprint) do
    Enum.find(recordings, fn recording ->
      recording.model == model and recording.request_sha256 == fingerprint
    end)
  end

  defp replay(event_lines) do
    stream =
      Enum.reduce(event_lines, Codec.new_stream(), fn line, state ->
        Codec.feed(state, <<"data: ", line::binary, "\n\n">>)
      end)

    Codec.finish(stream)
  end

  defp malformed_error(message), do: {:error, %ProviderError{class: :malformed, message: message}}
end

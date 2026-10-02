defmodule Kogen.Provider.ChatGPT do
  @moduledoc "Streams Responses requests through the ChatGPT Codex subscription backend."
  @behaviour Kogen.Contracts.ProviderPort

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ProviderError
  alias Kogen.Provider.ChatGPT.Auth
  alias Kogen.Provider.ChatGPT.Codec
  alias Kogen.Provider.ChatGPT.Transport

  @endpoint "https://chatgpt.com/backend-api/codex/responses"
  @request_timeout_ms 300_000

  defmodule Config do
    @moduledoc false
    @derive {Inspect, except: [:access_token, :account_id]}
    @enforce_keys [:access_token, :account_id, :endpoint, :timeout_ms]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            access_token: String.t(),
            account_id: String.t(),
            endpoint: String.t(),
            timeout_ms: pos_integer()
          }
  end

  @spec config(Path.t()) :: {:ok, Config.t()} | {:error, ProviderError.t()}
  def config(auth_path) when is_binary(auth_path) do
    with {:ok, credentials} <- Auth.load(auth_path) do
      {:ok,
       %Config{
         access_token: credentials.access_token,
         account_id: credentials.account_id,
         endpoint: @endpoint,
         timeout_ms: @request_timeout_ms
       }}
    end
  end

  @spec config(term()) :: {:error, ProviderError.t()}
  def config(_auth_path), do: login_error()

  @impl true
  @spec respond(term(), ModelRequest.t()) ::
          {:ok, ModelResponse.t()} | {:error, ProviderError.t()}
  def respond(%Config{} = config, %ModelRequest{} = request) do
    if valid_config?(config) do
      case execute(config, request) do
        {:ok, response, _body} -> {:ok, response}
        error -> error
      end
    else
      provider_error(:malformed, "ChatGPT provider configuration is invalid.")
    end
  end

  def respond(_config, _request),
    do: provider_error(:malformed, "ChatGPT provider configuration or request is invalid.")

  @doc false
  @spec respond_with_transcript(Config.t(), ModelRequest.t()) ::
          {:ok, ModelResponse.t(), binary()} | {:error, ProviderError.t()}
  def respond_with_transcript(%Config{} = config, %ModelRequest{} = request) do
    execute(config, request)
  end

  defp execute(config, request) do
    with {:ok, body} <- Codec.encode_request(request),
         {:ok, response} <-
           Transport.post_stream(config.endpoint, headers(config), body, config.timeout_ms) do
      handle_response(response)
    else
      {:error, reason} when reason in [:timeout, :transport, :too_large] ->
        transport_error(reason)

      {:error, %ProviderError{} = error} ->
        {:error, error}
    end
  end

  defp handle_response(%Transport.Response{status: status, body: body, chunks: chunks})
       when status in 200..299 do
    stream = Enum.reduce(chunks, Codec.new_stream(), &Codec.feed(&2, &1))

    case Codec.finish(stream) do
      {:ok, response} -> {:ok, response, body}
      error -> error
    end
  end

  defp handle_response(%Transport.Response{status: status, body: body}),
    do: response_error(status, body)

  defp headers(config) do
    [
      {"authorization", "Bearer " <> config.access_token},
      {"chatgpt-account-id", config.account_id},
      {"openai-beta", "responses=experimental"},
      {"originator", "kogen"},
      {"accept", "text/event-stream"},
      {"user-agent", "kogen/0.1"}
    ]
  end

  defp valid_config?(config) do
    is_binary(config.access_token) and config.access_token != "" and
      is_binary(config.account_id) and config.account_id != "" and
      is_binary(config.endpoint) and is_integer(config.timeout_ms) and config.timeout_ms > 0
  end

  defp response_error(401, _body), do: provider_error(:login, "ChatGPT rejected the Codex login.")

  defp response_error(status, body) do
    cond do
      status == 429 or usage_limit_body?(body) ->
        provider_error(:usage_limit, "ChatGPT subscription usage limit reached.")

      status in 500..599 or overloaded_body?(body) ->
        provider_error(:overload, "ChatGPT service is temporarily overloaded.")

      status in 200..299 ->
        provider_error(:malformed, "ChatGPT returned a malformed response stream.")

      true ->
        provider_error(:malformed, "ChatGPT rejected the request (HTTP #{status}).")
    end
  end

  defp usage_limit_body?(body) do
    body = normalized_error_body(body)

    Enum.any?(
      ["subscription_sharing_usage_limit_exceeded", "usage_limit", "usage limit"],
      &String.contains?(body, &1)
    )
  end

  defp overloaded_body?(body) do
    body = normalized_error_body(body)
    Enum.any?(["server_is_overloaded", "overloaded", "overload"], &String.contains?(body, &1))
  end

  defp normalized_error_body(body) do
    if String.valid?(body), do: String.downcase(body), else: ""
  end

  defp transport_error(:timeout), do: provider_error(:timeout, "ChatGPT request timed out.")

  defp transport_error(:too_large),
    do: provider_error(:malformed, "ChatGPT response stream exceeded the size limit.")

  defp transport_error(:transport),
    do: provider_error(:transport, "ChatGPT request could not connect.")

  defp provider_error(class, message),
    do: {:error, %ProviderError{class: class, message: message}}

  defp login_error, do: provider_error(:login, "Codex login path is invalid.")
end

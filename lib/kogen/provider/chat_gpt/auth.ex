defmodule Kogen.Provider.ChatGPT.Auth do
  @moduledoc false

  alias Kogen.Contracts.ProviderError

  defmodule Credentials do
    @moduledoc false
    @derive {Inspect, except: [:access_token, :account_id]}
    @enforce_keys [:access_token, :account_id]
    defstruct @enforce_keys

    @type t :: %__MODULE__{access_token: String.t(), account_id: String.t()}
  end

  @typep credential_result :: {:ok, Credentials.t()} | {:error, ProviderError.t()}

  @spec load(Path.t()) :: credential_result()
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> decode_credentials(contents)
      {:error, _reason} -> login_error()
    end
  end

  @spec load(term()) :: credential_result()
  def load(_path), do: login_error()

  defp decode_credentials(contents) do
    with {:ok, %{"tokens" => tokens}} <- decode_object(contents),
         %{"access_token" => access_token, "account_id" => account_id} <- tokens,
         true <- valid_credentials?(access_token, account_id),
         :ok <- token_not_expired(access_token) do
      {:ok, %Credentials{access_token: access_token, account_id: account_id}}
    else
      _ -> login_error()
    end
  end

  defp decode_object(contents) do
    case :json.decode(contents) do
      object when is_map(object) -> {:ok, object}
      _ -> {:error, :invalid_json}
    end
  rescue
    ErlangError -> {:error, :invalid_json}
  end

  defp valid_credentials?(access_token, account_id) do
    is_binary(access_token) and access_token != "" and is_binary(account_id) and account_id != ""
  end

  defp token_not_expired(token) do
    with [_, payload, _] <- String.split(token, "."),
         {:ok, decoded_payload} <- Base.url_decode64(payload, padding: false),
         %{"exp" => expiry} when is_integer(expiry) <- decode_payload(decoded_payload) do
      if expiry > :erlang.system_time(:second), do: :ok, else: {:error, :expired}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp decode_payload(payload) do
    :json.decode(payload)
  rescue
    ErlangError -> nil
  end

  defp login_error do
    {:error,
     %ProviderError{class: :login, message: "Codex login is missing, invalid, or expired."}}
  end
end

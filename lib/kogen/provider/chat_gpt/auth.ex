defmodule Kogen.Provider.ChatGPT.Auth do
  @moduledoc false

  alias Kogen.Contracts.ProviderError
  alias Kogen.Provider.ChatGPT.Codec

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
      {:ok, contents} -> credentials(contents)
      {:error, _reason} -> login_error()
    end
  end

  @spec load(term()) :: credential_result()
  def load(_path), do: login_error()

  defp credentials(contents) do
    case Codec.decode_credentials(contents) do
      {:ok, {access_token, account_id}} ->
        {:ok, %Credentials{access_token: access_token, account_id: account_id}}

      {:error, %ProviderError{} = error} ->
        {:error, error}
    end
  end

  defp login_error do
    {:error,
     %ProviderError{class: :login, message: "Codex login is missing, invalid, or expired."}}
  end
end

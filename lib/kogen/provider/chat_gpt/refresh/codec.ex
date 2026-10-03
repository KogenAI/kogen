defmodule Kogen.Provider.ChatGPT.Refresh.TokenResponse do
  @moduledoc false

  @enforce_keys [:access_token, :expires_in]
  defstruct [:access_token, :expires_in, :refresh_token, :id_token, :scopes]

  @type t :: %__MODULE__{
          access_token: String.t(),
          expires_in: pos_integer(),
          refresh_token: String.t() | nil,
          id_token: String.t() | nil,
          scopes: [String.t()] | nil
        }
end

defmodule Kogen.Provider.ChatGPT.Refresh.Codec do
  @moduledoc false

  alias Kogen.Provider.ChatGPT.Refresh.TokenResponse

  @spec decode(binary()) :: {:ok, TokenResponse.t()} | {:error, :invalid_refresh_response}
  def decode(body) when is_binary(body) do
    with response when is_map(response) <- :json.decode(body),
         access_token when is_binary(access_token) and access_token != "" <-
           response["access_token"],
         expires_in when is_integer(expires_in) and expires_in > 0 <- response["expires_in"],
         {:ok, refresh_token} <- optional_token(response, "refresh_token"),
         {:ok, id_token} <- optional_token(response, "id_token") do
      {:ok,
       %TokenResponse{
         access_token: access_token,
         expires_in: expires_in,
         refresh_token: refresh_token,
         id_token: id_token,
         scopes: scope_list(response["scope"])
       }}
    else
      _invalid -> {:error, :invalid_refresh_response}
    end
  rescue
    ArgumentError -> {:error, :invalid_refresh_response}
    ErlangError -> {:error, :invalid_refresh_response}
  end

  defp optional_token(response, key) do
    case response[key] do
      nil -> {:ok, nil}
      token when is_binary(token) and token != "" -> {:ok, token}
      _invalid -> {:error, :invalid_refresh_response}
    end
  end

  defp scope_list(scope) when is_binary(scope),
    do: scope |> String.split() |> Enum.uniq() |> Enum.sort()

  defp scope_list(scopes) when is_list(scopes),
    do: scopes |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.sort()

  defp scope_list(_scope), do: nil
end

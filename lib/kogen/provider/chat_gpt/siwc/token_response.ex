defmodule Kogen.Provider.ChatGPT.SIWC.TokenResponse do
  @moduledoc false

  @enforce_keys [:access_token, :refresh_token, :id_token, :expires_in, :scopes]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          access_token: String.t(),
          refresh_token: String.t(),
          id_token: String.t(),
          expires_in: pos_integer(),
          scopes: [String.t()]
        }

  @spec decode(binary()) :: {:ok, t()} | {:error, :invalid_token_response}
  def decode(body) when is_binary(body) do
    with response when is_map(response) <- :json.decode(body),
         access_token when is_binary(access_token) and access_token != "" <-
           response["access_token"],
         refresh_token when is_binary(refresh_token) and refresh_token != "" <-
           response["refresh_token"],
         id_token when is_binary(id_token) and id_token != "" <- response["id_token"],
         expires_in when is_integer(expires_in) and expires_in > 0 <- response["expires_in"] do
      scopes = scope_list(response["scope"])

      {:ok,
       %__MODULE__{
         access_token: access_token,
         refresh_token: refresh_token,
         id_token: id_token,
         expires_in: expires_in,
         scopes: scopes
       }}
    else
      _invalid -> {:error, :invalid_token_response}
    end
  rescue
    ArgumentError -> {:error, :invalid_token_response}
    ErlangError -> {:error, :invalid_token_response}
  end

  defp scope_list(scope) when is_binary(scope),
    do: scope |> String.split() |> Enum.uniq() |> Enum.sort()

  defp scope_list(scopes) when is_list(scopes),
    do: scopes |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.sort()

  defp scope_list(_scope), do: []
end

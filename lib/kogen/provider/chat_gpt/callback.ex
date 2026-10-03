defmodule Kogen.Provider.ChatGPT.Callback do
  @moduledoc false

  @spec validate(binary(), String.t(), :registration | :reauthorization) ::
          {:ok, map()} | {:error, atom()}
  def validate(query, expected_state, mode) when is_binary(query) and is_binary(expected_state) do
    with {:ok, params} <- decode(query),
         :ok <- validate_state(params, expected_state),
         :ok <- validate_oauth_error(params),
         code when is_binary(code) and code != "" <- Map.get(params, "code"),
         {:ok, client_id} <- callback_client_id(Map.get(params, "client_id"), mode) do
      {:ok, %{code: code, client_id: client_id, scope: Map.get(params, "scope")}}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :missing_code}
    end
  end

  def validate(_query, _expected_state, _mode), do: {:error, :malformed_callback}

  defp decode(query) do
    {:ok, URI.decode_query(query)}
  rescue
    ArgumentError -> {:error, :malformed_callback}
  end

  defp validate_state(%{"state" => state}, expected_state) when state == expected_state, do: :ok
  defp validate_state(_params, _expected_state), do: {:error, :state_mismatch}

  defp validate_oauth_error(%{"error" => error}) when is_binary(error),
    do: {:error, {:authorization_failed, error}}

  defp validate_oauth_error(_params), do: :ok

  defp callback_client_id(nil, :reauthorization), do: {:ok, nil}

  defp callback_client_id(client_id, _mode)
       when is_binary(client_id) and client_id != "" and client_id != "dynamic_agent_client",
       do: {:ok, client_id}

  defp callback_client_id(_client_id, :registration), do: {:error, :registration_incomplete}
  defp callback_client_id(_client_id, :reauthorization), do: {:error, :client_id_mismatch}
end

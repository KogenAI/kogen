defmodule Kogen.Provider.ChatGPT.PKCE do
  @moduledoc false

  @spec generate() :: %{verifier: String.t(), challenge: String.t()}
  def generate do
    verifier = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    %{verifier: verifier, challenge: challenge(verifier)}
  end

  @spec challenge(String.t()) :: String.t()
  def challenge(verifier) when is_binary(verifier) do
    verifier |> then(&:crypto.hash(:sha256, &1)) |> Base.url_encode64(padding: false)
  end
end

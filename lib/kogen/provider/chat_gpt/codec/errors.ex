defmodule Kogen.Provider.ChatGPT.Codec.Errors do
  @moduledoc false

  alias Kogen.Contracts.ProviderError

  @messages %{
    usage_limit: "ChatGPT subscription usage limit reached.",
    overload: "ChatGPT service is temporarily overloaded.",
    transport: "ChatGPT stream reported a provider error.",
    malformed: "ChatGPT returned a malformed response stream."
  }

  @type class :: :usage_limit | :overload | :transport | :malformed

  @spec provider(class()) :: ProviderError.t()
  def provider(class), do: %ProviderError{class: class, message: @messages[class]}

  @spec malformed() :: {:error, ProviderError.t()}
  def malformed, do: {:error, provider(:malformed)}

  @spec login() :: {:error, ProviderError.t()}
  def login,
    do:
      {:error,
       %ProviderError{class: :login, message: "Codex login is missing, invalid, or expired."}}

  @spec recording(String.t()) :: {:error, ProviderError.t()}
  def recording(message), do: {:error, %ProviderError{class: :malformed, message: message}}
end

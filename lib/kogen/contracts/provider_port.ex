defmodule Kogen.Contracts.ProviderPort do
  @moduledoc "Behaviour for one provider-neutral model response."

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ProviderError

  @callback respond(ModelRequest.t()) :: {:ok, ModelResponse.t()} | {:error, ProviderError.t()}
end

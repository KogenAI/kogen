defmodule Kogen.Contracts.ProviderPort do
  @moduledoc """
  Behaviour for one provider-neutral model response.

  The first argument is the provider's own explicit configuration (credentials,
  endpoint), built by the Kernel; providers never discover it ambiently.
  """

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ProviderError

  @callback respond(config :: term(), ModelRequest.t()) ::
              {:ok, ModelResponse.t()} | {:error, ProviderError.t()}
end

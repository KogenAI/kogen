defmodule Kogen.Contracts.ProviderError do
  @moduledoc "A classified, recoverable error returned by a model provider."

  @enforce_keys [:class, :message]
  defstruct @enforce_keys

  @type class :: :login | :usage_limit | :overload | :timeout | :malformed | :transport
  @type t :: %__MODULE__{class: class(), message: String.t()}
end

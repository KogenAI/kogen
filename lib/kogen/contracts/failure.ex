defmodule Kogen.Contracts.Failure do
  @moduledoc "A typed build failure and the short reason used by controllers."

  @enforce_keys [:class, :reason, :detail]
  defstruct @enforce_keys

  @type class :: :candidate | :environment | :provider | :controller
  @type t :: %__MODULE__{class: class(), reason: atom(), detail: String.t()}
end

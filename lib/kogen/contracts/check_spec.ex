defmodule Kogen.Contracts.CheckSpec do
  @moduledoc "An argv-based deterministic project check."

  @enforce_keys [:name, :argv, :timeout_ms]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          argv: [String.t()],
          timeout_ms: pos_integer()
        }
end

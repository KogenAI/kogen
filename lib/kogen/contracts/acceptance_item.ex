defmodule Kogen.Contracts.AcceptanceItem do
  @moduledoc "One verifiable acceptance criterion in an Intent."

  @enforce_keys [:id, :text, :verify, :domain]
  defstruct @enforce_keys

  @type verify :: :test | :test_keep | :example | :check
  @type t :: %__MODULE__{
          id: String.t(),
          text: String.t(),
          verify: verify(),
          domain: String.t() | nil
        }
end

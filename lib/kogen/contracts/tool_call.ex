defmodule Kogen.Contracts.ToolCall do
  @moduledoc "A tool invocation requested by a model response."

  @enforce_keys [:id, :name, :arguments]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          arguments: map()
        }
end

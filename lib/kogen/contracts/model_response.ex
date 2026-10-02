defmodule Kogen.Contracts.ModelResponse do
  @moduledoc "A provider-neutral response from a language model."

  alias Kogen.Contracts.ToolCall

  @enforce_keys [:id, :text, :tool_calls, :usage, :raw_items]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          text: String.t(),
          tool_calls: [ToolCall.t()],
          usage: map(),
          raw_items: list()
        }
end

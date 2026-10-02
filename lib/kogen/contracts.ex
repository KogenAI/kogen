defmodule Kogen.Contracts do
  @moduledoc "Shared data structures and behaviours used at Kogen's domain boundaries."
  use Boundary,
    deps: [],
    exports: [
      AcceptanceItem,
      CheckSpec,
      Failure,
      Intent,
      ModelRequest,
      ModelResponse,
      ProcPort,
      ProcResult,
      Project,
      ProviderError,
      ProviderPort,
      Receipt,
      ToolCall
    ]
end

defmodule Kogen.Harness do
  @moduledoc "Coordinates provider-backed Developer sessions and tool interactions."
  use Boundary,
    deps: [Kogen.Contracts, Kogen.Proc, Kogen.Provider, Kogen.Project],
    exports: []
end

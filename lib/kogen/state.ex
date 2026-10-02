defmodule Kogen.State do
  @moduledoc "Persists build progress, state transitions, and verification receipts."
  use Boundary, deps: [Kogen.Contracts, Kogen.Workspace], exports: []
end

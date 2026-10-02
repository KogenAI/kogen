defmodule Kogen.Workspace do
  @moduledoc "Creates and maintains isolated project checkouts and worktrees."
  use Boundary, deps: [Kogen.Contracts, Kogen.Proc], exports: []
end

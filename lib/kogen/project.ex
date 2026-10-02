defmodule Kogen.Project do
  @moduledoc "Loads and validates project configuration, checks, and domain paths."
  use Boundary, deps: [Kogen.Contracts], exports: []
end

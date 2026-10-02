defmodule Kogen.Build do
  @moduledoc "Runs the Developer loop and manages a candidate build lifecycle."
  use Boundary, deps: [Kogen.Contracts], exports: []
end

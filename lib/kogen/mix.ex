defmodule Kogen.Mix do
  @moduledoc "Boundary for repository Mix tasks and development-time tooling."
  use Boundary, deps: [Mix], exports: []
end

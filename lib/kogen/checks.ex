defmodule Kogen.Checks do
  @moduledoc "Runs deterministic project verification and records its results."
  use Boundary,
    deps: [Kogen.Contracts, Kogen.Proc, Kogen.Workspace, Kogen.Project],
    exports: []
end

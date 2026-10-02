defmodule Kogen.Kernel do
  @moduledoc "Coordinates Kogen domains and exposes the command-line entry point."
  use Boundary,
    deps: [
      Kogen.Contracts,
      Kogen.Proc,
      Kogen.Project,
      Kogen.Intent,
      Kogen.Provider,
      Kogen.Build,
      Kogen.Workspace,
      Kogen.State,
      Kogen.Checks,
      Kogen.Harness
    ],
    exports: [CLI]
end

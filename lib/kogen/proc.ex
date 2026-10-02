defmodule Kogen.Proc do
  @moduledoc "Runs bounded operating-system processes through the ProcPort contract."
  use Boundary, deps: [Kogen.Contracts], exports: []
end

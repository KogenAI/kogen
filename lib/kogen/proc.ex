defmodule Kogen.Proc do
  @moduledoc """
  Runs bounded operating-system processes through the ProcPort contract.

  `env:` is the complete explicit child environment supplied by Kernel plus call-specific values.
  The runner never reads the BEAM environment. The `ROOTDIR`, `BINDIR`, `ESCRIPT`, `ESCRIPT_DIR`,
  `KOGEN_ERTS_DIR`, `KOGEN_ERTS_BIN`, `KOGEN_ESCRIPT_DIR`, and `KOGEN_BIN_DIR` markers are
  consumed to scrub Kogen paths from `PATH` and omitted from the child environment.
  """
  @behaviour Kogen.Contracts.ProcPort

  use Boundary, deps: [Kogen.Contracts], exports: [Sandbox]

  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc.Request
  alias Kogen.Proc.Runner

  @spec run([String.t()], keyword()) :: {:ok, ProcResult.t()} | {:error, term()}
  @impl Kogen.Contracts.ProcPort
  def run(argv, opts) do
    with {:ok, request} <- Request.new(argv, opts) do
      Runner.run(request)
    end
  end
end

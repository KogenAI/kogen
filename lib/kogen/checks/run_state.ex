defmodule Kogen.Checks.RunState do
  @moduledoc false

  @enforce_keys [:workdir, :run_dir, :env, :tree]
  defstruct [:workdir, :run_dir, :env, :tree, index: 1, receipts: [], failures: []]

  @type t :: %__MODULE__{
          workdir: Path.t(),
          run_dir: Path.t(),
          env: %{String.t() => String.t()},
          tree: String.t(),
          index: pos_integer(),
          receipts: [Kogen.Contracts.Receipt.t()],
          failures: [String.t()]
        }
end

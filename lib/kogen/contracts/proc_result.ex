defmodule Kogen.Contracts.ProcResult do
  @moduledoc "The bounded outcome and captured output from one process call."

  @enforce_keys [:argv, :exit_status, :timed_out, :output_tail, :log_path, :duration_ms]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          argv: [String.t()],
          exit_status: integer() | nil,
          timed_out: boolean(),
          output_tail: binary(),
          log_path: Path.t() | nil,
          duration_ms: non_neg_integer()
        }
end

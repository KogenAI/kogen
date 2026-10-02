defmodule Kogen.Contracts.ProcPort do
  @moduledoc """
  Behaviour for bounded operating-system process execution.

  Supported options are `cd:`, `env:`, `timeout_ms:`, and `log_path:`.
  """

  alias Kogen.Contracts.ProcResult

  @type option ::
          {:cd, Path.t()}
          | {:env, map()}
          | {:timeout_ms, non_neg_integer()}
          | {:log_path, Path.t()}
  @type opts :: [option()]

  @callback run([String.t()], keyword()) :: {:ok, ProcResult.t()} | {:error, term()}
end

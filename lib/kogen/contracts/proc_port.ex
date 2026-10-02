defmodule Kogen.Contracts.ProcPort do
  @moduledoc """
  Behaviour for bounded operating-system process execution.

  Supported options are `cd:` (required), `env:`, `timeout_ms:`, `log_path:`, and
  `stdin:` (`nil`, `{:binary, iodata}` or `{:file, path}`). Content never travels in argv.
  """

  alias Kogen.Contracts.ProcResult

  @type option ::
          {:cd, Path.t()}
          | {:env, map()}
          | {:timeout_ms, non_neg_integer()}
          | {:log_path, Path.t()}
          | {:stdin, nil | {:binary, iodata()} | {:file, Path.t()}}
  @type opts :: [option()]

  @callback run([String.t()], keyword()) :: {:ok, ProcResult.t()} | {:error, term()}
end

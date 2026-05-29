defmodule CodegenTestHarness.BenchCommon do
  @moduledoc """
  Shared helpers used by multiple benchmark modules.
  """

  @doc "Returns the active harness name from the HARNESS env var (default: \"claude\")."
  @spec detect_harness() :: String.t()
  def detect_harness do
    System.get_env("HARNESS") || "claude"
  end
end

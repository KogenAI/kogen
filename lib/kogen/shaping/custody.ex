defmodule Kogen.Shaping.Custody do
  @moduledoc false

  alias Kogen.{ProcessCustody, ShapingAudit.Lock}

  @guard_wait_ms 30_000

  @doc false
  def acquire(control), do: guarded(control, fn -> ProcessCustody.acquire(control) end)

  @doc false
  def teardown(control),
    do: guarded(control, fn -> ProcessCustody.teardown(control) end)

  @doc false
  def release(control),
    do: guarded(control, fn -> ProcessCustody.release(control) end)

  # Shaping uses ProcessCustody's existing result types so callers retain the
  # same success and failure handling while independent BEAMs share one guard.
  defp guarded(control, fun) do
    case Lock.with_lock(ProcessCustody.lock_path(control), @guard_wait_ms, fun) do
      {:ok, result} -> result
      {:error, :busy} -> {:error, "build custody operation already in progress"}
    end
  end
end

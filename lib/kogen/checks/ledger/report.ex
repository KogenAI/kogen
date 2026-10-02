defmodule Kogen.Checks.Ledger.Report do
  @moduledoc false

  alias Kogen.Checks.LedgerCodec
  alias Kogen.Checks.LedgerRow
  alias Kogen.Contracts.Failure

  @spec read(Path.t()) :: {:ok, [LedgerRow.t()]} | {:error, Failure.t()}
  def read(path) do
    with {:ok, contents} <- File.read(path),
         true <- String.trim(contents) != "",
         {:ok, rows} <- decode_rows(contents) do
      {:ok, rows}
    else
      {:error, :enoent} ->
        {:error, failure(:environment, :ledger_missing, "acceptance formatter report is missing")}

      {:error, :invalid_row} ->
        {:error,
         failure(:environment, :ledger_invalid, "acceptance formatter report is malformed")}

      false ->
        {:error, failure(:environment, :ledger_empty, "acceptance formatter report is empty")}

      {:error, reason} ->
        {:error, failure(:environment, :ledger_read, inspect(reason))}
    end
  end

  defp decode_rows(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, rows} ->
      case LedgerCodec.decode(line) do
        {:ok, row} -> {:cont, {:ok, [row | rows]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp failure(class, reason, detail), do: %Failure{class: class, reason: reason, detail: detail}
end

defmodule Kogen.Check.MakeInventory do
  @moduledoc """
  The small, deliberately conservative Makefile rule inventory used by all
  target admission code.

  Only explicit target rules are inventoried.  Special declarations such as
  `.PHONY` and variable assignments are not targets.  GNU make's grouped
  target separator (`&:`) is supported; double-colon and pattern rules are
  rejected because their semantics cannot safely be represented by this
  inventory.
  """

  @target_name ~r/^[A-Za-z0-9_.-]+$/

  @spec load(Path.t()) :: {:ok, MapSet.t(String.t())} | {:error, String.t()}
  def load(path) do
    case File.read(path) do
      {:ok, bytes} -> parse(bytes)
      {:error, reason} -> {:error, "could not read Makefile: #{:file.format_error(reason)}"}
    end
  end

  @spec parse(String.t()) :: {:ok, MapSet.t(String.t())} | {:error, String.t()}
  def parse(bytes) when is_binary(bytes) do
    bytes
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {line, line_number}, {:ok, targets} ->
      case parse_line(line, line_number) do
        :skip -> {:cont, {:ok, targets}}
        {:ok, names} -> {:cont, {:ok, Enum.reduce(names, targets, &MapSet.put(&2, &1))}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def parse(_), do: {:error, "Makefile must be a string"}

  @doc "Returns the inventory, or an empty set when the Makefile is absent/invalid."
  @spec declared_targets(Path.t()) :: MapSet.t(String.t())
  def declared_targets(path) do
    case load(path) do
      {:ok, targets} -> targets
      _ -> MapSet.new()
    end
  end

  defp parse_line(line, line_number) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") or String.starts_with?(line, "\t") ->
        :skip

      Regex.match?(~r/^[^:#]+(?:\?|\+|:)?=/, trimmed) ->
        :skip

      true ->
        parse_rule(trimmed, line_number)
    end
  end

  defp parse_rule(line, line_number) do
    case Regex.run(~r/^(.+?)\s*(::|&:|:)\s*(?:.*)$/, line, capture: :all_but_first) do
      nil ->
        :skip

      [_raw_names, "::"] ->
        {:error, "double-colon Make rule at line #{line_number} is unsupported"}

      [raw_names, _separator] ->
        validate_names(raw_names, line_number)
    end
  end

  defp validate_names(raw_names, line_number) do
    names = String.split(raw_names, ~r/\s+/, trim: true)

    cond do
      names == [] ->
        {:error, "Make rule has no target at line #{line_number}"}

      ".PHONY" in names ->
        :skip

      Enum.any?(names, &String.contains?(&1, "%")) ->
        {:error, "pattern Make rule at line #{line_number} is unsupported"}

      Enum.any?(names, &(not Regex.match?(@target_name, &1))) ->
        {:error, "unsafe Make target at line #{line_number}"}

      true ->
        {:ok, names}
    end
  end
end

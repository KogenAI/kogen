defmodule Kogen.Check.MakeInventory do
  @moduledoc """
  The small, deliberately conservative Makefile rule inventory used by all
  target admission code.

  Only explicit target rules are inventoried. Special declarations such as
  `.PHONY` and variable assignments are not targets. GNU make's grouped
  target separator (`&:`) is supported and treated as ordinary. Double-colon
  and pattern rules are never added to the ordinary target set — their
  semantics cannot safely be represented by this inventory's simple
  membership check — but they are not refused outright either: a project's
  own helper rules (`fmt:`, `%.txt: ;`, and so on) are its business. They are
  collected separately as `unsupported`, so a caller that also knows the
  verification-target catalog (`Kogen.Build.VerificationPlan`) can refuse
  only the ones that could define or shadow a catalog target name, naming
  both the rule and the target.
  """

  @target_name ~r/^[A-Za-z0-9_.-]+$/

  @type inventory :: %{
          targets: MapSet.t(String.t()),
          unsupported: [
            %{kind: :double_colon | :pattern, names: [String.t()], line: pos_integer()}
          ]
        }

  @spec load(Path.t()) :: {:ok, inventory()} | {:error, String.t()}
  def load(path) do
    case File.read(path) do
      {:ok, bytes} -> parse(bytes)
      {:error, reason} -> {:error, "could not read Makefile: #{:file.format_error(reason)}"}
    end
  end

  @spec parse(String.t()) :: {:ok, inventory()} | {:error, String.t()}
  def parse(bytes) when is_binary(bytes) do
    bytes
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{targets: MapSet.new(), unsupported: []}}, fn {line, line_number},
                                                                              {:ok, acc} ->
      case parse_line(line, line_number) do
        :skip ->
          {:cont, {:ok, acc}}

        {:ok, :ordinary, names} ->
          targets = Enum.reduce(names, acc.targets, &MapSet.put(&2, &1))
          {:cont, {:ok, %{acc | targets: targets}}}

        {:ok, kind, names, line_number} when kind in [:double_colon, :pattern] ->
          entry = %{kind: kind, names: names, line: line_number}
          {:cont, {:ok, %{acc | unsupported: [entry | acc.unsupported]}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, %{acc | unsupported: Enum.reverse(acc.unsupported)}}
      error -> error
    end
  end

  def parse(_), do: {:error, "Makefile must be a string"}

  @doc "Returns the ordinary (single-colon) target inventory, or empty when the Makefile is absent/invalid."
  @spec declared_targets(Path.t()) :: MapSet.t(String.t())
  def declared_targets(path) do
    case load(path) do
      {:ok, %{targets: targets}} -> targets
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

      [raw_names, "::"] ->
        classify(raw_names, line_number, :double_colon)

      [raw_names, _separator] ->
        classify(raw_names, line_number, :ordinary)
    end
  end

  defp classify(raw_names, line_number, default_kind) do
    names = String.split(raw_names, ~r/\s+/, trim: true)

    cond do
      names == [] ->
        {:error, "Make rule has no target at line #{line_number}"}

      ".PHONY" in names ->
        :skip

      Enum.any?(names, &String.contains?(&1, "%")) ->
        {:ok, :pattern, names, line_number}

      Enum.any?(names, &(not Regex.match?(@target_name, &1))) ->
        {:error, "unsafe Make target at line #{line_number}"}

      default_kind == :ordinary ->
        {:ok, :ordinary, names}

      true ->
        {:ok, :double_colon, names, line_number}
    end
  end
end

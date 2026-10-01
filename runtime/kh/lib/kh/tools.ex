defmodule Kh.Tools do
  @moduledoc """
  Tool registry. Baseline (pi-equivalent): read, write, edit, bash.
  ctx: %{cwd, deadline, features (MapSet), tmp_dir}
  """
  alias Kh.Tools.{Read, Write, Edit, Bash}

  @baseline [Read, Write, Edit, Bash]

  def all_names(features), do: Enum.map(modules(features), & &1.spec().name)

  def modules(_features), do: @baseline

  def specs(features, only \\ nil) do
    modules(features)
    |> Enum.map(& &1.spec())
    |> Enum.filter(&(only == nil or &1.name in only))
  end

  @doc "-> {:ok, text} | {:error, text}"
  def run(name, args, ctx, only \\ nil) do
    case Enum.find(modules(ctx.features), &(&1.spec().name == name)) do
      nil ->
        {:error, "Unknown tool: #{name}"}

      mod ->
        if only != nil and name not in only do
          {:error, "Tool #{name} is disabled"}
        else
          try do
            case mod.run(args, ctx) do
              {:ok, t} -> {:ok, Kh.Util.utf8(t)}
              {:error, t} -> {:error, Kh.Util.utf8(t)}
            end
          rescue
            e -> {:error, "Tool #{name} crashed: " <> Exception.message(e)}
          end
        end
    end
  end
end
